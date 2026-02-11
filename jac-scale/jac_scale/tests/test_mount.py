"""Tests for ASGI sub-application mounting via [plugins.scale.mount]."""

import contextlib
import gc
import glob
import socket
import subprocess
import sys
import time
from pathlib import Path

import requests


def get_free_port() -> int:
    """Get a free port by binding to port 0 and releasing it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        return s.getsockname()[1]


class TestMountSubApp:
    """Test that sub-applications are mounted from jac.toml config."""

    fixtures_dir: Path
    port: int
    base_url: str
    server_process: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        """Start jac server with mount_app fixture."""
        cls.fixtures_dir = Path(__file__).parent / "fixtures" / "mount_app"
        assert cls.fixtures_dir.exists(), f"Fixture dir missing: {cls.fixtures_dir}"

        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"

        cls._cleanup(cls.fixtures_dir)
        cls._start_server()

    @classmethod
    def teardown_class(cls) -> None:
        """Stop server and clean up."""
        if cls.server_process:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                cls.server_process.wait()

        time.sleep(0.5)
        gc.collect()
        cls._cleanup(cls.fixtures_dir)

    @classmethod
    def _start_server(cls) -> None:
        """Start the jac-scale server as a subprocess."""
        jac_executable = Path(sys.executable).parent / "jac"

        cls.server_process = subprocess.Popen(
            [str(jac_executable), "start", "main.jac", "--port", str(cls.port)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(cls.fixtures_dir),
        )

        # Wait for server readiness
        for _ in range(50):
            if cls.server_process.poll() is not None:
                stdout, stderr = cls.server_process.communicate()
                raise RuntimeError(f"Server died.\nSTDOUT: {stdout}\nSTDERR: {stderr}")
            try:
                resp = requests.get(f"{cls.base_url}/docs", timeout=2)
                if resp.status_code in (200, 404):
                    return
            except (requests.ConnectionError, requests.Timeout):
                time.sleep(2)

        cls.server_process.terminate()
        stdout, stderr = cls.server_process.communicate(timeout=5)
        raise RuntimeError(
            f"Server not ready after 50 attempts.\nSTDOUT: {stdout}\nSTDERR: {stderr}"
        )

    @staticmethod
    def _cleanup(fixtures_dir: Path) -> None:
        """Remove database and build artifacts."""
        import shutil

        for pattern in ["*.db", "*.db-wal", "*.db-shm"]:
            for f in glob.glob(str(fixtures_dir / pattern)):
                with contextlib.suppress(Exception):
                    Path(f).unlink()
        jac_dir = fixtures_dir / ".jac"
        if jac_dir.exists():
            with contextlib.suppress(Exception):
                shutil.rmtree(jac_dir)

    # -- Tests --

    def test_mounted_root(self) -> None:
        """Mounted sub-app root should respond at /sub/."""
        resp = requests.get(f"{self.base_url}/sub/", timeout=5)
        assert resp.status_code == 200
        assert resp.json() == {"source": "mounted"}

    def test_mounted_health(self) -> None:
        """Mounted sub-app health endpoint should respond at /sub/health."""
        resp = requests.get(f"{self.base_url}/sub/health", timeout=5)
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}

    def test_main_app_docs_still_accessible(self) -> None:
        """Main app endpoints should still work alongside mounted sub-app."""
        resp = requests.get(f"{self.base_url}/docs", timeout=5)
        assert resp.status_code == 200
