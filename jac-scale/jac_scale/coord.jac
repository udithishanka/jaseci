"""Distributed coordination primitives for multi-pod jac-scale apps.

Exposes Redis-backed primitives (lock, KV, pub/sub) as the implementation
behind the `@restspec(lock=..., publish_on_success=..., ...)` decorator
extensions and the `Jac.lock() / Jac.kv / Jac.publish / @Jac.on` builtins.

All keys are auto-prefixed with `jac_coord:<app_name>:` to prevent collisions
when multiple jac-scale apps share a Redis instance. The app name is
configured via the `JAC_APP_NAME` env var (default: `default`).

Graceful degradation: if Redis is unavailable, behavior is controlled by
`JAC_COORD_ON_FAILURE=fail|degrade` (default: `degrade`). In degrade mode,
lock acquire returns `(True, "__degraded__")` with a logged warning — the
caller proceeds unlocked. In fail mode, functions raise `CoordUnavailable`.
"""

import os;
import time;
import uuid;
import json;
import logging;
import threading;
import from typing { Any, Callable }
import from contextlib { contextmanager }

glob _logger = logging.getLogger('jac_scale.coord');

"""Raised when the coordination backend (Redis) is unavailable and the
operating mode is `fail`. In `degrade` mode this is caught and translated
into a best-effort no-op response."""
class CoordUnavailable(Exception);

"""Apply the jac-scale coord key prefix. `JAC_APP_NAME` env var scopes keys
to a single deployment so multiple apps sharing a Redis instance don't
collide. Returns the fully-prefixed key."""
def _prefix(key: str) -> str;

"""`on_failure` resolution from `JAC_COORD_ON_FAILURE` env var."""
def _on_failure_mode -> str;

# -------------------------- Lock ---------------------------
"""Attempt to acquire a distributed lock backed by Redis `SET NX PX`.
Returns `(acquired, token)`. Token must be passed to `release()` to release
the lock safely (fencing — only the original acquirer can release).

`blocking_timeout_ms=0` means try once and return. Non-zero polls until
the lock is acquired or the timeout expires.

Degrade-mode behavior: if Redis is unavailable, returns `(True, "__degraded__")`
with a warning logged, allowing the caller to proceed without the lock.
Fail mode raises `CoordUnavailable`."""
def acquire_lock(
    key: str, ttl_ms: int = 30000, blocking_timeout_ms: int = 0
) -> tuple;

"""Release a lock previously acquired via `acquire_lock`. Uses a Lua script
to atomically check the fencing token before deleting. Returns True if the
lock was released (token matched), False if it was already expired or held
by another caller. Silent no-op in degrade mode."""
def release_lock(key: str, token: str) -> bool;

"""Context-manager style distributed lock. `acquired` is `True` if the lock
was obtained (or if degrade-mode skipped lock acquisition). Use in both
walker-internal code and middleware. Always releases on exit.

```jac
with distlock("community:manifest", timeout_ms=30000) as acquired {
    if acquired {
        # critical section
    } else {
        # lock contended past timeout
    }
}
```"""
@contextmanager
def distlock(key: str, ttl_ms: int = 30000, timeout_ms: int = 30000);

# -------------------------- KV with TTL ---------------------------
"""Sub-second TTL key-value store backed by Redis. Use for ephemeral state
where a graph-node commit cycle is too coarse (WS auth tokens, processing
flags with auto-expire, rate-limit counters).

`value` is JSON-encoded before storing. Returns True if the set succeeded."""
def kv_set(key: str, value: Any, ttl_ms: int = 0) -> bool;

"""Read a KV entry (JSON-decoded). Returns the fallback if the key is absent,
expired, or Redis is degraded."""
def kv_get(key: str, fallback: Any = None) -> Any;

"""Delete a KV entry. Returns True if a key was removed."""
def kv_delete(key: str) -> bool;

"""Check whether a KV entry currently exists."""
def kv_exists(key: str) -> bool;

"""Atomically increment a counter, setting its TTL on first create.
Useful for rate limiters (`INCR` then `EXPIRE` on window roll-over).
Returns the post-increment value, or 0 in degrade mode."""
def kv_incr(key: str, ttl_ms: int = 0) -> int;

# -------------------------- Pub/Sub ---------------------------
"""Publish a message to a Redis pub/sub channel. Payload is JSON-encoded.
Fire-and-forget — returns the subscriber count (0 in degrade mode). This
is the underlying primitive for `Jac.publish()` and
`@restspec(publish_on_success=...)`."""
def publish(channel: str, payload: Any) -> int;

"""Register a handler for a pub/sub channel. Safe to call from any context
(module load, plugin init, walker entry). Idempotent — same handler
registered twice fires only once.

Each jac-scale process runs a single background subscriber thread that
fans out to all registered handlers. Handlers must be short-lived; for
long work, dispatch to a ThreadPoolExecutor."""
def subscribe(channel: str, handler: Callable) -> None;

"""Unregister a previously-subscribed handler."""
def unsubscribe(channel: str, handler: Callable) -> None;

"""Decorator for registering a pub/sub subscriber at module load time.

```jac
import from jac_scale.coord { on, publish }

@on("project_deleted")
def cleanup_local_state(event: dict) -> None {
    _registry.pop((event["user_id"], event["project_id"]), None);
}
```"""
def on(channel: str) -> Callable;
