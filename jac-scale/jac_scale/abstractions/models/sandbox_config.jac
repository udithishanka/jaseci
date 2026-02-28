"""Sandbox configuration model."""
import from typing { Any }

"""Configuration for sandbox environments."""
class SandboxConfig {
    has sandbox_type: str = "docker",
        namespace: str = "jac-sandboxes",
        max_per_user: int = 3,
        ttl_seconds: int = 3600,
        cpu_limit: str = "500m",
        memory_limit: str = "512Mi",
        base_image: str = "python:3.12-slim",
        storage_limit: str = "256Mi",
        domain_template: str = "{sandbox_id}.preview.example.com",
        security_context_enabled: bool = True,
        network_isolation: bool = True,
        ingress_class: str = "nginx",
        tls_enabled: bool = False,
        tls_issuer: str = "letsencrypt-prod";

    def init(
        self: SandboxConfig,
        sandbox_type: str = "docker",
        namespace: str = "jac-sandboxes",
        max_per_user: int = 3,
        ttl_seconds: int = 3600,
        cpu_limit: str = "500m",
        memory_limit: str = "512Mi",
        base_image: str = "python:3.12-slim",
        storage_limit: str = "256Mi",
        domain_template: str = "{sandbox_id}.preview.example.com",
        security_context_enabled: bool = True,
        network_isolation: bool = True,
        ingress_class: str = "nginx",
        tls_enabled: bool = False,
        tls_issuer: str = "letsencrypt-prod"
    ) -> None {
        self.sandbox_type = sandbox_type;
        self.namespace = namespace;
        self.max_per_user = max_per_user;
        self.ttl_seconds = ttl_seconds;
        self.cpu_limit = cpu_limit;
        self.memory_limit = memory_limit;
        self.base_image = base_image;
        self.storage_limit = storage_limit;
        self.domain_template = domain_template;
        self.security_context_enabled = security_context_enabled;
        self.network_isolation = network_isolation;
        self.ingress_class = ingress_class;
        self.tls_enabled = tls_enabled;
        self.tls_issuer = tls_issuer;
    }

    """Create SandboxConfig from a dictionary."""
    static def from_dict(config: dict[str, Any]) -> SandboxConfig {
        return SandboxConfig(
            sandbox_type=config.get("type", config.get("sandbox_type", "docker")),
            namespace=config.get("namespace", "jac-sandboxes"),
            max_per_user=config.get("max_per_user", 3),
            ttl_seconds=config.get("ttl_seconds", 3600),
            cpu_limit=config.get("cpu_limit", "500m"),
            memory_limit=config.get("memory_limit", "512Mi"),
            base_image=config.get("base_image", "python:3.12-slim"),
            storage_limit=config.get("storage_limit", "256Mi"),
            domain_template=config.get("domain_template", "{sandbox_id}.preview.example.com"),
            security_context_enabled=config.get("security_context", True),
            network_isolation=config.get("network_isolation", True),
            ingress_class=config.get("ingress_class", "nginx"),
            tls_enabled=config.get("tls_enabled", False),
            tls_issuer=config.get("tls_issuer", "letsencrypt-prod")
        );
    }
}
