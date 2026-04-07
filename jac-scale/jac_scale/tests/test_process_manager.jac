"""Tests for microservices ServiceProcessManager."""

import unittest.mock;
import subprocess;
import from jac_scale.microservices.service_registry {
    ServiceRegistry,
    ServiceEntry,
    ServiceStatus
}
import from jac_scale.microservices.process_manager {
    ServiceProcessManager
}

# =============================================================================
# Port assignment
# =============================================================================

test "auto assigns ports starting from 8001" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders"));
    reg.register(ServiceEntry(name="payments", file="payments.jac", prefix="/api/payments"));

    pm = ServiceProcessManager(registry=reg);

    port1 = pm._assign_port(reg.entries["orders"]);
    port2 = pm._assign_port(reg.entries["payments"]);

    assert port1 == 8001;
    assert port2 == 8002;
}

test "uses explicit port when set" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=9090));

    pm = ServiceProcessManager(registry=reg);
    port = pm._assign_port(reg.entries["orders"]);

    assert port == 9090;
}

# =============================================================================
# Start service
# =============================================================================

test "start service launches subprocess" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders"));

    pm = ServiceProcessManager(registry=reg);

    mock_proc = unittest.mock.MagicMock();
    mock_proc.pid = 12345;

    with unittest.mock.patch("subprocess.Popen", return_value=mock_proc) {
        result = pm.start_service("orders");

        assert result;
        assert "orders" in pm.processes;
        assert reg.entries["orders"].pid == 12345;
        assert reg.entries["orders"].status == ServiceStatus.STARTING;
        assert reg.entries["orders"].url == "http://127.0.0.1:8001";
    }
}

test "start service with nonexistent name returns false" {
    reg = ServiceRegistry();
    pm = ServiceProcessManager(registry=reg);

    result = pm.start_service("nonexistent");
    assert not result;
}

test "start all launches all services" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders"));
    reg.register(ServiceEntry(name="payments", file="payments.jac", prefix="/api/payments"));

    pm = ServiceProcessManager(registry=reg);

    mock_proc = unittest.mock.MagicMock();
    mock_proc.pid = 100;

    with unittest.mock.patch("subprocess.Popen", return_value=mock_proc) {
        pm.start_all();
        assert len(pm.processes) == 2;
    }
}

# =============================================================================
# Stop service
# =============================================================================

test "stop service terminates process" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001));

    pm = ServiceProcessManager(registry=reg);

    mock_proc = unittest.mock.MagicMock();
    mock_proc.pid = 12345;
    mock_proc.wait = unittest.mock.MagicMock(return_value=0);
    pm.processes["orders"] = mock_proc;
    reg.entries["orders"].pid = 12345;
    reg.entries["orders"].status = ServiceStatus.HEALTHY;

    result = pm.stop_service("orders");

    assert result;
    assert "orders" not in pm.processes;
    assert reg.entries["orders"].status == ServiceStatus.STOPPED;
    assert reg.entries["orders"].pid is None;
    mock_proc.terminate.assert_called_once();
}

test "stop service force kills on timeout" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders", port=8001));

    pm = ServiceProcessManager(registry=reg);

    mock_proc = unittest.mock.MagicMock();
    mock_proc.pid = 12345;
    # First wait(timeout=10) raises TimeoutExpired, second wait() after kill succeeds
    mock_proc.wait = unittest.mock.MagicMock(
        side_effect=[subprocess.TimeoutExpired("jac", 10), 0]
    );
    pm.processes["orders"] = mock_proc;

    pm.stop_service("orders");

    mock_proc.terminate.assert_called_once();
    mock_proc.kill.assert_called_once();
}

test "stop nonexistent service returns false" {
    reg = ServiceRegistry();
    pm = ServiceProcessManager(registry=reg);
    assert not pm.stop_service("nonexistent");
}

test "stop all stops all running services" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders"));
    reg.register(ServiceEntry(name="payments", file="payments.jac", prefix="/api/payments"));

    pm = ServiceProcessManager(registry=reg);

    for name in ["orders", "payments"] {
        mock_proc = unittest.mock.MagicMock();
        mock_proc.pid = 100;
        mock_proc.wait = unittest.mock.MagicMock(return_value=0);
        pm.processes[name] = mock_proc;
    }

    pm.stop_all();
    assert len(pm.processes) == 0;
}

# =============================================================================
# Health checks
# =============================================================================

test "check health returns false on no url" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001
    ));

    pm = ServiceProcessManager(registry=reg);
    assert not pm.check_health("orders");
}

test "check health returns false on network error" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001"
    ));

    pm = ServiceProcessManager(registry=reg);

    with unittest.mock.patch(
        "urllib.request.urlopen",
        side_effect=OSError("connection refused")
    ) {
        assert not pm.check_health("orders");
    }
}

test "check all health marks service unhealthy after max failures" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001"
    ));

    pm = ServiceProcessManager(registry=reg, _max_failures=2);

    # Mock check_health to return False (simulates failed health checks)
    with unittest.mock.patch.object(pm, "check_health", return_value=False) {
        pm.check_all_health();
        assert reg.entries["orders"].status != ServiceStatus.UNHEALTHY;

        pm.check_all_health();
        assert reg.entries["orders"].status == ServiceStatus.UNHEALTHY;
    }
}

test "check all health resets failure count on success" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(
        name="orders", file="orders.jac", prefix="/api/orders",
        port=8001, url="http://127.0.0.1:8001"
    ));

    pm = ServiceProcessManager(registry=reg, _max_failures=3);

    # Fail once
    with unittest.mock.patch.object(pm, "check_health", return_value=False) {
        pm.check_all_health();
    }
    assert pm._failure_counts["orders"] == 1;

    # Succeed — resets count
    with unittest.mock.patch.object(pm, "check_health", return_value=True) {
        pm.check_all_health();
    }
    assert pm._failure_counts["orders"] == 0;
    assert reg.entries["orders"].status == ServiceStatus.HEALTHY;
}

# =============================================================================
# Restart
# =============================================================================

test "restart stops then starts service" {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/api/orders"));

    pm = ServiceProcessManager(registry=reg);

    # Set up a running process to stop
    mock_proc = unittest.mock.MagicMock();
    mock_proc.pid = 100;
    mock_proc.wait = unittest.mock.MagicMock(return_value=0);
    pm.processes["orders"] = mock_proc;

    new_proc = unittest.mock.MagicMock();
    new_proc.pid = 200;

    with unittest.mock.patch("subprocess.Popen", return_value=new_proc) {
        result = pm.restart_service("orders");
        assert result;
        assert pm.processes["orders"] == new_proc;
        mock_proc.terminate.assert_called_once();
    }
}
