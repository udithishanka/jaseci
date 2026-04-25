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
| P5 ✓ | **Retry with exponential backoff** in `sv_service_call` hookimpl - 3 attempts, 0.1s -> 0.2s -> 0.4s backoff, 10s connect+read timeout on each. Retries on transport errors (`httpx.RequestError`, `TimeoutException`) but NOT on application-level `ok=false` envelope errors (those are deterministic). Test clients bypass retry (in-process, no transport). Refactored envelope unwrap into `_unwrap_sv_envelope` helper so both retry and test-client paths share it. 3 new unit tests (transient-then-success, persistent failure exhausts attempts, app-error skips retry) | K8s pod restarts + DNS propagation lag + network blips all covered. Same hookimpl, same behavior | Same code |
| P6 ✓ | **Circuit breaker** in `sv_service_call` - per-provider CLOSED/OPEN/HALF_OPEN state machine in `plugin.jac`. Trips OPEN after 5 consecutive retry-exhausted transport-failure cycles; fail-fast with "blocked by open circuit breaker" for 30s cooldown; first call after cooldown becomes a HALF_OPEN probe (success -> CLOSED, failure -> back to OPEN). App-level envelope errors do NOT count (deterministic). Process-local state (dict + threading.Lock) - matches K8s pod-local semantics. 4 new unit tests (trip, success resets counter, HALF_OPEN probe success closes, app errors don't trip) | Prevents cascade failures when one K8s pod is unhealthy. Each pod runs its own breaker, which is the right granularity | Same code |
| P7 ✓ | **`X-Trace-Id` propagation** - new `microservices/_trace_ctx.jac` (ContextVar + set/get/reset + `ensure_trace_id` UUID4 minter + `TraceIdLogFilter` that prepends `[trace=<short>]` to root-logger messages). Gateway middleware stamps the ContextVar at ingress (preserving inbound header or minting fresh); `build_forward_headers` always emits `X-Trace-Id` downstream. Service middleware in `jfast_api.impl.jac` captures inbound, installs log filter on import, and echoes `X-Trace-Id` on every response. `sv_service_call` hookimpl forwards the ContextVar to the next hop's httpx.post. 6 unit tests (ctx round-trip, None handling, UUID4 mint, forwarding on sv, omits when unset) + 2 e2e (gateway round-trip echo, auto-mint when client omits) | Every external request gets a consistent correlator across every hop. Jaeger/Tempo in K8s just consumes the same header | Same code end-to-end |
| P8 ✓ | **Gateway + per-service metrics** - new `microservices/_metrics.jac` with `build_gateway_metrics` (fresh CollectorRegistry per gateway), `classify_outcome` (status -> 2xx/3xx/4xx/5xx/err), `render_metrics`. Gateway dispatcher wraps every request with start-time + counter + histogram observation. Service label is the matched route name, or one of `__health__`, `__builtin__`, `__admin__`, `__static__`, `__metrics__`, `__unmatched__`. Namespace + histogram buckets pulled from `get_monitoring_config()`. `/metrics` dispatched before passthrough (removed from `_BUILTIN_EXACT` to prevent accidental proxying). No-op when `prometheus_client` isn't installed. 4 new unit tests + 2 e2e (exposition reachable, `__health__` label recorded) | Prometheus scrapes `http://{gateway-pod}:8000/metrics`. Dashboards written locally work in K8s unchanged | Same exposition format |
| P9 ✓ | **Unified `/docs` Swagger aggregation** - new `microservices/_openapi_agg.jac` sequentially fetches each healthy service's `/openapi.json` via `urllib`, rewrites paths with the service's gateway prefix, merges `components.schemas` (first-wins on name collisions). Gateway owns `/docs` (Swagger UI pointing at `/openapi.json`) and `/openapi.json` (the merged doc). Both removed from `_BUILTIN_EXACT` so they're served locally instead of proxying. Gateway's own `/health` + `/metrics` always appear in the merged doc so consumers see the full surface. 5 new unit tests + 3 new e2e checks | Same aggregator + Swagger UI in K8s. Consumers see one API surface regardless of deploy target | Same aggregator |
| P10 ✓ | **Standardized error envelope + graceful degradation** - new `microservices/_errors.jac` with `error_response(code, message, status, service?, retry_after?)` helper + three convenience wrappers (`service_unavailable`, `gateway_timeout`, `not_found`). Envelope shape matches jac-scale's TransportResponse (`ok=false`, `error.code`, `error.message`, optional `error.service`, auto-filled `error.trace_id` from `_trace_ctx`). 503 responses ship `Retry-After: 2` so clients back off during pod restarts; 502/404 omit it. Every inline JSONResponse error in `gateway.impl.jac` replaced with the helper. 4 new unit tests + 2 e2e | K8s pod evictions are routine; consistent envelope means clients don't need to distinguish gateway from service errors. Retry-After works with standard retry-friendly HTTP clients | Same envelope shape |
| P11 skip | *Colored per-service log prefixes* - local-only DX polish; doesn't apply in K8s (use `kubectl logs`). Deliberately skipped | N/A | Skipped |
| P12 ✓ | **User docs + dev-setup section** - three layers now complete: (a) internal reference `microservices/docs.md` gains a "Production-Hardening Knobs" section covering drain, per-service rpc_timeout, WebSockets, CORS, rate limiting, observability with config snippets; (b) external tutorial `docs/docs/tutorials/production/microservices.md` gains a "Microservice Mode + Gateway" subsection with the knobs-at-a-glance table; (c) `jac setup microservice` now emits commented-out reference blocks for all hardening knobs (drain, rpc_timeout, CORS, rate_limit) so new projects discover them without activating unsafe defaults; (d) example README cross-links to the reference + calls out which knobs e2e exercises vs unit-tests | Documents the interface contract K8sDeployer will satisfy | Documentation |
| P13 ✓ | **Graceful shutdown / drain** - new `microservices/_drain.jac` with process-singleton drain state (is_draining, inflight counter, zero-event for wait-for-drain), a FastAPI middleware that 503s+`Retry-After: 2` new requests arriving after SIGTERM (standard envelope + service label), and `install_signal_drain` that wraps `uvicorn.Server.handle_exit` so the drain flag flips before uvicorn's own exit handler runs. Both service (`jfast_api.run_server`) and gateway (`gateway.start`) switched from `uvicorn.run` to `uvicorn.Config/Server` so `timeout_graceful_shutdown` is set (default 10s via new `drain_timeout_seconds` config under `microservices`). Drain middleware registered last so Starlette `insert(0,...)` puts it outermost - runs before dispatcher/metrics/trace so 503s don't burn metric labels. 14 unit tests (state, middleware, signal wrapping) + 2 gateway integration tests + 4 e2e checks (pid/port pre-SIGTERM, port closed within graceful window, drain log-line in service log) | K8s rolling deploys rely on `preStop` + `terminationGracePeriodSeconds`. Same drain semantics, just triggered by kubelet's SIGTERM | Same code |
| P14 ✓ | **Per-service RPC timeout override** - new `services` dict under `[plugins.scale.microservices]`, each entry `{rpc_timeout: float_seconds}`. `sv_service_call` hookimpl resolves it via a new `_sv_rpc_timeout(module_name)` helper (reads from `get_scale_config().get_microservices_config()['services']`, defaults 10s, fail-safe on config errors) and passes it to `httpx.post(timeout=...)`. 3 new unit tests (default timeout pass-through, per-service override pass-through, resolver fallback on config failure) | K8s just reads the same config key from a ConfigMap - no K8s-specific code path | Same config key |
| P15 ✓ | **WebSockets + SSE streaming on gateway** - HTTP streaming via a new `ForwardResult` + `stream_forward` in `impl/http_forward.jac`: opens the upstream response, lets the caller peek `status`/`headers` before deciding to wrap in `StreamingResponse` (session + response closed in the iterator's finally). `raw_forward` kept for the 404-try-next passthrough path; `handle_proxy` switched to `stream_forward` so SSE / chunked / large bodies flow through without buffering. WebSocket proxy via new `microservices/_ws_forward.jac` (aiohttp `ws_connect`, two-pump `asyncio.gather`, filtered handshake headers: keep auth/trace/XFF, strip cookies + the standard WS hop-by-hops). Gateway registers a catch-all `@app.websocket("/{ws_path:path}")` via module-level `_install_ws_catchall(gw)`. **Key PEP-563 gotcha fixed**: Jac compiles with `from __future__ import annotations`, so parameter annotations are strings. FastAPI resolves those via `get_type_hints(endpoint)` which uses the endpoint's `__globals__` - if `WebSocket` is only imported inside a helper function, resolution fails silently, no WebSocket is injected, and uvicorn 403s every upgrade. Fix: `import from fastapi { WebSocket }` at module scope of `gateway.impl.jac`. 12 unit tests in new `test_stream_ws.jac` cover URL scheme rewrite, header filtering, streaming round-trip (SSE, chunked 64KB, cleanup path, connect-refused -> None, raw_forward buffer path) + 2 gateway ws route tests. 2 new e2e checks: WS through gateway proxies to products_app `EchoMessage` walker end-to-end, and WS to unmatched path closes with 1008. | K8s Services are L4 pass-through for ws/sse. Same gateway handler works in-cluster unchanged | Same code |
| P16 ✓ | **CORS middleware on gateway** - FastAPI `CORSMiddleware` installed on the gateway app; fully configured via `[plugins.scale.microservices.cors]` (allow_origins, allow_methods, allow_headers, allow_credentials, expose_headers, max_age). Disabled unless `allow_origins` is non-empty. Registered AFTER drain so preflights answer correctly even during graceful shutdown (clients need CORS headers to read the 503 envelope). 4 unit tests (disabled-by-default, preflight, simple-request, drain interaction) | Gateway-level middleware - K8s runs the same app unchanged | Same code |
| P17 ✓ | **Rate limiting (per-IP + per-user)** - new `microservices/_rate_limit.jac` with `TokenBucket` + `InProcessRateLimiter` (thread-safe via module-level lock; negligible contention since state per bucket is two floats) + `build_rate_limit_middleware`. Per-IP bucket keyed on `X-Forwarded-For` / `request.client.host`, per-user bucket keyed on `sha256(Authorization)[:32]`. Config: `[plugins.scale.microservices.rate_limit]` with `enabled`, `per_ip_rpm`, `per_user_rpm`, `burst_multiplier` (capacity = rpm * burst / 60), `exempt_paths` (default `/health`, `/healthz`, `/metrics`). Registered between drain and CORS so preflights bypass it entirely. 429 returns `RATE_LIMITED` envelope + `Retry-After`. 9 unit tests in new `test_rate_limit.jac` (bucket consume/refill/isolate, disabled, 429 once empty, exempt paths, per-user on top of per-IP, envelope shape, X-Forwarded-For key precedence) | K8s Ingress can layer infra rate-limits on top; app-level still valid per-pod. Redis backend is a K8s-era addition (would slot behind the same `RateLimiterBackend` shape). | Same interface |
| P18 ✓ | **Declarative static mounts** - gateway can serve repo-root directories outside `client.dist_dir` without restructuring the build. New `static_mounts: list[dict]` field on `MicroserviceGateway`, configured via `[[plugins.scale.microservices.client.static_mounts]]` array-of-tables (each entry has `url_prefix` + `local_path`). `handle_static` checks mounts first; matched-prefix-but-missing-file returns 404 (canonical ownership — does NOT silently fall back to dist, which would mask config bugs). New `serve_extra_static(local_dir, file_path)` helper path-jails to the mount via `Path.resolve()` + common-prefix check (rejects `..` / symlink escapes). Orchestrator parses the array and prints the configured mounts in the startup banner. 7 unit tests in `test_gateway.jac`: serve_extra_static happy path, empty local_dir guard, missing-file 404, traversal block, dispatch wins-over-dist, dispatch fall-through-to-dist for non-matching prefix, matched-but-missing returns 404 instead of dist fallback. Closes the gap surfaced by the jac-builder microservices migration where /static/assets/onigasm.wasm + similar repo-root assets 404'd in microservices mode. | App-level config; no infra change. K8s ConfigMaps / volume-mounts can pin the local_path target if desired. | Same interface |

After P1-P18, the K8s work is bounded:

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
| 4d | Retry with exponential backoff (→ P5) | done | `plugin.jac:sv_service_call` retries 3x on transport errors with 0.1s/0.2s/0.4s backoff; does not retry on application envelope errors |
| 4e | Circuit breaker (→ P6) | done | `plugin.jac`: per-provider CLOSED/OPEN/HALF_OPEN, trip threshold 5, cooldown 30s. App errors don't count |
| 4f | `X-Trace-Id` propagation (→ P7) | done | ContextVar + middleware + sv_service_call forwarding + response-header echo |
| 5 | `jac setup microservice` CLI | done | `microservices/setup.jac` |
| 5a | `jac scale status/stop/logs` (→ P4) | done | `scale_cmd` + `pm.stop_service` now read `.jac/run/{name}.pid` when there's no Popen handle. `stop` + `logs` + `status` work cross-process |
| 5b | `jac scale restart` cross-process (follow-up to P4) | not started | `pm.start_service` spawns on new URL; orchestrator's in-process `sv_client._registry` isn't updated by external CLI. Needs a shared registry writer (file-backed or HTTP admin endpoint) |
| 6 | E-commerce example app | done | `examples/micr-s-example/` |
| 6a | 3 services: products, cart, orders | done | |
| 6b | Inter-service via `sv import` | done | `orders_app.jac` imports `cart_app` |
| 6c | SPA frontend with gateway API calls | done | `frontend.cl.jac` + `frontend.impl.jac` |
| 6d | e2e shell test (32 checks) | done | `examples/micr-s-example/test_e2e.sh` |
| 7 | User docs + production-local architecture (→ P12) | done | `microservices/docs.md` + production-hardening reference; `docs/.../production/microservices.md` tutorial; `jac setup microservice` emits commented reference blocks; example README cross-links |
| 8 | Complete endpoint passthrough | partial | Covers `/user`, `/sso`, `/walker`, `/function`, `/webhook`, `/ws`, `/jobs`, `/graph`, `/docs`, `/openapi.json`, `/redoc`, `/metrics`. `/admin` served separately |
| 9 | Distributed tracing - X-Trace-Id (→ P7) | done | See row 4f. Jaeger/Tempo collection in K8s deferred post-K8s |
| 10 | Gateway + per-service metrics (→ P8) | done | Prometheus Counter + Histogram on `/metrics`; `jac_scale_gateway_requests_total{service,method,outcome}` + `_request_duration_seconds` |
| 11 | Standardized error envelope + graceful degradation (→ P10) | done | `_errors.jac` with `SERVICE_UNAVAILABLE` / `GATEWAY_TIMEOUT` / `NOT_FOUND` / `METRICS_UNAVAILABLE` codes; `Retry-After: 2` on 503 |
| 12 | Unified Swagger `/docs` aggregation (→ P9) | done | `_openapi_agg.aggregate_openapi` + gateway `handle_docs` / `handle_openapi`. Merged paths prefixed with each service's gateway route |
| 13 | Developer experience - colored per-service logs (→ P11) | skipped | Per-service `.jac/logs/{name}.log` done; colored console output deliberately skipped - local-only, K8s uses `kubectl logs` |
| 14 | Graceful drain on SIGTERM (→ P13) | done | `microservices/_drain.jac` + middleware registered on both service (`jfast_api`) and gateway; `install_signal_drain` wraps `uvicorn.Server.handle_exit`; `timeout_graceful_shutdown` honored via `drain_timeout_seconds` config |
| 15 | Per-service RPC timeout override (→ P14) | done | `[plugins.scale.microservices.services.NAME].rpc_timeout` reads through `_sv_rpc_timeout` helper in `plugin.jac`, passed to `httpx.post(timeout=...)` |
| 16 | WebSockets + SSE streaming (→ P15) | done | `microservices/_ws_forward.jac` + `stream_forward` / `ForwardResult` in `impl/http_forward.jac`; `handle_proxy` streams; `_install_ws_catchall(gw)` registers `@app.websocket('/{ws_path:path}')` at module scope. `WebSocket` imported at file-module scope so FastAPI's PEP-563 annotation resolution succeeds. Exercised e2e via products_app `EchoMessage` walker |
| 17 | CORS on gateway (→ P16) | done | `[plugins.scale.microservices.cors]`; `CORSMiddleware` registered after drain so preflights answer during graceful shutdown |
| 18 | Rate limiting (→ P17) | done | `microservices/_rate_limit.jac` token bucket; per-IP + per-user; 429 + Retry-After; registered between drain and CORS |
| 19 | `KubernetesDeployer` (→ K1) | not started | |
| 20 | K8s manifests + HPA + minikube E2E (→ K2-K4) | not started | |

## Test coverage

186 tests green across 12 suites:

| Suite | Count | What it covers |
|-------|-------|----------------|
| `test_microservices_registry.jac` | 14 | prefix matching, register/deregister, rebuild |
| `test_process_manager.jac` | 18 | subprocess start/stop/restart, health, port pick, pidfile cross-process stop + stale-pidfile cleanup |
| `test_deployer.jac` | 16 | `ServiceDeployer` interface, `LocalDeployer`, `url_for` dispatch + pm wiring |
| `test_gateway.jac` | 50 | middleware handlers, static, admin, proxy errors, `get_sv_registry` hookspec dispatch, Prometheus metrics, Swagger UI + aggregated /openapi.json, standardized error envelope + Retry-After + trace_id correlation, drain 503 via TestClient with/without X-Trace-Id leakage, CORS (disabled-by-default, preflight, simple-request, drain interaction) |
| `test_drain.jac` | 14 | drain state primitives (start/inflight/wait_for_zero), middleware 503+envelope + inflight tracking across concurrent reqs, signal-handler wrapping + chaining |
| `test_stream_ws.jac` | 12 | ws url-scheme rewrite + handshake-header filter, stream_forward end-to-end (SSE + chunked 64KB + cleanup + connect-refused), raw_forward buffer path, gateway ws catch-all: 1008 no-match + 1012 drain (via Starlette TestClient) |
| `test_rate_limit.jac` | 9 | token-bucket consume/refill/isolate, middleware disabled/enabled, 429 RATE_LIMITED envelope + Retry-After, exempt paths, per-user on top of per-IP, X-Forwarded-For precedence |
| `test_orchestrator.jac` | 4 | `build_registry`, config routing |
| `test_setup.jac` | 13 | CLI utilities, add/remove/list, TOML write |
| `test_sv_auth_forward.jac` | 21 | sv_service_call auth forwarding, envelope errors, retry, circuit breaker (trip, counter reset, HALF_OPEN probe, app-errors-don't-trip), trace-ctx round-trip, UUID4 mint, sv forwarding of X-Trace-Id, per-service rpc_timeout resolution (default / override / config-failure fallback) |
| `test_microservice.jac` | 6 | sv_client contract tests (pre-existing) |
| `test_eager_spawn.jac` | 9 | BFS provider discovery (pre-existing) |
| `examples/micr-s-example/test_e2e.sh` | 54 | end-to-end: stack boot, deployer invariants, gateway surface (incl. /metrics + unified /docs + /openapi.json aggregation), auth, sv-import auth forwarding, CLI (incl. pidfile), X-Trace-Id round-trip + auto-mint, standardized error envelope on stopped service, P13 graceful drain (SIGTERM -> port closed within window + drain log line), P15 WS through gateway (products_app EchoMessage walker round-trip + unmatched-path 1008 close), P16 CORS (preflight Allow-Origin+Allow-Credentials, simple-request Allow-Origin, disallowed origin rejection) |

## How this file is maintained

Check items off when code lands, not when planned. Pre-K8s tasks go in
order (P1 → P12); only move to K1+ once everything above is done or
explicitly deferred with a reason. This doc should shrink over time,
not grow.

For manual verification steps, see
[`examples/micr-s-example/README.md`](../../examples/micr-s-example/README.md).
