# Microservice Mode

Split your Jac app into independent services using `sv import`.

## How It Works

Write `sv import` - the compiler handles the rest:

```jac
# orders_app.jac
sv import from cart_app { get_cart, clear_cart }

def:pub create_order(user_id: str) -> dict {
    cart = get_cart(user_id=user_id);      # cross-service call (HTTP under the hood)
    # ... create order from cart items ...
    clear_cart(user_id=user_id);           # another cross-service call
    return {"order_id": "ord_1", "status": "confirmed"};
}
```

```jac
# cart_app.jac - exposes functions via sv {}
sv {
    def:pub get_cart(user_id: str) -> dict { ... }
    def:pub clear_cart(user_id: str) -> bool { ... }
    def:pub add_to_cart(user_id: str, product_id: str, qty: int) -> dict { ... }
}
```

Locally: runtime spawns subprocesses, assigns ports, routes calls.
On K8s: runtime creates pods, uses K8s DNS, routes calls.
**Same code, zero changes.**

## Quick Start

### 1. Create services

Each service exposes `def:pub` functions via `sv {}`:

```
my-app/
├── jac.toml
├── main.jac              # client UI + entry point
├── products_app.jac      # product catalog functions
├── cart_app.jac          # cart management functions
├── orders_app.jac        # order functions (sv imports cart + products)
```

**products_app.jac**:

```jac
node Product {
    has id: str, name: str, price: float;
}

sv {
    def:pub list_products() -> list[dict] {
        products: list[dict] = [];
        for p in [-->](`?Product) {
            products.append({"id": p.id, "name": p.name, "price": p.price});
        }
        return products;
    }

    def:pub get_product(product_id: str) -> dict | None { ... }
}
```

**orders_app.jac** - consumes other services:

```jac
sv import from cart_app { get_cart, clear_cart }
sv import from products_app { get_product }

sv {
    def:pub create_order(user_id: str) -> dict {
        cart = get_cart(user_id=user_id);
        # ... validate, create order ...
        clear_cart(user_id=user_id);
        return {"order_id": "ord_1", "status": "confirmed"};
    }
}
```

### 2. Configure jac.toml

```toml
[plugins.scale.microservices]
enabled = true

# Map module names to gateway URL prefixes (for client-facing routing)
[plugins.scale.microservices.routes]
products_app = "/api/products"
cart_app = "/api/cart"
orders_app = "/api/orders"

# Optional: client UI served as SPA
[plugins.scale.microservices.client]
entry = "main.jac"
```

Services are NOT declared individually - `sv import` handles discovery.
The TOML only maps module names to gateway prefixes.

### 3. Start

```bash
jac start main.jac
```

Runtime automatically:

1. Discovers providers from `sv import` statements (BFS traversal)
2. Spawns each provider as a subprocess on auto-assigned port
3. Starts gateway on :8000
4. Routes client requests to services by prefix

## URL Structure

```
POST /api/{module}/function/{func_name}     # public functions
POST /api/{module}/walker/{walker_name}      # public walkers
GET  /health                                 # gateway health
```

## CLI Commands

```bash
# Setup
jac setup microservice                   # interactive config
jac setup microservice --list            # show config
jac setup microservice --add file.jac    # add route mapping
jac setup microservice --remove name     # remove route mapping

# Service management
jac scale status                         # show all services
jac scale stop orders_app                # stop one service
jac scale restart cart_app               # restart one service
jac scale logs products_app              # view logs
jac scale destroy                        # stop everything
```

## Inter-Service Communication

**With `sv import` (recommended)**:

```jac
sv import from cart_app { get_cart, clear_cart }

