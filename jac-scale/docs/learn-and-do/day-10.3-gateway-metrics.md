# Day 10.3: Gateway Metrics & Health Dashboard

## The Problem

The gateway proxies requests but doesn't track:

- How many requests each service gets
- How long each service takes to respond
- Error rates per service
- Which services are healthy/unhealthy

## What to Build

### Request Metrics

Track per-service stats in the gateway:

```
GET /health →
{
    "status": "healthy",
    "uptime": "2h 15m",
    "services": {
        "products": {
            "status": "healthy",
            "port": 8001,
            "requests": 1245,
            "errors": 3,
            "avg_latency_ms": 12.5,
            "p95_latency_ms": 45.2
        },
        "orders": {
            "status": "healthy",
            "port": 8002,
            "requests": 89,
            "errors": 0,
            "avg_latency_ms": 156.3,
            "p95_latency_ms": 320.1
        }
    }
}
```

### Gateway Changes

Add timing around proxy calls:

```jac
import time;
start = time.time();
result = await raw_forward(method, target_url, fwd_headers, body);
duration_ms = (time.time() - start) * 1000;

# Record metric
metrics.record(service=svc.name, status=status_code, duration_ms=duration_ms);
```

### Enhanced /health Endpoint

Include metrics in health response:

```jac
if path == "/health" {
    return JSONResponse(content={
        "status": "healthy",
        "services": gw_ref.registry.health_summary(),
        "metrics": gw_ref.metrics.summary()
    });
}
```

## Milestone

- [ ] Gateway tracks per-service request count, error count, latency
- [ ] `/health` endpoint includes metrics summary
- [ ] Can identify slow or failing services from gateway health
