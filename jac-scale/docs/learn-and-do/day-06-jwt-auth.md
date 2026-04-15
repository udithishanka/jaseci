# Day 6: JWT Auth & Gateway-Level Authentication

## Learn (~1 hour)

### What is JWT?

A **JSON Web Token** is a signed string that proves identity. When a user logs in, the server creates a JWT and gives it to the client. The client sends it with every request.

```
JWT = header.payload.signature

header:    {"alg": "HS256", "typ": "JWT"}
payload:   {"user_id": "abc123", "email": "user@example.com", "exp": 1712345678}
signature: HMAC-SHA256(header + payload, SECRET_KEY)
```

The signature proves the token wasn't tampered with. Anyone with the SECRET_KEY can verify it.

### JWT in Microservices

In a monolith, the single server validates the JWT. In microservices, you have a choice:

| Approach | How it works | Pros | Cons |
|----------|-------------|------|------|
| **Every service validates** | Each service has the JWT secret and validates tokens | Decentralized | Secret sprawl, duplicated logic |
| **Gateway validates** | Gateway validates once, passes identity via headers | Centralized, simple | Services must trust the gateway |

**We chose gateway validates** — it's simpler and matches jac-scale's existing pattern where `JacAPIServerCore` handles auth.

### How Gateway Auth Works

```
1. Client → POST /auth/login {username, password}
   Gateway validates credentials, returns JWT

2. Client → GET /api/orders/list
             Authorization: Bearer <JWT>
   Gateway:
     a) Extract JWT from Authorization header
     b) Verify signature (is it valid? not expired?)
     c) Decode payload → {user_id, email, ...}
     d) Add headers: X-User-Id: abc123, X-User-Email: user@example.com
     e) Forward to Orders service WITH these headers

3. Orders service:
     - Reads X-User-Id from headers (trusts gateway)
     - Does NOT validate JWT itself
     - Uses user_id for business logic
```

### Trust Boundary

The gateway is the **trust boundary**. External requests MUST have a valid JWT. But between gateway and services (internal network), we trust headers.

**Security rule**: Services MUST reject `X-User-Id` headers from external requests. Only the gateway sets them.

In local mode this is fine — services only listen on `127.0.0.1`. In K8s, network policies ensure only the gateway can reach services.

### What jac-scale Already Has

`jac_scale/impl/serve.core.impl.jac` already has:
- JWT creation and validation
- Login/register endpoints
- `Authorization: Bearer` header parsing

We'll **reuse the same JWT functions** in the gateway — no new auth code needed.

---

## Do (~2-3 hours)

### Task 1: Add auth middleware to the Gateway

The gateway needs to:
1. Let auth endpoints through without a token (`/auth/login`, `/auth/register`, `/health`)
2. Validate JWT on everything else
3. Inject identity headers before proxying

**Update `jac_scale/microservices/gateway.jac`** — add auth fields and methods:

```jac
obj MicroserviceGateway {
    # ... existing fields ...
    has jwt_secret: str = "",
        jwt_algorithm: str = "HS256";

    # ... existing methods ...

    """Validate JWT and return decoded payload, or None if invalid."""
    def validate_token(token: str) -> dict | None;

    """Extract Bearer token from Authorization header."""
    def extract_token(request: Request) -> str | None;

    """Paths that don't require authentication."""
    def is_public_path(path: str) -> bool;
}
```

### Task 2: Implement auth methods

**Add to `jac_scale/microservices/impl/gateway.impl.jac`**:

```jac
import jwt;

:obj:MicroserviceGateway:can:validate_token
(token: str) -> dict | None {
    try {
        payload = jwt.decode(token, self.jwt_secret, algorithms=[self.jwt_algorithm]);
        return payload;
    } except jwt.ExpiredSignatureError {
        logger.debug("Token expired");
        return None;
    } except jwt.InvalidTokenError as e {
        logger.debug(f"Invalid token: {e}");
        return None;
    }
}

:obj:MicroserviceGateway:can:extract_token
(request: Request) -> str | None {
    auth_header = request.headers.get("authorization", "");
    if auth_header.startswith("Bearer ") {
        return auth_header[7:];
    }
    return None;
}

:obj:MicroserviceGateway:can:is_public_path
(path: str) -> bool {
    public_paths = ["/health", "/auth/login", "/auth/register", "/auth/refresh"];
    return path in public_paths or path.startswith("/static/") or path.startswith("/assets/");
}
```

