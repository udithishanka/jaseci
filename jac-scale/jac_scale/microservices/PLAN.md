# Microservice Mode v2 — `sv import` Integration Plan

## Goal

Make `sv import` the single interface for microservices in Jac. The user writes
high-level Jac code with `sv import` and the runtime handles **everything** —
whether running locally as subprocesses on a laptop, or deployed as separate
pods across a Kubernetes cluster. Same code, zero infrastructure changes.

```
User writes:      sv import from cart_app { get_cart, clear_cart }
                  result = get_cart(user_id="u1");

Local dev:        runtime spawns subprocesses, assigns ports, routes calls
Production K8s:   runtime resolves K8s Service DNS, routes calls across pods
```

No `service_call()`, no `auth_token` passing, no URL management, no deployment
manifests per service. The `ServiceDeployer` interface abstracts the target
environment — `LocalDeployer` for dev, `KubernetesDeployer` for prod.

## What We've Already Built (scale-micro-service branch)

The prototype on this branch implements most of the v2 plan. Here's what
maps to each PR and what still needs rework:

| v2 PR | Component | Our Code | Status | What's Left |
|-------|-----------|----------|--------|-------------|
| PR 0 | Core hookspecs | — | Not started | Need `sv_service_call` + `get_sv_registry` in jaclang core |
| PR 1 | ServiceDeployer + LocalDeployer | `deployer.jac`, `local_deployer.jac`, `process_manager.jac` | **Done** (12 tests) | Add `JAC_DATA_DIR` isolation, hash-based ports |
| PR 2 | Gateway + config | `gateway.jac`, `http_forward.py`, `plugin_config.jac`, `config_loader.jac` | **Done** (37 tests) | Swap `ServiceRegistry` to read from `sv_client._registry` |
| PR 3 | Orchestrator + hooks | `orchestrator.jac`, `plugin.jac` pre-hook | **Done** (6 tests) | Replace pre-hook with `ensure_sv_service` hookimpl |
| PR 4 | `sv_service_call` override | `service_client.jac` (manual `service_call()`) | **Prototype** (11 tests) | Rewrite as hook override, auto auth from context |
| PR 5 | CLI tooling | `setup.jac`, `plugin.jac` (`jac setup` + `jac scale`) | **Done** (12 tests) | Minor: read from `sv_client._registry` for status |
| PR 6 | Example app | `examples/micr-s-example/` (3 services + frontend) | **Done** (working e2e) | Rewrite services as `def:pub` functions |
| PR 7 | Documentation | `docs.md`, `PLAN.md`, architecture doc, learn-and-do | **Done** | Already aligned with v2 |
| PR 8 | KubernetesDeployer | — | Not started | New: `ServiceDeployer` impl for K8s |
| PR 9 | K8s E2E | — | Not started | New: minikube-based tests |

**Summary: ~70% of code is directly reusable. 106 tests passing.**

### What needs rework (not rewrite)

1. **Orchestrator**: Change from pre-hook pattern to `ensure_sv_service` hookimpl
   - Same spawn/health/gateway logic, different entry point
2. **service_call → sv_service_call**: Replace manual HTTP client with hook override
   - Auth comes from execution context instead of explicit `auth_token` param
3. **ServiceRegistry**: Thin wrapper over `sv_client._registry` instead of standalone
4. **Example services**: Expose `def:pub` functions instead of walkers as public API
5. **TOML config**: Simplify from `[services.*]` declarations to `[routes]` mapping
6. **Data isolation**: Add `JAC_DATA_DIR=.jac/data/{module}/` per subprocess
7. **Port strategy**: Switch from sequential (8001, 8002) to hash-based (18000+)

### What stays exactly as-is

- `MicroserviceGateway` (FastAPI middleware, path routing, static/admin serving)
- `ServiceDeployer` interface (deploy/stop/restart/scale/status/logs/destroy)
- `LocalDeployer` (subprocess lifecycle wrapper)
- `ServiceProcessManager` (subprocess spawn/kill/health)
- CLI commands (`jac setup microservice`, `jac scale status/stop/restart/logs/destroy`)
- `http_forward.py` (aiohttp proxy)
- All test infrastructure and patterns

---

## Current State (verified 2026-04-16)

### What exists in jaclang core (main)

| Component | Location | Status |
|-----------|----------|--------|
| `sv import` detection | `jac0core/passes/impl/interop_analysis_pass.impl.jac` | Complete |
| Python stub generation | `jac0core/passes/impl/pyast_gen_pass.impl.jac` | Complete |
| JavaScript stub generation | `compiler/passes/ecmascript/impl/esast_gen_pass.impl.jac` | Complete |
| `sv_client` module | `runtimelib/sv_client.jac` (231 lines) | Complete |
| `sv_client.call()` RPC | Raw `httpx.post`, no auth, no retry | Complete |
| `sv_client._registry` | In-memory dict: module_name → URL | Complete |
| `sv_client._consumer_providers` | Compile-time injected consumer→provider edges | Complete |
| `sv_client.ensure_all()` | ThreadPoolExecutor(8) parallel eager-spawn | Complete |
| `ensure_sv_service` hookspec | `jac0core/runtime.jac:569` — **already hookable** | Complete |
| `ensure_sv_service` default impl | `jac0core/impl/runtime.impl.jac:1724` — thread + HTTPServer | Complete |
| Hash-based port strategy | `18000 + hash(module_name) % 1000`, 100 retries | Complete |
| `_ensure_sv_siblings` BFS | `runtimelib/impl/server.impl.jac` — transitive provider discovery | Complete |
| `is_sv_sibling` flag | Prevents recursive eager-spawn in spawned providers | Complete |
| Plugin system | `jac0core/plugin.jac` — hookspec/hookimpl/PluginManager | Complete |

