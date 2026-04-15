# Day 4: Reverse Proxies & The API Gateway

## Learn (~1 hour)

### What is a Reverse Proxy?

A **forward proxy** sits in front of clients (e.g., a VPN). A **reverse proxy** sits in front of servers — clients don't know which backend they're really talking to.

```
Forward proxy:    Client → [Proxy] → Internet
Reverse proxy:    Client → [Proxy] → Backend Server A
                                   → Backend Server B
```

Our gateway IS a reverse proxy. The client sends requests to `:8000`, and the gateway forwards them to the right service on `:8001`, `:8002`, etc.

### How HTTP Proxying Works

The proxy needs to:

1. **Receive** the full request (method, path, headers, body)
2. **Transform** it (strip prefix, add headers)
3. **Forward** it to the target service
4. **Relay** the response back (status, headers, body)

```python
# Simplified proxy logic
async def proxy_request(client_request, target_url):
    # 1. Read incoming request
    method = client_request.method        # GET, POST, etc.
    body = await client_request.body()    # request body
    headers = dict(client_request.headers) # copy headers

    # 2. Remove headers that shouldn't be forwarded
    del headers["host"]  # will be wrong (gateway's host, not target's)

    # 3. Forward to target
    response = await http_client.request(method, target_url, headers=headers, body=body)

    # 4. Return response to client
    return Response(status=response.status, headers=response.headers, body=response.body)
```

### Path Stripping

When the gateway receives `GET /api/orders/list`:

1. Match prefix: `/api/orders` → Orders service
2. Strip prefix: `/api/orders/list` → `/list`
3. Forward: `GET http://127.0.0.1:8001/walker/list`

The service doesn't know about prefixes — it just sees `/walker/list` as if the client called it directly.

### Headers to Watch Out For

| Header | What to do |
|--------|-----------|
| `Host` | Replace with target service's host |
| `X-Forwarded-For` | Add client's IP (for logging) |
| `X-Forwarded-Proto` | Preserve original protocol (http/https) |
| `Transfer-Encoding` | Don't forward (proxy handles chunking) |
| `Connection` | Don't forward (hop-by-hop header) |

### Existing Pattern: `sandbox_proxy.jac`

jac-scale already has a reverse proxy — the sandbox proxy at `providers/proxy/sandbox_proxy.jac`. It:

- Routes by **hostname** (not path)
- Uses **aiohttp** for async HTTP forwarding
- Handles **WebSocket** proxying too

Our gateway does the same thing but routes by **path prefix** and uses **FastAPI** (since it also needs to host auth endpoints, admin, etc.). The HTTP forwarding logic is nearly identical.

---

## Do (~2-3 hours)

### Task 1: Create the shared HTTP proxy utility

This small utility is used by both the gateway and sandbox proxy:

**`jac_scale/utils/http_proxy.jac`**

```jac
"""Shared HTTP forwarding utility for proxy implementations."""

import aiohttp;
import logging;
import from fastapi { Request, Response }

glob logger = logging.getLogger(__name__),
     # Headers that must not be forwarded between hops
     HOP_BY_HOP_HEADERS: set[str] = {"host", "transfer-encoding", "connection", "keep-alive", "upgrade"};


"""Forward an HTTP request to a target URL and return the response."""
async def forward_http_request(
    request: Request,
    target_url: str,
    extra_headers: dict[str, str] = {},
    timeout: int = 30
) -> Response;
```

**`jac_scale/utils/impl/http_proxy.impl.jac`**

```jac
import aiohttp;
import logging;
import from fastapi { Request, Response }
import from jac_scale.utils.http_proxy { forward_http_request, HOP_BY_HOP_HEADERS }

glob logger = logging.getLogger(__name__);

:can:forward_http_request
(request: Request, target_url: str, extra_headers: dict[str, str] = {}, timeout: int = 30) -> Response {
    # Build headers — exclude hop-by-hop, add extras
    headers: dict[str, str] = {};
    for (key, value) in request.headers.items() {
        if key.lower() not in HOP_BY_HOP_HEADERS {
            headers[key] = value;
        }
    }
    headers.update(extra_headers);

    # Add forwarding headers
    client_ip = request.client.host if request.client else "unknown";
    headers["X-Forwarded-For"] = client_ip;
    headers["X-Forwarded-Proto"] = request.url.scheme;

    body = await request.body();

    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=timeout)
    ) as session {
        async with session.request(
            method=request.method,
            url=target_url,
            headers=headers,
            data=body,
            allow_redirects=False
        ) as resp {
            resp_body = await resp.read();
            resp_headers = {
                k: v for (k, v) in resp.headers.items()
                if k.lower() not in HOP_BY_HOP_HEADERS
            };
            return Response(
                status_code=resp.status,
                headers=resp_headers,
                content=resp_body
            );
        }
    }
}
```

### Task 2: Build the Gateway

**`jac_scale/microservices/gateway.jac`**

