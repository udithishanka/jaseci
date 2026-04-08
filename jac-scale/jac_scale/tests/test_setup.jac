"""Tests for microservices setup CLI utilities."""

import os;
import tempfile;
import tomllib;
import from pathlib { Path }
import from jac_scale.microservices.setup {
    scan_jac_files,
    derive_service_name,
    derive_prefix,
    add_service,
    remove_service,
    list_services
}

# =============================================================================
# Utility functions
# =============================================================================

test "derive_service_name strips _app suffix" {
    assert derive_service_name("orders_app.jac") == "orders";
    assert derive_service_name("payments_app.jac") == "payments";
}

test "derive_service_name keeps name without _app" {
    assert derive_service_name("orders.jac") == "orders";
    assert derive_service_name("services/orders.jac") == "orders";
}

test "derive_prefix adds /api/ prefix" {
    assert derive_prefix("orders") == "/api/orders";
    assert derive_prefix("payments") == "/api/payments";
}

# =============================================================================
# scan_jac_files
# =============================================================================

test "scan_jac_files finds jac files" {
    tmp = tempfile.mkdtemp();
    (Path(tmp) / "app.jac").write_text("# app");
    (Path(tmp) / "orders.jac").write_text("# orders");

    files = scan_jac_files(tmp);
    assert "app.jac" in files;
    assert "orders.jac" in files;

    import shutil;
    shutil.rmtree(tmp);
}

test "scan_jac_files excludes build dirs" {
    tmp = tempfile.mkdtemp();
    (Path(tmp) / "app.jac").write_text("# app");
    jac_dir = Path(tmp) / ".jac";
    jac_dir.mkdir();
    (jac_dir / "cache.jac").write_text("# cached");
    pycache_dir = Path(tmp) / "__pycache__";
    pycache_dir.mkdir();
    (pycache_dir / "mod.jac").write_text("# compiled");

    files = scan_jac_files(tmp);
    assert "app.jac" in files;
    assert len(files) == 1;

    import shutil;
    shutil.rmtree(tmp);
}

test "scan_jac_files finds nested files" {
    tmp = tempfile.mkdtemp();
    svc_dir = Path(tmp) / "services";
    svc_dir.mkdir();
    (svc_dir / "orders.jac").write_text("# orders");

    files = scan_jac_files(tmp);
    assert len(files) == 1;
    found_path: str = files[0];
    assert "services" in found_path;
    assert "orders.jac" in found_path;

    import shutil;
    shutil.rmtree(tmp);
}

# =============================================================================
# add_service / remove_service / list_services
# =============================================================================

test "add_service appends to jac.toml" {
    tmp = tempfile.mkdtemp();
    toml_path = Path(tmp) / "jac.toml";
    toml_path.write_text('[plugins.scale.microservices]\nenabled = true\n');

    add_service(tmp, "orders_app.jac");

    with open(str(toml_path), "rb") as f {
        doc = tomllib.load(f);
    }
    services = doc["plugins"]["scale"]["microservices"]["services"];
    assert "orders" in services;
    assert services["orders"]["file"] == "orders_app.jac";
    assert services["orders"]["prefix"] == "/api/orders";

    import shutil;
    shutil.rmtree(tmp);
}

test "add_service rejects duplicate" {
    tmp = tempfile.mkdtemp();
    toml_content = '[plugins.scale.microservices]\nenabled = true\n\n[plugins.scale.microservices.services.orders]\nfile = "orders_app.jac"\nprefix = "/api/orders"\n';
    (Path(tmp) / "jac.toml").write_text(toml_content);

    # Should print error, not crash
    add_service(tmp, "orders_app.jac");

    import shutil;
    shutil.rmtree(tmp);
}

test "remove_service removes from jac.toml" {
    tmp = tempfile.mkdtemp();
    toml_content = '[plugins.scale.microservices]\nenabled = true\n\n[plugins.scale.microservices.services.orders]\nfile = "orders_app.jac"\nprefix = "/api/orders"\n\n[plugins.scale.microservices.services.payments]\nfile = "payments_app.jac"\nprefix = "/api/payments"\n';
    (Path(tmp) / "jac.toml").write_text(toml_content);

    remove_service(tmp, "orders");

    content = (Path(tmp) / "jac.toml").read_text();
    assert "orders" not in content.lower() or "payments" in content;
    assert "[plugins.scale.microservices.services.payments]" in content;

    import shutil;
    shutil.rmtree(tmp);
}

test "remove_service handles missing service" {
    tmp = tempfile.mkdtemp();
    (Path(tmp) / "jac.toml").write_text('[plugins.scale.microservices]\nenabled = true\n');

    # Should print error, not crash
    remove_service(tmp, "nonexistent");

    import shutil;
    shutil.rmtree(tmp);
}

test "list_services shows config" {
    tmp = tempfile.mkdtemp();
    toml_content = '[plugins.scale.microservices]\nenabled = true\ngateway_port = 8000\n\n[plugins.scale.microservices.services.orders]\nfile = "orders_app.jac"\nprefix = "/api/orders"\n';
    (Path(tmp) / "jac.toml").write_text(toml_content);

    # Should print without crashing
    list_services(tmp);

    import shutil;
    shutil.rmtree(tmp);
}

test "list_services handles missing toml" {
    tmp = tempfile.mkdtemp();

    # Should print error, not crash
    list_services(tmp);

    import shutil;
    shutil.rmtree(tmp);
}