### What exists in jac-scale (main)

| Component | Location | Status |
|-----------|----------|--------|
| Plugin registration | `plugin.jac` — @hookimpl for create_server, create_cmd, etc. | Complete |
| JFastApiServer | `jserver/` — FastAPI-based server wrapper | Complete |
| Config loading | `config_loader.jac` — `[plugins.scale.*]` TOML sections | Complete |
| CLI commands | `jac start --scale`, `jac destroy`, `jac status` | Complete |
| K8s deployment | `targets/kubernetes/` — deploys **monolith** (single pod) | Complete |
| `DeploymentTarget` interface | `abstractions/deployment_target.jac` — deploy/destroy/status/scale | Complete |
| `DeploymentTargetFactory` | `factories/deployment_factory.jac` — pluggable target creation | Complete |
| `KubernetesTarget` | `targets/kubernetes/kubernetes_target.jac` (2465 lines) | Complete |
| Auth/SSO/JWT | `sso/`, JWT validation, API key management | Complete |
| Admin portal | `admin/` — pre-built admin UI | Complete |
| Test fixtures | `tests/fixtures/microservice/` — math, calculator, order, inventory | Complete |
| Microservice tests | `tests/test_microservice.jac`, `test_eager_spawn.jac` | Complete |

### What does NOT exist yet (must be created from scratch)

- Gateway (reverse proxy, path-based routing, static serving)
- `ServiceDeployer` interface (per-service lifecycle — distinct from `DeploymentTarget`)
- `LocalDeployer` (subprocess-based, for local dev)
- `KubernetesDeployer` (per-service pods, for prod K8s)
- Orchestrator (coordinates deployer + gateway + sv_client)
- `sv_service_call` hook or production-grade RPC override
- CLI commands for `jac setup microservice`, `jac scale stop/restart/logs`
- `microservices/` module (directory exists but is empty)

### Key distinction: `DeploymentTarget` vs `ServiceDeployer`

These are **different abstractions** at different levels:

| | `DeploymentTarget` (exists) | `ServiceDeployer` (new) |
|-|----------------------------|------------------------|
| **Scope** | Whole application | Single microservice |
| **What it deploys** | App + MongoDB + Redis + Ingress + monitoring | One `{module}.jac` as a service |
| **Entry point** | `jac start app.jac --scale` | Called by `ensure_sv_service` hook |
| **Interface** | `deploy(AppConfig) → DeploymentResult` | `deploy(module_name, base_path) → ServiceInfo` |
| **K8s resources** | Deployment + StatefulSets + Ingress + HPA + NetworkPolicy | One Deployment + one ClusterIP Service |
| **Existing impl** | `KubernetesTarget` (2465 lines) | None yet |

`ServiceDeployer` is lighter — it manages one service at a time. The orchestrator
calls it once per `sv import` provider. `DeploymentTarget` manages the whole
application stack including databases and monitoring.

## Target State

### Local development (`jac start app.jac`)

```
app.jac has: sv import from cart_app { get_cart }
             sv import from products_app { get_product }

Runtime automatically:
  1. BFS discovers providers: cart_app, products_app
  2. LocalDeployer.deploy("cart_app") → subprocess on :18103
  3. LocalDeployer.deploy("products_app") → subprocess on :18342
  4. sv_client.register("cart_app", "http://127.0.0.1:18103")
  5. Gateway starts on :8000, routes /api/cart/* → :18103, /api/products/* → :18342
  6. get_cart("u1") → HTTP POST http://127.0.0.1:18103/function/get_cart
```

### Production K8s (`jac start app.jac --scale`)

```
Same app.jac, same sv import statements.

Runtime automatically:
  1. BFS discovers providers: cart_app, products_app
  2. KubernetesDeployer.deploy("cart_app") → K8s Deployment + ClusterIP Service
  3. KubernetesDeployer.deploy("products_app") → K8s Deployment + ClusterIP Service
  4. sv_client.register("cart_app", "http://cart-app.{ns}.svc.cluster.local:8000")
  5. Gateway pod routes /api/cart/* → cart-app ClusterIP, /api/products/* → products-app ClusterIP
  6. get_cart("u1") → HTTP POST http://cart-app.{ns}.svc.cluster.local:8000/function/get_cart
```

**Same Jac code. Different deployer. Zero user changes.**

---

## Critical Design Decisions

### Decision 1: `sv import` supports `def:pub` functions only (not walkers)

The stub generator (`_collect_abilities` in `interop_analysis_pass.impl.jac:238`)
collects `uni.Ability` nodes. Walkers are `Architype` nodes and are NOT collected.
This means `sv import from cart_app { ViewCart }` will NOT generate a stub if
`ViewCart` is a walker.

**The correct pattern** (already proven in test fixtures):
- Walkers live on their own service and are called via `/walker/WalkerName` HTTP
- Functions are sv-imported for cross-service calls
- A walker on service A calls sv-imported functions from service B internally

```jac
# cart_app.jac — exposes functions via sv {}
def:pub get_cart(user_id: str) -> CartData { ... }
def:pub clear_cart(user_id: str) -> bool { ... }

# orders_app.jac — consumes cart functions
sv import from cart_app { get_cart, clear_cart }

walker:pub CreateOrder {
    has items: list[dict];
    can create with Root entry {
        cart = get_cart(self.user_id);  # sv-imported function → HTTP stub
        ...
    }
}
```