### Task 3: Wire auth into the proxy handler

Update `proxy_handler` to validate JWT and inject identity headers:

```jac
:obj:MicroserviceGateway:can:proxy_handler
(request: Request) -> Response {
    path = request.url.path;
    entry = self.registry.match_route(path);

    if not entry {
        return JSONResponse(status_code=404, content={"error": "No service matches this path"});
    }

    # --- AUTH CHECK ---
    extra_headers: dict[str, str] = {};

    if not self.is_public_path(path) {
        token = self.extract_token(request);
        if not token {
            return JSONResponse(status_code=401, content={"error": "Missing authentication token"});
        }
        payload = self.validate_token(token);
        if not payload {
            return JSONResponse(status_code=401, content={"error": "Invalid or expired token"});
        }

        # Inject identity headers for the service
        extra_headers["X-User-Id"] = str(payload.get("user_id", ""));
        extra_headers["X-User-Email"] = str(payload.get("email", ""));
    }
    # --- END AUTH ---

    if entry.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
        return JSONResponse(status_code=503, content={"error": f"Service '{entry.name}' is {entry.status.value}"});
    }

    # Strip prefix and build target URL
    remaining_path = path[len(entry.prefix):];
    if not remaining_path.startswith("/") {
        remaining_path = "/" + remaining_path;
    }
    if not remaining_path.startswith(("/walker/", "/function/", "/health")) {
        remaining_path = "/walker" + remaining_path;
    }

    target_url = f"{entry.url}{remaining_path}";
    if request.url.query {
        target_url += f"?{request.url.query}";
    }

    logger.info(f"Proxy: {request.method} {path} → {target_url} (user={extra_headers.get('X-User-Id', 'anon')})");

    try {
        return await forward_http_request(request, target_url, extra_headers=extra_headers);
    } except Exception as e {
        return JSONResponse(status_code=502, content={"error": f"Failed to reach service '{entry.name}'"});
    }
}
```

### Task 4: Add login endpoint on the gateway

The gateway itself hosts `/auth/login` — reusing jac-scale's existing JWT creation:

```jac
# Add to setup() method, before the catch-all route:

@self.app.post("/auth/login")
async def login(request: Request) -> JSONResponse {
    body = await request.json();
    username = body.get("username", "");
    password = body.get("password", "");

    # For now, simple validation (later: integrate with JacScaleUserManager)
    # TODO: Replace with real user validation from database
    if not username or not password {
        return JSONResponse(status_code=400, content={"error": "Username and password required"});
    }

    # Create JWT
    import from datetime { datetime, UTC, timedelta }
    payload = {
        "user_id": username,  # simplified — real impl uses DB user ID
        "email": f"{username}@example.com",
        "exp": datetime.now(UTC) + timedelta(days=7)
    };
    token = jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm);

    return JSONResponse(content={"token": token});
}
```

### Task 5: Test auth flow

```bash
# 1. Login and get a token
TOKEN=$(curl -s -X POST http://localhost:8000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "testpass"}' | python -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "Token: $TOKEN"

# 2. Request WITHOUT token → 401
curl -s http://localhost:8000/api/orders/list_orders
# → {"error": "Missing authentication token"}

# 3. Request WITH token → proxied with identity headers
curl -s http://localhost:8000/api/orders/list_orders \
  -H "Authorization: Bearer $TOKEN"
# → Response from orders service

# 4. Health endpoint (public) → no token needed
curl -s http://localhost:8000/health
# → {"status": "healthy", "services": {...}}
```

---

## Milestone

- [ ] Gateway validates JWT on API routes
- [ ] Public paths (`/health`, `/auth/*`, static files) don't require auth
- [ ] Invalid/missing token returns 401
- [ ] Valid token: gateway decodes it and adds `X-User-Id`, `X-User-Email` headers to proxied request
- [ ] Login endpoint returns a working JWT

**You now understand**: how JWT works, why gateway-level auth is simpler for microservices, what the trust boundary means, and how identity headers propagate user context to services.
