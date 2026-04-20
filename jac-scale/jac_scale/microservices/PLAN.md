# Microservice Mode v2 — `sv import` Integration Plan

## Goal

Make `sv import` the primary microservice interface in jac-scale. The compiler
generates HTTP stubs, jac-scale provides the production-grade infrastructure.
Users write `sv import from cart { ViewCart }` and everything works — auth,
subprocess management, health checks, retry, gateway routing.

## Current State

- **Core (main)**: `sv import` compiler detection, stub generation, `sv_client.call()`,
  `ensure_sv_service()` hook with thread-based HTTPServer (dev quality)
- **jac-scale (our branch)**: gateway, deployer, process manager, CLI tooling,
  manual `service_call()` for inter-service HTTP

## Target State

```
User writes:      sv import from cart_app { ViewCart }
Compiler:         generates stub → sv_client.call("cart_app", "ViewCart", kw)
jac-scale hook:   auth propagation + subprocess + health + retry
```

No `service_call()`, no `auth_token` passing, no URL management.

---

## Hooks to Override

### 1. `ensure_sv_service(module_name, base_path)`

**Core default**: Thread + HTTPServer (dev quality)
**jac-scale override**: Subprocess + JFastApiServer + health check

```
- Hash-based port: 18000 + (hash(module_name) % 1000), 100 retries
- Spawn: jac start {module_name}.jac --port {port} --no_client
- Health check: poll /healthz until ready (30s timeout)
- Register: sv_client.register(module_name, f"http://127.0.0.1:{port}")
- Track: add to ServiceProcessManager for lifecycle management
```

### 2. `sv_service_call(module_name, func_name, args)` (NEW hook needed in core)

**Core default**: Raw httpx.post, no auth, no retry
**jac-scale override**: Production-grade RPC

```
- Extract auth token from current request context (Jac execution context)
- Forward Authorization header to target service
- Retry on transient failures (503, timeout) with exponential backoff
- Circuit breaker after N consecutive failures
- Unwrap TransportResponse envelope
- Structured logging with trace ID
```

### 3. Gateway Integration

Gateway reads service URLs from `sv_client._registry` instead of its own registry.
One source of truth for service locations.

```
sv_client._registry = {
    "products_app": "http://127.0.0.1:18342",
    "orders_app":   "http://127.0.0.1:18567",
    "cart_app":     "http://127.0.0.1:18103"
}

Gateway prefix map (from TOML):
    /api/products/* → sv_client._registry["products_app"]
    /api/orders/*   → sv_client._registry["orders_app"]
    /api/cart/*     → sv_client._registry["cart_app"]
```

---

## Implementation Steps

### Phase 1: Port Assignment + Process Manager Update

**Files**: `process_manager.jac`, `impl/process_manager.impl.jac`

- Replace sequential port (8001, 8002...) with hash-based
- Add `_is_port_available(port)` check
- `_assign_port` uses `18000 + hash(name) % 1000` with 100 retries
- Services can start in parallel (no port coordination needed)

### Phase 2: Override `ensure_sv_service` in plugin.jac

**Files**: `plugin.jac`

- `@hookimpl ensure_sv_service(module_name, base_path)`
- Uses ServiceProcessManager to spawn subprocess
- Hash-based port, health check /healthz
- Registers in sv_client._registry
- Tracks process for lifecycle management (stop/restart)
- Sets `JAC_MICROSERVICE_CHILD=1` env to prevent recursive orchestration

### Phase 3: Override `sv_service_call` (requires core hook addition)

**Files**: Core `runtime.jac` (add hookspec), `plugin.jac` (add hookimpl)

Option A — Add new hook in core:

```jac
// core hookspec
def sv_service_call(module_name: str, func_name: str, args: dict) -> Any;

// jac-scale hookimpl
@hookimpl
def sv_service_call(module_name, func_name, args) {
    // 1. Get auth from execution context
    // 2. Add Authorization header
    // 3. Call with retry + circuit breaker
    // 4. Unwrap response
}
```

Option B — Override sv_client.call() at module level (no core change):

```jac
// In plugin.jac postinit, monkey-patch sv_client.call
import from jaclang.runtimelib { sv_client }
sv_client.call = _jac_scale_sv_call;  // our production impl
```

Option B is faster (no core PR needed). Option A is cleaner.

### Phase 4: Gateway Reads sv_client Registry

**Files**: `gateway.jac`, `orchestrator.jac`

