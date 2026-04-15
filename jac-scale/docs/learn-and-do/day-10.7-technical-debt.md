# Day 10.7: Technical Debt & Standards Audit

## Current Non-Standard Patterns

Everything that needs fixing before this is production-grade.

### CRITICAL

| Issue | Where | What's Wrong | Fix |
|-------|-------|-------------|-----|
| **Mock auth** | `gateway.impl.jac` `/auth/login` | No password validation — anyone can login as anyone | Remove gateway login; let services handle auth via `/user/login` passthrough (already works) |
| **Token in request body** | `orders.jac` `has auth_token` | Token passed as walker field in POST body instead of Authorization header | Extract auth from request headers in walker, not as `has` field |

### HIGH

| Issue | Where | What's Wrong | Fix |
|-------|-------|-------------|-----|
| **O(N) walker discovery** | `gateway.impl.jac` passthrough | Tries every service until one returns non-404 | Cache walker→service mapping after first discovery |
| **DEVNULL logs** | `process_manager.impl.jac` | Service output discarded — can't debug startup failures | Write to `.jac/logs/{service}.log` |
| **Sync HTTP in async** | `service_client.jac` | Uses blocking `requests` library in async context | Use `aiohttp` or `httpx` async client |

### MEDIUM

| Issue | Where | What's Wrong | Fix |
|-------|-------|-------------|-----|
| **No distributed tracing** | Gateway + service_call | No trace ID propagation across services | Add X-Trace-Id header (Day 10.2) |
| **No metrics** | Gateway | No per-service request count/latency/error tracking | Add gateway metrics (Day 10.3) |
| **No retry/circuit breaker** | service_call | Single attempt, no backoff, no circuit breaker | Add retry + circuit breaker (Day 10.4) |
| **No rate limiting** | Gateway | Open to brute force and DDoS | Add per-IP rate limiting middleware |
| **localStorage token** | `frontend.impl.jac` | XSS vulnerable — token in localStorage not HttpOnly cookie | Use HttpOnly cookie or accept as client-side limitation |
| **http_forward.py is Python** | `impl/http_forward.py` | Should be Jac but type checker can't handle aiohttp | Accept until Jac type checker supports aiohttp stubs |

### LOW

| Issue | Where | What's Wrong | Fix |
|-------|-------|-------------|-----|
| **Globals at import time** | `gateway.jac` | JWT secret loaded at import, can't rotate | Load at `setup()` time |
| **JAC_MICROSERVICE_CHILD env** | `process_manager.impl.jac` | Set but only checked in plugin.jac — fragile | Keep both checks, document as defense-in-depth |
| **Entry-point heuristic** | `plugin.jac` | Falls back to "not a service file" check | Require explicit entry-point in jac.toml |

## Fix Plan

### Phase 1: Remove hacks (Do Now)

1. **Remove `/auth/login` from gateway** — services already handle auth via `/user/login` passthrough
2. **Fix token propagation** — extract auth from request context, not walker field
3. **Add service log files** — write to `.jac/logs/` instead of DEVNULL

### Phase 2: Add observability (Days 10.2-10.3)

1. **X-Trace-Id** — generate at gateway, propagate through all proxied requests and service_call
2. **Gateway metrics** — per-service request count, error rate, latency in `/health`

### Phase 3: Add resilience (Day 10.4)

1. **service_call retry** — 2 retries with exponential backoff
2. **Walker routing cache** — cache which service handles which walker path
3. **Rate limiting** — per-IP token bucket on the gateway

### Phase 4: Clean up (Day 10.5-10.6)

1. **Unified Swagger** — aggregate OpenAPI schemas from all services
2. **Colored log output** — prefix gateway logs with service name
3. **Load config at runtime** — move globals to setup()

## What's Acceptable As-Is

These are known limitations, not bugs:

- **http_forward.py as Python** — Jac type checker limitation with aiohttp, documented
- **localStorage for token** — standard for SPAs, HttpOnly cookies need server-side session management which adds complexity
- **Sync service_call** — works for the current use case, async is a future optimization
- **JAC_MICROSERVICE_CHILD env var** — defense-in-depth alongside entry-point check, acceptable