If walker-level sv import is needed later, that's a separate core compiler PR
(extend `_collect_abilities` to handle `Architype` nodes + generate walker stubs
that POST to `/walker/WalkerName`). Out of scope for this plan.

### Decision 2: Add `sv_service_call` hookspec to core (Option A)

Monkey-patching `sv_client.call` (Option B) is fragile — it breaks if any code
captures the function reference before the patch, and it's invisible to the type
system. We add a clean hookspec instead.

**Core PR** (small, prerequisite for PR 4):

```jac
# In jac0core/runtime.jac — add to JacAPIServer class
static def sv_service_call(
    module_name: str, func_name: str, args: dict
) -> Any;

# In jac0core/impl/runtime.impl.jac — default impl wraps existing logic
impl JacAPIServer.sv_service_call(
    module_name: str, func_name: str, args: dict
) -> Any {
    # Current sv_client.call() body moves here
    ...
}
```

Then `sv_client.call()` delegates to `JacRuntime.sv_service_call()`, making it
hookable by any plugin.

**Same PR adds public registry API:**

```jac
static def get_sv_registry() -> dict[str, str];
```

This replaces direct access to `sv_client._registry` (private attribute).

### Decision 3: Each service gets isolated data directory

Multiple services sharing `.jac/data/` will corrupt shelf DBs. Both deployers
MUST isolate data:

| Environment | Strategy |
|-------------|----------|
| Local | `JAC_DATA_DIR=.jac/data/{module_name}/` env var per subprocess |
| K8s | Separate `emptyDir` or PVC mount per pod (natural isolation) |

This is a hard requirement for PR 1 (LocalDeployer) and PR 8 (KubernetesDeployer).

### Decision 4: Eager spawn with BFS (keep existing pattern)

Core's `_ensure_sv_siblings` already does BFS-based transitive provider discovery
with `is_sv_sibling=True` to prevent recursive spawning. The jac-scale orchestrator
wraps this same pattern but replaces the thread+HTTPServer with the active deployer.
We do NOT duplicate the BFS logic — we override `ensure_sv_service` (the leaf call)
and let core's BFS drive the traversal.

### Decision 5: `ServiceDeployer` selected by environment

The orchestrator picks the deployer based on context:

```
if running locally (no --scale flag):
    deployer = LocalDeployer()          # subprocesses
elif target == "kubernetes":
    deployer = KubernetesDeployer()     # K8s pods
```

The `ensure_sv_service` hookimpl delegates to whichever deployer is active.
All downstream code (gateway, sv_service_call, CLI) works identically because
it only interacts with `sv_client._registry` URLs — it doesn't care whether
the URL points to `127.0.0.1:18103` or `cart-app.default.svc.cluster.local:8000`.

---

## Hooks to Override

### 1. `ensure_sv_service(module_name, base_path)` — already hookable

**Core default** (runtime.impl.jac:1724): Thread + HTTPServer + 10s health timeout
**jac-scale override**: Delegates to active `ServiceDeployer`

```
Local mode (LocalDeployer):
  - Reuse core's port strategy: 18000 + (hash(module_name) % 1000), 100 retries
  - Spawn: subprocess with `jac start {module_name}.jac --port {port}`
  - Set env: JAC_MICROSERVICE_CHILD=1, JAC_DATA_DIR=.jac/data/{module_name}/
  - Health check: poll /healthz until ready (30s timeout)
  - Register: sv_client.register(module_name, "http://127.0.0.1:{port}")
  - Track: add to LocalDeployer for lifecycle management

K8s mode (KubernetesDeployer):
  - Create K8s Deployment + ClusterIP Service for module
  - Wait for pod Ready condition (60s timeout)
  - Register: sv_client.register(module_name, "http://{svc}.{ns}.svc.cluster.local:8000")
  - No PID tracking needed — K8s manages lifecycle
```

### 2. `sv_service_call(module_name, func_name, args)` — NEW hookspec (core PR)

**Core default**: Current `sv_client.call()` body (raw httpx.post, no auth)
**jac-scale override**: Production-grade RPC

```
- Extract auth token from current request context (JScaleExecutionContext)
- Forward Authorization header to target service
- Retry on transient failures (503, timeout) with exponential backoff
- Circuit breaker after N consecutive failures
- Unwrap TransportResponse envelope
- Structured logging with trace ID
```

Works identically for local and K8s — the URL from `get_sv_registry()` is the
only thing that changes, and that's handled by the deployer.

### 3. Gateway Integration

Gateway reads service URLs via `JacRuntime.get_sv_registry()` (public API).

```
Gateway prefix map (from TOML):
    /api/products/* → get_sv_registry()["products_app"]
    /api/orders/*   → get_sv_registry()["orders_app"]
    /api/cart/*     → get_sv_registry()["cart_app"]
```

On K8s the gateway runs as its own pod (or as a sidecar in the main app pod)
and routes to ClusterIP URLs instead of localhost ports.

---

## PR Strategy

All PRs branch from `main`. Each is independently mergeable and testable.
PRs 0-7 deliver the full local development story. PR 8 extends to K8s.

### PR 0: Core hookspec additions (prerequisite)

**Branch**: `feat/sv-call-hook`
**Repo**: jaclang (core)

Small PR — adds two hookspecs + moves existing code behind them.

Files:

- `jac0core/runtime.jac` (add `sv_service_call` + `get_sv_registry` hookspecs)
- `jac0core/impl/runtime.impl.jac` (default impls — move existing logic)
- `runtimelib/sv_client.jac` (delegate `call()` to `JacRuntime.sv_service_call()`)
- Tests to verify delegation works

