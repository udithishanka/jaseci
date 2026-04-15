# Day 13: Observability — Logs, Metrics, Traces

## Learn (~1 hour)

### The Three Pillars of Observability

In a monolith, debugging is "read the log file." In microservices, a single user request touches 3+ services. You need:

| Pillar | What it answers | Tool |
|--------|----------------|------|
| **Logs** | "What happened?" | Structured logging (JSON) |
| **Metrics** | "How is the system performing?" | Prometheus / counters / histograms |
| **Traces** | "Where did this request go and how long did each hop take?" | Distributed tracing (trace IDs) |

### Structured Logging

Unstructured: `ERROR: Failed to charge payment for user`

Structured:
```json
{"level": "error", "service": "orders", "user_id": "abc123", "action": "charge_payment",
 "target_service": "payments", "error": "timeout", "duration_ms": 10023, "trace_id": "t-789"}
```

Structured logs can be searched, filtered, and correlated across services.

### Distributed Tracing

A **trace ID** follows a request across all services:

```
Client → Gateway → Orders → Payments
  trace_id: "t-789" propagated through all 4 hops

Timeline:
  Gateway  ├──────────────────────────────────────────┤ 250ms total
  Orders   │  ├────────────────────────────────┤       │ 200ms
  Payments │  │        ├──────────────┤        │       │  80ms
```

The trace ID lets you see the full journey of one request — which service was slow, where errors occurred.

### How Trace IDs Propagate

1. Gateway generates a trace ID for each incoming request (or uses one from `X-Trace-Id` header)
2. Gateway passes it as `X-Trace-Id` header when proxying
3. Each service includes `trace_id` in all log entries
4. `service_call()` automatically forwards the trace ID

### Metrics That Matter

| Metric | Type | What it tells you |
|--------|------|------------------|
| `request_count` | Counter | How many requests per service |
| `request_duration` | Histogram | How long requests take (p50, p95, p99) |
| `error_rate` | Counter | How many requests fail (5xx) |
| `circuit_breaker_state` | Gauge | Is a circuit open? |
| `active_connections` | Gauge | Current concurrent requests per service |
| `service_health` | Gauge | Is each service healthy? |

jac-scale already has Prometheus metrics support (`monitoring` config). We extend it.

---

## Do (~2-3 hours)

### Task 1: Add trace ID propagation to the gateway

Update the gateway proxy handler to generate and forward trace IDs:

```jac
import uuid;

# In proxy_handler, add trace ID:
trace_id = request.headers.get("x-trace-id", str(uuid.uuid4()));
extra_headers["X-Trace-Id"] = trace_id;

logger.info(f"Proxy: {request.method} {path} → {target_url}",
    extra={"trace_id": trace_id, "service": entry.name, "user_id": extra_headers.get("X-User-Id", "anon")});
```

### Task 2: Add trace ID to service_call()

Update `service_call()` to read and forward the trace ID:

```jac
# In service_call(), add:
# Read trace_id from current request context
req_headers["X-Trace-Id"] = headers.get("X-Trace-Id", str(uuid.uuid4()));
```

### Task 3: Create a structured logger

**`jac_scale/microservices/logging.jac`**

```jac
"""Structured logging for microservice mode."""

import json;
import logging;
import time;

class MicroserviceLogFormatter(logging.Formatter) {
    """JSON log formatter that includes service context."""

    has service_name: str = "gateway";

    def format(self: 'MicroserviceLogFormatter', record: logging.LogRecord) -> str {
        log_entry = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": self.service_name,
            "message": record.getMessage(),
            "logger": record.name
        };

        # Add extras if present (trace_id, user_id, etc.)
        for key in ("trace_id", "user_id", "target_service", "duration_ms", "status_code") {
            if hasattr(record, key) {
                log_entry[key] = getattr(record, key);
            }
        }

        if record.exc_info {
            log_entry["exception"] = self.formatException(record.exc_info);
        }

        return json.dumps(log_entry);
    }
}

def setup_microservice_logging(service_name: str = "gateway", level: int = logging.INFO) -> None {
    formatter = MicroserviceLogFormatter(service_name=service_name);
    handler = logging.StreamHandler();
    handler.setFormatter(formatter);

    root_logger = logging.getLogger("jac_scale.microservices");
    root_logger.addHandler(handler);
    root_logger.setLevel(level);
}
```

### Task 4: Add gateway-level metrics

Extend the gateway to track per-service metrics:

```jac
import time;

obj GatewayMetrics {
    has request_counts: dict[str, int] = {},      # service → count
        error_counts: dict[str, int] = {},         # service → error count
        total_duration_ms: dict[str, float] = {},  # service → total ms
        request_count_total: int = 0;

    def record_request(service: str, status_code: int, duration_ms: float) -> None {
        self.request_count_total += 1;
        self.request_counts[service] = self.request_counts.get(service, 0) + 1;
        self.total_duration_ms[service] = self.total_duration_ms.get(service, 0) + duration_ms;
        if status_code >= 500 {
            self.error_counts[service] = self.error_counts.get(service, 0) + 1;
        }
    }

    def summary -> dict {
        result: dict = {};
        for service in self.request_counts {
            count = self.request_counts[service];
            result[service] = {
                "requests": count,
                "errors": self.error_counts.get(service, 0),
                "avg_duration_ms": round(self.total_duration_ms.get(service, 0) / max(count, 1), 2)
            };
        }
        return result;
    }
}
```

Add timing to the proxy handler:

```jac
# In proxy_handler:
start_time = time.time();
response = await forward_http_request(request, target_url, extra_headers=extra_headers);
duration_ms = (time.time() - start_time) * 1000;

self.metrics.record_request(entry.name, response.status_code, duration_ms);

logger.info(f"Proxy: {request.method} {path} → {response.status_code} ({duration_ms:.0f}ms)",
    extra={"trace_id": trace_id, "service": entry.name, "duration_ms": duration_ms, "status_code": response.status_code});

return response;
```

### Task 5: Add metrics endpoint to gateway

```jac
# In gateway setup():
@self.app.get("/metrics/services")
async def service_metrics() -> dict {
    return {
        "gateway": {"total_requests": self.metrics.request_count_total},
        "services": self.metrics.summary(),
        "circuit_breakers": {
            name: cb.state.value
            for (name, cb) in _circuit_breakers.items()
        }
    };
}
```

---

## Milestone

- [ ] Trace IDs generated at gateway and propagated to all services
- [ ] Structured JSON logs with trace_id, service, duration_ms
- [ ] Per-service request count, error count, average duration metrics
- [ ] `/metrics/services` endpoint shows live metrics
- [ ] Circuit breaker state visible in metrics
- [ ] Can correlate logs across services using trace_id

**You now understand**: the three pillars of observability, why distributed tracing is essential for debugging microservices, how trace IDs propagate across services, and how metrics reveal system health at a glance.