- Gateway's `ServiceRegistry` wraps `sv_client._registry`
- When `ensure_sv_service` registers a URL, gateway can route to it
- TOML config maps service names to API prefixes:
  `products_app → /api/products`
- Gateway still handles: static files, admin UI, /health, /user/* passthrough

### Phase 5: Update Example App

**Files**: `examples/micr-s-example/services/orders.jac`

Before:

```jac
import from jac_scale.microservices.service_client { service_call }
cart_resp = service_call(service="cart", endpoint="walker/ViewCart", auth_token=token);
```

After:

```jac
sv import from cart_app { ViewCart, ClearCart }
cart = ViewCart();
ClearCart();
```

### Phase 6: Deprecate service_call

- Keep `service_client.jac` for backward compat but mark as deprecated
- Update docs to show `sv import` as the primary approach
- Remove manual auth_token passing from examples

---

## Port Strategy

```
Hash-based port assignment:
  base = 18000 + (hash(module_name) % 1000)
  try ports base, base+1, base+2, ... up to base+99

Examples:
  hash("products_app") % 1000 = 342 → try 18342, 18343, ...
  hash("orders_app")   % 1000 = 567 → try 18567, 18568, ...
  hash("cart_app")     % 1000 = 103 → try 18103, 18104, ...

Benefits:
  - Parallel startup (no coordination)
  - Deterministic (same name = same port range)
  - 100 retries handles collisions
  - Separate from user-facing gateway port (8000)
```

## Gateway Port

Gateway stays on user-configured port (default 8000 from TOML).
Services get auto-assigned ports in 18000-19000 range.

```
Client → Gateway :8000 → /api/products/* → :18342
                       → /api/orders/*   → :18567
                       → /api/cart/*     → :18103
                       → static files
                       → admin UI

Service-to-service (sv import):
  Orders :18567 → sv_client.call("cart_app") → :18103 (direct, no gateway hop)
```

## Auth Flow with sv import

```
1. Client → Gateway :8000 (Authorization: Bearer USER_TOKEN)
2. Gateway → Orders :18567 (forwards Authorization header)
3. Orders walker runs, hits: sv import from cart_app { ViewCart }
4. jac-scale sv_service_call hook:
   a. Reads Authorization from current request context
   b. POST http://127.0.0.1:18103/function/ViewCart
      with Authorization: Bearer USER_TOKEN (forwarded)
5. Cart validates token (same JWT secret from jac.toml)
6. Cart returns result
7. Compiler stub unwraps and returns to Orders walker
```

No manual token passing. The hook reads it from the execution context.

## TOML Config (Simplified)

```toml
# Minimal — just enable + map prefixes for the gateway
[plugins.scale.microservices]
enabled = true

# Only needed if you want a gateway (client-facing apps)
[plugins.scale.microservices.gateway]
port = 8000

# Map module names to API prefixes for the gateway
[plugins.scale.microservices.routes]
products_app = "/api/products"
orders_app = "/api/orders"
cart_app = "/api/cart"

# Client UI (optional)
[plugins.scale.microservices.client]
entry = "main.jac"
```

Services are NOT declared individually anymore — `sv import` handles discovery.
The TOML just maps names to gateway prefixes and optionally configures the gateway.

## What Changes vs Current

| Current | New |
|---------|-----|
| `service_call("cart", "walker/ViewCart")` | `sv import from cart_app { ViewCart }` |
| Manual `auth_token` passing | Hook reads from request context |
| Sequential ports 8001, 8002... | Hash-based 18000+ range |
| Separate ServiceRegistry | Wraps sv_client._registry |
| TOML declares every service file | TOML only maps gateway prefixes |
| Gateway required for inter-service | Direct service-to-service via sv import |
| `*_app.jac` service entry files | Still needed for sv {} endpoint registration |

## What Stays the Same

- Gateway (client-facing routing, static files, admin)
- ServiceDeployer interface (local vs K8s abstraction)
- CLI: jac setup microservice, jac scale status/stop/restart
- Process manager (subprocess lifecycle, health checks)
- Test infrastructure

---

## What Already Exists on Main

Before planning PRs, here's what jac-scale already has for `sv import`:

| File | What it does |
|------|-------------|
| `serve.core.impl.jac` | `_ensure_sv_siblings()` called at server startup — walks compile-time recorded providers and spawns them |
| `tests/test_microservice.jac` | Tests for sv-to-sv interop using JacAPIServer + TestClient |
| `tests/test_eager_spawn.jac` | Tests for eager auto-spawn of providers at startup |
| `tests/fixtures/microservice/` | Test fixture services (math_service, calculator_service, etc.) |

The core `sv import` flow already works end-to-end on main:

1. Compiler detects `sv import` → generates HTTP stub
2. Stub calls `sv_client.call(module, func, args)`
3. `sv_client` resolves URL via registry/env/ensure_sv_service hook
4. jac-scale's `_ensure_sv_siblings` spawns providers as threads at startup

**What's missing on main**: gateway, deployer abstraction, CLI tooling,
TOML-based config, static/admin serving, production subprocess management.

---

## PR Strategy

All PRs branch from `main`. Each PR builds on what already exists on main
(especially `sv import` + `_ensure_sv_siblings`). PRs are ordered so each
is independently mergeable and testable.

### PR 1: Microservice Gateway + HTTP Forwarding

**Branch**: `feat/ms-gateway`
**From**: `main`

Why first: The gateway is the biggest new component and has no dependency
on the existing `sv import` setup. It's a standalone FastAPI middleware that
proxies requests to services by URL prefix.

Files:

- `jac_scale/microservices/__init__.py`
- `jac_scale/microservices/impl/__init__.py`
- `jac_scale/microservices/gateway.jac` + impl
- `jac_scale/microservices/impl/http_forward.py`
- `jac_scale/tests/test_gateway.jac`
- `jac_scale/plugin_config.jac` (add `[plugins.scale.microservices]` schema)
- `jac_scale/config_loader.jac` + impl (add `get_microservices_config`)

What it does:

- `MicroserviceGateway`: FastAPI middleware for path-based reverse proxy
- Routes `/api/{service}/walker/*` and `/api/{service}/function/*` to services
- Static file serving + SPA fallback from client dist
- Admin UI serving from pre-built bundle
- Built-in passthrough for `/user/*`, `/cl/*`, `/healthz`, etc.
- `/health` endpoint with per-service status
- TOML config schema for `[plugins.scale.microservices]`
- 37+ tests

Adapts to `sv import`: The gateway reads service URLs from `sv_client._registry`
(the same registry that `ensure_sv_service` populates). So when `sv import`
auto-spawns a provider, the gateway automatically knows its URL.

Depends on: nothing — standalone component

---

### PR 2: ServiceDeployer Interface + LocalDeployer

**Branch**: `feat/ms-deployer`
**From**: `main` (after PR 1 merged)

Why separate: Clean abstraction layer that wraps the existing `_ensure_sv_siblings`
subprocess spawning with a proper lifecycle interface (stop/restart/status/logs).

Files:

- `jac_scale/microservices/deployer.jac` (interface)
- `jac_scale/microservices/local_deployer.jac` + impl
- `jac_scale/tests/test_deployer.jac`

What it does:

- `ServiceDeployer`: abstract interface (deploy, stop, restart, scale, status, logs, destroy)
- `LocalDeployer`: wraps subprocess lifecycle with deployer API
- Hash-based port assignment (from core's pattern: `18000 + hash % 1000`, 100 retries)
- Health check via `/healthz`
- Same interface for future `KubernetesDeployer`
- 12 tests

Adapts to `sv import`: LocalDeployer uses the same port strategy as core's
`ensure_sv_service`. Services spawned by either path end up in `sv_client._registry`.

Depends on: PR 1 (uses gateway's service URL resolution)

---

### PR 3: Orchestrator + Plugin Hook Override

**Branch**: `feat/ms-orchestrator`
**From**: `main` (after PR 2 merged)

Why: This is where `sv import` meets jac-scale infrastructure. The orchestrator
replaces core's thread-based `ensure_sv_service` with production subprocess management.

Files:

- `jac_scale/microservices/orchestrator.jac`
- `jac_scale/plugin.jac` (override `ensure_sv_service` + add pre-hook)
- `jac_scale/tests/test_orchestrator.jac`

What it does:

- `@hookimpl ensure_sv_service`: spawn subprocess + JFastApiServer (not thread + HTTPServer)
- Orchestrator: build client → start services → health check → start gateway
- Plugin pre-hook: detects `microservices.enabled`, calls orchestrator
- Entry-point detection to prevent recursive spawning
- Registers spawned services in `sv_client._registry`
- atexit cleanup
- 6+ tests

Key integration point: When user writes `sv import from cart { ViewCart }`,
the compiler generates a stub that calls `sv_client.call("cart", ...)`.
On first call, `sv_client._ensure_available` calls `ensure_sv_service`.
jac-scale's `@hookimpl` intercepts this and spawns a proper subprocess
instead of a thread.

Depends on: PR 2

---

### PR 4: `sv_client.call` Override — Auth Propagation + Retry

**Branch**: `feat/ms-sv-call`
**From**: `main` (after PR 3 merged)

Why: Makes `sv import` production-ready — auth flows automatically between
services, transient failures are retried, circuit breaker prevents cascading.

Files:

- `jac_scale/plugin.jac` (override or monkey-patch sv_client.call)
- `jac_scale/microservices/sv_call.jac` (production call implementation)
- Tests

What it does:

- Extract auth token from current Jac execution context
- Forward Authorization header in inter-service calls
- Retry on 503/timeout with exponential backoff
- Circuit breaker after N consecutive failures
- Structured logging with trace ID

User experience:

```jac
sv import from cart_app { ViewCart }
result = ViewCart();  // auth propagated automatically, retry on failure
```

Depends on: PR 3
May need: Small core PR to make `sv_client.call` hookable (or monkey-patch)

---

### PR 5: CLI Tooling — Setup + Scale Commands

**Branch**: `feat/ms-cli`
**From**: `main` (after PR 2 merged, parallel with PR 3/4)

Files:

- `jac_scale/microservices/setup.jac`
- `jac_scale/plugin.jac` (register CLI commands)
- `jac_scale/tests/test_setup.jac`

What it does:

- `jac setup microservice` — interactive setup, TOML generation
- `jac setup microservice --add/--remove/--list`
- `jac scale status` — show all services (reads sv_client._registry)
- `jac scale stop/restart/logs/destroy` — uses ServiceDeployer
- 12 tests

Depends on: PR 2 (needs deployer)

---

### PR 6: E-Commerce Example App

**Branch**: `feat/ms-example`
**From**: `main` (after PR 4 merged)

Files:

- `examples/micr-s-example/` (services, frontend, jac.toml)

What it does:

- 3-service e-commerce: products, orders, cart
- Inter-service: `sv import from cart_app { ViewCart, ClearCart }` (not manual service_call)
- Frontend: fetch API calls to gateway
- Works in monolith + microservice mode
- README with instructions

Depends on: PR 4 (uses sv import with auth propagation)

---

### PR 7: Documentation

**Branch**: `feat/ms-docs`
**From**: `main` (after PR 6 merged)

Files:

- `jac_scale/microservices/docs.md`
- Update `docs/docs/tutorials/production/microservices.md`

Depends on: PR 6

---

## PR Dependency Graph

```
PR 1 (gateway + config)     PR 5 (CLI tooling)
  │                            │ (parallel after PR 2)
  ▼                            │
PR 2 (deployer) ───────────────┘
  │
  ▼
PR 3 (orchestrator + ensure_sv_service override)
  │
  ▼
PR 4 (sv_client.call override — auth + retry)
  │
  ▼
PR 6 (example app)
  │
  ▼
PR 7 (docs)
```

## PR Sizes (Estimated)

| PR | What | Files | Lines | Tests |
|----|------|-------|-------|-------|
| 1  | Gateway + config | ~8 | ~500 | 37 |
| 2  | Deployer | ~4 | ~300 | 12 |
| 3  | Orchestrator + hooks | ~3 | ~250 | 6 |
| 4  | sv_client.call override | ~2 | ~200 | TBD |
| 5  | CLI tooling | ~3 | ~350 | 12 |
| 6  | Example app | ~12 | ~800 | — |
| 7  | Docs | ~2 | ~300 | — |

## Open Questions

1. **Core PR needed?** Add `sv_service_call` hookspec to core for clean override,
   or monkey-patch `sv_client.call` in jac-scale plugin init?
2. **Walker support**: `sv import` on main works for `def:pub` functions.
   Does it work for `walker:pub`? Our example uses walkers heavily.
3. **Eager vs lazy spawn**: Core does eager (spawn all on startup).
   Our orchestrator also does eager. Keep both?
4. **Shared shelf DB**: Multiple subprocesses writing to `.jac/data/` —
   need file locking or separate DB per service?
5. **TOML simplification**: Current TOML declares each service file.
   With `sv import`, do we still need service declarations, or just
   gateway route mappings?