What it does:

- `sv_service_call(module_name, func_name, args) -> Any` hookspec
- `get_sv_registry() -> dict[str, str]` hookspec (returns copy of `_registry`)
- `sv_client.call()` becomes a thin wrapper around the hook
- Zero behavior change — existing tests must pass unchanged

Depends on: nothing

---

### PR 1: ServiceDeployer Interface + LocalDeployer

**Branch**: `feat/ms-deployer`
**From**: `main`

Why first: The deployer is the foundational abstraction. Everything else
(orchestrator, CLI, gateway, K8s) depends on this interface. LocalDeployer
has zero dependencies on other new components.

Files (all new):

- `jac_scale/microservices/__init__.py`
- `jac_scale/microservices/impl/__init__.py`
- `jac_scale/microservices/deployer.jac` (abstract interface)
- `jac_scale/microservices/local_deployer.jac` + `impl/local_deployer.impl.jac`
- `jac_scale/tests/test_deployer.jac`

What it does:

- `ServiceDeployer`: abstract interface
  - `deploy(module_name, base_path, port?) -> ServiceInfo`
  - `stop(module_name) -> bool`
  - `restart(module_name) -> ServiceInfo`
  - `status(module_name) -> ServiceStatus`
  - `logs(module_name, lines?) -> list[str]`
  - `destroy(module_name) -> bool`
  - `list_services() -> list[ServiceInfo]`
- `LocalDeployer`: subprocess-based implementation
  - Spawns `jac start {module}.jac --port {port}` as subprocess
  - Sets `JAC_DATA_DIR=.jac/data/{module_name}/` per process (isolated data)
  - Sets `JAC_MICROSERVICE_CHILD=1` to prevent recursive orchestration
  - Health check via `/healthz` with configurable timeout (default 30s)
  - SIGTERM graceful shutdown with drain period, SIGKILL fallback
  - Stdout/stderr capture for `logs()` command
  - Tracks PIDs for lifecycle management
- 15+ tests (spawn, stop, restart, health check failure, port collision, log capture)

Depends on: nothing — standalone abstraction

---

### PR 2: Microservice Gateway + HTTP Forwarding

**Branch**: `feat/ms-gateway`
**From**: `main` (after PR 0 merged)

Why: The gateway is the biggest new component. It uses `get_sv_registry()` from
PR 0 to discover service URLs. It has no dependency on the deployer (services
can be registered by any means).

Files (all new):

- `jac_scale/microservices/gateway.jac` + `impl/gateway.impl.jac`
- `jac_scale/microservices/impl/http_forward.py` (httpx-based async proxy)
- `jac_scale/tests/test_gateway.jac`
- `jac_scale/plugin_config.jac` (add `[plugins.scale.microservices]` schema)
- `jac_scale/config_loader.jac` + impl (add `get_microservices_config`)

What it does:

- `MicroserviceGateway`: FastAPI middleware for path-based reverse proxy
- Routes from TOML config: `/api/{prefix}/*` → service URL from `get_sv_registry()`
- Forwards all HTTP methods, headers (including Authorization), query params
- Static file serving + SPA fallback from client dist directory
- Admin UI serving from pre-built bundle
- Built-in passthrough for `/user/*`, `/cl/*`, `/healthz`
- `/health` endpoint: aggregates per-service health status
- TOML config schema for `[plugins.scale.microservices]`
- 30+ tests (routing, forwarding, static serving, health, config parsing)

**Environment-agnostic**: The gateway doesn't care if URLs are localhost or K8s DNS.
It reads `get_sv_registry()` and forwards. Works on both targets unchanged.

Depends on: PR 0 (uses `get_sv_registry()`)

---

### PR 3: Orchestrator + Plugin Hook Override (`ensure_sv_service`)

**Branch**: `feat/ms-orchestrator`
**From**: `main` (after PR 1 + PR 2 merged)

Why: This is the integration point. The orchestrator ties together the deployer,
gateway, and core's `sv import` infrastructure.

Files:

- `jac_scale/microservices/orchestrator.jac` + impl (new)
- `jac_scale/plugin.jac` (add `@hookimpl ensure_sv_service`)
- `jac_scale/tests/test_orchestrator.jac` (new)

What it does:

- `@hookimpl ensure_sv_service(module_name, base_path)`:
  - Delegates to active `ServiceDeployer` (LocalDeployer by default)
  - On K8s: delegates to `KubernetesDeployer` (PR 8) when `--scale` is active
  - Registers URL via `sv_client.register()`
  - Result: core's `_ensure_sv_siblings` BFS calls OUR hook at each leaf
- `MicroserviceOrchestrator`:
  - Holds reference to active `ServiceDeployer` instance
  - Startup sequence: detect providers → spawn via deployer → health check → start gateway
  - `_scale_pre_hook` integration: when `microservices.enabled` in TOML, orchestrator activates
  - `JAC_MICROSERVICE_CHILD` env check to prevent recursive orchestration
  - atexit handler: graceful shutdown in reverse dependency order
  - SIGTERM propagation to child subprocesses with drain period
- 10+ tests (spawn override, BFS integration, shutdown ordering, recursive prevention)

**Key insight**: We do NOT reimplement BFS traversal. Core's `_ensure_sv_siblings()`
already walks the consumer→provider graph via `sv_client.get_consumer_providers()`.
It calls `sv_client.ensure_all()` → `_ensure_available()` → `ensure_sv_service()`.
We only override the leaf hook. This means transitive discovery, cycle handling,
and parallel spawning all come for free from core.

