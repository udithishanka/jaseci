# Day 14: Rate Limiting & Throttling

## Learn (~1 hour)

### Why Rate Limit?

Without rate limiting, one misbehaving client can overwhelm a service (intentionally via DDoS or accidentally via a bug). Rate limiting protects services by capping how many requests a client can make in a time window.

### Algorithms

| Algorithm | How it works | Pros | Cons |
|-----------|-------------|------|------|
| **Fixed window** | N requests per minute (resets at minute boundary) | Simple | Burst at window edges |
| **Sliding window** | N requests in the last 60 seconds | Smooth | Slightly more state |
| **Token bucket** | Tokens refill at a rate; each request costs a token | Allows bursts | More complex |
| **Leaky bucket** | Requests queue and process at a fixed rate | Very smooth | Adds latency |

**Token bucket** is the most practical — it allows short bursts while enforcing an average rate.

### Where to Rate Limit

```
Client → [Gateway rate limiter] → Service
          ├── Per-user: 100 req/min
          ├── Per-service: 1000 req/min to payments
          └── Global: 5000 req/min total
```

The gateway is the right place — one enforcement point for all services.

### Rate Limit Headers

Standard response headers tell clients their limits:

```
X-RateLimit-Limit: 100          # max requests per window
X-RateLimit-Remaining: 73       # requests left
X-RateLimit-Reset: 1712345678   # when the window resets (Unix timestamp)
```

When exceeded: `429 Too Many Requests`

---

## Do (~2-3 hours)

### Task 1: Build a token bucket rate limiter

```jac
"""Token bucket rate limiter for the gateway."""

import time;

obj TokenBucket {
    has capacity: int,                 # max tokens
        refill_rate: float,            # tokens per second
        tokens: float = 0.0,
        last_refill: float = 0.0;

    def postinit -> None {
        self.tokens = float(self.capacity);
        self.last_refill = time.time();
    }

    """Try to consume one token. Returns True if allowed."""
    def allow -> bool {
        self._refill();
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            return True;
        }
        return False;
    }

    def _refill -> None {
        now = time.time();
        elapsed = now - self.last_refill;
        self.tokens = min(float(self.capacity), self.tokens + elapsed * self.refill_rate);
        self.last_refill = now;
    }

    def remaining -> int {
        self._refill();
        return int(self.tokens);
    }
}

obj RateLimiter {
    has default_capacity: int = 100,       # requests per window
        default_refill_rate: float = 1.67, # tokens/sec (100/60)
        buckets: dict[str, TokenBucket] = {},
        service_limits: dict[str, tuple[int, float]] = {};  # service → (capacity, rate)

    """Check if a request from this user to this service is allowed."""
    def check(user_id: str, service: str = "global") -> tuple[bool, dict[str, str]] {
        key = f"{user_id}:{service}";
        if key not in self.buckets {
            cap, rate = self.service_limits.get(service, (self.default_capacity, self.default_refill_rate));
            self.buckets[key] = TokenBucket(capacity=cap, refill_rate=rate);
        }
        bucket = self.buckets[key];
        allowed = bucket.allow();
        headers = {
            "X-RateLimit-Limit": str(bucket.capacity),
            "X-RateLimit-Remaining": str(bucket.remaining())
        };
        return (allowed, headers);
    }
}
```

### Task 2: Wire rate limiter into gateway

```jac
# In gateway setup, before the catch-all:
rate_limiter = RateLimiter();

# In proxy_handler, after auth check:
user_id = extra_headers.get("X-User-Id", request.client.host if request.client else "anon");
allowed, rate_headers = rate_limiter.check(user_id, entry.name);

if not allowed {
    resp = JSONResponse(status_code=429, content={"error": "Rate limit exceeded"});
    for (k, v) in rate_headers.items() {
        resp.headers[k] = v;
    }
    return resp;
}

# After getting response, add rate limit headers:
for (k, v) in rate_headers.items() {
    response.headers[k] = v;
}
```

### Task 3: Configurable per-service limits

```toml
# jac.toml
[plugins.scale.microservices.services.payments]
file = "services/payments.jac"
prefix = "/api/payments"
rate_limit = 50  # requests per minute (payments is expensive)

[plugins.scale.microservices.services.orders]
file = "services/orders.jac"
prefix = "/api/orders"
rate_limit = 200  # higher limit for reads
```

### Task 4: Test rate limiting

```python
import time

# Make 10 rapid requests
for i in range(10):
    resp = requests.get(f"{url}/api/orders/list", headers=auth_headers)
    print(f"  {i+1}: {resp.status_code} remaining={resp.headers.get('X-RateLimit-Remaining')}")

# Should see 429 once limit is exceeded
```

---

## Milestone

- [ ] Token bucket rate limiter with per-user, per-service buckets
- [ ] 429 response with `X-RateLimit-*` headers when exceeded
- [ ] Configurable limits per service in TOML
- [ ] Rate limit info in response headers for all requests

**You now understand**: rate limiting algorithms (fixed window, sliding window, token bucket), where to enforce limits in a microservice architecture, and how to communicate limits to clients via headers.
