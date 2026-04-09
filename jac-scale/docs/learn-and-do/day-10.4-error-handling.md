# Day 10.4: Error Handling & Resilience

## The Problem

Currently if a service is down:
- Gateway returns 502 and gives up
- No retry for transient failures
- No circuit breaker to prevent hammering a dead service
- Inter-service calls (`service_call`) fail silently

## What to Build

### Gateway-Level Retry

For 502/503 responses, retry once after a short delay:

```jac
result = await raw_forward(method, target_url, fwd_headers, body);
if result is None or result[0] in (502, 503) {
    # Retry once after 500ms
    await asyncio.sleep(0.5);
    result = await raw_forward(method, target_url, fwd_headers, body);
}
```

### service_call Retry

Add retry with backoff to `service_call()`:

```jac
def service_call(..., max_retries: int = 2) -> ServiceResponse {
    for attempt in range(max_retries) {
        resp = requests.request(...);
        if resp.status_code < 500 {
            return ServiceResponse(...);
        }
        if attempt < max_retries - 1 {
            time.sleep(0.5 * (attempt + 1));  # backoff
        }
    }
    return ServiceResponse(status=502, ...);
}
```

### Better Error Responses

Standardize error format across the gateway:

```json
{
    "error": "Service unavailable",
    "service": "orders",
    "trace_id": "a1b2c3d4",
    "retry_after": 5
}
```

### Graceful Degradation for Passthrough

When trying all services for `/walker/*` passthrough, handle errors gracefully:

```jac
# Instead of stopping at first error, try all services
for svc in healthy_services {
    result = await raw_forward(...);
    if result and result[0] != 404 {
        return Response(...);
    }
}
```

## Milestone
- [ ] Gateway retries 502/503 once before failing
- [ ] service_call has configurable retry with backoff
- [ ] Standardized error response format with trace_id
- [ ] Passthrough gracefully tries all services
