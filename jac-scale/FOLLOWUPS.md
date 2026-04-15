# Microservice Follow-Ups

Simple checklist of what's done and what's next.

---

## ✅ Done

- [x] `sv import` core primitive (on main: a590d10, fa5cbe0, 5da4bd7)
- [x] PR 1: Microservice gateway (`feat/ms-gateway` — this PR)
  - [x] `MicroserviceGateway` FastAPI middleware
  - [x] Path-based reverse proxy (`/api/{service}/walker/*`, `/function/*`)
  - [x] Static file serving + SPA fallback
  - [x] Admin UI serving from pre-built bundle
  - [x] Built-in route passthrough (`/user/*`, `/cl/*`, `/healthz`, etc.)
  - [x] `/health` endpoint with per-service status
  - [x] TOML config schema `[plugins.scale.microservices]`
  - [x] Startup banner
  - [x] 37 tests
  - [x] `admin_portal.__file__` None handling fix
  - [x] Lint clean (console.print, formatted)

---

## 📋 Upcoming PRs

### PR 2: ServiceDeployer + LocalDeployer
- [ ] `ServiceDeployer` abstract interface
- [ ] `LocalDeployer` subprocess-based impl
- [ ] Hash-based port assignment (`18000 + hash % 1000`)
- [ ] Health checks via `/healthz`
- [ ] 12 tests

### PR 3: Orchestrator + Plugin Hooks
- [ ] `start_microservice_mode()` orchestrator
- [ ] `@hookimpl ensure_sv_service` override (subprocess + JFastApiServer)
- [ ] Pre-hook in `plugin.jac` for `microservices.enabled`
- [ ] Entry-point detection (no recursive spawn)
- [ ] `JAC_MICROSERVICE_CHILD=1` safety belt
- [ ] `atexit` graceful shutdown
- [ ] 6+ tests
- [ ] **This unlocks `jac start main.jac` auto-launching everything**

### PR 4: `sv_client.call` Override
- [ ] Auth token extraction from request context
- [ ] Forward `Authorization` header
- [ ] Retry with exponential backoff
- [ ] Circuit breaker
- [ ] Trace ID propagation
- [ ] Tests

### PR 5: CLI Tooling
- [ ] `jac setup microservice` (interactive)
- [ ] `jac setup microservice --add/--remove/--list`
- [ ] `jac scale status`
- [ ] `jac scale stop/restart/logs/destroy`
- [ ] 12 tests

### PR 6: Example App
- [ ] `examples/micr-s-example/` 3-service e-commerce
- [ ] products, orders, cart services
- [ ] Inter-service via `sv import`
- [ ] Frontend with fetch API
- [ ] README

### PR 7: User Documentation
- [ ] `jac_scale/microservices/docs.md`
- [ ] Update `docs/docs/tutorials/production/microservices.md`
- [ ] Architecture diagram

---

## 📋 Production Readiness (Days 10.1–10.6)

### PR 8: Endpoint Passthrough
- [ ] `/sso/*`
- [ ] `/webhooks/*`
- [ ] `/scheduler/*`
- [ ] `/metrics`
- [ ] `/admin/*` passthrough
- [ ] `/docs` and `/openapi.json` aggregated

### PR 9: Distributed Tracing
- [ ] Generate `X-Trace-Id` at gateway
- [ ] Forward through HTTP proxies
- [ ] Forward through `sv_client.call`
- [ ] Structured logs with trace ID

### PR 10: Gateway Metrics
- [ ] Request count per service
- [ ] Error rate per service
- [ ] p50/p95/p99 latency
- [ ] `/metrics` Prometheus format

### PR 11: Error Handling
- [ ] Gateway retry on 503/timeout
- [ ] Backoff in `service_call` / `sv_client.call`
- [ ] Standardized error envelope
- [ ] Circuit breaker
- [ ] Service-down fallback

### PR 12: Admin & Unified Swagger
- [ ] Admin passthrough for all services
- [ ] Unified Swagger at `/docs`
- [ ] Service topology view

### PR 13: Developer Experience
- [ ] Per-service log files
- [ ] Colored/prefixed console output
- [ ] HMR per service
- [ ] `--verbose` flag

---

## 📋 K8s (Future)

### PR 14: KubernetesDeployer
- [ ] `KubernetesDeployer` implementing `ServiceDeployer`
- [ ] `kubectl`-based deploy/stop/restart
- [ ] K8s Service DNS URL resolution
- [ ] HPA support
- [ ] Rolling restart
- [ ] `kubectl logs` integration
- [ ] Multi-service manifest generation

### PR 15: K8s Example + Docs
- [ ] K8s manifests for e-commerce example
- [ ] Ingress config
- [ ] ConfigMaps + Secrets
- [ ] K8s section in microservices tutorial

---

## ❓ Open Questions

- [ ] Add `sv_service_call` hookspec to core, or monkey-patch?
- [ ] Does `sv import` work for `walker:pub`? (currently only `def:pub`)
- [ ] Eager vs lazy spawn — keep both?
- [ ] Multiple subprocesses + shelf DB locking?
- [ ] Simplify TOML — drop service declarations once `sv import` is universal?

---

## Status Summary

| # | PR | Status |
|---|----|--------|
| – | sv import core | ✅ on main |
| 1 | Gateway | ✅ this PR |
| 2 | Deployer | 📋 |
| 3 | Orchestrator | 📋 |
| 4 | sv_client.call override | 📋 |
| 5 | CLI tooling | 📋 |
| 6 | Example app | 📋 |
| 7 | User docs | 📋 |
| 8 | Endpoint passthrough | 📋 |
| 9 | Distributed tracing | 📋 |
| 10 | Gateway metrics | 📋 |
| 11 | Error handling | 📋 |
| 12 | Admin & Swagger | 📋 |
| 13 | Dev experience | 📋 |
| 14 | K8s deployer | 📋 |
| 15 | K8s example | 📋 |
