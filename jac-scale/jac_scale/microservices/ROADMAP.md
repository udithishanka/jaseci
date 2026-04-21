# Microservice Mode Roadmap

Feature-scoped tracker for jac-scale microservice mode. Updated as work
lands; not an aspirational planning doc.

## Design target: production-local completeness

The pre-K8s goal is to finish every production concern (observability,
resilience, cross-process lifecycle, shared state) in local mode first.
When `KubernetesDeployer` lands, it's just implementing the same
interfaces the local deployer already exercises - no new architecture
surfaces in K8s.

Shared state model: a **single centralized store** shared across services.
Local mode simulates this with `.jac/data/anchor_store.db` (sqlite on
one filesystem); K8s mode uses an external MongoDB that every pod
connects to. Class deserialization works in both because every service
imports every node type via a shared models module (see
`examples/micr-s-example/shared/models.jac`).

## Pre-K8s ordered tasks

Work top-to-bottom. Each row maps 1:1 to an interface that
`KubernetesDeployer` will implement (not re-architect).

| Order | Task | Why it gates K8s | Production parallel |
|-------|------|-------------------|---------------------|
| P1 ✓ | **URL construction on `ServiceDeployer`** - `url_for(service_entry) -> str` is now the single source of truth. `LocalDeployer.url_for` returns loopback; `ServiceProcessManager` got a `deployer` field and `_url_for` that dispatches through it (with loopback fallback for tests that instantiate `pm` directly). Peer-URL env builder and `entry.url` assignment both go through this. 4 new unit tests + e2e check that every `/health` URL matches the loopback shape | K8sDeployer overrides `url_for` to return `http://{svc}.{ns}.svc.cluster.local:{port}`. No call-site changes needed in K8s | Same interface, different impl |
| P2 skip | *Deferred to K8s bring-up* - `MONGODB_URI` subprocess path isn't independently verified. If it's broken, we'll find out while standing up minikube. Trade: saves ~30 min now, accepts "K8s debug includes storage path" risk | Same env var, same code path in theory | Verification postponed |
| P3 ✓ | **`get_sv_registry()` hookspec in jaclang core** - `JacAPIServer.get_sv_registry -> dict[str, str]` added as a public hookspec. Default impl returns `dict(sv_client._registry)` (snapshot, not a live view). Gateway's `resolve_target_url` now calls `jaclang.JacRuntime.get_sv_registry()` instead of poking `sv_client._registry` directly. 3 new unit tests (dispatch prefers registry over entry.url, fallback to entry.url when unregistered, snapshot semantics) | K8sDeployer's hookimpl populates the registry from K8s Service DNS. Gateway doesn't know or care | Same getter, different producer |
| P4 ~ | **Cross-process CLI state via pidfile** - `.jac/run/{service}.pid` per service. `process_manager.start_service` writes pidfile; `stop_service` dual-mode: Popen handle when in-process, `os.kill`+pid when cross-process. Stop from a separate shell now works. 3 new unit tests (pidfile path, stale-pidfile cleanup, no-pidfile return-False). **Restart deferred**: CLI can spawn a new service but the orchestrator's in-process `sv_client._registry` still holds the old URL, so the gateway routes to the dead port. Fixing that needs a shared (file-backed or socket-based) registry writer, which is a cross-process state task beyond P4's pidfile scope. Tracked as a follow-up | K8sDeployer backs the same CLI with `kubectl get pod` / `kubectl delete pod`; K8s doesn't have the registry-sync gap because K8s Service DNS is the authority | Same CLI shape, different state source |
| P5 | **Retry with exponential backoff** in `sv_service_call` hookimpl (row 4d) - N retries, backoff, connect+read timeouts. Applies to both local and K8s transports | K8s networking has pod restarts and transient DNS resolution failures. Retry in the hookimpl means every sv-import call gets resilience for free | Same hookimpl, same behavior |
| P6 | **Circuit breaker** in `sv_service_call` (row 4e) - per-provider half-open/open/closed state with a trip threshold. Fails fast when a downstream is unhealthy instead of piling up stuck requests | Prevents cascade failures when one K8s pod is unhealthy. Essential in prod; a local simulation tests the failure semantics | Same code |
| P7 | **`X-Trace-Id` propagation** (rows 4f + 9) - generate at gateway ingress, thread through `build_forward_headers` for proxy calls and the `sv_service_call` hookimpl via a ContextVar next to `_auth_ctx`. Log it on each service | Tracing is the primary observability tool in K8s. Same header flows through local and prod | Same code; K8s just adds Jaeger/Tempo collector |
| P8 | **Gateway + per-service metrics** (row 10) - `/metrics` Prometheus endpoint on the gateway. Per-service request count, error rate, p50/p95/p99 latency histograms. Reuse jac-scale's existing `monitoring` config | K8s pod gets scraped by Prometheus. Local simulation runs prom scraping against `http://localhost:8000/metrics`. Identical metric shape | Same exposition format |
| P9 | **Unified `/docs` Swagger aggregation** (row 12) - gateway aggregates OpenAPI schemas from all healthy services into one `/docs` view | Same in K8s - unified API surface for consumers. Local and prod both see one Swagger | Same aggregator |
| P10 | **Standardized error envelope + graceful degradation** (row 11) - consistent error shape across proxy, passthrough, and sv_service_call failure paths. Service-down -> gateway returns 503 with retry-after | K8s pod evictions are normal; clients need predictable error semantics | Same envelope |
| P11 | **Developer experience** (row 13) - colored per-service log prefixes in the orchestrator console output, consolidated tail view across services | Local-only niceness; doesn't map to K8s (use `kubectl logs` there) | N/A |
| P12 | **User docs + dev-setup section** (row 7, F) - editable-install prerequisites, MongoDB quickstart, the production-local contract. Tutorial at `docs/docs/tutorials/production/microservices.md` | Documents the interface contract K8sDeployer will satisfy | Documentation |

