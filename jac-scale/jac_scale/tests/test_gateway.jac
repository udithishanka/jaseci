"""Tests for microservices MicroserviceGateway."""

import os;
import tempfile;
import from pathlib { Path }
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
# Setup
# =============================================================================

test "setup creates fastapi app" {
    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg);
    app = gw.setup();
    assert app is not None;
    assert gw.app is not None;
}

# =============================================================================
# Routing via TestClient
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

# =============================================================================
# Static file serving
# =============================================================================

test "serve static returns file with correct mime type" {
    tmp = tempfile.mkdtemp();
    assets_dir = Path(tmp) / "assets";
    assets_dir.mkdir();
    js_file = assets_dir / "app.js";
    js_file.write_text("console.log('hello');");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_static("assets/app.js");
    assert resp is not None;
    assert "javascript" in resp.media_type;
    assert b"hello" in resp.body;

    # Cleanup
    import shutil;
    shutil.rmtree(tmp);
}

test "serve static returns none for missing file" {
    tmp = tempfile.mkdtemp();

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_static("nonexistent.js");
    assert resp is None;

    import shutil;
    shutil.rmtree(tmp);
}

test "serve static blocks path traversal" {
    tmp = tempfile.mkdtemp();

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_static("../../etc/passwd");
    assert resp is None;

    import shutil;
    shutil.rmtree(tmp);
}

test "serve static css file returns text content type" {
    tmp = tempfile.mkdtemp();
    css_file = Path(tmp) / "style.css";
    css_file.write_text("body { color: red; }");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_static("style.css");
    assert resp is not None;
    assert resp.media_type == "text/css";

    import shutil;
    shutil.rmtree(tmp);
}

# =============================================================================
# SPA fallback
# =============================================================================

test "spa fallback serves index.html" {
    tmp = tempfile.mkdtemp();
    index = Path(tmp) / "index.html";
    index.write_text("<html><body>SPA</body></html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_spa_fallback();
    assert resp is not None;
    assert b"SPA" in resp.body;

    import shutil;
    shutil.rmtree(tmp);
}

test "spa fallback returns none when no index.html" {
    tmp = tempfile.mkdtemp();

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);

    resp = gw.serve_spa_fallback();
    assert resp is None;

    import shutil;
    shutil.rmtree(tmp);
}

# =============================================================================
# Static + SPA via TestClient (integration)
# =============================================================================

test "gateway serves static files for unmatched paths" {
    tmp = tempfile.mkdtemp();
    assets_dir = Path(tmp) / "assets";
    assets_dir.mkdir();
    (assets_dir / "app.js").write_text("var x = 1;");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/assets/app.js");
    assert resp.status_code == 200;
    assert "var x = 1" in resp.text;

    import shutil;
    shutil.rmtree(tmp);
}

test "gateway serves spa fallback for html navigation" {
    tmp = tempfile.mkdtemp();
    (Path(tmp) / "index.html").write_text("<html>SPA App</html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/dashboard", headers={"Accept": "text/html"});
    assert resp.status_code == 200;
    assert "SPA App" in resp.text;

    import shutil;
    shutil.rmtree(tmp);
}

test "gateway returns 404 for missing static and no spa" {
    tmp = tempfile.mkdtemp();

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, client_dist_dir=tmp);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/nonexistent.js");
    assert resp.status_code == 404;

    import shutil;
    shutil.rmtree(tmp);
}

# =============================================================================
# Admin UI serving
# =============================================================================

test "serve admin asset returns index.html for root" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    admin_dir.mkdir();
    (admin_dir / "index.html").write_text("<html>Admin Portal</html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));

    resp = gw.serve_admin_asset("");
    assert resp is not None;
    assert b"Admin Portal" in resp.body;

    import shutil;
    shutil.rmtree(tmp);
}

test "serve admin asset returns static file" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    assets = admin_dir / "assets";
    assets.mkdir(parents=True);
    (assets / "admin.js").write_text("var admin = true;");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));

    resp = gw.serve_admin_asset("assets/admin.js");
    assert resp is not None;
    assert b"admin" in resp.body;

    import shutil;
    shutil.rmtree(tmp);
}

test "serve admin asset spa fallback for unknown route" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    admin_dir.mkdir();
    (admin_dir / "index.html").write_text("<html>Admin SPA</html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));

    resp = gw.serve_admin_asset("users/list");
    assert resp is not None;
    assert b"Admin SPA" in resp.body;

    import shutil;
    shutil.rmtree(tmp);
}

test "serve admin asset blocks path traversal" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    admin_dir.mkdir();

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));

    resp = gw.serve_admin_asset("../../etc/passwd");
    assert resp is None;

    import shutil;
    shutil.rmtree(tmp);
}

test "admin redirect via testclient" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    admin_dir.mkdir();
    (admin_dir / "index.html").write_text("<html>Admin</html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app, follow_redirects=False);
    resp = client.get("/admin");
    assert resp.status_code == 302;
    assert resp.headers["location"] == "/admin/";

    import shutil;
    shutil.rmtree(tmp);
}

test "admin index served at /admin/" {
    tmp = tempfile.mkdtemp();
    admin_dir = Path(tmp) / "admin";
    admin_dir.mkdir();
    (admin_dir / "index.html").write_text("<html>Admin Dashboard</html>");

    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg, admin_dist_dir=str(admin_dir));
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);
    resp = client.get("/admin/");
    assert resp.status_code == 200;
    assert "Admin Dashboard" in resp.text;

    import shutil;
    shutil.rmtree(tmp);
}

# =============================================================================
# Auth - gateway is a pure passthrough; services handle auth via /user/login
# =============================================================================

test "api request to unreachable service returns 502" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001", status=ServiceStatus.HEALTHY
    ));
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);

    # Gateway proxies to service - service is not running so 502
    resp = client.get("/api/orders/walker/list");
    assert resp.status_code == 502;
}

test "health endpoint does not require auth" {
    reg = ServiceRegistry();
    gw = MicroserviceGateway(registry=reg);
    gw.setup();

    import from fastapi.testclient { TestClient }
    client = TestClient(gw.app);

    resp = client.get("/health");
    assert resp.status_code == 200;
}
