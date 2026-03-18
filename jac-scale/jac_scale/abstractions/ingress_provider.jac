import from typing { Any }

obj IngressProvider {
    def create_route(
        self: IngressProvider,
        sandbox_id: str,
        service_name: str,
        target_port: int,
        namespace: str,
        config: dict[str, Any]
    ) -> str;

    def delete_route(self: IngressProvider, sandbox_id: str, namespace: str) -> None;
    def get_url(self: IngressProvider, sandbox_id: str) -> (str | None);
}
