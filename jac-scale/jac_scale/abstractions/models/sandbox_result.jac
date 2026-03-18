import from typing { Any }

obj SandboxResult {
    has success: bool,
        sandbox_id: str = "",
        url: str = "",
        port: int = 0,
        api_port: int = 0,
        message: (str | None) = None,
        details: dict[str, Any] = {};

    def is_successful(self: SandboxResult) -> bool {
        return self.success;
    }
}
