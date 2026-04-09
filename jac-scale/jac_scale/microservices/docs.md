# Microservice Mode

Split your Jac app into independent services behind an API gateway.

## Quick Start

### 1. Create service files

Each service has walkers in a `.jac` file and an entry point with `sv {}`:

```
my-app/
├── jac.toml
├── main.jac              # client UI entry
├── products_app.jac      # service entry point
├── orders_app.jac        # service entry point
├── services/
│   ├── products.jac      # product walkers
│   └── orders.jac        # order walkers
```

**services/products.jac**:

```jac
walker ListProducts {
    has items: list = [];
    can collect with Root entry { visit [-->]; }
    can gather with Product entry {
        self.items.append({"id": here.id, "name": here.name});
    }
    can done with Root exit { report self.items; }
}
```

**products_app.jac**:

```jac
sv {
    import from services.products { Product, ListProducts, GetProduct }
}
```

### 2. Configure jac.toml

```bash
jac setup microservice
```

Or manually:

```toml
[plugins.scale.microservices]
enabled = true
gateway_port = 8000

[plugins.scale.microservices.services.products]
file = "products_app.jac"
prefix = "/api/products"

[plugins.scale.microservices.services.orders]
file = "orders_app.jac"
prefix = "/api/orders"

[plugins.scale.microservices.client]
entry = "main.jac"
dist_dir = ".jac/client/dist"
```

### 3. Start

```bash
jac start main.jac
```

Launches gateway on :8000, products on :8001, orders on :8002, client UI built and served.

## URL Structure

```
POST /api/{service}/walker/{walker_name}
POST /api/{service}/function/{func_name}
```

## CLI Commands

```bash
# Setup
jac setup microservice                   # interactive config
jac setup microservice --list            # show config
jac setup microservice --add file.jac    # add service
jac setup microservice --remove name     # remove service

# Management
jac scale status                         # show all services
jac scale stop orders                    # stop one service
jac scale restart cart                   # restart one service
jac scale logs products                  # view logs
jac scale destroy                        # stop everything
```

## Inter-Service Communication

```jac
import from jac_scale.microservices.service_client { service_call }

walker PlaceOrder {
    has auth_token: str = "";

    can create with Root entry {
        cart_resp = service_call(
            service="cart",
            endpoint="walker/ViewCart",
            auth_token=self.auth_token
        );
        items = cart_resp.json().get("data", {}).get("reports", [[]])[0].get("items", []);

        service_call(service="cart", endpoint="walker/ClearCart", auth_token=self.auth_token);
    }
}
```

| Param | Description |
|-------|-------------|
| `service` | Service name from jac.toml |
| `endpoint` | Path e.g. `"walker/ViewCart"` |
| `method` | HTTP method (default: `"POST"`) |
| `body` | JSON body dict (default: `{}`) |
| `auth_token` | Authorization header to forward |
| `gateway_url` | Override gateway URL |

## Client Frontend

```jac
impl app.apiCall(service: str, endpoint: str, body: dict = {}) -> any {
    token = localStorage.getItem("jac_token");
    resp = await fetch(f"/api/{service}/walker/{endpoint}", {
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + (token or "")
        },
        "body": JSON.stringify(body or {})
    });
    return await resp.json();
}

impl app.fetchProducts -> None {
    data = await apiCall("products", "ListProducts", {});
    products = data.data.reports[0] if data.data and data.data.reports else [];
}
```

## What Is and Isn't a Service

Only files in `[plugins.scale.microservices.services.*]` become services:

| File | In TOML? | What happens |
|------|----------|-------------|
| `products_app.jac` | Yes | Runs as service on :8001 |
| `orders_app.jac` | Yes | Runs as service on :8002 |
| `services/products.jac` | No | Imported by products_app.jac |
| `shared/models.jac` | No | Imported by any service |
| `main.jac` | No (client entry) | Built as static SPA |

## Built-in Route Passthrough

The gateway forwards these to healthy services (tries all, skips 404):

| Route | What |
|-------|------|
| `/user/*` | Auth (register, login, refresh, update) |
| `/sso/*` | SSO (Google, Apple, GitHub) |
| `/api-key/*` | API key management |
| `/walker/*`, `/function/*` | Walker/function calls |
| `/webhook/*` | Webhook walker endpoints |
| `/ws/*` | WebSocket walker endpoints |
| `/jobs/*` | Scheduler job management |
| `/cl/*` | Client error reporting |
| `/healthz` | Health check |
| `/graph`, `/graph/data` | Graph visualization |
| `/metrics` | Prometheus metrics |
| `/docs`, `/openapi.json` | API documentation |

## Architecture

```
Client --> Gateway (:8000) --> Products (:8001)
                           --> Orders   (:8002)
                           --> Cart     (:8003)
                           --> Static files (.jac/client/dist/)
                           --> Admin UI (.jac/admin/)

Inter-service: Orders --service_call()--> Gateway --> Cart
```

## Roadmap

### Done
- Gateway with path-based proxy + static serving + admin UI
- Service registry, process manager, deployer interface
- Inter-service communication with token propagation
- `jac setup microservice` + `jac scale status/stop/restart/logs/destroy`
- E-commerce example (products, orders, cart)

### Next (Pre-K8s)
- Complete endpoint passthrough (all 51 jac-scale endpoints)
- Distributed tracing (X-Trace-Id propagation)
- Gateway metrics (per-service latency, error rates)
- Error handling (retry, backoff, circuit breaker)
- Unified Swagger docs across services
- Per-service log files + colored gateway output

### Future (K8s)
- KubernetesDeployer implementing ServiceDeployer interface
- Per-service K8s Deployments from same Docker image
- K8s Service DNS for service URLs
- Ingress for gateway