Depends on: PR 1 (deployer) + PR 2 (gateway)

---

### PR 4: `sv_service_call` Override — Auth Propagation + Retry

**Branch**: `feat/ms-sv-call`
**From**: `main` (after PR 0 + PR 3 merged)

Why: Makes `sv import` production-ready. Auth flows automatically between
services, transient failures are retried, circuit breaker prevents cascading.

Files:

- `jac_scale/microservices/sv_call.jac` + impl (new — production call logic)
- `jac_scale/plugin.jac` (add `@hookimpl sv_service_call`)
- `jac_scale/tests/test_sv_call.jac` (new)

What it does:

- `@hookimpl sv_service_call(module_name, func_name, args)`:
  1. Extract auth token from `JScaleExecutionContext` (current request context)
  2. Build headers: `Authorization: Bearer {token}`, `X-Trace-ID: {uuid}`
  3. Resolve URL via `get_sv_registry()`
  4. POST to `/function/{func_name}` with auth headers forwarded
  5. Retry on 503/timeout: exponential backoff (100ms, 200ms, 400ms), max 3 retries
  6. Circuit breaker: after 5 consecutive failures, fail-fast for 30s
  7. Unwrap `TransportResponse` envelope
  8. Structured logging: trace ID, latency, success/failure
- 15+ tests (auth forwarding, retry on 503, circuit breaker open/close,
  trace ID propagation, timeout handling)

**Environment-agnostic**: Auth propagation and retry logic work identically
regardless of whether the target URL is localhost or K8s DNS.

User experience:

```jac
sv import from cart_app { get_cart, clear_cart }
cart = get_cart(user_id="u123");  # auth propagated automatically, retry on failure
clear_cart(user_id="u123");
```

Depends on: PR 0 (hookspec) + PR 3 (orchestrator must be in place)

---

### PR 5: CLI Tooling — Setup + Scale Commands

**Branch**: `feat/ms-cli`
**From**: `main` (after PR 1 merged, parallel with PR 3/4)

Files:

- `jac_scale/microservices/setup.jac` + impl (new)
- `jac_scale/plugin.jac` (register new CLI subcommands)
- `jac_scale/tests/test_setup.jac` (new)

What it does:

- `jac setup microservice` — interactive scaffolding:
  - Asks for service names, generates TOML config
  - Creates skeleton `{service}.jac` files with `sv {}` block
  - `--add {name}` / `--remove {name}` / `--list` for incremental edits
- `jac scale status` — tabular display of all running services
  - Reads from active `ServiceDeployer.list_services()`
  - Shows: name, port/URL, PID (local) or pod count (K8s), health status
- `jac scale stop {name}` / `restart {name}` — lifecycle via deployer
- `jac scale logs {name} [--lines N]` — subprocess stdout/stderr (local) or pod logs (K8s)
- `jac scale destroy` — stop all services, clean up
- 12+ tests

Depends on: PR 1 (needs deployer for lifecycle commands)

---

### PR 6: E-Commerce Example App (local)

**Branch**: `feat/ms-example`
**From**: `main` (after PR 4 merged)

Files (all new):

- `examples/microservices/products_app.jac` — product CRUD functions
- `examples/microservices/cart_app.jac` — cart management functions
- `examples/microservices/orders_app.jac` — sv imports from products + cart
- `examples/microservices/jac.toml` — microservice config + gateway routes
- `examples/microservices/README.md`

What it does:

- 3-service e-commerce: products, cart, orders
- Inter-service via `sv import`:
  ```jac
  # orders_app.jac
  sv import from cart_app { get_cart, clear_cart }
  sv import from products_app { get_product, check_inventory }

  def:pub create_order(user_id: str, items: list[dict]) -> OrderResult {
      cart = get_cart(user_id);
      for item in cart.items {
          avail = check_inventory(item.product_id, item.quantity);
          if not avail { return OrderResult(ok=False, error="Out of stock"); }
      }
      clear_cart(user_id);
      return OrderResult(ok=True, order_id=order_id);
  }
  ```
- Gateway routes: `/api/products/*`, `/api/cart/*`, `/api/orders/*`
- Works locally with `jac start orders_app.jac`
- README: setup instructions, architecture diagram

Depends on: PR 4 (uses sv import with auth propagation)

---

### PR 7: Documentation

**Branch**: `feat/ms-docs`
**From**: `main` (after PR 6 merged)

Files:

- Update `docs/docs/tutorials/production/microservices.md`
- `jac_scale/microservices/README.md` (API reference for deployer, gateway, orchestrator)

Depends on: PR 6

---

### PR 8: KubernetesDeployer — Per-Service Pod Deployment

**Branch**: `feat/ms-k8s-deployer`
**From**: `main` (after PR 3 merged)

Why: This closes the local→K8s gap. With this PR, the same `sv import` code
that runs locally as subprocesses deploys to K8s as individual pods with
zero user code changes.

Files:

- `jac_scale/microservices/k8s_deployer.jac` + `impl/k8s_deployer.impl.jac` (new)
- `jac_scale/microservices/orchestrator.jac` (update: deployer selection logic)
- `jac_scale/plugin.jac` (update: `--scale` activates KubernetesDeployer)
- `jac_scale/tests/test_k8s_deployer.jac` (new — uses mocked K8s client)

What it does:

**`KubernetesDeployer` implements `ServiceDeployer` interface:**

