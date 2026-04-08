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

**After Day 10**: You have a working microservice mode — gateway, subprocess management, auth, inter-service calls, CLI setup, deployment tooling, and a clean interface for adding K8s support.

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

## What You'll Know

```
Days 1-10 (Build)           Days 11-20 (Master)
─────────────────           ────────────────────
Service Registry            Testing Pyramid
Process Management          Circuit Breakers
API Gateway                 Distributed Tracing
Static Serving              Rate Limiting
JWT Auth                    Saga Pattern
Inter-Service Calls         API Versioning
CLI Tooling                 Service Decomposition
Plugin Integration          Security in Depth
K8s Deployment              Caching & Performance
                            Production Readiness
```

## Test Project

Throughout the 20 days, you'll build against a test project:

```
test-microservices/
├── jac.toml
├── services/
│   ├── orders.jac       # walker: list_orders, create_order
│   └── payments.jac     # walker: charge, refund
├── shared/
│   └── models.jac       # shared types (Order, Payment)
└── client/
    └── main.jac         # simple jac-client UI
```

This gets created on Day 1 and grows throughout the program.
