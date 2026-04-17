# Microservice Mode: 20-Day Learn & Do Program

A structured program where you **learn a concept each day** and **immediately apply it** by building a piece of the microservice module in jac-scale.

## How This Works

- Each day has a **Learn** section (concept + reading) and a **Do** section (implementation task)
- **Days 1-10**: Build the microservice module from scratch — by Day 10 you have the full feature working
- **Days 11-20**: Master production concerns — testing, resilience, security, performance, and operations
- Each day ends with a **Milestone** — a concrete thing you can run/test to prove it works
- Estimated ~3-4 hours per day (1h learn, 2-3h code)

## Prerequisites

- You can write Jac code and know the jac-scale codebase basics
- You have a local dev setup (Python, jac, jac-scale editable install)
- You can run `jac start some_file.jac` and hit endpoints

---

## Part 1: Build It (Days 1-10)

Build the microservice module from zero to a working system.

| Day | Learn | Do | Milestone |
|-----|-------|----|-----------|
| [1](day-01-what-are-microservices.md) | What are microservices? Monolith vs decomposed | Set up the module skeleton + TOML config schema | `jac.toml` parses `[plugins.scale.microservices]` without errors |
| [2](day-02-service-registry.md) | Service registries & discovery | Build `ServiceRegistry` + `ServiceEntry` | Unit test: register/deregister/lookup services by prefix |
| [3](day-03-process-management.md) | Process management & health checks | Build `ServiceProcessManager` — spawn/kill subprocesses | Start 2 jac services as subprocesses, health check passes |
| [4](day-04-reverse-proxy.md) | Reverse proxies & API gateways | Build the gateway — path-based routing + HTTP forwarding | `curl /api/orders/health` proxied to subprocess on :8001 |
| [5](day-05-gateway-static-serving.md) | Static file serving & SPA routing | Add static asset serving + SPA fallback to gateway | Gateway serves a built client + SPA fallback works |
| [6](day-06-jwt-auth.md) | JWT auth & token propagation | Gateway JWT validation + `X-User-Id` header injection | Authenticated request proxied with identity headers |
| [7](day-07-inter-service-communication.md) | Inter-service communication patterns | Build `service_call()` + internal service tokens | Service A calls Service B through gateway with token |
| [8](day-08-cli-tooling.md) | CLI design & TOML manipulation | Build `jac setup microservice` command | Run setup, select files, see generated TOML |
| [9](day-09-plugin-integration.md) | Plugin architecture & hook system | Wire everything into `plugin.jac` — full local flow | `jac start app.jac` launches gateway + all services |
| [10](day-10-deployment-interface.md) | Deployment interface & Strategy Pattern | `ServiceDeployer` abstraction + `LocalDeployer` + `jac scale` CLI | `jac scale status/stop/restart/logs/destroy` all work |

**After Day 10**: You have a working microservice mode with deployment tooling.

---

## Part 1.5: Production Readiness (Days 10.1-10.6)

Before K8s, make the local setup production-grade.

| Day | Topic | What to Build | Milestone |
|-----|-------|--------------|-----------|
| [10.1](day-10.1-endpoint-passthrough.md) | Complete endpoint passthrough | All 51 jac-scale endpoints accessible via gateway | SSO, webhooks, scheduler, metrics all work |
| [10.2](day-10.2-distributed-tracing.md) | Distributed tracing | X-Trace-Id propagation across all services | Correlate logs across services by trace ID |
| [10.3](day-10.3-gateway-metrics.md) | Gateway metrics | Per-service request count, error rate, latency | `/health` shows metrics summary |
| [10.4](day-10.4-error-handling.md) | Error handling & resilience | Gateway retry, service_call backoff, error format | Transient failures handled gracefully |
| [10.5](day-10.5-admin-and-docs.md) | Admin & API docs | Unified Swagger, admin passthrough, service topology | Single `/docs` showing all services' walkers |
| [10.6](day-10.6-dev-experience.md) | Developer experience | Per-service logs, colored output, individual restart | `jac scale logs products` shows service output |
| [10.7](day-10.7-technical-debt.md) | Technical debt audit | Fix hacks, remove mock auth, proper token propagation | All non-standard patterns documented and resolved |

