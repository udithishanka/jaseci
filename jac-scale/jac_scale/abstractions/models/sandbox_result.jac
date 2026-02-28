"""Sandbox result model."""
import from typing { Any }

"""Result of a sandbox creation operation."""
class SandboxResult {
    has success: bool,
        sandbox_id: str = "",
        url: str = "",
        port: int = 0,
        api_port: int = 0,
        message: (str | None) = None,
        details: dict[str, Any] = {};

    def init(
        self: SandboxResult,
        success: bool,
        sandbox_id: str = "",
        url: str = "",
        port: int = 0,
        api_port: int = 0,
        message: (str | None) = None,
        details: dict[str, Any] = {}
    ) -> None {
        self.success = success;
        self.sandbox_id = sandbox_id;
        self.url = url;
        self.port = port;
        self.api_port = api_port;
        self.message = message;
        self.details = details;
    }

    def is_successful(self: SandboxResult) -> bool {
        return self.success;
    }
}
