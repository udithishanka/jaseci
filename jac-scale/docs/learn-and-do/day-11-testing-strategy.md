# Day 11: Testing Microservices

## Learn (~1 hour)

### Why Testing Microservices Is Hard

In a monolith, you test one thing. In microservices, you test:

- Each service in isolation (**unit/integration tests**)
- Services talking to each other (**contract tests**)
- The whole system together (**end-to-end tests**)

### The Test Pyramid for Microservices

```
         /\
        /  \        End-to-End (E2E)
       / E2E\       Few, slow, expensive — test full flows
      /------\
     /Contract\     Contract Tests
    /----------\    Medium — verify service-to-service agreements
   /  Integration\  Integration Tests
  /--------------\  Many — test each service with real DB
 /    Unit Tests   \
/------------------\ Most — test logic in isolation, fast
```

| Level | What it tests | Speed | Fragility |
|-------|--------------|-------|-----------|
| **Unit** | Single function/walker logic | ms | Low |
| **Integration** | Service + database + real HTTP | seconds | Medium |
| **Contract** | "Does orders send what payments expects?" | seconds | Low |
| **E2E** | Full flow: client → gateway → service A → service B | 10+ seconds | High |

### Contract Testing

The biggest pitfall in microservices: **Service A changes its response format and breaks Service B** without anyone knowing until production.

**Contract tests** prevent this. A contract says:

- "When you call `POST /walker/charge` with `{amount: float}`, you get back `{charge_id: string, status: string}`"

If either side violates the contract, the test fails.

### Test Doubles for Microservices

| Double | What it does | When to use |
|--------|-------------|-------------|
| **Mock service** | Fake HTTP server that returns canned responses | Unit tests for service_call() |
| **Stub service** | Real service with hardcoded data (no DB) | Integration tests |
| **Real service** | Actual service subprocess | E2E tests |

---

## Do (~2-3 hours)

### Task 1: Unit tests for ServiceRegistry

```python
# jac_scale/tests/test_microservices/test_registry.py
import pytest
from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry, ServiceStatus

class TestServiceRegistry:
    def setup_method(self):
        self.reg = ServiceRegistry()

    def test_register_and_lookup(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        match = self.reg.match_route("/api/orders/list")
        assert match is not None
        assert match.name == "orders"

    def test_no_match_returns_none(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        assert self.reg.match_route("/api/unknown") is None

    def test_longest_prefix_wins(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        self.reg.register(ServiceEntry(name="orders_v2", file="orders_v2.jac", prefix="/api/orders/v2", port=8002))
        assert self.reg.match_route("/api/orders/v2/list").name == "orders_v2"
        assert self.reg.match_route("/api/orders/list").name == "orders"

    def test_deregister(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        assert self.reg.deregister("orders") is True
        assert self.reg.match_route("/api/orders/list") is None
        assert self.reg.deregister("orders") is False

    def test_exact_prefix_match(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        assert self.reg.match_route("/api/orders").name == "orders"

    def test_prefix_boundary(self):
        """'/api/orders' should NOT match '/api/ordershistory'"""
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        assert self.reg.match_route("/api/ordershistory") is None

    def test_health_summary(self):
        self.reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001))
        summary = self.reg.health_summary()
        assert "orders" in summary
        assert summary["orders"]["port"] == 8001
        assert summary["orders"]["status"] == "registered"
```

### Task 2: Integration test for gateway proxying

```python
# jac_scale/tests/test_microservices/test_gateway.py
import pytest
from fastapi.testclient import TestClient
from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry, ServiceStatus
from jac_scale.microservices.gateway import MicroserviceGateway

class TestGatewayRouting:
    def setup_method(self):
        self.reg = ServiceRegistry()
        self.reg.register(ServiceEntry(
            name="orders", file="orders.jac", prefix="/api/orders",
            port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
        ))
        self.gw = MicroserviceGateway(
            registry=self.reg, port=8000, jwt_secret="test-secret"
        )
        self.app = self.gw.setup()
        self.client = TestClient(self.app)

    def test_health_endpoint(self):
        resp = self.client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "healthy"
        assert "orders" in data["services"]

    def test_unmatched_path_returns_404(self):
        resp = self.client.get("/api/unknown/thing")
        assert resp.status_code == 404

    def test_unauthenticated_api_returns_401(self):
        resp = self.client.get("/api/orders/list")
        assert resp.status_code == 401

    def test_auth_login_is_public(self):
        resp = self.client.post("/auth/login", json={"username": "test", "password": "test"})
        assert resp.status_code == 200
        assert "token" in resp.json()
```