After P1-P12, the K8s work is bounded:

| | Task |
|---|------|
| K1 | `KubernetesDeployer` - implements `deploy_service`, `stop_service`, `restart_service`, `url_for`, `status`, `get_logs`, `destroy_all`. Plus the `get_sv_registry` hookimpl sourced from K8s Service DNS |
| K2 | Manifest generation (Deployment + ClusterIP Service per microservice, Ingress at gateway) |
| K3 | HPA per service, wired to the `scale_service(name, replicas)` interface |
| K4 | K8s manifests for the example app + minikube E2E in CI |

## Status matrix

| # | Scope | Status | Commit / file |
|---|-------|--------|---------------|
| 0 | `sv_service_call` hookspec in jaclang core | done | `8e09549c3`, `jac/jaclang/jac0core/runtime.jac` |
| 0b | `get_sv_registry()` hookspec (→ P3) | done | `jac/jaclang/jac0core/runtime.jac` hookspec + default impl returning `dict(sv_client._registry)`. Gateway uses `jaclang.JacRuntime.get_sv_registry()` |
| 1 | `ServiceDeployer` abstract + `LocalDeployer` | done | `microservices/deployer.jac`, `local_deployer.jac` |
| 1a | Hash-based port assignment (`18000 + hash % 1000`) | done | `microservices/_util.jac:pick_free_port` |
| 1b | Shared anchor store across all services | done locally | single `.jac/data/anchor_store.db`; each service imports shared node classes so deserialize resolves. See `examples/micr-s-example/shared/models.jac`. K8s uses shared external Mongo (→ P2) |
| 1c | `/healthz` polling on startup | done | `_util.jac:wait_for_health` |
| 1d | Peer-URL env (`JAC_SV_{NAME}_URL`) injected into children so sv-imports resolve without grandchild spawns | done | `process_manager.impl.jac:start_service` + `start_all` pre-assign |
| 1e | URL construction abstraction (→ P1) | done | `ServiceDeployer.url_for` in `deployer.jac`; `LocalDeployer.url_for` returns loopback; `process_manager._url_for` dispatches via injected deployer |
| 1f | Shared Mongo storage verification (→ P2) | deferred | Skipped before K8s by choice; will surface in PR 15 if there's a subprocess-env gap |
| 2 | `MicroserviceGateway` FastAPI reverse proxy | done | `microservices/gateway.jac` + `impl/gateway.impl.jac` |
| 2a | Path-based routing (`/api/{service}/*`) | done | `handle_proxy` handler |
| 2b | Static file serving + SPA fallback | done | `handle_static` handler |
| 2c | Admin UI at `/admin/` | done | `handle_admin` + `bootstrap_admin` |
| 2d | Built-in route passthrough | done | `handle_builtin_passthrough` |
| 2e | `/health` with per-service status | done | `handle_health` |
| 2f | TOML schema `[plugins.scale.microservices]` | done | `plugin_config.jac`, `config_loader.impl.jac` |
| 3 | Orchestrator + `ensure_sv_service` hookimpl | done | `microservices/orchestrator.jac`, `plugin.jac` |
| 3a | Client build before services start | done | `orchestrator.jac:start_microservice_mode` |
| 3b | Health-check wait loop with banner | done | `orchestrator.jac` |
| 3c | `JAC_SV_SIBLING` recursive spawn guard | done | `plugin.jac` |
| 3d | `atexit` graceful shutdown | done | `plugin.jac:ensure_sv_service` |
| 3e | Sequential service startup (avoid CREATE TABLE race) | done | `process_manager.start_all` waits on `/healthz` between spawns |
| 4 | `sv_service_call` hookimpl in jac-scale | done | `b1a12c5b0`, `plugin.jac` |
| 4a | Auth extraction from request ContextVar | done | `microservices/_auth_ctx.jac` |
| 4b | Forward `Authorization` header on sv RPC | done | `plugin.jac:sv_service_call` |
| 4c | `TransportResponse` envelope unwrap | done | `plugin.jac:sv_service_call` |
| 4d | Retry with exponential backoff (→ P5) | not started | |
| 4e | Circuit breaker (→ P6) | not started | |
| 4f | `X-Trace-Id` propagation (→ P7) | not started | |
| 5 | `jac setup microservice` CLI | done | `microservices/setup.jac` |
| 5a | `jac scale status/stop/logs` (→ P4) | done | `scale_cmd` + `pm.stop_service` now read `.jac/run/{name}.pid` when there's no Popen handle. `stop` + `logs` + `status` work cross-process |
| 5b | `jac scale restart` cross-process (follow-up to P4) | not started | `pm.start_service` spawns on new URL; orchestrator's in-process `sv_client._registry` isn't updated by external CLI. Needs a shared registry writer (file-backed or HTTP admin endpoint) |
| 6 | E-commerce example app | done | `examples/micr-s-example/` |
| 6a | 3 services: products, cart, orders | done | |
| 6b | Inter-service via `sv import` | done | `orders_app.jac` imports `cart_app` |
| 6c | SPA frontend with gateway API calls | done | `frontend.cl.jac` + `frontend.impl.jac` |
| 6d | e2e shell test (32 checks) | done | `examples/micr-s-example/test_e2e.sh` |
| 7 | User docs + production-local architecture (→ P12) | partial | `microservices/docs.md` done; tutorial + dev-setup section not yet |
| 8 | Complete endpoint passthrough | partial | Covers `/user`, `/sso`, `/walker`, `/function`, `/webhook`, `/ws`, `/jobs`, `/graph`, `/docs`, `/openapi.json`, `/redoc`, `/metrics`. `/admin` served separately |
| 9 | Distributed tracing - X-Trace-Id (→ P7) | not started | |
| 10 | Gateway + per-service metrics (→ P8) | not started | |
| 11 | Standardized error envelope + graceful degradation (→ P10) | partial | Basic error envelope done; no retry/circuit-breaker/graceful-degrade |
| 12 | Unified Swagger `/docs` aggregation (→ P9) | not started | |
| 13 | Developer experience - colored per-service logs (→ P11) | partial | Per-service log files at `.jac/logs/{name}.log` done; colored console output not done |
| 14 | `KubernetesDeployer` (→ K1) | not started | |
| 15 | K8s manifests + HPA + minikube E2E (→ K2-K4) | not started | |

