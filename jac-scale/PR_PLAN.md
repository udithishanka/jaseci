# jac-scale Microservice PR Plan

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

---

## PR 1 Scope (Current PR: `feat/ms-gateway`)

PR 1 adds the API Gateway — the one thing `sv import` on main cannot do:
give clients a single URL with routing, static files, and admin.

**Right now on main (without gateway):**

```
Client → :8002/function/sum_list     (must know the exact port)
Client → :18342/function/check_stock  (auto-assigned, random-looking port)
```

**After PR 1:**

```
Client → :8000/api/orders/function/create_order    (gateway routes it)
Client → :8000/api/inventory/function/check_stock  (gateway routes it)
Client → :8000/                                     (static SPA)
Client → :8000/admin/                               (admin dashboard)
Client → :8000/health                               (all services status)
```

### PR 1 contents

| File | What |
|------|------|
| `microservices/__init__.py` | Module init |
| `microservices/impl/__init__.py` | Impl init |
| `microservices/gateway.jac` + impl | FastAPI middleware — path proxy, static, admin |
| `microservices/impl/http_forward.py` | aiohttp forwarding |
| `plugin_config.jac` | Add `[plugins.scale.microservices]` schema |
| `config_loader.jac` + impl | Add `get_microservices_config()` |
| `tests/test_gateway.jac` | 37 tests |

### PR 1 does NOT include

- No ServiceRegistry (gateway reads `sv_client._registry` directly)
- No ProcessManager (services are spawned by existing `ensure_sv_service`)
- No Deployer (that's PR 2)
- No orchestrator (PR 3)
- No CLI commands (PR 5)

### How PR 1 connects to `sv import`

```
1. User starts: jac start main.jac
2. Core's ensure_sv_service auto-spawns services (existing behavior)
3. Services register in sv_client._registry (existing behavior)
4. Gateway reads sv_client._registry to know where to proxy (NEW in PR 1)
5. Client hits :8000 → gateway → :18xxx service (NEW in PR 1)
```

The gateway is a **layer on top of `sv import`**, not a replacement.
`sv import` handles service-to-service. The gateway handles client-to-service.

---

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