# Just call it like a normal function - auth propagated automatically
cart = get_cart(user_id="u123");
clear_cart(user_id="u123");
```

Under the hood:

1. Compiler generates HTTP stub
2. Stub calls `sv_client.call("cart_app", "get_cart", {user_id: "u123"})`
3. jac-scale hook: reads auth from request context, forwards Authorization header
4. Cart service validates token, executes function, returns result
5. Stub unwraps response and returns to caller

**No manual `service_call()`, no `auth_token` passing, no URL management.**

## Client Frontend

The frontend calls the gateway API directly:

```jac
impl app.apiCall(service: str, endpoint: str, body: dict = {}) -> any {
    token = localStorage.getItem("jac_token");
    resp = await fetch(f"/api/{service}/function/{endpoint}", {
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + (token or "")
        },
        "body": JSON.stringify(body or {})
    });
    return await resp.json();
}
```

## What Is and Isn't a Service

Any module `sv import`ed somewhere is a service. No TOML declaration needed:

| File | How it becomes a service |
|------|------------------------|
| `cart_app.jac` | Some module has `sv import from cart_app { ... }` |
| `products_app.jac` | Some module has `sv import from products_app { ... }` |
| `shared/models.jac` | Regular import, NOT a service |
| `main.jac` | Entry point, client UI |

The TOML `[routes]` section only controls which services get **public gateway URLs**.
A service without a route still works for internal `sv import` calls.

## Architecture

```
Client --> Gateway (:8000) --> /api/products/* --> products_app (:18342)
                           --> /api/orders/*   --> orders_app   (:18567)
                           --> /api/cart/*     --> cart_app     (:18103)
                           --> Static files, Admin UI

Inter-service (sv import, direct - no gateway hop):
  orders_app (:18567) --sv_client.call()--> cart_app (:18103)
```

Ports are auto-assigned: `18000 + hash(module_name) % 1000`, 100 retries.

## Auth Flow

```
1. Client --> Gateway (Authorization: Bearer USER_TOKEN)
2. Gateway forwards Authorization --> orders_app
3. orders_app walker calls: get_cart(user_id)  [sv imported]
4. jac-scale sv_service_call hook:
   a. Reads Authorization from execution context
   b. POST to cart_app with same Authorization header
5. cart_app validates token (same JWT secret)
6. Result flows back automatically
```

No manual token passing. The hook reads it from the execution context.

## Local vs Kubernetes

Same code, different deployer:

| | Local | K8s (`--scale`) |
|-|-------|-----------------|
| Spawning | Subprocess per service | Pod per service |
| URLs | `http://127.0.0.1:18xxx` | `http://svc.ns.svc.cluster.local:8000` |
| Health | HTTP `/healthz` polling | K8s probes |
| Lifecycle | `LocalDeployer` | `KubernetesDeployer` |
| Scaling | 1 replica | HPA per service |
| Data | `.jac/data/{module}/` per process | Separate PVC per pod |

## Built-in Route Passthrough

The gateway forwards these to healthy services (tries all, skips 404):

| Route | What |
|-------|------|
| `/user/*` | Auth (register, login, refresh) |
| `/sso/*` | SSO (Google, Apple, GitHub) |
| `/walker/*`, `/function/*` | Direct walker/function calls |
| `/healthz` | Health check |
| `/cl/*` | Client error reporting |
| `/docs`, `/openapi.json` | API documentation |

## Production-Hardening Knobs

All configured under `[plugins.scale.microservices]` in `jac.toml`. `jac
setup microservice` writes commented reference blocks for each; uncomment
and tune per deployment.

### Graceful shutdown on SIGTERM

```toml
[plugins.scale.microservices]
drain_timeout_seconds = 10
```

On SIGTERM (or `jac scale stop`), gateway + services flip a drain flag
(new requests get `503 SERVICE_UNAVAILABLE` with `Retry-After: 2`) and
then uvicorn waits up to `drain_timeout_seconds` for in-flight requests
to complete. Mirrors K8s `terminationGracePeriodSeconds`.

### Per-service RPC timeout

Default is 10s. Override for LLM / generation / long-running services:

```toml
[plugins.scale.microservices.services.llm_app]
rpc_timeout = 120.0
```

The override is read on every `sv` RPC and passed through to `httpx.post(timeout=...)`.

### WebSockets + SSE streaming

No config needed. Any client-hit `/api/{service}/ws/{rest}` is proxied
bidirectionally to `{service}`'s `ws://.../ws/{rest}` endpoint with
auth + trace forwarding. HTTP responses that are `text/event-stream`
or chunked are streamed through the gateway rather than buffered.

### CORS

Open by default — `allow_origins` defaults to `["*"]` so local SPA
dev workflows (Vite on `:5173`, React on `:3000`, etc.) work without
config. Override to restrict:

```toml
[plugins.scale.microservices.cors]
allow_origins     = ["https://app.example.com"]   # concrete list
allow_methods     = ["GET", "POST", "OPTIONS"]
allow_headers     = ["Authorization", "Content-Type"]
allow_credentials = true    # requires concrete origins (not "*")
max_age           = 600
```

Set `allow_origins = []` to disable CORS entirely. Registered
outermost so preflights answer even during drain (clients need CORS
headers to read a 503 envelope).

### Rate limiting

Token bucket, per-IP + optional per-user. Opt-in:

```toml
[plugins.scale.microservices.rate_limit]
enabled           = true
per_ip_rpm        = 600
per_user_rpm      = 120        # 0 disables per-user tier
burst_multiplier  = 2.0        # capacity = rpm * burst / 60
exempt_paths      = ["/health", "/healthz", "/metrics"]
```

Per-IP key falls back from `X-Forwarded-For` (first hop) to
`request.client.host`. Per-user key is `sha256(Authorization)[:32]`. 429
responses carry the standard envelope + `Retry-After` header.

### Observability

- `GET /health` — JSON summary of service statuses (always on).
- `GET /metrics` — Prometheus exposition. Enable with
  `[plugins.scale.monitoring] enabled = true`.
- `X-Trace-Id` — gateway mints one if the client omits it and threads
  it through every downstream hop (including `sv` RPCs). Echoed back
  on every response.
- `GET /docs` + `GET /openapi.json` — unified Swagger UI + merged
  OpenAPI doc across all healthy services.
