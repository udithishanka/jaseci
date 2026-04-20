"""Tests for microservices orchestrator."""

import from jac_scale.microservices.orchestrator { build_registry }
import from jac_scale.microservices.service_registry { ServiceStatus }

# =============================================================================
# build_registry — routes (v2) path
# =============================================================================

test "build_registry creates entries from routes map" {
    ms_config = {
        "routes": {
            "orders_app": "/api/orders",
            "cart_app": "/api/cart"
        }
    };

    registry = build_registry(ms_config);

    assert len(registry.entries) == 2;
    assert "orders_app" in registry.entries;
    assert "cart_app" in registry.entries;
    assert registry.entries["orders_app"].prefix == "/api/orders";
    assert registry.entries["cart_app"].prefix == "/api/cart";
    # file derived from module name
    assert registry.entries["orders_app"].file == "orders_app.jac";
    assert registry.entries["cart_app"].file == "cart_app.jac";
}

test "build_registry handles empty config" {
    registry = build_registry({});
    assert len(registry.entries) == 0;
}

test "build_registry route entries have port 0" {
    ms_config = {"routes": {"orders_app": "/api/orders"}};
    registry = build_registry(ms_config);
    assert registry.entries["orders_app"].port == 0;
}

test "build_registry routes work after build" {
    ms_config = {
        "routes": {
            "orders_app": "/api/orders",
            "cart_app": "/api/cart"
        }
    };

    registry = build_registry(ms_config);
    assert registry.match_route("/api/orders/function/create_order").name == "orders_app";
    assert registry.match_route("/api/cart/function/view_cart").name == "cart_app";
    assert registry.match_route("/api/unknown") is None;
}

# =============================================================================
# build_registry — legacy services (v1) path
# =============================================================================

test "build_registry supports legacy services map" {
    ms_config = {
        "services": {
            "orders": {"file": "orders_app.jac", "prefix": "/api/orders"},
            "cart": {"file": "cart_app.jac", "prefix": "/api/cart"}
        }
    };

    registry = build_registry(ms_config);
    assert len(registry.entries) == 2;
    assert registry.entries["orders"].file == "orders_app.jac";
    assert registry.entries["orders"].prefix == "/api/orders";
}

test "build_registry legacy respects explicit port" {
    ms_config = {
        "services": {
            "orders": {"file": "orders_app.jac", "prefix": "/api/orders", "port": 9001}
        }
    };

    registry = build_registry(ms_config);
    assert registry.entries["orders"].port == 9001;
}

test "build_registry routes take precedence over legacy services" {
    ms_config = {
        "routes": {"orders_app": "/api/orders"},
        "services": {
            "orders_app": {"file": "different.jac", "prefix": "/different"}
        }
    };

    registry = build_registry(ms_config);
    # routes entry wins
    assert registry.entries["orders_app"].prefix == "/api/orders";
    assert registry.entries["orders_app"].file == "orders_app.jac";
}