```
deploy(module_name, base_path) → ServiceInfo:
  1. Build container spec:
     - Same base image as main app (shared image, different CMD)
     - CMD: ["jac", "start", "{module_name}.jac", "--port", "8000"]
     - Env: JAC_MICROSERVICE_CHILD=1
     - Mount: code volume (synced from code-server, same as existing K8s infra)
     - Mount: K8s Secret for JWT secret (shared across all service pods)
  2. Create K8s Deployment:
     - name: {module_name} (sanitized: underscores → hyphens)
     - namespace: from jac.toml [plugins.scale.kubernetes]
     - replicas: 1 (default, HPA scales later)
     - readinessProbe: httpGet /healthz port 8000
     - livenessProbe: httpGet /healthz port 8000
     - resources: from TOML or defaults (100m CPU, 128Mi mem)
  3. Create K8s ClusterIP Service:
     - name: {module_name}-svc
     - port: 8000 → targetPort: 8000
     - selector: app={module_name}
  4. Create NetworkPolicy:
     - Allow ingress from gateway pod and other service pods
     - Allow egress to other services + DNS
  5. Wait for pod Ready (60s timeout)
  6. Register URL:
     sv_client.register(module_name, "http://{svc-name}.{ns}.svc.cluster.local:8000")

stop(module_name):
  - Scale Deployment to 0 replicas

restart(module_name):
  - kubectl rollout restart deployment/{module_name}

status(module_name):
  - Read Deployment status (ready/total replicas, conditions)

logs(module_name, lines):
  - kubectl logs deployment/{module_name} --tail={lines}

destroy(module_name):
  - Delete Deployment + Service + NetworkPolicy
```

**Image strategy — shared image, different entrypoint:**

All services use the same container image (built once during `jac start --scale`).
The image contains all `.jac` source files. Each Deployment's `CMD` specifies
which module to start. This avoids building N separate Docker images.

```dockerfile
# Single image (already built by existing KubernetesTarget)
FROM python:3.12-slim
COPY . /app
WORKDIR /app
# CMD overridden per Deployment:
#   cart_app pod:     CMD ["jac", "start", "cart_app.jac"]
#   products_app pod: CMD ["jac", "start", "products_app.jac"]
#   orders_app pod:   CMD ["jac", "start", "orders_app.jac"]
```

**Service discovery — K8s DNS (zero config):**

K8s automatically provides DNS for ClusterIP Services:
`{service-name}.{namespace}.svc.cluster.local`

The `ensure_sv_service` hook on K8s registers this DNS name in `sv_client._registry`.
No service mesh, no sidecar, no Consul — just native K8s DNS.

**Integration with existing KubernetesTarget:**

`KubernetesDeployer` is NOT a replacement for `KubernetesTarget`. They coexist:

| | `KubernetesTarget` (existing) | `KubernetesDeployer` (new) |
|-|-------------------------------|---------------------------|
| Creates | Main app Deployment + MongoDB + Redis + Ingress + monitoring | One Deployment + ClusterIP per sv-imported service |
| Called by | `jac start app.jac --scale` (the `_scale_pre_hook`) | `ensure_sv_service` hook during provider discovery |
| Image | Builds and pushes to registry | Reuses the same image |
| Resources | Full stack (DB, cache, Ingress, HPA, NetworkPolicy) | Lightweight (Deployment + Service + NetworkPolicy) |

**Flow on `jac start app.jac --scale` with microservices:**

```
1. _scale_pre_hook fires → KubernetesTarget.deploy(app_config)
   → Builds image, pushes, creates main Deployment + MongoDB + Redis + Ingress
2. Main app pod starts → loads app.jac → _ensure_sv_siblings() fires
3. BFS discovers sv-imported providers: cart_app, products_app
4. ensure_sv_service("cart_app", ...) → KubernetesDeployer.deploy("cart_app")
   → Creates cart-app Deployment + ClusterIP Service in same namespace
   → Registers http://cart-app-svc.{ns}.svc.cluster.local:8000
5. ensure_sv_service("products_app", ...) → same
6. Gateway on main pod routes /api/cart/* → cart-app-svc ClusterIP
7. sv_service_call("cart_app", "get_cart", {...})
   → POST http://cart-app-svc.{ns}.svc.cluster.local:8000/function/get_cart
```

**Auth on K8s:**

All service pods mount the same K8s Secret containing the JWT signing key
(from `[plugins.scale.secrets]` in jac.toml). Auth propagation works identically
to local — the `sv_service_call` hook forwards the Authorization header, and
each service validates with the shared secret.

**Scaling per service:**

Each service gets its own HPA (optional, from TOML config):

```toml
[plugins.scale.microservices.scaling]
cart_app = { min = 2, max = 10, target_cpu = 60 }
products_app = { min = 1, max = 5, target_cpu = 70 }
```

If not specified, defaults to 1 replica (no HPA). This is a significant advantage
over the monolith model — hot services scale independently.

**Tests (mocked K8s API):**
- 15+ tests using `unittest.mock` to mock `kubernetes.client` API calls
- Verify: correct Deployment spec generated (CMD, env, probes, resources)
- Verify: ClusterIP Service created with correct selectors
- Verify: NetworkPolicy allows inter-service traffic
- Verify: DNS-based URL registered in sv_client
- Verify: pod readiness wait + timeout
- Verify: stop scales to 0, destroy deletes resources
- Integration test with real minikube (optional, CI-only)

Depends on: PR 3 (orchestrator — provides the deployer selection seam)

---

### PR 9: K8s Example + E2E Test

**Branch**: `feat/ms-k8s-example`
**From**: `main` (after PR 8 merged)

Files:

- `examples/microservices/jac.toml` (update: add K8s config section)
- `examples/microservices/README.md` (update: add K8s deployment instructions)
- `jac_scale/tests/test_k8s_e2e.jac` (new — minikube-based E2E, CI-only)

