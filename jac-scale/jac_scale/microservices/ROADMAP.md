# Microservice Mode Roadmap

Feature-scoped tracker for jac-scale microservice mode. Updated as work
lands; not an aspirational planning doc.

## Status matrix

| # | Scope | Status | Commit / file |
|---|-------|--------|---------------|
| 0 | `sv_service_call` hookspec in jaclang core | done | `8e09549c3`, `jac/jaclang/jac0core/runtime.jac` |
| 0b | `get_sv_registry()` hookspec in jaclang core | not started | gateway still reads `sv_client._registry` directly |
| 1 | `ServiceDeployer` abstract + `LocalDeployer` | done | `microservices/deployer.jac`, `local_deployer.jac` |
| 1a | Hash-based port assignment (`18000 + hash % 1000`) | done | `microservices/_util.jac:pick_free_port` |
| 1b | Per-service data isolation via `JAC_DATA_DIR` | done | `plugin.jac:ensure_sv_service` |
| 1c | `/healthz` polling on startup | done | `_util.jac:wait_for_health` |
| 1d | Peer-URL env (`JAC_SV_{NAME}_URL`) injected into children so sv-imports resolve without grandchild spawns | done | `process_manager.impl.jac:start_service` + `start_all` pre-assign |
| 2 | `MicroserviceGateway` FastAPI reverse proxy | done | `microservices/gateway.jac` + `impl/gateway.impl.jac` |
| 2a | Path-based routing (`/api/{service}/*`) | done | `handle_proxy` handler |
| 2b | Static file serving + SPA fallback | done | `handle_static` handler |
| 2c | Admin UI at `/admin/` | done | `handle_admin` + `bootstrap_admin` |
| 2d | Built-in route passthrough | done | `handle_builtin_passthrough` (`/user`, `/walker`, `/function`, `/sso`, etc.) |
| 2e | `/health` with per-service status | done | `handle_health` |
| 2f | TOML schema `[plugins.scale.microservices]` | done | `plugin_config.jac`, `config_loader.impl.jac` |
| 3 | Orchestrator + `ensure_sv_service` hookimpl | done | `microservices/orchestrator.jac`, `plugin.jac` |
| 3a | Client build before services start | done | `orchestrator.jac:start_microservice_mode` |
| 3b | Health-check wait loop with banner | done | `orchestrator.jac` |
| 3c | `JAC_SV_SIBLING` recursive spawn guard | done | `plugin.jac` |
| 3d | `atexit` graceful shutdown | done | `plugin.jac:ensure_sv_service` |
| 4 | `sv_service_call` hookimpl in jac-scale | done | `b1a12c5b0`, `plugin.jac` |
| 4a | Auth extraction from request ContextVar | done | `microservices/_auth_ctx.jac` |
| 4b | Forward `Authorization` header on sv RPC | done | `plugin.jac:sv_service_call` |
| 4c | `TransportResponse` envelope unwrap | done | `plugin.jac:sv_service_call` |
| 4d | Retry with exponential backoff | not started | |
| 4e | Circuit breaker | not started | |
| 4f | `X-Trace-Id` propagation | not started | |
| 5 | `jac setup microservice` CLI | done | `microservices/setup.jac` |
| 5a | `jac scale status/stop/restart/logs/destroy` | done | `plugin.jac:scale_cmd` |
| 6 | E-commerce example app | done | `examples/micr-s-example/` |
| 6a | 3 services: products, cart, orders | done | |
| 6b | Inter-service via `sv import` | done | `orders_app.jac` imports `cart_app` |
| 6c | SPA frontend with gateway API calls | done | `frontend.cl.jac` + `frontend.impl.jac` |
| 7 | User docs | partial | `microservices/docs.md` done; tutorial under `docs/docs/tutorials/` not yet |
| 8 | Complete endpoint passthrough | partial | Covers `/user`, `/sso`, `/walker`, `/function`, `/webhook`, `/ws`, `/jobs`, `/graph`, `/docs`, `/openapi.json`, `/redoc`, `/metrics`. `/admin` served separately |
| 9 | Distributed tracing (X-Trace-Id) | not started | |
| 10 | Gateway metrics (count, latency, error rate) | not started | |
| 11 | Error handling hardening | partial | Basic error envelope done; no retry/circuit-breaker/graceful-degrade |
| 12 | Unified Swagger `/docs` aggregation | not started | Admin UI served; aggregated OpenAPI across services not done |
| 13 | Developer experience | partial | Per-service log files at `.jac/logs/{name}.log` done; colored per-service stdout and HMR not done |
| 14 | `KubernetesDeployer` | not started | Unblocks "same code dev to prod" promise |
| 15 | K8s E2E example | not started | |

## Test coverage

106 tests across 9 suites:

| Suite | Count | What it covers |
|-------|-------|----------------|
| `test_microservices_registry.jac` | 14 | prefix matching, register/deregister, rebuild |
| `test_process_manager.jac` | 15 | subprocess start/stop/restart, health, port pick |
| `test_deployer.jac` | 12 | `ServiceDeployer` interface, `LocalDeployer` |
| `test_gateway.jac` | 28 | all 5 middleware handlers, static, admin, proxy errors |
| `test_orchestrator.jac` | 4 | `build_registry`, config routing |
| `test_setup.jac` | 13 | CLI utilities, add/remove/list, TOML write |
| `test_sv_auth_forward.jac` | 5 | sv_service_call auth forwarding, envelope errors |
| `test_microservice.jac` | 6 | sv_client contract tests (pre-existing) |
| `test_eager_spawn.jac` | 9 | BFS provider discovery (pre-existing) |

## Highest-value next steps

1. **`get_sv_registry()` hookspec** (row 0b) - cheap, removes the last direct access to `sv_client._registry` private state
2. **`KubernetesDeployer`** (row 14) - the one missing piece for the dev/prod story
3. **Retry + trace-id in `sv_service_call`** (4d, 4f) - small additions to the existing hookimpl
4. **Unified `/docs` Swagger** (row 12) - aggregates OpenAPI schemas across services

## How this file is maintained

Check items off when code lands, not when planned. If a row turns into
"not going to happen," delete it rather than marking it stale. This doc
should shrink over time, not grow.

For manual verification steps, see
[`examples/micr-s-example/README.md`](../../examples/micr-s-example/README.md).
