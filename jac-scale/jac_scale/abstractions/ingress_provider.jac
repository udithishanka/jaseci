"""Base ingress provider abstraction for jac_scale.

All ingress provider implementations should inherit from this class.
"""
import from typing { Any }

"""Base class for all ingress provider implementations."""
class IngressProvider {

    """Create a routing rule for a sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        service_name: Name of the K8s Service or Docker container to route to
        target_port: Port on the target to route traffic to
        namespace: Namespace where the service lives
        config: Additional config (domain, tls, annotations, etc.)

    Returns:
        The publicly accessible URL for this sandbox
    """
    def create_route(
        self: IngressProvider,
        sandbox_id: str,
        service_name: str,
        target_port: int,
        namespace: str,
        config: dict[str, Any]
    ) -> str;

    """Delete the routing rule for a sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        namespace: Namespace where the ingress lives
    """
    def delete_route(
        self: IngressProvider,
        sandbox_id: str,
        namespace: str
    ) -> None;

    """Get the URL for a sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox

    Returns:
        The URL or None if no route exists
    """
    def get_url(self: IngressProvider, sandbox_id: str) -> (str | None);
}
