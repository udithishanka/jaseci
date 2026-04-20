# Day 7: Inter-Service Communication

## Learn (~1 hour)

### The Problem

In a monolith, if orders needs to charge a payment, it's a function call:

```jac
# Monolith — direct call, same process
result = charge(amount=99.99);
```

In microservices, orders and payments are separate processes. Orders can't call `charge()` directly — it has to make an HTTP request over the network.

### Synchronous vs Asynchronous Communication

| Style | How it works | Example | When to use |
|-------|-------------|---------|-------------|
| **Synchronous (request/reply)** | Service A calls B and waits for response | HTTP POST, gRPC | Need an immediate answer |
| **Asynchronous (event-driven)** | Service A publishes an event, B reacts later | Message queues (RabbitMQ, Kafka) | Don't need immediate answer, eventual consistency ok |

**We're starting with synchronous HTTP** — it's simpler to understand and implement. Async messaging can be added later as a future enhancement.

### The Token Propagation Problem

When a user calls `POST /api/orders/create`, the gateway validates their JWT and forwards to Orders. But when Orders needs to call Payments, what identity does it use?

```
User (JWT) → Gateway → Orders → ??? → Gateway → Payments
                                  │
                        What token does Orders send?
```

**Option 1: Forward user's JWT** — Orders passes the original JWT along. But Orders might not have access to the raw token (gateway stripped it and sent headers instead).

**Option 2: Internal service token** — The gateway gives Orders a short-lived internal token. When Orders calls back through the gateway, the gateway recognizes it as an internal call.

**We use Option 2** — the gateway issues an `X-Internal-Token` with each proxied request. Services forward this token when making service-to-service calls.

### Internal Token Flow

```
1. Client → Gateway (JWT: user123)
2. Gateway → Orders
     X-User-Id: user123
     X-Internal-Token: eyJ...(short-lived, 30s, signed by gateway)

3. Orders needs to call Payments:
     POST http://gateway:8000/api/payments/charge
     X-Internal-Token: eyJ...(same token from step 2)

4. Gateway receives internal call:
     - Sees X-Internal-Token (not Authorization: Bearer)
     - Validates internal token (signed by gateway, not expired)
     - Extracts original user_id from token payload
     - Forwards to Payments with X-User-Id: user123
```

The internal token:

- Is signed by the gateway (same JWT secret)
- Has a very short TTL (30 seconds)
- Contains the original user's identity
- Is only valid for one hop through the gateway

### The `service_call()` Helper

To make this easy for service developers, we provide a helper function:

```jac
result = service_call(service="payments", endpoint="/charge", body={...});
```

Under the hood it:

1. Reads `X-Internal-Token` from the current request context
2. Calls `http://gateway:8000/api/payments/charge` with that token
3. Returns the response

---

## Do (~2-3 hours)

### Task 1: Add internal token support to the Gateway

Update the gateway to issue and validate internal tokens.

**Add to `jac_scale/microservices/gateway.jac`**:

```jac
obj MicroserviceGateway {
    # ... existing ...
    has internal_token_ttl: int = 30;   # seconds

    """Create a short-lived internal service token."""
    def create_internal_token(user_id: str, user_email: str) -> str;

    """Validate an internal service token. Returns payload or None."""
    def validate_internal_token(token: str) -> dict | None;
}
```

### Task 2: Implement internal tokens

**Add to `jac_scale/microservices/impl/gateway.impl.jac`**:

```jac
import from datetime { datetime, UTC, timedelta }

:obj:MicroserviceGateway:can:create_internal_token
(user_id: str, user_email: str) -> str {
    payload = {
        "user_id": user_id,
        "email": user_email,
        "type": "internal",   # marks this as a service-to-service token
        "exp": datetime.now(UTC) + timedelta(seconds=self.internal_token_ttl)
    };
    return jwt.encode(payload, self.jwt_secret, algorithm=self.jwt_algorithm);
}

:obj:MicroserviceGateway:can:validate_internal_token
(token: str) -> dict | None {
    payload = self.validate_token(token);
    if payload and payload.get("type") == "internal" {
        return payload;
    }
    return None;
}
```

### Task 3: Update proxy handler to issue and accept internal tokens

Update the auth section of `proxy_handler`:

```jac
# --- AUTH CHECK ---
extra_headers: dict[str, str] = {};

if not self.is_public_path(path) {
    user_id = "";
    user_email = "";

    # Check for internal service token first (service-to-service call)
    internal_token = request.headers.get("x-internal-token", "");
    if internal_token {
        payload = self.validate_internal_token(internal_token);
        if payload {
            user_id = str(payload.get("user_id", ""));
            user_email = str(payload.get("email", ""));
        } else {
            return JSONResponse(status_code=401, content={"error": "Invalid internal service token"});
        }
    } else {
        # External request — validate user JWT
        token = self.extract_token(request);
        if not token {
            return JSONResponse(status_code=401, content={"error": "Missing authentication token"});
        }
        payload = self.validate_token(token);
        if not payload {
            return JSONResponse(status_code=401, content={"error": "Invalid or expired token"});
        }
        user_id = str(payload.get("user_id", ""));
        user_email = str(payload.get("email", ""));
    }

    # Inject identity headers
    extra_headers["X-User-Id"] = user_id;
    extra_headers["X-User-Email"] = user_email;

    # Issue internal token so service can make service-to-service calls
    extra_headers["X-Internal-Token"] = self.create_internal_token(user_id, user_email);
}
# --- END AUTH ---
```

