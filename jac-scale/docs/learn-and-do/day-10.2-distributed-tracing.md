# Day 10.2: Distributed Tracing & Request Correlation

## The Problem

When a request flows through 3 services:

```
Client → Gateway → Orders → Cart (via service_call) → back
```

How do you debug when something fails? Each service has its own logs. You need a **trace ID** that follows the request across all services.

## What to Build

### Trace ID Propagation

1. Gateway generates a `X-Trace-Id` (UUID) for each incoming request
2. Gateway passes it as a header when proxying to services
3. `service_call()` automatically forwards `X-Trace-Id`
4. Every service logs with the trace ID

### Gateway Changes

```jac
# In proxy middleware, before forwarding:
import uuid;
trace_id = request.headers.get("x-trace-id", str(uuid.uuid4()));
fwd_headers["X-Trace-Id"] = trace_id;
logger.info(f"[{trace_id[:8]}] Proxy: {method} {path} -> {target}");
```

### service_call Changes

```jac
# service_call automatically reads and forwards X-Trace-Id
req_headers["X-Trace-Id"] = trace_id or str(uuid.uuid4());
```

### Structured Logging

Each log entry includes the trace ID:

```json
{"trace_id": "a1b2c3d4", "service": "orders", "action": "PlaceOrder", "duration_ms": 45}
{"trace_id": "a1b2c3d4", "service": "cart", "action": "ViewCart", "duration_ms": 12}
{"trace_id": "a1b2c3d4", "service": "cart", "action": "ClearCart", "duration_ms": 8}
```

Now you can grep for `a1b2c3d4` and see the full journey.

## Milestone

- [ ] Gateway generates and propagates X-Trace-Id
- [ ] service_call forwards trace ID
- [ ] Gateway logs include trace ID prefix
- [ ] Can correlate logs across services by trace ID
