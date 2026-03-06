"""Base sandbox environment abstraction for jac_scale.

All sandbox environment implementations should inherit from this class.
"""
import os;
import re;
import from typing { Any }
import from jac_scale.abstractions.models.sandbox_config { SandboxConfig }
import from jac_scale.abstractions.models.sandbox_result { SandboxResult }
import from jac_scale.abstractions.models.sandbox_status { SandboxStatus, SandboxInfo }
import from jac_scale.abstractions.logger { Logger }

# Regex to reject shell metacharacters and path traversal
glob _UNSAFE_PATH_RE = re.compile(r"(\.\.[\\/]|[;|&`$'\"\\\n\r])");

"""Validate a relative path for sandbox file operations.

Rejects absolute paths, path traversal (..), and shell metacharacters.
Returns the sanitized path or raises ValueError.
"""
def validate_sandbox_path(path: str) -> str {
    if not path or not path.strip() {
        raise ValueError("Path cannot be empty");
    }
    path = path.strip();
    if os.path.isabs(path) {
        raise ValueError("Absolute paths are not allowed");
    }
    normalized = os.path.normpath(path);
    if normalized.startswith("..") or "/../" in normalized or normalized == ".." {
        raise ValueError("Path traversal is not allowed");
    }
    if _UNSAFE_PATH_RE.search(path) {
        raise ValueError("Path contains unsafe characters");
    }
    return normalized;
}

"""Base class for all sandbox environment implementations."""
class SandboxEnvironment {
    has config: SandboxConfig,
        logger: (Logger | None) = None;

    """Create a new sandbox for a user's project.

    Args:
        user_id: Unique identifier for the user
        project_id: Unique identifier for the project
        code_path: Path to directory containing the project code

    Returns:
        SandboxResult with sandbox_id, url, and status
    """
    def create(
        self: SandboxEnvironment, user_id: str, project_id: str, code_path: str
    ) -> SandboxResult;

    """Stop a running sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
    """
    def stop(self: SandboxEnvironment, sandbox_id: str) -> None;

    """Get the current status of a sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox

    Returns:
        SandboxStatus with state, url, and uptime
    """
    def status(self: SandboxEnvironment, sandbox_id: str) -> SandboxStatus;

    """Stop and fully clean up a sandbox (remove all resources).

    Args:
        sandbox_id: Unique identifier for the sandbox
    """
    def destroy(self: SandboxEnvironment, sandbox_id: str) -> None;

    """List all sandboxes for a user.

    Args:
        user_id: Unique identifier for the user

    Returns:
        List of SandboxInfo summaries
    """
    def list_sandboxes(self: SandboxEnvironment, user_id: str) -> list[SandboxInfo];

    """Clean up sandboxes that have exceeded their TTL.

    Returns:
        Number of sandboxes cleaned up
    """
    def cleanup_expired(self: SandboxEnvironment) -> int;

    """Read logs from a sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        offset: Byte offset to start reading from

    Returns:
        Dict with 'success', 'content', and 'offset' keys
    """
    def logs(self: SandboxEnvironment, sandbox_id: str, offset: int = 0) -> dict;

    """Write a file into the sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        path: Relative path within the sandbox
        content: File content to write

    Returns:
        Dict with 'success' and optional 'error' keys
    """
    def write_file(
        self: SandboxEnvironment, sandbox_id: str, path: str, content: str
    ) -> dict;

    """Read a file from the sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        path: Relative path within the sandbox

    Returns:
        Dict with 'success', 'content', and optional 'error' keys
    """
    def read_file(self: SandboxEnvironment, sandbox_id: str, path: str) -> dict;

    """Delete a file from the sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        path: Relative path within the sandbox

    Returns:
        Dict with 'success' and optional 'error' keys
    """
    def delete_file(self: SandboxEnvironment, sandbox_id: str, path: str) -> dict;

    """List files in the sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        path: Relative directory path to list

    Returns:
        Dict with 'success', 'files' list, and optional 'error' keys
    """
    def list_files(self: SandboxEnvironment, sandbox_id: str, path: str = ".") -> dict;

    """Execute a command inside the sandbox.

    Args:
        sandbox_id: Unique identifier for the sandbox
        command: Shell command to execute
        timeout: Maximum execution time in seconds

    Returns:
        Dict with 'success', 'exit_code', 'stdout', 'stderr' keys
    """
    def exec_command(
        self: SandboxEnvironment, sandbox_id: str, command: str, timeout: int = 30
    ) -> dict;
}
