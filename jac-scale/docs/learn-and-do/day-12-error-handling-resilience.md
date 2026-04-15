# Day 12: Error Handling & Resilience

## Learn (~1 hour)

### The Network Is Not Reliable

In a monolith, a function call either works or throws an exception — instantly. In microservices, network calls can:

| Failure mode | What happens | How often |
|-------------|-------------|-----------|
| **Timeout** | Service takes too long, no response | Common under load |
| **Connection refused** | Service is down, port not listening | During deploys/crashes |
| **5xx error** | Service is up but hit an internal error | Bugs, resource exhaustion |
| **Partial failure** | Request succeeded but response is corrupted | Rare but devastating |
| **Cascading failure** | Service A is slow → B waits → B is slow → C waits → everything dies | The nightmare scenario |

### The Circuit Breaker Pattern

Imagine a service is down. Without protection, every request waits for a timeout (30s), then fails. 100 users = 100 × 30s of wasted resources.

A **circuit breaker** stops calling a failing service:

```
CLOSED (normal)          OPEN (broken)           HALF-OPEN (testing)
   │                        │                        │
   │ Request → forward      │ Request → fail fast    │ Allow 1 request
   │ Success → stay closed  │ (no network call!)     │ Success → CLOSED
   │ Failure → count it     │ After 30s → HALF-OPEN  │ Failure → OPEN
   │ N failures → OPEN      │                        │
```

**States:**

- **CLOSED**: Normal operation. Failures are counted.
- **OPEN**: Too many failures. Requests fail immediately (no network call). Saves resources.
- **HALF-OPEN**: After a cooldown, try one request. If it succeeds, close the circuit. If it fails, stay open.

### Retry with Backoff

Sometimes failures are transient (a service restarting). Retrying can help:

```
Attempt 1: fail → wait 1s
Attempt 2: fail → wait 2s
Attempt 3: fail → wait 4s (exponential backoff)
Attempt 4: success!
```

**Rules:**

- Only retry on transient errors (503, timeout) — NOT on 400, 401, 404
- Use exponential backoff (1s, 2s, 4s, 8s...) — don't hammer a struggling service
- Set a max retries limit (3-5)
- Add jitter (random ±20%) — prevents all clients retrying at the same second

### Timeout Budgets

If a user request has a 10s timeout, and it involves 3 service calls:

```
User → Gateway (10s budget)
  → Orders (must respond in 4s)
    → Payments (must respond in 3s)  ← nested call eats into budget
  → remaining: 3s for any other work
```

Each hop should have a **shorter timeout** than its parent. The gateway's timeout should be the overall budget; services get a fraction.

### Graceful Degradation

When a non-critical service is down, return a degraded response instead of an error:

```jac
walker get_order_with_recommendations {
    can process with `root entry {
        order = get_order(self.order_id);  // critical — fail if down

        // Non-critical — degrade gracefully
        try {
            recommendations = service_call("recommendations", "/for-order", ...);
        } except {
            recommendations = {"items": [], "degraded": true};
        }

        report {"order": order, "recommendations": recommendations};
    }
}
```

---

## Do (~2-3 hours)

### Task 1: Add circuit breaker to service_call()

**`jac_scale/microservices/circuit_breaker.jac`**

```jac
"""Circuit breaker for inter-service HTTP calls."""

import time;
import logging;
import from enum { Enum }

glob logger = logging.getLogger(__name__);

enum CircuitState {
    CLOSED = "closed",
    OPEN = "open",
    HALF_OPEN = "half_open"
}

obj CircuitBreaker {
    has name: str,
        failure_threshold: int = 5,       # failures before opening
        recovery_timeout: float = 30.0,   # seconds before half-open
        state: CircuitState = CircuitState.CLOSED,
        failure_count: int = 0,
        last_failure_time: float = 0.0,
        success_count_in_half_open: int = 0;

    """Check if a request should be allowed through."""
    def allow_request -> bool;

    """Record a successful call."""
    def record_success -> None;

    """Record a failed call."""
    def record_failure -> None;
}
```

### Task 2: Implement circuit breaker

**`jac_scale/microservices/impl/circuit_breaker.impl.jac`**

```jac
import time;
import from jac_scale.microservices.circuit_breaker { CircuitBreaker, CircuitState }

:obj:CircuitBreaker:can:allow_request -> bool {
    if self.state == CircuitState.CLOSED {
        return True;
    }

    if self.state == CircuitState.OPEN {
        # Check if recovery timeout has passed
        if time.time() - self.last_failure_time >= self.recovery_timeout {
            self.state = CircuitState.HALF_OPEN;
            self.success_count_in_half_open = 0;
            logger.info(f"Circuit {self.name}: OPEN → HALF_OPEN (testing)");
            return True;  # Allow one test request
        }
        return False;  # Still open, fail fast
    }

    # HALF_OPEN: allow requests to test
    return True;
}

