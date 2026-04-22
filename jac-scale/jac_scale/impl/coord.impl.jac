"""Impl of coord primitives. Redis-backed via jac_scale.db.get_redis_client."""

import os;
import time;
import uuid;
import json;
import logging;
import threading;
import from typing { Any, Callable }

# Atomic lock-release Lua script — prevents a caller from accidentally
# releasing a lock held by someone else (happens when TTL expires mid-critical-
# section and another holder has re-acquired before release fires).
glob _RELEASE_LUA: str = (
    "if redis.call('GET', KEYS[1]) == ARGV[1] then "
    "return redis.call('DEL', KEYS[1]) "
    "else return 0 end"
);

# Process-local in-memory pub/sub handler registry. Each jac-scale pod runs
# one subscriber thread that routes messages to registered handlers.
glob _ps_handlers: dict[str, list] = {},
     _ps_thread: (threading.Thread | None) = None,
     _ps_pubsub: Any = None,
     _ps_lock: threading.Lock = threading.Lock(),
     _ps_stop: threading.Event = threading.Event();

impl _prefix(key: str) -> str {
    app = os.environ.get("JAC_APP_NAME", "default");
    return f"jac_coord:{app}:{key}";
}

impl _on_failure_mode -> str {
    return os.environ.get("JAC_COORD_ON_FAILURE", "degrade").lower();
}

"""Get the shared Redis client, or None if unavailable. Logs first failure."""
def _redis_or_none -> Any {
    try {
        import from jac_scale.db { get_redis_client }
        return get_redis_client();
    } except Exception as e {
        _logger.warning(f"Redis unavailable for coord: {e}");
        return None;
    }
}

def _redis_or_fail -> Any {
    r = _redis_or_none();
    if r is None {
        if _on_failure_mode() == "fail" {
            raise CoordUnavailable("Redis unavailable and JAC_COORD_ON_FAILURE=fail");
        }
        return None;
    }
    return r;
}

# -------------------------- Lock ---------------------------

impl acquire_lock(
    key: str, ttl_ms: int = 30000, blocking_timeout_ms: int = 0
) -> tuple {
    r = _redis_or_fail();
    if r is None {
        # degrade: pretend we acquired so callers proceed unlocked
        return (True, "__degraded__");
    }
    pk = _prefix(f"lock:{key}");
    token = str(uuid.uuid4());
    deadline = time.monotonic() + (blocking_timeout_ms / 1000.0);
    while True {
        ok = r.set(pk, token, nx=True, px=ttl_ms);
        if ok {
            return (True, token);
        }
        if blocking_timeout_ms <= 0 or time.monotonic() >= deadline {
            return (False, "");
        }
        time.sleep(0.05);
    }
}

impl release_lock(key: str, token: str) -> bool {
    if token == "__degraded__" or not token {
        return False;
    }
    r = _redis_or_none();
    if r is None {
        return False;
    }
    pk = _prefix(f"lock:{key}");
    try {
        result = r.eval(_RELEASE_LUA, 1, pk, token);
        return bool(result);
    } except Exception as e {
        _logger.warning(f"release_lock({key}) failed: {e}");
        return False;
    }
}

impl distlock(key: str, ttl_ms: int = 30000, timeout_ms: int = 30000) {
    (acquired, token) = acquire_lock(key, ttl_ms=ttl_ms, blocking_timeout_ms=timeout_ms);
    try {
        yield acquired;
    } finally {
        if acquired and token and token != "__degraded__" {
            release_lock(key, token);
        }
    }
}

# -------------------------- KV ---------------------------

impl kv_set(key: str, value: Any, ttl_ms: int = 0) -> bool {
    r = _redis_or_fail();
    if r is None { return False; }
    pk = _prefix(f"kv:{key}");
    try {
        encoded = json.dumps(value);
    } except Exception {
        encoded = str(value);
    }
    try {
        if ttl_ms > 0 {
            return bool(r.set(pk, encoded, px=ttl_ms));
        }
        return bool(r.set(pk, encoded));
    } except Exception as e {
        _logger.warning(f"kv_set({key}) failed: {e}");
        return False;
    }
}

impl kv_get(key: str, fallback: Any = None) -> Any {
    r = _redis_or_none();
    if r is None { return fallback; }
    pk = _prefix(f"kv:{key}");
    try {
        raw = r.get(pk);
        if raw is None { return fallback; }
        if isinstance(raw, bytes) { raw = raw.decode("utf-8"); }
        try {
            return json.loads(raw);
        } except Exception {
            return raw;
        }
    } except Exception as e {
        _logger.warning(f"kv_get({key}) failed: {e}");
        return fallback;
    }
}

impl kv_delete(key: str) -> bool {
    r = _redis_or_none();
    if r is None { return False; }
    pk = _prefix(f"kv:{key}");
    try {
        return bool(r.delete(pk));
    } except Exception as e {
        _logger.warning(f"kv_delete({key}) failed: {e}");
        return False;
    }
}