What it does:

- Same example app from PR 6, deployed to K8s with zero code changes
- README shows: `jac start orders_app.jac` (local) vs `jac start orders_app.jac --scale` (K8s)
- TOML config additions for K8s:
  ```toml
  [plugins.scale.microservices.scaling]
  cart_app = { min = 2, max = 5 }

  [plugins.scale.kubernetes]
  namespace = "ecommerce"
  ```
- E2E test: deploys to minikube, runs full request chain, verifies auth propagation

Depends on: PR 8

---

## PR Dependency Graph

```
PR 0 (core: sv_service_call + get_sv_registry hookspecs)
  │
  ├── PR 2 (gateway — uses get_sv_registry)
  │     │
  │     └──┐
  │        │
  │   PR 1 (deployer interface + LocalDeployer — no deps)
  │     │  │
  │     │  ├── PR 5 (CLI — parallel with PR 3/4/8)
  │     │  │
  │     └──┘
  │     │
  │     ▼
  ├── PR 3 (orchestrator — needs deployer + gateway)
  │     │
  │     ├── PR 8 (KubernetesDeployer — parallel with PR 4)
  │     │     │
  │     │     ▼
  │     │   PR 9 (K8s example + E2E)
  │     │
  │     ▼
  └── PR 4 (sv_service_call override — needs core hook + orchestrator)
        │
        ▼
      PR 6 (local example app)
        │
        ▼
      PR 7 (docs — covers both local + K8s)
```

**Parallelism opportunities:**
- PR 0 (core) + PR 1 (deployer) can be developed simultaneously
- PR 5 (CLI) can start as soon as PR 1 lands, runs parallel with PR 3/4/8
- PR 2 (gateway) can start as soon as PR 0 lands
- PR 4 (sv_service_call) and PR 8 (K8s deployer) run in parallel after PR 3
- PR 7 (docs) waits for PR 6 but should also cover K8s from PR 8/9

## PR Sizes (Estimated)

| PR | What | Files | Lines | Tests |
|----|------|-------|-------|-------|
| 0  | Core hookspecs | ~4 | ~100 | ~5 |
| 1  | Deployer + LocalDeployer | ~5 | ~400 | 15 |
| 2  | Gateway + config | ~7 | ~500 | 30 |
| 3  | Orchestrator + hooks | ~4 | ~300 | 10 |
| 4  | sv_service_call override | ~3 | ~250 | 15 |
| 5  | CLI tooling | ~3 | ~350 | 12 |
| 6  | Local example app | ~5 | ~400 | — |
| 7  | Docs (local + K8s) | ~2 | ~400 | — |
| 8  | KubernetesDeployer | ~4 | ~500 | 15 |
| 9  | K8s example + E2E | ~3 | ~200 | ~5 |

---

## Port Strategy

### Local (inherited from core — no changes needed)

```
Hash-based port assignment (already in core's ensure_sv_service):
  base = 18000 + (hash(module_name) % 1000)
  try ports base, base+1, base+2, ... up to base+99

Benefits:
  - Parallel startup (no coordination)
  - Deterministic (same name = same port range across restarts)
  - 100 retries handles collisions
  - Separate from user-facing gateway port (8000)
```

### K8s (fixed port, K8s handles routing)

```
Every service pod listens on port 8000 (fixed).
ClusterIP Service maps port 8000 → targetPort 8000.
No port coordination needed — K8s Services provide stable DNS endpoints.
```

## Network Architecture

### Local

```
Client → Gateway :8000 → /api/products/* → :18342 (subprocess)
                       → /api/orders/*   → :18567 (subprocess)
                       → /api/cart/*     → :18103 (subprocess)
                       → static files
                       → admin UI

Service-to-service (sv import):
  Orders :18567 → sv_service_call("cart_app", ...) → :18103 (direct, no gateway hop)
```

### Kubernetes

```
Client → Ingress → Gateway pod :8000 → /api/products/* → products-app-svc ClusterIP :8000
                                     → /api/orders/*   → orders-app-svc ClusterIP :8000
                                     → /api/cart/*     → cart-app-svc ClusterIP :8000
                                     → static files
                                     → admin UI

Service-to-service (sv import):
  Orders pod → sv_service_call("cart_app", ...)
             → http://cart-app-svc.{ns}.svc.cluster.local:8000 (direct, no gateway hop)
```

## Auth Flow with sv import

Identical on both environments:

```
1. Client → Gateway (Authorization: Bearer USER_TOKEN)
2. Gateway forwards Authorization header → Orders service
3. Orders walker runs, calls: get_cart(user_id)  [sv-imported function]
4. jac-scale @hookimpl sv_service_call:
   a. Reads Authorization from JScaleExecutionContext (set by request middleware)
   b. POST to orders service URL (localhost or K8s DNS) /function/get_cart
      with Authorization: Bearer USER_TOKEN (forwarded)
5. Cart validates token (same JWT secret — from jac.toml locally, from K8s Secret in cluster)
6. Cart returns result via TransportResponse envelope
7. Hook unwraps envelope and returns to caller
```

No manual token passing. The hook reads it from the execution context.

## TOML Config