## Test coverage

121 tests green across 9 suites:

| Suite | Count | What it covers |
|-------|-------|----------------|
| `test_microservices_registry.jac` | 14 | prefix matching, register/deregister, rebuild |
| `test_process_manager.jac` | 18 | subprocess start/stop/restart, health, port pick, pidfile cross-process stop + stale-pidfile cleanup |
| `test_deployer.jac` | 16 | `ServiceDeployer` interface, `LocalDeployer`, `url_for` dispatch + pm wiring |
| `test_gateway.jac` | 31 | all 5 middleware handlers, static, admin, proxy errors, `get_sv_registry` hookspec dispatch |
| `test_orchestrator.jac` | 4 | `build_registry`, config routing |
| `test_setup.jac` | 13 | CLI utilities, add/remove/list, TOML write |
| `test_sv_auth_forward.jac` | 5 | sv_service_call auth forwarding, envelope errors |
| `test_microservice.jac` | 6 | sv_client contract tests (pre-existing) |
| `test_eager_spawn.jac` | 9 | BFS provider discovery (pre-existing) |
| `examples/micr-s-example/test_e2e.sh` | 36 | end-to-end: stack boot, deployer invariants (incl. url_for shape), gateway surface, auth, sv-import auth forwarding, CLI (incl. pidfile + cross-process stop) |

## How this file is maintained

Check items off when code lands, not when planned. Pre-K8s tasks go in
order (P1 → P12); only move to K1+ once everything above is done or
explicitly deferred with a reason. This doc should shrink over time,
not grow.

For manual verification steps, see
[`examples/micr-s-example/README.md`](../../examples/micr-s-example/README.md).
