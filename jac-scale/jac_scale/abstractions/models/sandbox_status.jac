"""Sandbox status models."""
import from enum { Enum }
import from typing { Any }

"""State of a sandbox environment."""
class SandboxState(Enum) {
    has PENDING: str = "pending",
        STARTING: str = "starting",
        RUNNING: str = "running",
        STOPPING: str = "stopping",
        STOPPED: str = "stopped",
        ERROR: str = "error";
}

"""Detailed sandbox status information."""
class SandboxStatus {
    has state: SandboxState,
        sandbox_id: str = "",
        uptime_seconds: float = 0.0,
        url: str = "",
        port: int = 0,
        message: (str | None) = None;

    def is_running(self: SandboxStatus) -> bool {
        return self.state == SandboxState.RUNNING;
    }
}

"""Summary info for listing sandboxes."""
class SandboxInfo {
    has sandbox_id: str,
        user_id: str,
        project_id: str,
        state: SandboxState,
        url: str = "",
        created_at: float = 0.0;
}
