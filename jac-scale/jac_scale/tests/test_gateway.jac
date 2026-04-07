"""Tests for microservices MicroserviceGateway."""

import from jac_scale.microservices.service_registry {
    ServiceRegistry,
    ServiceEntry,
    ServiceStatus
}
import from jac_scale.microservices.gateway {
    MicroserviceGateway
}

# =============================================================================
# resolve_target_url
# =============================================================================

test "resolve strips prefix and preserves walker path" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);

    svc = reg.entries["orders"];
    url = gw.resolve_target_url(svc, "/api/orders/walker/list_orders", "");
    assert url == "http://127.0.0.1:8001/walker/list_orders";
}

test "resolve strips prefix and preserves function path" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);

    svc = reg.entries["orders"];
    url = gw.resolve_target_url(svc, "/api/orders/function/get_total", "");
    assert url == "http://127.0.0.1:8001/function/get_total";
}

test "resolve appends query string" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);

    svc = reg.entries["orders"];
    url = gw.resolve_target_url(svc, "/api/orders/walker/list", "limit=10");
    assert url == "http://127.0.0.1:8001/walker/list?limit=10";
}

test "resolve exact prefix returns root" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);

    svc = reg.entries["orders"];
    url = gw.resolve_target_url(svc, "/api/orders", "");
    assert url == "http://127.0.0.1:8001/";
}

test "resolve no query string omits question mark" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);

    svc = reg.entries["orders"];
    url = gw.resolve_target_url(svc, "/api/orders/walker/list", "");
    assert "?" not in url;
}

# =============================================================================
# Setup creates app
# =============================================================================

test "setup creates fastapi app" {
    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg);
    app = gw.setup();
    assert app is not None;
    assert gw.app is not None;
}

# =============================================================================
# Health endpoint via TestClient
# =============================================================================

test "health endpoint returns service summary" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/health");
    assert resp.status_code == 200;
    data = resp.json();
    assert data["status"] == "healthy";
    assert "orders" in data["services"];
}

test "unmatched path returns 404" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/api/unknown/walker/thing");
    assert resp.status_code == 404;
}

test "unhealthy service returns 503" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.UNHEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/api/orders/walker/list");
    assert resp.status_code == 503;
}

test "stopped service returns 503" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.STOPPED
    ));
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/api/orders/walker/list");
    assert resp.status_code == 503;
}

test "empty registry returns 404" {
    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/api/anything/walker/test");
    assert resp.status_code == 404;
}