```jac
"""API Gateway — path-based reverse proxy for microservices."""

import logging;
import from fastapi { FastAPI, Request, Response }
import from jac_scale.microservices.registry { ServiceRegistry }
import from jac_scale.utils.http_proxy { forward_http_request }

glob logger = logging.getLogger(__name__);

obj MicroserviceGateway {
    has registry: ServiceRegistry,
        app: FastAPI | None = None,
        port: int = 8000,
        host: str = "0.0.0.0";

    """Create the FastAPI app and register the catch-all proxy route."""
    def setup -> FastAPI;

    """Proxy handler — matches path to service and forwards."""
    async def proxy_handler(request: Request) -> Response;

    """Start the gateway (blocking)."""
    def start -> None;
}
```

### Task 3: Implement the Gateway

**`jac_scale/microservices/impl/gateway.impl.jac`**

```jac
import uvicorn;
import logging;
import from fastapi { FastAPI, Request, Response }
import from fastapi.responses { JSONResponse }
import from jac_scale.microservices.gateway { MicroserviceGateway }
import from jac_scale.microservices.registry { ServiceStatus }
import from jac_scale.utils.http_proxy { forward_http_request }

glob logger = logging.getLogger(__name__);

:obj:MicroserviceGateway:can:setup
-> FastAPI {
    self.app = FastAPI(title="Jac Microservice Gateway");

    # Health endpoint for the gateway itself
    @self.app.get("/health")
    async def gateway_health() -> dict {
        return {
            "status": "healthy",
            "services": self.registry.health_summary()
        };
    }

    # Catch-all: proxy to the matching service
    @self.app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
    async def catch_all(request: Request) -> Response {
        return await self.proxy_handler(request);
    }

    return self.app;
}

:obj:MicroserviceGateway:can:proxy_handler
(request: Request) -> Response {
    path = request.url.path;

    # Find the service that owns this path
    entry = self.registry.match_route(path);

    if not entry {
        return JSONResponse(
            status_code=404,
            content={"error": "No service matches this path", "path": path}
        );
    }

    if entry.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
        return JSONResponse(
            status_code=503,
            content={"error": f"Service '{entry.name}' is {entry.status.value}", "service": entry.name}
        );
    }

    # Strip the prefix and build target URL
    # /api/orders/list → /walker/list
    remaining_path = path[len(entry.prefix):];
    if not remaining_path.startswith("/") {
        remaining_path = "/" + remaining_path;
    }

    # If the remaining path doesn't start with /walker/ or /function/,
    # assume it's a walker name and add the /walker/ prefix
    if not remaining_path.startswith(("/walker/", "/function/", "/health")) {
        remaining_path = "/walker" + remaining_path;
    }

    target_url = f"{entry.url}{remaining_path}";
    if request.url.query {
        target_url += f"?{request.url.query}";
    }

    logger.info(f"Proxy: {request.method} {path} → {target_url}");

    try {
        return await forward_http_request(request, target_url);
    } except Exception as e {
        logger.error(f"Proxy error for {entry.name}: {e}");
        return JSONResponse(
            status_code=502,
            content={"error": f"Failed to reach service '{entry.name}'", "detail": str(e)}
        );
    }
}

:obj:MicroserviceGateway:can:start
-> None {
    if not self.app {
        self.setup();
    }
    logger.info(f"Gateway starting on {self.host}:{self.port}");
    uvicorn.run(self.app, host=self.host, port=self.port);
}
```

### Task 4: End-to-end test

Bring together Days 2-4:

```python
# test_gateway.py
import time
import threading
from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry
from jac_scale.microservices.process_manager import ServiceProcessManager
from jac_scale.microservices.gateway import MicroserviceGateway

# 1. Set up registry
reg = ServiceRegistry()
reg.register(ServiceEntry(name="orders", file="services/orders.jac", prefix="/api/orders"))
reg.register(ServiceEntry(name="payments", file="services/payments.jac", prefix="/api/payments"))

# 2. Start service subprocesses
pm = ServiceProcessManager(registry=reg)
pm.start_all()
time.sleep(5)  # Wait for services to be ready
pm.check_all_health()

# 3. Start gateway in a thread
gw = MicroserviceGateway(registry=reg, port=8000)
gw.setup()

# In a real scenario you'd run gw.start() — for testing, just verify setup:
print("Registry:", reg.health_summary())
print("\nTest: match_route('/api/orders/list') →", reg.match_route("/api/orders/list").name)
print("Test: match_route('/api/payments/charge') →", reg.match_route("/api/payments/charge").name)

# You can also test with curl in another terminal:
# curl http://localhost:8001/walker/list_orders
# (hitting the service directly to verify it works)

pm.stop_all()
print("\nDone!")
```

---

## Milestone

- [ ] `http_proxy.jac` utility exists — forwards HTTP requests with proper header handling
- [ ] `MicroserviceGateway` creates a FastAPI app with a catch-all proxy route
- [ ] Path stripping works: `/api/orders/list` → `/walker/list`
- [ ] Gateway returns 404 for unmatched paths, 503 for unhealthy services
- [ ] Can verify services respond by curling them directly

**You now understand**: how reverse proxies work, how to forward HTTP requests, how path stripping maps gateway URLs to service URLs. Tomorrow you add static file serving so the gateway can also serve the client UI.
