"""Implementation of ServiceProcessManager methods."""

import subprocess;
import logging;
import from urllib.request { urlopen, Request }
import from urllib.error { URLError }
import from jac_scale.microservices.service_registry { ServiceStatus }

glob logger = logging.getLogger(__name__);

"""Assign a port to a service (auto-assign if port=0)."""
impl ServiceProcessManager._assign_port
(service_entry: ServiceEntry) -> int {
    if service_entry.port > 0 {
        return service_entry.port;
    }
    port = self._next_port;
    self._next_port += 1;
    return port;
}

"""Start a single service subprocess. Returns True on success."""
impl ServiceProcessManager.start_service
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
    } except OSError as e {
        logger.error(f"Failed to start {name}: {e}");
        entry.status = ServiceStatus.STOPPED;
        return False;
    }
}

"""Start all registered services."""
impl ServiceProcessManager.start_all
-> None {
    for name in self.registry.entries {
        self.start_service(name);
    }
}

"""Stop a single service (graceful SIGTERM, then SIGKILL)."""
impl ServiceProcessManager.stop_service
(name: str) -> bool {
    proc = self.processes.get(name);
    if not proc {
        return False;
    }

    entry = self.registry.entries.get(name);
    logger.info(f"Stopping {name} (pid={proc.pid})...");

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

"""Stop all running services."""
impl ServiceProcessManager.stop_all
-> None {
    names = list(self.processes.keys());
    for name in names {
        self.stop_service(name);
    }
}

"""Restart a service (stop + start)."""
impl ServiceProcessManager.restart_service
(name: str) -> bool {
    self.stop_service(name);
    return self.start_service(name);
}

"""Check /health on a single service. Returns True if healthy."""
impl ServiceProcessManager.check_health
(name: str) -> bool {
    entry = self.registry.entries.get(name);
    if not entry or not entry.url {
        return False;
    }

    try {
        req = Request(f"{entry.url}/health", method="GET");
        resp = urlopen(req, timeout=self._health_check_timeout);
        return getattr(resp, "status", 0) == 200;
    } except URLError {
        return False;
    } except OSError {
        return False;
    }
}

"""Run health checks on all services. Returns per-service results."""
impl ServiceProcessManager.check_all_health
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
                logger.warning(
                    f"{name} is UNHEALTHY ({self._failure_counts[name]} consecutive failures)"
                );
            }
        }
    }

    return results;
}
