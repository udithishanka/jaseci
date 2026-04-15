# Day 20: Production Readiness — Putting It All Together

## Learn (~1 hour)

### The Production Readiness Checklist

You've built all the pieces over 19 days. Today is about assembling them into a production-grade system and understanding what "production-ready" actually means.

### The 12-Factor App (Applied to Microservices)

| Factor | What it means | Our implementation |
|--------|--------------|-------------------|
| 1. **Codebase** | One repo per service (or monorepo) | Monorepo with `services/` dir |
| 2. **Dependencies** | Explicitly declared | `pyproject.toml` + `jac.toml` |
| 3. **Config** | Stored in environment | `jac.toml` + env vars via `${VAR}` |
| 4. **Backing services** | Treat DB/cache as attached resources | MongoDB, Redis via config |
| 5. **Build, release, run** | Strict separation | `jac build` → Docker image → `jac start --scale` |
| 6. **Processes** | Stateless, share-nothing | Each service is stateless (state in DB) |
| 7. **Port binding** | Export services via port | Each service binds a port |
| 8. **Concurrency** | Scale out via processes | K8s replicas |
| 9. **Disposability** | Fast startup, graceful shutdown | SIGTERM handling, health checks |
| 10. **Dev/prod parity** | Keep environments similar | Subprocess locally = pod in K8s |
| 11. **Logs** | Treat as event streams | Structured JSON logs to stdout |
| 12. **Admin** | Run admin tasks as one-off processes | `jac setup microservice`, admin dashboard |

### What Can Go Wrong in Production

| Scenario | Impact | Prevention |
|----------|--------|-----------|
| Service crashes in a loop | Repeated restarts, resource exhaustion | Circuit breaker, crash backoff |
| Memory leak in one service | OOM kill, restarts | K8s resource limits, monitoring |
| Slow DB query blocks everything | Cascading timeout | Timeout budgets, async queries |
| Config mismatch between services | Silent data corruption | Contract tests, versioning |
| Secret rotation | Services suddenly can't auth | K8s Secrets with rolling restart |
| Service ordering on startup | Service A starts before B is ready | Health check dependencies, retry |

### Deployment Strategies

| Strategy | How it works | Risk | Rollback speed |
|----------|-------------|------|----------------|
| **Rolling update** | Replace pods one by one | Low — gradual | Automatic |
| **Blue/Green** | Run old + new, switch traffic | Low — instant switch | Instant |
| **Canary** | Send 5% traffic to new, watch, then 100% | Very low | Instant |
| **Recreate** | Kill all old, start all new | High — downtime | Slow |

K8s default is rolling update — good enough for most cases.

---

## Do (~3-4 hours)

### Task 1: Create a production readiness checklist for your microservice mode

Go through each item and verify it works:

```markdown
## Production Readiness Checklist

### Infrastructure
- [ ] All services start and pass health checks within 30s
- [ ] Ctrl+C cleanly shuts down all services (no orphan processes)
- [ ] Gateway returns 503 for unhealthy services (not 502)
- [ ] Auto-restart on crash (process manager restarts failed services)

### Security
- [ ] JWT validation on all API routes
- [ ] Scope-based authorization per service prefix
- [ ] Internal service tokens are short-lived (30s)
- [ ] No sensitive data in logs (passwords, tokens redacted)
- [ ] Input validation at every service boundary
- [ ] K8s NetworkPolicy: only gateway reaches services

### Resilience
- [ ] Circuit breakers on all service_call()s
- [ ] Retry with exponential backoff for transient errors
- [ ] Timeout budgets: gateway 10s, service-to-service 5s
- [ ] Graceful degradation for non-critical services

### Observability
- [ ] Structured JSON logs with trace_id
- [ ] Trace ID propagation across all hops
- [ ] Per-service metrics: request count, error rate, latency
- [ ] /health endpoint on every service and gateway
- [ ] /metrics/services endpoint on gateway

### Performance
- [ ] Response caching for GET requests (configurable TTL)
- [ ] Connection pooling for inter-service HTTP calls
- [ ] X-Cache header shows HIT/MISS

### Data
- [ ] Saga pattern for multi-service transactions
- [ ] Idempotency keys on state-changing operations
- [ ] Contract tests between all service pairs

### Deployment
- [ ] jac setup microservice generates valid config
- [ ] jac start works locally (subprocesses)
- [ ] jac start --scale works on K8s (separate Deployments)
- [ ] Per-service K8s Deployment + Service + NetworkPolicy
- [ ] Shared MongoDB/Redis across services
```

### Task 2: Load test your system

Install a load testing tool and stress-test your microservice setup:

