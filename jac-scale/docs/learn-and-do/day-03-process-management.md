# Day 3: Process Management & Health Checks

## Learn (~1 hour)

### Processes vs Threads

When you run `jac start orders.jac`, the OS creates a **process** — an independent program with its own memory. This is different from threads (which share memory within one process).

```
Process A (orders.jac)          Process B (payments.jac)
┌──────────────────────┐       ┌──────────────────────┐
│ Own memory           │       │ Own memory           │
│ Own ModuleIntrospector│      │ Own ModuleIntrospector│
│ Own FastAPI on :8001 │       │ Own FastAPI on :8002 │
│ If I crash, B is fine│       │ If I crash, A is fine│
└──────────────────────┘       └──────────────────────┘
```

**Why subprocesses for microservices?**

- Crash isolation: one service dying doesn't kill others
- Memory isolation: no walker name collisions between services
- Maps 1:1 to K8s pods (same architecture local and in production)

### Python's `subprocess` Module

Python provides `subprocess.Popen` to start child processes:

```python
import subprocess

# Start a child process
proc = subprocess.Popen(
    ["jac", "start", "orders.jac", "--port", "8001", "--no-client"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE
)

print(proc.pid)       # OS process ID
print(proc.poll())    # None if still running, exit code if done

proc.terminate()      # Send SIGTERM (graceful shutdown)
proc.kill()           # Send SIGKILL (force kill)
```

### Health Checks

How does the gateway know a service is ready? **Health checks** — periodic HTTP requests to a known endpoint:

```
Gateway                    Service (:8001)
  │                            │
  │  GET /health               │
  │───────────────────────────►│
  │                            │
  │  200 {"status": "healthy"} │
  │◄───────────────────────────│
```

jac-scale already registers a `/health` endpoint on every server. We just need to poll it.

**Health check lifecycle:**

```
Start process → wait 2s → poll /health every 5s
                              │
                    200? → mark HEALTHY
                    fail? → increment fail count
                              │
                    3 consecutive fails? → mark UNHEALTHY → restart
```

### Graceful Shutdown

When stopping a service:

1. Send `SIGTERM` (polite: "please shut down")
2. Wait up to 10 seconds for the process to exit
3. If still running, send `SIGKILL` (force kill)

This gives the service time to finish in-flight requests.

---

## Do (~2-3 hours)

### Task 1: Build the Process Manager

**`jac_scale/microservices/process_manager.jac`**

```jac
"""Manages service subprocess lifecycles in local mode."""

import subprocess;
import logging;
import from typing { Any }
import from jac_scale.microservices.registry { ServiceRegistry, ServiceEntry, ServiceStatus }

glob logger = logging.getLogger(__name__);

obj ServiceProcessManager {
    has registry: ServiceRegistry,
        processes: dict[str, subprocess.Popen] = {},
        _health_check_interval: int = 5,     # seconds between health checks
        _health_check_timeout: int = 3,       # seconds to wait for /health response
        _max_failures: int = 3,               # consecutive failures before UNHEALTHY
        _failure_counts: dict[str, int] = {},
        _next_port: int = 8001;               # auto-assign ports starting here

    """Start all registered services as subprocesses."""
    def start_all -> None;

    """Start a single service subprocess."""
    def start_service(name: str) -> bool;

    """Stop a single service (graceful then force)."""
    def stop_service(name: str) -> bool;

    """Stop all services."""
    def stop_all -> None;

    """Restart a service (stop + start)."""
    def restart_service(name: str) -> bool;

    """Check /health on one service. Returns True if healthy."""
    def check_health(name: str) -> bool;

    """Run health checks on all services. Call this periodically."""
    def check_all_health -> dict[str, bool];

    """Assign a port to a service (if port=0, auto-assign)."""
    def _assign_port(entry: ServiceEntry) -> int;
}
```

### Task 2: Implement it

**`jac_scale/microservices/impl/process_manager.impl.jac`**