### Task 3: Contract test between orders and payments

```python
# jac_scale/tests/test_microservices/test_contracts.py
"""
Contract: orders expects payments /walker/charge to accept {amount, currency}
and return {charge_id: str, status: str}
"""
import pytest

def test_payments_charge_contract():
    """Verify payments service honors the charge contract."""
    # This would hit the real payments service in CI
    # For now, validate the expected shapes

    # What orders sends:
    request_body = {"amount": 99.99, "currency": "USD"}
    assert isinstance(request_body["amount"], float)
    assert isinstance(request_body["currency"], str)

    # What orders expects back:
    expected_response_keys = {"charge_id", "status"}

    # In a real contract test, you'd call the service and validate:
    # resp = service_call("payments", "/charge", body=request_body)
    # assert expected_response_keys.issubset(resp.json().keys())
    # assert isinstance(resp.json()["charge_id"], str)
    # assert resp.json()["status"] in ("succeeded", "failed", "pending")
```

### Task 4: E2E test script

```python
# jac_scale/tests/test_microservices/test_e2e.py
"""
E2E test: starts real services, gateway, and tests full flow.
Run with: pytest test_e2e.py -v --timeout=60
"""
import pytest
import time
import requests
from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry
from jac_scale.microservices.process_manager import ServiceProcessManager
from jac_scale.microservices.gateway import MicroserviceGateway
import threading

@pytest.fixture(scope="module")
def microservice_env():
    """Start services + gateway for E2E tests."""
    reg = ServiceRegistry()
    reg.register(ServiceEntry(name="orders", file="services/orders.jac", prefix="/api/orders"))
    reg.register(ServiceEntry(name="payments", file="services/payments.jac", prefix="/api/payments"))

    pm = ServiceProcessManager(registry=reg)
    pm.start_all()
    time.sleep(5)
    pm.check_all_health()

    gw = MicroserviceGateway(registry=reg, port=9000, jwt_secret="test-secret")
    gw.setup()

    # Start gateway in background thread
    server_thread = threading.Thread(
        target=lambda: __import__("uvicorn").run(gw.app, host="127.0.0.1", port=9000),
        daemon=True
    )
    server_thread.start()
    time.sleep(2)

    yield {"gateway_url": "http://127.0.0.1:9000", "registry": reg}

    pm.stop_all()

def test_full_flow(microservice_env):
    url = microservice_env["gateway_url"]

    # 1. Login
    resp = requests.post(f"{url}/auth/login", json={"username": "testuser", "password": "pass"})
    assert resp.status_code == 200
    token = resp.json()["token"]

    # 2. Call orders service
    resp = requests.get(f"{url}/api/orders/list_orders", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200

    # 3. Call payments service
    resp = requests.post(
        f"{url}/api/payments/charge",
        headers={"Authorization": f"Bearer {token}"},
        json={"amount": 50.0, "currency": "USD"}
    )
    assert resp.status_code == 200
```

---

## Milestone

- [ ] Unit tests for registry: all 7+ test cases pass
- [ ] Integration tests for gateway: routing, auth, 404/401 responses
- [ ] Contract test structure: validates request/response shapes between services
- [ ] E2E test: full flow from login → orders → payments works
- [ ] `pytest jac_scale/tests/test_microservices/ -v` passes

**You now understand**: the test pyramid for microservices, why contract tests prevent integration breakage, and how to test at each level (unit → integration → contract → E2E).
