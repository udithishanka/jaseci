"""Shared helpers for jac-scale microservice mode.

Both the `ensure_sv_service` hookimpl (plugin.jac) and the
ServiceProcessManager (process_manager.impl.jac) need the same port-picking
and jac-binary-resolution logic. Keeping them here avoids duplication.
"""

import socket;
import shutil;
import sys;
import from pathlib { Path }
import from typing { Any }

"""Pick a free TCP port near `base + hash(name) % 1000` on 127.0.0.1.

Matches core's strategy so sv_client._registry URLs and deployer URLs
resolve consistently when the same module is re-spawned. Raises
RuntimeError if no free port is found within `retries` attempts.
"""
def pick_free_port(name: str, base: int = 18000, retries: int = 100) -> int {
    start: int = base + (hash(name) % 1000);
    port: int = start;
    for _ in range(retries) {
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1);
        try {
            s.bind(('127.0.0.1', port));
            s.close();
            return port;
        } except OSError {
            s.close();
            port = port + 1;
        }
    }
    raise RuntimeError(f"Could not find free port near {start}");
}

"""Resolve the `jac` binary path.

Tries PATH first, then falls back to the directory of the currently-running
Python interpreter (handles activated virtualenvs where jac lives next to
python but isn't on PATH yet). Returns the string "jac" as a last resort.
"""
def resolve_jac_binary -> str {
    found: str = shutil.which("jac") or "";
    if found {
        return found;
    }
    candidate = Path(sys.executable).parent / "jac";
    if candidate.exists() {
        return str(candidate);
    }
    return "jac";
}

"""Poll `base_url/healthz` until the service responds <500 or the deadline hits.

`proc_alive` is called once per iteration; if it returns False, raises
RuntimeError immediately (service died before becoming healthy). Returns
True if healthy within the timeout, False otherwise.
"""
def wait_for_health(
    base_url: str,
    proc_alive: Any,
    timeout: float = 15.0,
    poll_interval: float = 0.1
) -> bool {
    import time;
    import urllib.request;

    deadline: float = time.time() + timeout;
    while time.time() < deadline {
        if not proc_alive() {
            raise RuntimeError(f"service at {base_url} exited before becoming healthy");
        }
        try {
            with urllib.request.urlopen(f"{base_url}/healthz", timeout=1) as resp {
                if resp.status < 500 {
                    return True;
                }
            }
        } except Exception {
            time.sleep(poll_interval);
        }
    }
    return False;
}
