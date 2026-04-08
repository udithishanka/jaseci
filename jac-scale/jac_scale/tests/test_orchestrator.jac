"""Tests for microservices orchestrator."""

import from jac_scale.microservices.orchestrator { build_registry }
import from jac_scale.microservices.service_registry { ServiceStatus }

# =============================================================================
# build_registry
# =============================================================================

test "build_registry creates entries from config" {
    config = {
        "orders": {"file": "orders_app.jac", "prefix": "/api/orders"},
        "payments": {"file": "payments_app.jac", "prefix": "/api/payments"}
    };

    registry = build_registry(config);

    assert len(registry.entries) == 2;
    assert "orders" in registry.entries;
    assert "payments" in registry.entries;
    assert registry.entries["orders"].file == "orders_app.jac";
    assert registry.entries["orders"].prefix == "/api/orders";
    assert registry.entries["payments"].file == "payments_app.jac";
}

test "build_registry defaults prefix from name" {
    config = {
        "orders": {"file": "orders_app.jac"}
    };

    registry = build_registry(config);
    assert registry.entries["orders"].prefix == "/api/orders";
}

test "build_registry handles empty config" {
    registry = build_registry({});
    assert len(registry.entries) == 0;
}

test "build_registry sets default port 0" {
    config = {
        "orders": {"file": "orders_app.jac", "prefix": "/api/orders"}
    };

    registry = build_registry(config);
    assert registry.entries["orders"].port == 0;
}

test "build_registry respects explicit port" {
    config = {
        "orders": {"file": "orders_app.jac", "prefix": "/api/orders", "port": 9001}
    };

    registry = build_registry(config);
    assert registry.entries["orders"].port == 9001;
}

test "build_registry routes work after build" {
    config = {
        "orders": {"file": "orders_app.jac", "prefix": "/api/orders"},
        "cart": {"file": "cart_app.jac", "prefix": "/api/cart"}
    };

    registry = build_registry(config);
    assert registry.match_route("/api/orders/walker/list").name == "orders";
    assert registry.match_route("/api/cart/walker/add").name == "cart";
    assert registry.match_route("/api/unknown") is None;
}
