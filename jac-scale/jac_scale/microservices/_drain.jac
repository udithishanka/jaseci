"""Graceful drain state for services and gateway (ROADMAP P13).

Drain is a two-phase state triggered by SIGTERM:

  Phase 1 - draining
    `_is_draining` flips True. A FastAPI middleware consults this on
    every request and returns 503 (with the standard error envelope +
    `Retry-After: 2`) for any new request arriving on an existing
    keep-alive connection. In-flight requests that were already in
    their handler keep going - they're counted in `_inflight` and the
    drainer waits for that to reach 0 before letting the process exit.

  Phase 2 - uvicorn graceful shutdown
    Uvicorn stops accepting new TCP connections and waits for active
    connections to close, bounded by `timeout_graceful_shutdown`. The
    503 middleware makes that wait safe to cut short: by the time
    uvicorn gives up, we know no new request is still expecting a
    real response.

K8s parallel:
  kubelet sends SIGTERM at pod termination then gives us
  `terminationGracePeriodSeconds` before SIGKILL. Same drain
  semantics; only the signal source differs. The Service endpoints
  controller takes a few seconds to observe the pod as terminating,
  during which the Service keeps routing new connections to us - the
  503 + Retry-After is load-bearing for exactly that window.

Why not rely on uvicorn's own graceful shutdown?
  Uvicorn stops accepting new *connections* but clients with existing
  HTTP/1.1 keep-alive (or HTTP/2) connections can send *new requests*
  on those connections. Without the 503 middleware those requests run
  to completion, delaying shutdown. With it, we fail fast and let the
  client retry against the replacement pod.

State is module-level so `import from jac_scale.microservices._drain`
always yields the same snapshot within a process - which is what we
want since there's exactly one uvicorn process per service/gateway.
"""

import logging;
import threading;
import time;
import from typing { Any }
import from threading { Lock as _DrainLock }

glob logger = logging.getLogger(__name__);

# _zero_event starts pre-set because inflight starts at 0. It's cleared
# on each incr when inflight becomes > 0 and set again when inflight
# returns to 0. threading.Event() defaults to not-set, so we build it
# in a helper to keep the initial-set semantics encapsulated.
def _make_preset_event -> threading.Event {
    ev = threading.Event();
    ev.set();
    return ev;
}

glob _is_draining: bool = False,
     _drain_started_ts: float | None = None,
     _drain_timeout_s: float = 10.0,
     _inflight: int = 0,
     _drain_lock = _DrainLock(),
     _zero_event: threading.Event = _make_preset_event();


"""Whether drain has been triggered in this process."""
def is_draining -> bool {
    return _is_draining;
}


"""Timestamp drain started, or None if not draining. For logging + tests."""
def drain_started_ts -> float | None {
    return _drain_started_ts;
}


"""Configured drain timeout in seconds."""
def drain_timeout_s -> float {
    return _drain_timeout_s;
}


"""Current in-flight request count (for tests + logging)."""
def inflight -> int {
    with _drain_lock {
        return _inflight;
    }
}


"""Begin the drain. Idempotent - second call is a no-op so signal
handlers can be re-entrantly safe."""
def start_drain(timeout_s: float | None = None) -> None {
    global _is_draining, _drain_started_ts, _drain_timeout_s;
    with _drain_lock {
        if _is_draining {
            return;
        }
        _is_draining = True;
        _drain_started_ts = time.time();
        if timeout_s is not None {
            _drain_timeout_s = timeout_s;
        }
        current_inflight = _inflight;
    }
    logger.warning(
        f"drain: started (timeout={_drain_timeout_s}s, inflight={current_inflight})"
    );
}


"""Increment in-flight counter. Called by drain middleware on request entry."""
def incr_inflight -> int {
    global _inflight;
    with _drain_lock {
        _inflight += 1;
        _zero_event.clear();
        return _inflight;
    }
}


"""Decrement in-flight counter. Called by drain middleware on request exit.
Releases `_zero_event` when the counter hits 0."""
def decr_inflight -> int {
    global _inflight;
    with _drain_lock {
        if _inflight > 0 {
            _inflight -= 1;
        }
        if _inflight == 0 {
            _zero_event.set();
        }
        return _inflight;
    }
}


"""Block until in-flight reaches 0 or the configured timeout elapses.
Returns True if cleanly drained, False if the timeout fired. Uses
threading.Event so it's safe from signal-handler downstream paths."""
def wait_for_zero(timeout_s: float | None = None) -> bool {
    t = timeout_s if timeout_s is not None else _drain_timeout_s;
    return _zero_event.wait(timeout=t);
}


"""Reset for tests. Never call from production paths."""
def reset_drain -> None {
    global _is_draining, _drain_started_ts, _inflight;
    with _drain_lock {
        _is_draining = False;
        _drain_started_ts = None;
        _inflight = 0;
        _zero_event.set();
    }
}


"""Build the FastAPI HTTP middleware that enforces drain 503s + inflight
accounting.

Returned as a closure so callers pick the service label embedded in
the error envelope ("__gateway__" for the gateway, service name for
jfast). Signature matches FastAPI's `app.middleware('http')` contract.
"""
def build_drain_middleware(service_label: str = "service") -> Any {
    import from jac_scale.microservices._errors { service_unavailable }

    async def drain_middleware(request: Any, call_next: Any) -> Any {
        # Fast path: not draining, just count in-flight so a drain
        # that starts mid-request can still observe us and wait.
        if not _is_draining {
            incr_inflight();
            try {
                response = await call_next(request);
                return response;
            } finally {
                decr_inflight();
            }
        }
        # Drain is live. Reject new requests with the standard 503 +
        # Retry-After envelope. Don't incr inflight - this request
        # never enters real processing.
        return service_unavailable(service_label, "draining");
    }

    return drain_middleware;
}


"""Install a SIGTERM/SIGINT handler on a uvicorn.Server that flips the
drain flag before uvicorn's own exit handler runs.

Call this AFTER constructing the Server but BEFORE `server.run()`.
The hook chains: our wrapper -> uvicorn's original handle_exit.
Uvicorn's handler then sets `should_exit=True` which begins the
graceful shutdown in its event loop.

`timeout_s` bounds how long `wait_for_zero` will block; uvicorn's
`timeout_graceful_shutdown` (set independently in Config) bounds how
long the server's own shutdown waits.
"""
def install_signal_drain(server: Any, timeout_s: float = 10.0) -> None {
    global _drain_timeout_s;
    _drain_timeout_s = timeout_s;
    orig_handle_exit = server.handle_exit;

    def wrapped_handle_exit(sig: Any, frame: Any) -> None {
        start_drain(timeout_s);
        orig_handle_exit(sig, frame);
    }

    server.handle_exit = wrapped_handle_exit;
}