```toml
# Enable microservice mode
[plugins.scale.microservices]
enabled = true

# Gateway (client-facing — optional for headless service meshes)
[plugins.scale.microservices.gateway]
port = 8000

# Map module names to gateway URL prefixes
[plugins.scale.microservices.routes]
products_app = "/api/products"
orders_app = "/api/orders"
cart_app = "/api/cart"

# Client UI (optional — SPA served by gateway)
[plugins.scale.microservices.client]
entry = "main.jac"

# Resilience tuning (optional — sensible defaults)
[plugins.scale.microservices.resilience]
retry_max = 3
retry_backoff_ms = 100
circuit_breaker_threshold = 5
circuit_breaker_reset_s = 30
health_check_timeout_s = 30

# K8s per-service scaling (optional — only used with --scale)
[plugins.scale.microservices.scaling]
cart_app = { min = 2, max = 10, target_cpu = 60 }
products_app = { min = 1, max = 5, target_cpu = 70 }
# orders_app: no entry = 1 replica, no HPA
```

Services are NOT declared individually — `sv import` handles discovery.
The TOML only maps names to gateway prefixes and tunes operational parameters.
K8s scaling config is optional and only applies when deploying with `--scale`.

## What Changes vs Current

| Current (core default) | New (with jac-scale) |
|------------------------|----------------------|
| Thread + HTTPServer per provider | Subprocess (local) or K8s pod (prod) per provider |
| All services in one process/pod | Each service isolated in own process/pod |
| Raw httpx.post, no auth | Auth forwarded from request context |
| No retry, no circuit breaker | Exponential backoff + circuit breaker |
| Shared `.jac/data/` directory | Isolated data per service (dir or PVC) |
| No gateway | Gateway with path-based routing + static serving |
| No lifecycle management | deploy/stop/restart/logs/destroy via CLI |
| `sv_client._registry` (private) | `get_sv_registry()` public API |
| Monolith K8s deployment | Per-service K8s Deployments + independent scaling |

## What Stays the Same

- Core's `sv import` compiler detection and stub generation
- Core's `_ensure_sv_siblings` BFS traversal (we override the leaf, not the tree walk)
- Core's `sv_client._consumer_providers` tracking
- Core's `is_sv_sibling` flag for recursive spawn prevention
- Port strategy (18000 + hash % 1000) for local mode
- Existing `KubernetesTarget` for whole-app deployment (DB, monitoring, Ingress)
- Existing jac-scale features: SSO, admin, monitoring, storage factories
- Existing test fixtures and test patterns

## Testing Strategy

### Unit tests (per PR)
- Mock subprocess spawning for LocalDeployer tests
- Mock `kubernetes.client` for KubernetesDeployer tests
- Mock httpx for gateway forwarding tests
- Mock execution context for auth propagation tests

### Integration tests (PR 3+)
- Real subprocess spawning with test fixture services (math_service, calculator_service)
- Verify: spawn → health check → sv_client.call → response
- Verify: graceful shutdown ordering
- Use `register_test_client()` pattern for fast in-process tests where subprocess
  spawning is not the thing being tested

### E2E tests
- **Local** (PR 6): Full gateway → service → sv import → service flow
- **K8s** (PR 9): minikube-based deployment, full request chain (CI-only)
- Auth propagation across 3-service chain on both environments

## Graceful Shutdown

### Local (orchestrator, PR 3)

```
1. Stop accepting new requests (gateway returns 503)
2. Drain in-flight requests (configurable timeout, default 10s)
3. Stop dependent services first (orders before cart, if orders sv-imports cart)
4. SIGTERM each subprocess, wait up to 5s
5. SIGKILL any remaining
6. Deregister from sv_client registry
7. Clean up temp files
```

The dependency order for shutdown is the reverse of the BFS startup order
(already tracked in `sv_client._consumer_providers`).

### K8s (KubernetesDeployer, PR 8)

K8s handles graceful shutdown natively:
- Pod receives SIGTERM from kubelet
- `terminationGracePeriodSeconds: 30` (configurable)
- Readiness probe fails → Service stops routing traffic
- Pod drains in-flight requests
- K8s deletes pod after grace period

For full teardown (`jac scale destroy`):
1. Scale all service Deployments to 0 (drain traffic)
2. Delete service Deployments + Services + NetworkPolicies
3. Gateway pod is last to go (part of main app Deployment)

## Resolved Questions

1. **Core PR needed?** → YES. PR 0 adds `sv_service_call` and `get_sv_registry`
   hookspecs. Small, clean, follows established pattern.

2. **Walker support?** → `sv import` generates stubs for `def:pub` functions ONLY.
   Walkers are Architype nodes, not collected by `_collect_abilities`. The pattern
   is: walkers call sv-imported functions, they are not themselves sv-imported.
   Walker-level sv import is a future core compiler enhancement, out of scope here.

3. **Eager vs lazy spawn?** → Keep core's eager spawn. jac-scale overrides the leaf
   hook (`ensure_sv_service`) but lets core's BFS drive traversal. No duplication.

4. **Shared shelf DB?** → RESOLVED. Each service gets isolated data. Local:
   `JAC_DATA_DIR=.jac/data/{module}/`. K8s: separate pods = natural isolation.

5. **TOML simplification?** → TOML only needs `[routes]` for gateway prefix mapping.
   Service discovery is automatic via `sv import` + `_consumer_providers`. Individual
   service declarations are no longer needed.

6. **How does K8s deployment work?** → `KubernetesDeployer` creates one Deployment +
   ClusterIP Service per sv-imported module. Shared container image, different CMD
   per pod. Service discovery via K8s DNS. Coexists with existing `KubernetesTarget`
   which handles the full application stack (DB, monitoring, Ingress).

7. **Per-service scaling?** → Each service gets its own HPA via optional TOML config
   (`[plugins.scale.microservices.scaling]`). Hot services scale independently
   instead of scaling the entire monolith.