```bash
# Install hey (HTTP load tester)
# go install github.com/rakyll/hey@latest

# Or use Python's locust, or simply:
python -c "
import time, requests, concurrent.futures

url = 'http://localhost:8000/api/orders/list_orders'
headers = {'Authorization': 'Bearer YOUR_TOKEN'}

def make_request(i):
    start = time.time()
    r = requests.get(url, headers=headers)
    return (r.status_code, (time.time()-start)*1000)

# 50 concurrent requests
with concurrent.futures.ThreadPoolExecutor(max_workers=50) as executor:
    futures = [executor.submit(make_request, i) for i in range(200)]
    results = [f.result() for f in futures]

statuses = [r[0] for r in results]
latencies = [r[1] for r in results]

print(f'Requests: {len(results)}')
print(f'Success: {statuses.count(200)} ({statuses.count(200)/len(results)*100:.0f}%)')
print(f'429 (rate limited): {statuses.count(429)}')
print(f'Errors: {len([s for s in statuses if s >= 500])}')
print(f'Latency p50: {sorted(latencies)[len(latencies)//2]:.0f}ms')
print(f'Latency p95: {sorted(latencies)[int(len(latencies)*0.95)]:.0f}ms')
print(f'Latency p99: {sorted(latencies)[int(len(latencies)*0.99)]:.0f}ms')
"
```

### Task 3: Document your architecture

Create a one-page architecture diagram for your project:

```markdown
## My Microservice Architecture

### Services
| Service | File | Prefix | Depends On | Cache TTL |
|---------|------|--------|-----------|-----------|
| orders | services/orders.jac | /api/orders | payments | 0 (none) |
| payments | services/payments.jac | /api/payments | — | 0 (none) |
| catalog | services/catalog.jac | /api/catalog | — | 60s |

### Communication
- Client → Gateway: JWT (user token)
- Gateway → Service: X-User-Id + X-Internal-Token
- Service → Service: service_call() via gateway + internal token

### Data Flow
- Orders: MongoDB collection `orders`
- Payments: MongoDB collection `payments`
- Catalog: MongoDB collection `products` (read-heavy, cached at gateway)

### Critical Path
Client → Gateway → Orders → Payments (saga: charge + confirm)

### Non-Critical
Orders → Notifications (graceful degradation if down)
```

### Task 4: Write a runbook for common issues

```markdown
## Operational Runbook

### Service won't start
1. Check logs: is the port already in use?
2. Check the .jac file compiles: `jac check services/orders.jac`
3. Try starting it directly: `jac start services/orders.jac --port 9999 --no-client`

### Circuit breaker is open
1. Check `/metrics/services` ��� which service triggered it?
2. Check that service's `/health` endpoint directly
3. Look at structured logs for the trace_id of failing requests
4. If the service is healthy, the circuit will auto-recover in 30s

### High latency
1. Check `/metrics/services` — which service is slow?
2. Is the cache working? Look for `X-Cache: HIT` headers
3. Check connection pool: are we hitting the `limit_per_host`?
4. Check DB: is a slow query blocking?

### Memory/CPU spike
1. K8s: `kubectl top pods -n default`
2. Local: check process manager health summary
3. Identify the service, check its logs for unusual patterns
4. If one service, restart it: gateway will retry via circuit breaker

### Deploying a single service update
1. Update the .jac file
2. Local: process manager will auto-restart (HMR)
3. K8s: `kubectl rollout restart deployment/orders`
4. Monitor health checks: `curl gateway:8000/health`
```

---

## Milestone

- [ ] Production readiness checklist: all items verified
- [ ] Load test completed: know your p50, p95, p99 latencies
- [ ] Architecture documented with service map and dependencies
- [ ] Operational runbook for common failure scenarios
- [ ] Can explain every component and why it exists

---

## Congratulations — You're a Microservice Expert!

Over 20 days, you've gone from "what are microservices?" to building and understanding a production-grade system:

### Days 1-10: Build It

| Day | What you built |
|-----|---------------|
| 1 | Foundation — config schema, project structure |
| 2 | Service Registry — registration, prefix matching |
| 3 | Process Manager — subprocess lifecycle, health checks |
| 4 | API Gateway — reverse proxy, path stripping |
| 5 | Static Serving — SPA fallback, asset serving |
| 6 | JWT Auth — gateway-level auth, identity headers |
| 7 | Inter-Service Calls — service_call(), token propagation |
| 8 | CLI Tooling — jac setup microservice |
| 9 | Plugin Integration — full local flow |
| 10 | K8s Deployment — multi-service manifests |

### Days 11-20: Master It

| Day | What you mastered |
|-----|------------------|
| 11 | Testing — pyramid, contracts, E2E |
| 12 | Resilience — circuit breakers, retry, timeouts |
| 13 | Observability — logs, metrics, distributed tracing |
| 14 | Rate Limiting — token bucket, per-user/per-service |
| 15 | Data Consistency — sagas, idempotency, eventual consistency |
| 16 | API Versioning — contracts, backward compatibility |
| 17 | Decomposition — DDD, bounded contexts, strangler fig |
| 18 | Security — defense in depth, scopes, network segmentation |
| 19 | Performance — caching, connection pooling, measurement |
| 20 | Production Readiness — checklist, load testing, runbooks |

### What Makes You an Expert

You can now:

- **Design**: Identify service boundaries using bounded contexts
- **Build**: Implement gateway, registry, process management, inter-service communication
- **Secure**: JWT + scopes + network segmentation + input validation
- **Operate**: Monitoring, circuit breakers, health checks, runbooks
- **Evolve**: Version APIs, run sagas, manage data consistency
- **Optimize**: Caching, connection pooling, load testing
- **Debug**: Distributed tracing, structured logs, metrics

Most importantly, you know **when NOT to use microservices** — which is the mark of real expertise.