:obj:CircuitBreaker:can:record_success -> None {
    if self.state == CircuitState.HALF_OPEN {
        self.success_count_in_half_open += 1;
        if self.success_count_in_half_open >= 2 {
            self.state = CircuitState.CLOSED;
            self.failure_count = 0;
            logger.info(f"Circuit {self.name}: HALF_OPEN → CLOSED (recovered)");
        }
    } elif self.state == CircuitState.CLOSED {
        self.failure_count = 0;  # Reset on success
    }
}

:obj:CircuitBreaker:can:record_failure -> None {
    self.failure_count += 1;
    self.last_failure_time = time.time();

    if self.state == CircuitState.HALF_OPEN {
        self.state = CircuitState.OPEN;
        logger.warning(f"Circuit {self.name}: HALF_OPEN → OPEN (test failed)");
    } elif self.state == CircuitState.CLOSED and self.failure_count >= self.failure_threshold {
        self.state = CircuitState.OPEN;
        logger.warning(f"Circuit {self.name}: CLOSED → OPEN ({self.failure_count} failures)");
    }
}
```

### Task 3: Add retry logic to service_call()

Update `service_call()` to use circuit breaker and retry:

```jac
import time;
import random;

# Global circuit breakers per service
glob _circuit_breakers: dict[str, CircuitBreaker] = {};

def _get_circuit_breaker(service: str) -> CircuitBreaker {
    if service not in _circuit_breakers {
        _circuit_breakers[service] = CircuitBreaker(name=service);
    }
    return _circuit_breakers[service];
}

async def service_call_with_resilience(
    service: str,
    endpoint: str,
    method: str = "POST",
    body: dict | None = None,
    internal_token: str = "",
    max_retries: int = 3,
    timeout: int = 10
) -> ServiceResponse {
    cb = _get_circuit_breaker(service);

    if not cb.allow_request() {
        logger.warning(f"Circuit breaker OPEN for {service} — failing fast");
        return ServiceResponse(status=503, _body=b'{"error": "Service unavailable (circuit open)"}');
    }

    last_error: Exception | None = None;
    for attempt in range(max_retries) {
        try {
            result = await service_call(
                service=service, endpoint=endpoint, method=method,
                body=body, internal_token=internal_token,
                gateway_url="", timeout=timeout
            );

            if result.status < 500 {
                cb.record_success();
                return result;
            }

            # 5xx = server error, worth retrying
            cb.record_failure();
            last_error = Exception(f"Service returned {result.status}");

        } except Exception as e {
            cb.record_failure();
            last_error = e;
        }

        # Exponential backoff with jitter
        if attempt < max_retries - 1 {
            delay = (2 ** attempt) + random.uniform(0, 0.5);
            logger.info(f"Retrying {service}/{endpoint} in {delay:.1f}s (attempt {attempt + 2}/{max_retries})");
            await __import__("asyncio").sleep(delay);
        }
    }

    logger.error(f"All {max_retries} attempts failed for {service}/{endpoint}: {last_error}");
    return ServiceResponse(status=503, _body=f'{{"error": "Service unavailable after {max_retries} retries"}}'.encode());
}
```

### Task 4: Add timeout to gateway proxy

Update the gateway's `forward_http_request` call to use a timeout:

```jac
# In gateway proxy_handler, add a per-request timeout:
try {
    return await forward_http_request(request, target_url, extra_headers=extra_headers, timeout=10);
} except asyncio.TimeoutError {
    return JSONResponse(status_code=504, content={"error": f"Service '{entry.name}' timed out"});
} except Exception as e {
    return JSONResponse(status_code=502, content={"error": f"Failed to reach service '{entry.name}'"});
}
```

### Task 5: Test circuit breaker

```python
# test_circuit_breaker.py
from jac_scale.microservices.circuit_breaker import CircuitBreaker, CircuitState

cb = CircuitBreaker(name="payments", failure_threshold=3, recovery_timeout=2)

# Normal: closed
assert cb.state == CircuitState.CLOSED
assert cb.allow_request() is True

# Accumulate failures
cb.record_failure()
cb.record_failure()
assert cb.state == CircuitState.CLOSED  # not enough yet
cb.record_failure()
assert cb.state == CircuitState.OPEN    # 3 failures → open!

# Open: fail fast
assert cb.allow_request() is False

# Wait for recovery
import time
time.sleep(2.1)
assert cb.allow_request() is True       # half-open
assert cb.state == CircuitState.HALF_OPEN

# Successful test → close
cb.record_success()
cb.record_success()
assert cb.state == CircuitState.CLOSED

print("All circuit breaker tests passed!")
```

---

## Milestone

- [ ] Circuit breaker with CLOSED → OPEN → HALF_OPEN → CLOSED transitions
- [ ] `service_call_with_resilience()` retries with exponential backoff + jitter
- [ ] Circuit breaker fails fast when open (no network call)
- [ ] Gateway returns 504 on timeout, 502 on connection error
- [ ] Circuit breaker tests pass

**You now understand**: why networks fail differently than function calls, how circuit breakers prevent cascading failures, why retry with backoff is essential, and how timeout budgets prevent resource exhaustion.
