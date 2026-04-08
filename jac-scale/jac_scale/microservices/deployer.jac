"""Service deployment interface — abstract base for local and K8s deployers.

Provides a unified API for managing microservice lifecycles that can be
overridden for different deployment targets (local subprocesses, K8s pods, etc.).
"""

import logging;
import from typing { Any }
import from jac_scale.microservices.service_registry { ServiceRegistry, ServiceEntry, ServiceStatus }

glob logger = logging.getLogger(__name__);

"""Abstract deployer interface — override for each deployment target."""
obj ServiceDeployer {
    has registry: ServiceRegistry,
        target: str = "local";

    """Deploy a single service. Returns True on success."""
    def deploy_service(name: str) -> bool;

    """Stop a running service. Returns True on success."""
    def stop_service(name: str) -> bool;

    """Restart a service (stop + deploy). Returns True on success."""
    def restart_service(name: str) -> bool;

    """Scale a service to N replicas (K8s only, local always 1)."""
    def scale_service(name: str, replicas: int) -> bool;

    """Get status of all services."""
    def status -> dict[str, dict];

    """Get logs for a service."""
    def get_logs(name: str, lines: int = 50) -> str;

    """Stop all services and clean up."""
    def destroy_all -> bool;

    """Deploy all registered services."""
    def deploy_all -> bool;
}
