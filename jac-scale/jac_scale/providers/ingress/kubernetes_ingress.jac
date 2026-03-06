"""Kubernetes Ingress provider for sandbox routing.

Creates K8s Ingress resources with wildcard subdomain routing,
TLS support via cert-manager, and cloud-agnostic annotations.
"""
import from typing { Any }
import from jac_scale.abstractions.ingress_provider { IngressProvider }

"""Kubernetes Ingress provider — creates Ingress resources for sandbox routing."""
class KubernetesIngressProvider(IngressProvider) {
    has _config: dict = {},
        _k8s_initialized: bool = False;

    def init(self: KubernetesIngressProvider, config: dict[str, Any] = {}) -> None {
        self._config = config;
        self._k8s_initialized = False;
    }

    def _init_k8s(self: KubernetesIngressProvider) -> None {
        if self._k8s_initialized {
            return;
        }
        import from kubernetes { config as k8s_config }
        import from kubernetes.config { ConfigException }
        try {
            k8s_config.load_kube_config();
        } except ConfigException {
            k8s_config.load_incluster_config();
        }
        self._k8s_initialized = True;
    }

    def create_route(
        self: KubernetesIngressProvider,
        sandbox_id: str,
        service_name: str,
        target_port: int,
        namespace: str,
        config: dict[str, Any]
    ) -> str {
        self._init_k8s();
        import from kubernetes { client }
        networking_v1 = client.NetworkingV1Api();

        domain_template = config.get(
            "domain_template",
            self._config.get("domain_template", "{sandbox_id}.preview.example.com")
        );
        ingress_class = config.get(
            "ingress_class", self._config.get("ingress_class", "nginx")
        );
        tls_enabled = config.get("tls_enabled", self._config.get("tls_enabled", False));
        tls_issuer = config.get(
            "tls_issuer", self._config.get("tls_issuer", "letsencrypt-prod")
        );

        # Build hostname from template
        hostname = domain_template.replace("{sandbox_id}", sandbox_id);
        protocol = "https" if tls_enabled else "http";
        url = f"{protocol}://{hostname}";
        ingress_name = f"{sandbox_id}-ingress";

        # Annotations — merge custom annotations from config
        annotations: dict[str, str] = {};
        custom_annotations = config.get(
            "ingress_annotations", self._config.get("ingress_annotations", {})
        );
        if isinstance(custom_annotations, dict) {
            annotations.update(custom_annotations);
        }
        if "kubernetes.io/ingress.class" not in annotations {
            annotations["kubernetes.io/ingress.class"] = ingress_class;
        }
        if tls_enabled and "cert-manager.io/cluster-issuer" not in annotations {
            annotations["cert-manager.io/cluster-issuer"] = tls_issuer;
        }

        # TLS configuration
        tls_config = None;
        if tls_enabled {
            tls_config = [
                client.V1IngressTLS(hosts=[hostname], secret_name=f"{sandbox_id}-tls")
            ];
        }

        # Ingress spec
        ingress = client.V1Ingress(
            metadata=client.V1ObjectMeta(
                name=ingress_name,
                namespace=namespace,
                annotations=annotations,
                labels={"jac-sandbox": "true", "jac-sandbox-id": sandbox_id}
            ),
            spec=client.V1IngressSpec(
                ingress_class_name=ingress_class,
                tls=tls_config,
                rules=[
                    client.V1IngressRule(
                        host=hostname,
                        http=client.V1HTTPIngressRuleValue(
                            paths=[
                                client.V1HTTPIngressPath(
                                    path="/",
                                    path_type="Prefix",
                                    backend=client.V1IngressBackend(
                                        service=client.V1IngressServiceBackend(
                                            name=service_name,
                                            port=client.V1ServiceBackendPort(
                                                number=target_port
                                            )
                                        )
                                    )
                                )
                            ]
                        )
                    )
                ]
            )
        );

        networking_v1.create_namespaced_ingress(namespace, ingress);
        return url;
    }

    def delete_route(
        self: KubernetesIngressProvider, sandbox_id: str, namespace: str
    ) -> None {
        self._init_k8s();
        import from kubernetes { client }
        import from kubernetes.client.exceptions { ApiException }
        networking_v1 = client.NetworkingV1Api();
        ingress_name = f"{sandbox_id}-ingress";
        try {
            networking_v1.delete_namespaced_ingress(ingress_name, namespace);
        } except ApiException {
            ;
        }
    }

    def get_url(self: KubernetesIngressProvider, sandbox_id: str) -> (str | None) {
        domain_template = self._config.get(
            "domain_template", "{sandbox_id}.preview.example.com"
        );
        tls_enabled = self._config.get("tls_enabled", False);
        hostname = domain_template.replace("{sandbox_id}", sandbox_id);
        protocol = "https" if tls_enabled else "http";
        return f"{protocol}://{hostname}";
    }
}
