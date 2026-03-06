"""Proxy-mode ingress provider for jac-scale sandboxes.

Returns the expected URL without creating any K8s Ingress resources.
Routing is handled by an external sandbox-proxy service that discovers
pods via K8s Watch API and routes by sandbox_id label.
"""
import from typing { Any }
import from jac_scale.abstractions.ingress_provider { IngressProvider }

"""Proxy-mode ingress — no-op K8s resource creation."""
class ProxyIngressProvider(IngressProvider) {
    has _config: dict = {};

    def init(self: ProxyIngressProvider, config: dict[str, Any] = {}) -> None {
        self._config = config;
    }

    def create_route(
        self: ProxyIngressProvider,
        sandbox_id: str,
        service_name: str,
        target_port: int,
        namespace: str,
        config: dict[str, Any]
    ) -> str {
        domain_template = config.get(
            "domain_template",
            self._config.get("domain_template", "{sandbox_id}.preview.example.com")
        );
        tls_enabled = config.get("tls_enabled", self._config.get("tls_enabled", False));
        hostname = domain_template.replace("{sandbox_id}", sandbox_id);
        protocol = "https" if tls_enabled else "http";
        return f"{protocol}://{hostname}";
    }

    def delete_route(
        self: ProxyIngressProvider, sandbox_id: str, namespace: str
    ) -> None {
        ;
    }

    def get_url(self: ProxyIngressProvider, sandbox_id: str) -> (str | None) {
        domain_template = self._config.get(
            "domain_template", "{sandbox_id}.preview.example.com"
        );
        tls_enabled = self._config.get("tls_enabled", False);
        hostname = domain_template.replace("{sandbox_id}", sandbox_id);
        protocol = "https" if tls_enabled else "http";
        return f"{protocol}://{hostname}";
    }
}
