# Microservice Mode — PR Tracker

## ✅ Done

- [x] `sv import` core primitive (on main)

---

## 📋 PRs

### PR 0: Core hookspec additions
**Repo**: jaclang (core)

- [ ] `sv_service_call(module_name, func_name, args)` hookspec
- [ ] `get_sv_registry() -> dict[str, str]` hookspec
- [ ] `sv_client.call()` delegates to hook
- [ ] Tests

### PR 1: ServiceDeployer + LocalDeployer

- [ ] `ServiceDeployer` abstract interface
- [ ] `LocalDeployer` subprocess impl
- [ ] Hash-based ports (`18000 + hash % 1000`)
- [ ] `JAC_DATA_DIR` per-service data isolation
- [ ] `/healthz` health checks
- [ ] Tests

### PR 2: Microservice Gateway

- [ ] `MicroserviceGateway` FastAPI middleware
- [ ] Path-based reverse proxy (`/api/{service}/*`)
- [ ] Reads URLs from `get_sv_registry()`
- [ ] Static file serving + SPA fallback
- [ ] Admin UI serving
- [ ] Built-in route passthrough (`/user/*`, `/cl/*`, `/healthz`, etc.)
- [ ] `/health` with per-service status
- [ ] TOML config `[plugins.scale.microservices]`
- [ ] Tests

### PR 3: Orchestrator + `ensure_sv_service` override

- [ ] `@hookimpl ensure_sv_service` — subprocess spawning via `LocalDeployer`
- [ ] Core BFS (`_ensure_sv_siblings`) drives discovery
- [ ] Client build before services start
- [ ] Health check wait loop
- [ ] Startup banner
- [ ] `JAC_MICROSERVICE_CHILD=1` recursive spawn prevention
- [ ] Gateway startup after services healthy
- [ ] `atexit` graceful shutdown
- [ ] Tests

### PR 4: `sv_service_call` override

- [ ] `@hookimpl sv_service_call` in plugin.jac
- [ ] Auth extraction from `JScaleExecutionContext`
- [ ] Forward `Authorization` header automatically
- [ ] Retry with exponential backoff
- [ ] Circuit breaker
- [ ] `TransportResponse` envelope unwrap
- [ ] Trace ID propagation
- [ ] Tests

### PR 5: CLI Tooling

- [ ] `jac setup microservice` (interactive + `--add/--remove/--list`)
- [ ] `jac scale status` (reads `get_sv_registry()`)
- [ ] `jac scale stop/restart/logs/destroy`
- [ ] Tests

### PR 6: Example App

- [ ] 3-service e-commerce (products, orders, cart)
- [ ] Services expose `def:pub` functions via `sv {}`
- [ ] Inter-service via `sv import` (not manual HTTP)
- [ ] Frontend with gateway API calls
- [ ] README

### PR 7: Documentation

- [ ] User docs (`docs.md`)
- [ ] Architecture doc
- [ ] Tutorial at `docs/docs/tutorials/production/microservices.md`

---

## 📋 Production Hardening

### PR 8: Complete endpoint passthrough
- [ ] All jac-scale endpoints accessible via gateway

### PR 9: Distributed tracing
- [ ] `X-Trace-Id` propagation gateway → services → sv_client.call

### PR 10: Gateway metrics
- [ ] Per-service request count, error rate, latency

### PR 11: Error handling
- [ ] Standardized error envelope, graceful degradation

### PR 12: Admin & unified Swagger
- [ ] Unified `/docs` across services

### PR 13: Developer experience
- [ ] Per-service log files, colored output, HMR

---

## 📋 K8s

### PR 14: KubernetesDeployer
- [ ] `ServiceDeployer` impl for K8s
- [ ] Same image, different CMD per pod
- [ ] K8s DNS service discovery
- [ ] Per-service HPA
- [ ] Tests (mocked K8s client)

### PR 15: K8s example + E2E
- [ ] Same example app deployed to K8s
- [ ] minikube E2E test

---

## Status

| # | PR | Status |
|---|----|--------|
| 0 | Core hookspecs | 📋 |
| 1 | Deployer | 📋 |
| 2 | Gateway | 📋 |
| 3 | Orchestrator | 📋 |
| 4 | sv_service_call | 📋 |
| 5 | CLI | 📋 |
| 6 | Example | 📋 |
| 7 | Docs | 📋 |
| 8-13 | Production | 📋 |
| 14-15 | K8s | 📋 |
