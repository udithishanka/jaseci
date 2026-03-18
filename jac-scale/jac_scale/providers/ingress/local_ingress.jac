import from typing { Any }
import from jac_scale.abstractions.ingress_provider { IngressProvider }

obj LocalIngressProvider(IngressProvider) {
    has _config: dict = {},
        _routes: dict = {};

    def init(self: LocalIngressProvider, config: dict[str, Any] = {}) -> None {
        self._config = config;
        self._routes = {};
    }

    def create_route(
        self: LocalIngressProvider,
        sandbox_id: str,
        service_name: str,
        target_port: int,
        namespace: str,
        config: dict[str, Any]
    ) -> str {
        url = f"http://localhost:{target_port}";
        self._routes[sandbox_id] = url;
        return url;
    }

    def delete_route(
        self: LocalIngressProvider, sandbox_id: str, namespace: str
    ) -> None {
        self._routes.pop(sandbox_id, None);
    }

    def get_url(self: LocalIngressProvider, sandbox_id: str) -> (str | None) {
        return self._routes.get(sandbox_id);
    }
}
