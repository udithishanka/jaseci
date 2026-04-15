# Day 2: Service Registry & Discovery

## Learn (~1 hour)

### What is a Service Registry?

In a monolith, calling another feature is a function call — you know exactly where the code is. In microservices, services run in separate processes on different ports (or different machines). You need a way to answer: **"Where is the payments service right now?"**

A **service registry** is a data structure (or external system) that maps service names to their network locations:

```
Registry:
  orders   → http://127.0.0.1:8001  (HEALTHY)
  payments → http://127.0.0.1:8002  (HEALTHY)
  users    → http://127.0.0.1:8003  (STARTING)
```

### Types of Service Discovery

| Type | How it works | Example |
|------|-------------|---------|
| **Static config** | Hardcoded in a config file | Our TOML approach |
| **DNS-based** | Service names resolve via DNS | K8s Service DNS |
| **Registry server** | Dedicated service (Consul, etcd, Eureka) | Netflix OSS |
| **Platform-native** | The platform tracks services | K8s, AWS ECS |

**Our approach**: Static config locally (TOML defines services + auto-assigned ports), DNS-based in K8s (each service gets a K8s Service with DNS name). Simple, no extra infrastructure.

### Service Health States

A service goes through these states:

```
REGISTERED → STARTING → HEALTHY → UNHEALTHY → STOPPED
                ↑                      │
                └──────────────────────┘
                     (auto-restart)
```

- **STARTING**: Process launched, waiting for `/health` to respond
- **HEALTHY**: `/health` returns 200
- **UNHEALTHY**: `/health` failed N times in a row
- **STOPPED**: Process exited or was killed

### Longest-Prefix Matching

When the gateway gets a request for `/api/orders/list`, it needs to find the right service. With multiple services registered:

```
/api/orders   → Orders service
/api/orders/v2 → Orders V2 service (hypothetical)
/api          → Catch-all API service (hypothetical)
```

Request for `/api/orders/v2/list` should match `/api/orders/v2` (longest prefix), not `/api/orders`.

**Algorithm**: Sort prefixes by length (longest first), find first match. Simple, O(n) where n = number of services.

### Reading (optional)

- [microservices.io — Service Registry](https://microservices.io/patterns/service-registry.html) (10 min)

---

## Do (~2-3 hours)

### Task 1: Define `ServiceEntry`

**`jac_scale/microservices/registry.jac`**

```jac
"""Service registry — tracks declared microservices and their runtime state."""

import from enum { Enum }
import from datetime { datetime, UTC }

enum ServiceStatus {
    REGISTERED = "registered",
    STARTING = "starting",
    HEALTHY = "healthy",
    UNHEALTHY = "unhealthy",
    STOPPED = "stopped"
}

obj ServiceEntry {
    has name: str,                          # "orders"
        file: str,                          # "services/orders.jac"
        prefix: str,                        # "/api/orders"
        port: int = 0,                      # 0 = auto-assign
        replicas: int = 1,                  # k8s only
        env: dict[str, str] = {},           # per-service env vars
        url: str = "",                      # resolved at runtime: "http://127.0.0.1:8001"
        pid: int | None = None,             # subprocess PID (local mode)
        status: ServiceStatus = ServiceStatus.REGISTERED,
        last_health_check: datetime | None = None;
}
```

### Task 2: Build `ServiceRegistry`

Continue in the same file:

```jac
obj ServiceRegistry {
    has entries: dict[str, ServiceEntry] = {},
        _sorted_prefixes: list[tuple[str, str]] = [];   # [(prefix, name)] sorted by length desc

    """Register a service. Rebuilds prefix index."""
    def register(entry: ServiceEntry) -> None;

    """Remove a service by name."""
    def deregister(name: str) -> bool;

    """Find the service that matches a request path (longest-prefix match)."""
    def match_route(path: str) -> ServiceEntry | None;

    """Get all entries as a dict for health reporting."""
    def health_summary -> dict[str, dict];

    """Rebuild the sorted prefix list (call after register/deregister)."""
    def _rebuild_prefix_index -> None;
}
```

### Task 3: Implement the registry

**`jac_scale/microservices/impl/registry.impl.jac`**

```jac
import from jac_scale.microservices.registry { ServiceRegistry, ServiceEntry, ServiceStatus }

:obj:ServiceRegistry:can:register
(entry: ServiceEntry) -> None {
    self.entries[entry.name] = entry;
    self._rebuild_prefix_index();
}

:obj:ServiceRegistry:can:deregister
(name: str) -> bool {
    if name in self.entries {
        del self.entries[name];
        self._rebuild_prefix_index();
        return True;
    }
    return False;
}

:obj:ServiceRegistry:can:match_route
(path: str) -> ServiceEntry | None {
    # Longest-prefix match: _sorted_prefixes is sorted longest-first
    for (prefix, name) in self._sorted_prefixes {
        if path == prefix or path.startswith(prefix + "/") {
            return self.entries[name];
        }
    }
    return None;
}

:obj:ServiceRegistry:can:health_summary
-> dict[str, dict] {
    result: dict[str, dict] = {};
    for (name, entry) in self.entries.items() {
        result[name] = {
            "file": entry.file,
            "prefix": entry.prefix,
            "port": entry.port,
            "url": entry.url,
            "status": entry.status.value,
            "pid": entry.pid
        };
    }
    return result;
}

:obj:ServiceRegistry:can:_rebuild_prefix_index
-> None {
    self._sorted_prefixes = sorted(
        [(e.prefix, e.name) for e in self.entries.values()],
        key=lambda x: len(x[0]),
        reverse=True
    );
}
```

### Task 4: Write tests

Create a test to verify your registry works:

```python
# Quick test script — run with: python test_registry.py
# (Or write proper pytest tests in jac_scale/tests/)

from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry, ServiceStatus

reg = ServiceRegistry()

# Register two services
reg.register(ServiceEntry(name="orders", file="services/orders.jac", prefix="/api/orders", port=8001))
reg.register(ServiceEntry(name="payments", file="services/payments.jac", prefix="/api/payments", port=8002))

# Test lookup
assert reg.match_route("/api/orders/list").name == "orders"
assert reg.match_route("/api/payments/charge").name == "payments"
assert reg.match_route("/api/unknown") is None
assert reg.match_route("/health") is None

# Test exact prefix match
assert reg.match_route("/api/orders").name == "orders"

# Test deregister
assert reg.deregister("orders") == True
assert reg.match_route("/api/orders/list") is None
assert reg.deregister("nonexistent") == False

# Test health summary
summary = reg.health_summary()
assert "payments" in summary
assert summary["payments"]["port"] == 8002

print("All registry tests passed!")
```

---

## Milestone

- [ ] `ServiceEntry` and `ServiceRegistry` classes exist and compile
- [ ] `register()`, `deregister()`, `match_route()` all work correctly
- [ ] Longest-prefix matching works (tested with overlapping prefixes)
- [ ] Test script passes

**You now understand**: what a service registry does, how path-based routing uses longest-prefix matching, and you have a working registry that the gateway will use on Day 4.