```jac
import subprocess;
import time;
import signal;
import logging;
import from urllib.request { urlopen, Request }
import from urllib.error { URLError }
import from jac_scale.microservices.process_manager { ServiceProcessManager }
import from jac_scale.microservices.registry { ServiceEntry, ServiceStatus }

glob logger = logging.getLogger(__name__);

:obj:ServiceProcessManager:can:_assign_port
(entry: ServiceEntry) -> int {
    if entry.port > 0 {
        return entry.port;
    }
    port = self._next_port;
    self._next_port += 1;
    return port;
}

:obj:ServiceProcessManager:can:start_service
(name: str) -> bool {
    if name not in self.registry.entries {
        logger.error(f"Service '{name}' not found in registry");
        return False;
    }

    entry = self.registry.entries[name];
    port = self._assign_port(entry);

    cmd = ["jac", "start", entry.file, "--port", str(port), "--no-client"];
    logger.info(f"Starting {name}: {' '.join(cmd)}");

    try {
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        );
        self.processes[name] = proc;
        entry.pid = proc.pid;
        entry.port = port;
        entry.url = f"http://127.0.0.1:{port}";
        entry.status = ServiceStatus.STARTING;
        self._failure_counts[name] = 0;

        logger.info(f"Started {name} (pid={proc.pid}, port={port})");
        return True;
    } except Exception as e {
        logger.error(f"Failed to start {name}: {e}");
        entry.status = ServiceStatus.STOPPED;
        return False;
    }
}

:obj:ServiceProcessManager:can:start_all
-> None {
    for name in self.registry.entries {
        self.start_service(name);
    }
}

:obj:ServiceProcessManager:can:stop_service
(name: str) -> bool {
    proc = self.processes.get(name);
    if not proc {
        return False;
    }

    entry = self.registry.entries.get(name);
    logger.info(f"Stopping {name} (pid={proc.pid})...");

    # Graceful shutdown: SIGTERM → wait → SIGKILL
    proc.terminate();
    try {
        proc.wait(timeout=10);
    } except subprocess.TimeoutExpired {
        logger.warning(f"{name} did not exit gracefully, force killing");
        proc.kill();
        proc.wait();
    }

    del self.processes[name];
    if entry {
        entry.status = ServiceStatus.STOPPED;
        entry.pid = None;
    }

    logger.info(f"Stopped {name}");
    return True;
}

:obj:ServiceProcessManager:can:stop_all
-> None {
    for name in list(self.processes.keys()) {
        self.stop_service(name);
    }
}

:obj:ServiceProcessManager:can:restart_service
(name: str) -> bool {
    self.stop_service(name);
    return self.start_service(name);
}

:obj:ServiceProcessManager:can:check_health
(name: str) -> bool {
    entry = self.registry.entries.get(name);
    if not entry or not entry.url {
        return False;
    }

    try {
        req = Request(f"{entry.url}/health", method="GET");
        resp = urlopen(req, timeout=self._health_check_timeout);
        return resp.status == 200;
    } except (URLError, Exception) {
        return False;
    }
}

:obj:ServiceProcessManager:can:check_all_health
-> dict[str, bool] {
    results: dict[str, bool] = {};

    for (name, entry) in self.registry.entries.items() {
        healthy = self.check_health(name);
        results[name] = healthy;

        if healthy {
            entry.status = ServiceStatus.HEALTHY;
            self._failure_counts[name] = 0;
        } else {
            self._failure_counts[name] = self._failure_counts.get(name, 0) + 1;
            if self._failure_counts[name] >= self._max_failures {
                entry.status = ServiceStatus.UNHEALTHY;
                logger.warning(f"{name} is UNHEALTHY ({self._failure_counts[name]} consecutive failures)");
            }
        }
    }

    return results;
}
```

### Task 3: Manual integration test

Test with your Day 1 test project:

```python
# test_process_manager.py — run from test-microservices/
import time
from jac_scale.microservices.registry import ServiceRegistry, ServiceEntry
from jac_scale.microservices.process_manager import ServiceProcessManager

# Set up registry
reg = ServiceRegistry()
reg.register(ServiceEntry(name="orders", file="services/orders.jac", prefix="/api/orders"))
reg.register(ServiceEntry(name="payments", file="services/payments.jac", prefix="/api/payments"))

# Start services
pm = ServiceProcessManager(registry=reg)
pm.start_all()

print("Services starting...")
print(f"  orders: pid={reg.entries['orders'].pid}, port={reg.entries['orders'].port}")
print(f"  payments: pid={reg.entries['payments'].pid}, port={reg.entries['payments'].port}")

# Wait for services to be ready
time.sleep(5)

# Health check
results = pm.check_all_health()
print(f"\nHealth: {results}")
print(f"  orders status: {reg.entries['orders'].status.value}")
print(f"  payments status: {reg.entries['payments'].status.value}")

# Test that services are actually responding
import urllib.request
for name, entry in reg.entries.items():
    try:
        resp = urllib.request.urlopen(f"{entry.url}/health")
        print(f"  {name} /health: {resp.status}")
    except Exception as e:
        print(f"  {name} /health: FAILED ({e})")

# Clean up
pm.stop_all()
print("\nAll services stopped.")
```

---

## Milestone

- [ ] `ServiceProcessManager` starts services as subprocesses with `jac start --no-client`
- [ ] Auto-assigns ports (8001, 8002, ...)
- [ ] Health checks via HTTP `/health` endpoint work
- [ ] Graceful shutdown works (SIGTERM → wait → SIGKILL)
- [ ] Running the test script: 2 services start, pass health check, then stop cleanly

**You now understand**: how subprocesses provide isolation, how health checks monitor service state, and how graceful shutdown works. Tomorrow you'll build the gateway that routes traffic to these services.
