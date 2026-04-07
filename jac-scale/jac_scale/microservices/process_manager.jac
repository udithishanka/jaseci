"""Manages service subprocess lifecycles in local mode."""

import subprocess;
import logging;
import from urllib.request { urlopen, Request as URLRequest }
import from urllib.error { URLError }
import from jac_scale.microservices.service_registry {
    ServiceRegistry,
    ServiceEntry,
    ServiceStatus
}

glob logger = logging.getLogger(__name__);

"""Starts, stops, health-checks, and restarts service subprocesses."""
obj ServiceProcessManager {
    has registry: ServiceRegistry,
        processes: dict[str, subprocess.Popen] = {},
        _health_check_timeout: int = 3,
        _max_failures: int = 3,
        _failure_counts: dict[str, int] = {},
        _next_port: int = 8001;

    """Assign a port to a service (auto-assign if port=0)."""
    def _assign_port(service_entry: ServiceEntry) -> int;

    """Start a single service subprocess. Returns True on success."""
    def start_service(name: str) -> bool;

    """Start all registered services."""
    def start_all -> None;

    """Stop a single service (graceful SIGTERM, then SIGKILL)."""
    def stop_service(name: str) -> bool;

    """Stop all running services."""
    def stop_all -> None;

    """Restart a service (stop + start)."""
    def restart_service(name: str) -> bool;

    """Check /health on a single service. Returns True if healthy."""
    def check_health(name: str) -> bool;

    """Run health checks on all services. Returns per-service results."""
    def check_all_health -> dict[str, bool];
}
