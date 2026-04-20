# Day 18: Security in Depth

## Learn (~1 hour)

### Microservice Security Is Different

A monolith has one perimeter to defend. Microservices have a **larger attack surface** — every service is a potential entry point, and every network call is a potential interception point.

### Defense in Depth Layers

```
Layer 1: Network        → Who can reach what? (firewalls, K8s NetworkPolicy)
Layer 2: Transport      → Is the connection encrypted? (TLS/HTTPS)
Layer 3: Authentication → Who are you? (JWT, API keys)
Layer 4: Authorization  → Are you allowed to do this? (RBAC, scopes)
Layer 5: Input          → Is the data safe? (validation, sanitization)
Layer 6: Secrets        → Are credentials safe? (secret management)
```

### Network Segmentation

In K8s, **NetworkPolicy** controls which pods can talk to each other:

```yaml
# Only gateway can reach service pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-only
spec:
  podSelector:
    matchLabels:
      role: service
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: gateway
      ports:
        - port: 8000
```

This means: even if an attacker compromises the orders pod, they can't reach the payments pod directly.

### JWT Scopes and RBAC

Not all users should access all services. **Scopes** in the JWT control what a user can do:

```json
{
  "user_id": "abc123",
  "scopes": ["orders:read", "orders:write", "payments:read"],
  "role": "customer"
}
```

The gateway can enforce scopes per prefix:

- `GET /api/orders/*` requires `orders:read`
- `POST /api/orders/*` requires `orders:write`
- `POST /api/admin/*` requires `role: admin`

### Common Microservice Security Mistakes

| Mistake | Impact | Fix |
|---------|--------|-----|
| Services trust any `X-User-Id` header | Spoofing identity | Only trust headers from gateway (NetworkPolicy) |
| Plaintext HTTP between services | Sniffing credentials | mTLS or encrypted overlay network |
| JWT secret in code/config | Token forgery | Use K8s Secrets, env vars, vault |
| No input validation | Injection attacks | Validate at service boundary |
| Logging sensitive data | Data leak via logs | Redact tokens, passwords, PII |
| No rate limiting | DDoS, abuse | Gateway-level rate limiting (Day 14) |

---

## Do (~2-3 hours)

### Task 1: Add scope-based authorization to the gateway

```jac
"""Scope-based authorization at the gateway level."""

# Define which scopes are required per prefix + method
glob SCOPE_RULES: dict[str, dict[str, list[str]]] = {
    "/api/orders": {
        "GET": ["orders:read"],
        "POST": ["orders:write"],
        "DELETE": ["orders:write"]
    },
    "/api/payments": {
        "GET": ["payments:read"],
        "POST": ["payments:write"]
    },
    "/api/admin": {
        "*": ["admin"]   # all methods require admin
    }
};

def check_scopes(path: str, method: str, user_scopes: list[str]) -> bool {
    """Check if user scopes allow access to this path + method."""
    for (prefix, method_scopes) in SCOPE_RULES.items() {
        if path.startswith(prefix) {
            required = method_scopes.get(method, method_scopes.get("*", []));
            if required and not any(s in user_scopes for s in required) {
                return False;
            }
        }
    }
    return True;
}

# Wire into gateway proxy_handler after JWT validation:
# user_scopes = payload.get("scopes", []);
# if not check_scopes(path, request.method, user_scopes):
#     return JSONResponse(status_code=403, content={"error": "Insufficient permissions"});
```

### Task 2: Redact sensitive data in logs

```jac
"""Log sanitizer — prevents sensitive data from appearing in logs."""

import re;

glob SENSITIVE_PATTERNS = [
    (re.compile(r'"password"\s*:\s*"[^"]*"'), '"password": "***"'),
    (re.compile(r'"token"\s*:\s*"[^"]*"'), '"token": "***"'),
    (re.compile(r'"secret"\s*:\s*"[^"]*"'), '"secret": "***"'),
    (re.compile(r'Bearer\s+[A-Za-z0-9\-_\.]+'), 'Bearer ***'),
    (re.compile(r'"credit_card"\s*:\s*"[^"]*"'), '"credit_card": "***"'),
];

def sanitize_log(message: str) -> str {
    for (pattern, replacement) in SENSITIVE_PATTERNS {
        message = pattern.sub(replacement, message);
    }
    return message;
}
```

### Task 3: Add K8s NetworkPolicy generation

Add to the K8s manifest generator:

```jac
def generate_network_policy(service_name: str, namespace: str = "default") -> dict {
    """Only allow traffic from the gateway pod to this service."""
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": f"{service_name}-allow-gateway",
            "namespace": namespace
        },
        "spec": {
            "podSelector": {
                "matchLabels": {"app": service_name}
            },
            "policyTypes": ["Ingress"],
            "ingress": [{
                "from": [{
                    "podSelector": {
                        "matchLabels": {"app": "gateway"}
                    }
                }],
                "ports": [{"port": 8000, "protocol": "TCP"}]
            }]
        }
    };
}
```

### Task 4: Input validation at service boundary

```jac
"""Validate inputs at the service boundary — don't trust anything from the network."""

walker charge {
    has amount: float, currency: str = "USD", idempotency_key: str = "";

    can validate with `root entry {
        # Validate at the boundary
        if self.amount <= 0 or self.amount > 999999 {
            report {"error": "Invalid amount", "detail": "Amount must be between 0 and 999999"};
            disengage;
        }
        if self.currency not in ("USD", "EUR", "GBP") {
            report {"error": "Invalid currency", "detail": f"Unsupported currency: {self.currency}"};
            disengage;
        }
        if len(self.idempotency_key) > 256 {
            report {"error": "Invalid idempotency_key", "detail": "Too long"};
            disengage;
        }
    }

    can process with `root entry {
        # Safe to use self.amount, self.currency here
        ...
    }
}
```

---

## Milestone

- [ ] Scope-based authorization: users can only access services their scopes allow
- [ ] Sensitive data redacted in logs (passwords, tokens, PII)
- [ ] K8s NetworkPolicy: only gateway can reach service pods
- [ ] Input validation at every service boundary
- [ ] Understand the 6 layers of defense in depth

**You now understand**: why microservice security requires defense in depth, how network segmentation prevents lateral movement, how JWT scopes provide fine-grained authorization, and the common security mistakes to avoid.
