"""Implementation of ServiceProcessManager methods."""

"""Assign a port to a service.

Uses core's hash-based strategy (18000 + hash(module) % 1000, 100 retries)
to match how `ensure_sv_service` assigns ports. This way `sv_client._registry`
URLs and our deployer URLs are consistent when the same module is re-spawned.
"""
impl ServiceProcessManager._assign_port
(service_entry: ServiceEntry) -> int {
    if service_entry.port > 0 {
        return service_entry.port;
    }
    import socket;
    base_port = 18000 + (hash(service_entry.name) % 1000);
    port = base_port;
    for _ in range(100) {
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1);
        try {
            s.bind(('127.0.0.1', port));
            s.close();
            return port;
        } except OSError {
            s.close();
            port = port + 1;
        }
    }
    logger.warning(f"Could not find free port near {base_port}, using fallback");
    return base_port;
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

    cmd = ["jac", "start", entry.file, "--port", str(port), "--no_client"];
    logger.info(f"Starting {name}: {' '.join(cmd)}");

    try {
        import os;
        import from pathlib { Path }
        child_env = dict(os.environ);
        # Prevent child process from re-triggering the orchestrator
        child_env["JAC_SV_SIBLING"] = "1";

        # Isolate data per service so shelf DBs don't clash.
        # Each subprocess writes to .jac/data/{name}/ instead of sharing .jac/data/.
        data_dir = Path(".jac/data") / name;
        data_dir.mkdir(parents=True, exist_ok=True);
        child_env["JAC_DATA_DIR"] = str(data_dir.resolve());

        # Write service logs to .jac/logs/{name}.log
        log_dir = Path(".jac/logs");
        log_dir.mkdir(parents=True, exist_ok=True);
        log_path = str(log_dir / f"{name}.log");
        log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND);

        proc = subprocess.Popen(
            cmd,
            stdout=log_fd,
            stderr=log_fd,
            stdin=subprocess.DEVNULL,
            env=child_env
        );
        os.close(log_fd);
        self.processes[name] = proc;
        entry.pid = proc.pid;
        entry.port = port;
        entry.url = f"http://127.0.0.1:{port}";
        entry.status = ServiceStatus.STARTING;
        self._failure_counts[name] = 0;

        # Register URL in sv_client so sv import calls can resolve it
        import from jaclang.runtimelib { sv_client }
        sv_client.register(name, entry.url);

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

    # Unregister from sv_client so sv import calls get fresh resolution
    import from jaclang.runtimelib { sv_client }
    sv_client.unregister(name);

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
        req = URLRequest(f"{entry.url}/healthz", method="GET");
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
