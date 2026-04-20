# Day 19: Performance & Caching

## Learn (~1 hour)

### The Microservice Performance Tax

Every service-to-service call adds:

- **Network latency**: ~1-5ms local, 10-100ms across data centers
- **Serialization**: JSON encode/decode on each hop
- **Auth overhead**: Token validation per request

A monolith function call: ~0.01ms. A microservice HTTP call: ~5-50ms. That's 500-5000x slower.

### Caching Strategies

| Strategy | Where | What it caches | TTL |
|----------|-------|---------------|-----|
| **Gateway cache** | Gateway memory | Frequent read-only responses | 10-60s |
| **Service cache** | Redis (jac-scale L2) | Per-service query results | Minutes |
| **Client cache** | Browser/CDN | Static assets, API responses | Hours |
| **Shared cache** | Redis | Cross-service shared data | Varies |

### Cache Invalidation (The Hard Part)

```
"There are only two hard things in Computer Science:
 cache invalidation and naming things." — Phil Karlton
```

| Pattern | How it works | When to use |
|---------|-------------|-------------|
| **TTL-based** | Cache expires after N seconds | When stale data is acceptable |
| **Event-based** | Service publishes "data changed", cache clears | When freshness matters |
| **Write-through** | Write to cache AND database | When reads far outnumber writes |

### Connection Pooling

Creating a new HTTP connection per request is expensive (TCP handshake, TLS handshake). **Connection pooling** reuses connections:

```
Without pooling:          With pooling:
Request 1: connect → use → close     Request 1: connect → use → keep
Request 2: connect → use → close     Request 2: reuse → use → keep
Request 3: connect → use → close     Request 3: reuse → use → keep

3 TCP handshakes                     1 TCP handshake
```

### Response Compression

Large JSON responses benefit from compression:

- Client sends: `Accept-Encoding: gzip`
- Server responds with gzipped body
- Typically 70-90% smaller for JSON

---

## Do (~2-3 hours)

### Task 1: Add response caching to the gateway

```jac
"""Gateway-level response cache for read-only API calls."""

import time;
import hashlib;

obj CacheEntry {
    has key: str,
        response_body: bytes,
        response_headers: dict[str, str],
        status_code: int,
        created_at: float,
        ttl: float;

    def is_expired -> bool {
        return time.time() - self.created_at > self.ttl;
    }
}

obj GatewayCache {
    has entries: dict[str, CacheEntry] = {},
        default_ttl: float = 30.0,    # 30 seconds
        max_entries: int = 1000;

    def get(key: str) -> CacheEntry | None {
        entry = self.entries.get(key);
        if entry and not entry.is_expired() {
            return entry;
        }
        if entry {
            del self.entries[key];  # expired
        }
        return None;
    }

    def put(key: str, body: bytes, headers: dict, status: int, ttl: float = 0) -> None {
        if len(self.entries) >= self.max_entries {
            self._evict_expired();
        }
        self.entries[key] = CacheEntry(
            key=key, response_body=body, response_headers=headers,
            status_code=status, created_at=time.time(),
            ttl=ttl if ttl > 0 else self.default_ttl
        );
    }

    def _evict_expired -> None {
        now = time.time();
        expired = [k for (k, v) in self.entries.items() if v.is_expired()];
        for k in expired {
            del self.entries[k];
        }
    }

    @staticmethod
    def make_key(method: str, path: str, user_id: str = "") -> str {
        """Cache key = hash of method + path + user (user-specific caching)."""
        raw = f"{method}:{path}:{user_id}";
        return hashlib.sha256(raw.encode()).hexdigest()[:16];
    }
}
```

### Task 2: Wire caching into the gateway proxy

```jac
# In proxy_handler, before forwarding:

# Only cache GET requests
if request.method == "GET" {
    cache_key = GatewayCache.make_key(request.method, path, extra_headers.get("X-User-Id", ""));
    cached = self.cache.get(cache_key);
    if cached {
        logger.debug(f"Cache HIT: {path}");
        headers = {**cached.response_headers, "X-Cache": "HIT"};
        return Response(content=cached.response_body, status_code=cached.status_code, headers=headers);
    }
}

# After getting response from service:
response = await forward_http_request(request, target_url, extra_headers=extra_headers);

# Cache successful GET responses
if request.method == "GET" and response.status_code == 200 {
    self.cache.put(cache_key, response.body, dict(response.headers), response.status_code);
    response.headers["X-Cache"] = "MISS";
}
```

### Task 3: Add connection pooling to service_call()

```jac
"""Reusable connection pool for inter-service calls."""

import aiohttp;

glob _connection_pool: aiohttp.ClientSession | None = None;

async def get_connection_pool() -> aiohttp.ClientSession {
    global _connection_pool;
    if _connection_pool is None or _connection_pool.closed {
        connector = aiohttp.TCPConnector(
            limit=100,           # max total connections
            limit_per_host=20,   # max connections per service
            keepalive_timeout=30 # reuse connections for 30s
        );
        _connection_pool = aiohttp.ClientSession(
            connector=connector,
            timeout=aiohttp.ClientTimeout(total=10)
        );
    }
    return _connection_pool;
}

# Update service_call() to use the pool:
# session = await get_connection_pool();
# async with session.request(method, url, ...) as resp:
#     ...
```

### Task 4: Add cache headers to configure per-service caching

```toml
# jac.toml — per-service cache config
[plugins.scale.microservices.services.catalog]
file = "services/catalog.jac"
prefix = "/api/catalog"
cache_ttl = 60    # catalog data changes rarely — cache for 60s

[plugins.scale.microservices.services.orders]
file = "services/orders.jac"
prefix = "/api/orders"
cache_ttl = 0     # orders are user-specific — no caching
```

### Task 5: Measure the improvement

```python
import time
import requests

url = "http://localhost:8000/api/catalog/products"
headers = {"Authorization": f"Bearer {token}"}

# First request (cache MISS)
start = time.time()
r1 = requests.get(url, headers=headers)
t1 = (time.time() - start) * 1000
print(f"First request:  {t1:.1f}ms  X-Cache: {r1.headers.get('X-Cache')}")

# Second request (cache HIT)
start = time.time()
r2 = requests.get(url, headers=headers)
t2 = (time.time() - start) * 1000
print(f"Second request: {t2:.1f}ms  X-Cache: {r2.headers.get('X-Cache')}")

print(f"Speedup: {t1/t2:.1f}x")
```

---

## Milestone

- [ ] Gateway cache: GET responses cached with TTL, `X-Cache: HIT/MISS` headers
- [ ] Per-service cache TTL configurable in TOML
- [ ] Connection pooling: reuse HTTP connections for inter-service calls
- [ ] Cache eviction on expiry and max entries
- [ ] Measurable latency improvement on repeated requests

**You now understand**: the performance overhead of microservices, caching strategies at different layers, why cache invalidation is hard, how connection pooling reduces latency, and how to measure improvements.