**After Day 10.7**: Production-ready local setup with observability, resilience, proper security, and developer tooling.

---

## Part 2: Master It (Days 11-20)

Go from "it works" to "I understand the hard problems and can run this in production."

| Day | Learn | Do | Milestone |
|-----|-------|----|-----------|
| [11](day-11-testing-strategy.md) | Test pyramid: unit, integration, contract, E2E | Write tests at every level | `pytest` passes for registry, gateway, contracts, E2E |
| [12](day-12-error-handling-resilience.md) | Circuit breakers, retry, timeouts | Build `CircuitBreaker` + `service_call_with_resilience()` | Circuit opens after 5 failures, recovers after 30s |
| [13](day-13-observability.md) | Logs, metrics, distributed tracing | Trace ID propagation + structured JSON logs + metrics endpoint | Correlate logs across services by trace_id |
| [14](day-14-rate-limiting-and-throttling.md) | Rate limiting algorithms | Token bucket rate limiter at gateway level | 429 response with `X-RateLimit-*` headers |
| [15](day-15-data-consistency.md) | Sagas, idempotency, eventual consistency | Saga coordinator + idempotency keys | Multi-service order creation with rollback on failure |
| [16](day-16-api-versioning-and-contracts.md) | Versioning strategies, backward compatibility | Consumer-driven contracts + versioned routes | Two versions of a service running simultaneously |
| [17](day-17-service-decomposition.md) | DDD, bounded contexts, strangler fig | Extract a service from a monolith | Successfully split and run with service_call() bridge |
| [18](day-18-security-in-depth.md) | Defense in depth, scopes, network isolation | Scope-based auth + K8s NetworkPolicy + log redaction | Fine-grained authorization per service |
| [19](day-19-performance-and-caching.md) | Caching, connection pooling, compression | Gateway cache + connection pool + load testing | Measurable latency improvement with cache hits |
| [20](day-20-production-readiness.md) | 12-factor app, deployment strategies, runbooks | Production checklist + load test + architecture docs | All checklist items verified, runbook written |

**After Day 20**: You can design, build, secure, operate, and debug production microservice systems.

---

## Mapping to v2 PRs

The learn-and-do days map to the production PR plan in [PLAN.md](../../jac_scale/microservices/PLAN.md):

| Days | v2 PR | What |
|------|-------|------|
| 1-3 | PR 1 | ServiceDeployer + LocalDeployer |
| 4-5 | PR 2 | Gateway + HTTP forwarding + static serving |
| 6, 7 | PR 4 | Auth propagation + `sv_service_call` override |
| 8 | PR 5 | CLI tooling |
| 9 | PR 3 | Orchestrator + `ensure_sv_service` hook |
| 10 | PR 1-2 | Deployment interface |
| 10.1-10.7 | Pre-K8s hardening | Production readiness |
| 11-20 | Mastery topics | Testing, resilience, observability, security |

## Test Project

Throughout the program, you build an e-commerce app using `sv import`:

```
ecommerce/
├── jac.toml
├── main.jac                # client UI entry
├── products_app.jac        # def:pub list_products, get_product
├── cart_app.jac            # def:pub get_cart, add_to_cart, clear_cart
├── orders_app.jac          # sv import from cart_app, products_app
└── client/
    └── main.jac            # jac-client SPA
```

Services expose `def:pub` functions (not walkers) for cross-service calls.
Walkers stay internal to each service. `sv import` generates HTTP stubs automatically.

## Key Concepts

- **`sv import`** — compiler-generated HTTP stubs for cross-service calls
- **`sv {}`** — marks functions/walkers as service endpoints
- **`def:pub`** — public functions exposed via `sv import`
- **`ServiceDeployer`** — abstract lifecycle (local subprocesses or K8s pods)
- **Gateway** — client-facing reverse proxy, reads `sv_client._registry`
- **`sv_service_call` hook** — auth propagation + retry + circuit breaker