impl kv_exists(key: str) -> bool {
    r = _redis_or_none();
    if r is None { return False; }
    pk = _prefix(f"kv:{key}");
    try {
        return bool(r.exists(pk));
    } except Exception {
        return False;
    }
}

impl kv_incr(key: str, ttl_ms: int = 0) -> int {
    r = _redis_or_fail();
    if r is None { return 0; }
    pk = _prefix(f"kv:{key}");
    try {
        pipe = r.pipeline();
        pipe.incr(pk);
        if ttl_ms > 0 {
            # Only set TTL on first increment — PEXPIRE NX in newer Redis,
            # but for compatibility we read the existing TTL and only set
            # if none exists.
            pipe.pttl(pk);
        }
        results = pipe.execute();
        value = int(results[0]);
        if ttl_ms > 0 and len(results) > 1 {
            current_ttl = int(results[1]);
            if current_ttl < 0 {
                r.pexpire(pk, ttl_ms);
            }
        }
        return value;
    } except Exception as e {
        _logger.warning(f"kv_incr({key}) failed: {e}");
        return 0;
    }
}

# -------------------------- Pub/Sub ---------------------------

"""Start the background subscriber thread on first subscribe. Idempotent."""
def _ensure_subscriber -> None {
    global _ps_thread, _ps_pubsub, _ps_stop;
    with _ps_lock {
        if _ps_thread is not None and _ps_thread.is_alive() {
            return;
        }
        r = _redis_or_none();
        if r is None {
            return;
        }
        _ps_stop = threading.Event();
        _ps_pubsub = r.pubsub(ignore_subscribe_messages=True);
        # subscribe to all currently-registered channels
        channels = [_prefix(f"ps:{ch}") for ch in list(_ps_handlers.keys())];
        if channels {
            _ps_pubsub.subscribe(*channels);
        }
        t = threading.Thread(
            target=_ps_run_loop, args=(_ps_pubsub, _ps_stop), daemon=True, name="jac_coord_pubsub"
        );
        t.start();
        _ps_thread = t;
    }
}

def _ps_run_loop(pubsub: Any, stop: threading.Event) -> None {
    while not stop.is_set() {
        try {
            msg = pubsub.get_message(timeout=1.0);
            if msg is None {
                continue;
            }
            if msg.get("type") != "message" {
                continue;
            }
            raw_channel = msg.get("channel", b"");
            if isinstance(raw_channel, bytes) {
                raw_channel = raw_channel.decode("utf-8");
            }
            # strip "jac_coord:<app>:ps:" prefix to get user-facing channel name
            prefix_len = len(_prefix("ps:"));
            channel = raw_channel[prefix_len:] if raw_channel.startswith(_prefix("ps:")) else raw_channel;
            data = msg.get("data", b"");
            if isinstance(data, bytes) {
                data = data.decode("utf-8");
            }
            try {
                payload = json.loads(data);
            } except Exception {
                payload = data;
            }
            handlers = list(_ps_handlers.get(channel, []));
            for h in handlers {
                try {
                    h(payload);
                } except Exception as e {
                    _logger.warning(f"pubsub handler for {channel} failed: {e}");
                }
            }
        } except Exception as e {
            if not stop.is_set() {
                _logger.warning(f"pubsub loop error: {e}");
                time.sleep(0.5);
            }
        }
    }
}

impl publish(channel: str, payload: Any) -> int {
    r = _redis_or_fail();
    if r is None { return 0; }
    pk = _prefix(f"ps:{channel}");
    try {
        encoded = json.dumps(payload) if not isinstance(payload, str) else payload;
    } except Exception {
        encoded = str(payload);
    }
    try {
        return int(r.publish(pk, encoded));
    } except Exception as e {
        _logger.warning(f"publish({channel}) failed: {e}");
        return 0;
    }
}

impl subscribe(channel: str, handler: Callable) -> None {
    with _ps_lock {
        handlers = _ps_handlers.setdefault(channel, []);
        if handler not in handlers {
            handlers.append(handler);
    }
        # if subscriber thread is already running, update its channel list
        global _ps_pubsub;
        if _ps_pubsub is not None {
            try {
                _ps_pubsub.subscribe(_prefix(f"ps:{channel}"));
            } except Exception as e {
                _logger.warning(f"subscribe({channel}) failed: {e}");
            }
        }
    }
    _ensure_subscriber();
}

impl unsubscribe(channel: str, handler: Callable) -> None {
    with _ps_lock {
        handlers = _ps_handlers.get(channel);
        if handlers and handler in handlers {
            handlers.remove(handler);
        if not handlers and _ps_pubsub is not None {
            try { _ps_pubsub.unsubscribe(_prefix(f"ps:{channel}")); } except Exception { }
            _ps_handlers.pop(channel, None);
        }
        }
    }
}

impl on(channel: str) -> Callable {
    def decorator(handler: Callable) -> Callable {
        subscribe(channel, handler);
        return handler;
    }
    return decorator;
}