### Task 4: Build the `service_call()` helper

**`jac_scale/microservices/client.jac`**

```jac
"""Inter-service HTTP client with automatic token propagation."""

import aiohttp;
import logging;
import from typing { Any }

glob logger = logging.getLogger(__name__);

"""
Call another microservice through the gateway.
Automatically forwards the internal token from the current request context.

Args:
    service: Service name as declared in jac.toml (e.g., "payments")
    endpoint: Path on the target service (e.g., "/charge")
    method: HTTP method (default: "POST")
    body: JSON body (optional)
    headers: Additional headers (optional)
    gateway_url: Gateway base URL (default: from env GATEWAY_URL or http://127.0.0.1:8000)
    internal_token: The X-Internal-Token from the current request (required)

Returns:
    ServiceResponse with status, json(), and text()
"""
async def service_call(
    service: str,
    endpoint: str,
    method: str = "POST",
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    gateway_url: str = "",
    internal_token: str = ""
) -> 'ServiceResponse';

obj ServiceResponse {
    has status: int,
        _body: bytes = b"",
        _headers: dict[str, str] = {};

    def json -> Any;
    def text -> str;
}
```

### Task 5: Implement `service_call()`

**`jac_scale/microservices/impl/client.impl.jac`**

```jac
import os;
import json;
import aiohttp;
import logging;
import from jac_scale.microservices.client { service_call, ServiceResponse }

glob logger = logging.getLogger(__name__);

:can:service_call
(service: str, endpoint: str, method: str = "POST", body: dict | None = None,
 headers: dict[str, str] | None = None, gateway_url: str = "", internal_token: str = "") -> ServiceResponse {

    if not gateway_url {
        gateway_url = os.environ.get("GATEWAY_URL", "http://127.0.0.1:8000");
    }

    # Build URL: gateway/api/{service}/{endpoint}
    endpoint = endpoint.lstrip("/");
    url = f"{gateway_url}/api/{service}/{endpoint}";

    # Build headers
    req_headers: dict[str, str] = {"Content-Type": "application/json"};
    if internal_token {
        req_headers["X-Internal-Token"] = internal_token;
    }
    if headers {
        req_headers.update(headers);
    }

    logger.info(f"service_call: {method} {url}");

    try {
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=30)
        ) as session {
            async with session.request(
                method=method,
                url=url,
                headers=req_headers,
                json=body
            ) as resp {
                resp_body = await resp.read();
                resp_headers = dict(resp.headers);
                return ServiceResponse(
                    status=resp.status,
                    _body=resp_body,
                    _headers=resp_headers
                );
            }
        }
    } except Exception as e {
        logger.error(f"service_call failed: {e}");
        return ServiceResponse(status=500, _body=str(e).encode());
    }
}

:obj:ServiceResponse:can:json -> Any {
    return json.loads(self._body);
}

:obj:ServiceResponse:can:text -> str {
    return self._body.decode("utf-8");
}
```

### Task 6: Test inter-service communication

Update `test-microservices/services/orders.jac` to call payments:

```jac
import from jac_scale.microservices.client { service_call }

walker create_order_with_payment {
    has item: str, amount: float;

    can process with `root entry {
        # Get the internal token from the request headers
        # (injected by gateway)
        import from fastapi { Request }
        # In real implementation, the request context provides this
        # For now, read from environment or request header

        charge_result = await service_call(
            service="payments",
            endpoint="/charge",
            body={"amount": self.amount, "currency": "USD"},
            internal_token=self._get_internal_token()
        );

        if charge_result.status == 200 {
            report {
                "order": {"item": self.item, "status": "confirmed"},
                "payment": charge_result.json()
            };
        } else {
            report {"error": "Payment failed", "status": charge_result.status};
        }
    }
}
```

---

## Milestone

- [ ] Gateway issues `X-Internal-Token` with every proxied request
- [ ] Gateway accepts `X-Internal-Token` header for service-to-service calls
- [ ] Internal tokens are short-lived (30s TTL) and marked with `type: "internal"`
- [ ] `service_call()` helper makes HTTP calls through the gateway with token propagation
- [ ] `ServiceResponse` wrapper provides `.status`, `.json()`, `.text()`
- [ ] Service A can call Service B: orders → gateway → payments → response back

**You now understand**: why inter-service communication is different from function calls, how token propagation maintains user identity across services, and how a helper function hides the HTTP complexity from service developers.
