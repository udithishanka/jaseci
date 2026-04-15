# Day 16: API Versioning & Service Contracts

## Learn (~1 hour)

### The Versioning Problem

Service A depends on Service B's response format. If B changes its API, A breaks. In a monolith, you'd see the breakage at compile time. In microservices, you find out in production.

### Versioning Strategies

| Strategy | URL looks like | Pros | Cons |
|----------|---------------|------|------|
| **URL path** | `/api/v1/orders`, `/api/v2/orders` | Explicit, easy to route | URL clutter |
| **Header** | `Accept: application/vnd.jac.v2+json` | Clean URLs | Hidden, harder to test |
| **Query param** | `/api/orders?version=2` | Simple | Ugly, cache problems |

**For jac-scale**: URL path versioning is clearest and works naturally with our prefix routing:

```toml
[plugins.scale.microservices.services.orders_v1]
file = "services/orders_v1.jac"
prefix = "/api/v1/orders"

[plugins.scale.microservices.services.orders_v2]
file = "services/orders_v2.jac"
prefix = "/api/v2/orders"
```

Both versions run simultaneously. Old clients use v1, new clients use v2.

### Backward Compatibility Rules

When evolving a service API:

| Change | Safe? | Why |
|--------|-------|-----|
| Add a new field to response | Yes | Clients ignore unknown fields |
| Add an optional parameter | Yes | Existing callers don't send it |
| Remove a response field | **No** | Clients relying on it break |
| Rename a field | **No** | Same as remove + add |
| Change a field's type | **No** | Parsing breaks |
| Add a required parameter | **No** | Existing callers don't send it |

**Rule of thumb**: you can ADD, you can't REMOVE or CHANGE (without a new version).

### Consumer-Driven Contracts

Instead of the provider defining the contract alone, **consumers declare what they need**:

```
Orders (consumer) declares:
  "I call payments /walker/charge and need {charge_id: str, status: str} back.
   I don't care about other fields."

Payments (provider) can add fields freely.
Payments CANNOT remove charge_id or status without breaking the contract.
```

This is formalized as **contract tests** (from Day 11) that live in the consumer's repo and run against the provider.

---

## Do (~2-3 hours)

### Task 1: Define service contracts as schemas

```jac
"""Service contracts — define what each service expects from others."""

# contracts/payments.jac — what callers expect from payments

obj ChargeRequest {
    has amount: float,
        currency: str = "USD",
        idempotency_key: str = "";
}

obj ChargeResponse {
    has charge_id: str,
        amount: float,
        status: str;   # "succeeded" | "failed" | "pending"
}

obj RefundRequest {
    has charge_id: str;
}

obj RefundResponse {
    has refund_id: str,
        charge_id: str,
        status: str;   # "refunded" | "failed"
}
```

### Task 2: Contract validation helper

```jac
"""Validate responses against contracts at runtime."""

def validate_response(response: dict, contract_fields: dict[str, type]) -> tuple[bool, list[str]] {
    """Check that a response dict contains all required fields with correct types."""
    errors: list[str] = [];

    for (field, expected_type) in contract_fields.items() {
        if field not in response {
            errors.append(f"Missing field: {field}");
        } elif not isinstance(response[field], expected_type) {
            errors.append(f"Field '{field}': expected {expected_type.__name__}, got {type(response[field]).__name__}");
        }
    }

    return (len(errors) == 0, errors);
}

# Usage in orders.jac:
# resp = await service_call("payments", "/charge", body={...});
# valid, errors = validate_response(resp.json(), {"charge_id": str, "status": str});
# if not valid:
#     logger.error(f"Contract violation from payments: {errors}");
```

### Task 3: Implement versioned routing

Show how to run two versions simultaneously:

```toml
# jac.toml — two versions of orders
[plugins.scale.microservices.services.orders_v1]
file = "services/orders_v1.jac"
prefix = "/api/v1/orders"

[plugins.scale.microservices.services.orders_v2]
file = "services/orders_v2.jac"
prefix = "/api/v2/orders"
```

```jac
# services/orders_v2.jac — adds a "total_price" field
walker list_orders {
    can process with `root entry {
        report [
            {"id": 1, "item": "Widget", "qty": 3, "total_price": 29.97},   # new field
            {"id": 2, "item": "Gadget", "qty": 1, "total_price": 14.99}    # new field
        ];
    }
}
```

### Task 4: Write contract tests

```python
# tests/test_contracts/test_payments_contract.py
"""
Consumer-driven contract: Orders depends on Payments.
These tests run against the real payments service.
"""

def test_charge_returns_required_fields(payments_service):
    """Orders needs charge_id and status from charge response."""
    resp = payments_service.post("/walker/charge", json={"amount": 10.0, "currency": "USD"})
    assert resp.status_code == 200
    data = resp.json()
    assert "charge_id" in data, "Contract violation: missing charge_id"
    assert "status" in data, "Contract violation: missing status"
    assert isinstance(data["charge_id"], str)
    assert data["status"] in ("succeeded", "failed", "pending")

def test_refund_returns_required_fields(payments_service):
    """Orders needs refund_id and status from refund response."""
    # First create a charge to refund
    charge = payments_service.post("/walker/charge", json={"amount": 10.0}).json()
    resp = payments_service.post("/walker/refund", json={"charge_id": charge["charge_id"]})
    assert resp.status_code == 200
    data = resp.json()
    assert "refund_id" in data
    assert "status" in data
```

---

## Milestone

- [ ] Understand backward-compatible vs breaking API changes
- [ ] Service contracts defined as typed schemas
- [ ] Runtime contract validation helper
- [ ] Two versions of a service running simultaneously via prefixes
- [ ] Consumer-driven contract tests that catch breaking changes

**You now understand**: why API versioning matters, the rules for backward-compatible changes, how consumer-driven contracts prevent integration breakage, and how to run multiple versions of a service simultaneously.
