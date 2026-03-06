"""Factory for creating sandbox environment instances."""
import os;
import from typing { Any }
import from jac_scale.abstractions.sandbox_environment { SandboxEnvironment }
import from jac_scale.abstractions.models.sandbox_config { SandboxConfig }
import from jac_scale.abstractions.logger { Logger }

"""Factory for creating sandbox environment instances.

Configuration priority: jac.toml > environment variable > default

In jac.toml:
    [plugins.scale.sandbox]
    type = "docker"           # "kubernetes", "docker", "local"
    namespace = "jac-sandboxes"
    max_per_user = 3
    ttl_seconds = 3600

Environment variables:
    JAC_SANDBOX_TYPE: Sandbox type (kubernetes, docker, local)
    JAC_SANDBOX_NAMESPACE: K8s namespace for sandbox pods
    JAC_SANDBOX_DOMAIN: Domain template for preview URLs
"""
class SandboxFactory {
    """Create a sandbox environment based on type.

    Args:
        sandbox_type: Type of sandbox ('kubernetes', 'docker', 'local')
        config: Configuration dictionary
        logger: Optional logger instance

    Returns:
        SandboxEnvironment instance

    Raises:
        ValueError: If sandbox_type is not supported
    """
    static def create(
        sandbox_type: str,
        config: (dict[str, Any] | None) = None,
        logger: (Logger | None) = None
    ) -> SandboxEnvironment {
        cfg = config or {};
        sandbox_config = SandboxConfig.from_dict(cfg);

        if sandbox_type == "kubernetes" {
            import from jac_scale.providers.sandbox.kubernetes_sandbox {
                KubernetesSandbox
            }
            return KubernetesSandbox(config=sandbox_config, logger=logger);
        } elif sandbox_type == "docker" {
            import from jac_scale.providers.sandbox.docker_sandbox { DockerSandbox }
            return DockerSandbox(config=sandbox_config, logger=logger);
        } elif sandbox_type == "local" {
            import from jac_scale.providers.sandbox.local_sandbox { LocalSandbox }
            return LocalSandbox(config=sandbox_config, logger=logger);
        } else {
            raise ValueError(f"Unsupported sandbox type: {sandbox_type}");
        }
    }

    """Create a sandbox environment using config priority: jac.toml > env > defaults.

    Args:
        config_override: Optional config dict to override defaults
        logger: Optional logger instance

    Returns:
        SandboxEnvironment instance
    """
    static def get_default(
        config_override: (dict[str, Any] | None) = None, logger: (Logger | None) = None
    ) -> SandboxEnvironment {
        sandbox_type = "local";
        cfg: dict[str, Any] = {};

        # Priority 1: jac.toml [plugins.scale.sandbox]
        try {
            import from jac_scale.config_loader { get_scale_config }
            scale_config = get_scale_config();
            sandbox_cfg = scale_config.get("sandbox", {})
                if isinstance(scale_config, dict)
                else {};
            if sandbox_cfg and sandbox_cfg.get("enabled", False) {
                sandbox_type = sandbox_cfg.get("type", "local");
                cfg = sandbox_cfg;
            }
        } except Exception {
            ;
        }

        # Priority 2: Environment variables
        env_type = os.environ.get("JAC_SANDBOX_TYPE", "").strip();
        if env_type {
            sandbox_type = env_type;
        }
        env_ns = os.environ.get("JAC_SANDBOX_NAMESPACE", "").strip();
        if env_ns {
            cfg["namespace"] = env_ns;
        }
        env_domain = os.environ.get("JAC_SANDBOX_DOMAIN", "").strip();
        if env_domain {
            cfg["domain_template"] = env_domain;
        }

        # Priority 3: Explicit overrides
        if config_override {
            if "type" in config_override {
                sandbox_type = config_override["type"];
            }
            for (k, v) in config_override.items() {
                cfg[k] = v;
            }
        }

        return SandboxFactory.create(sandbox_type, cfg, logger);
    }
}
