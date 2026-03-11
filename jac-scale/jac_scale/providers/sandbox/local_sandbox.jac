"""Local subprocess sandbox provider — backward-compatible fallback.

Wraps the original preview_manager subprocess logic as a SandboxEnvironment
provider. Used when JAC_SANDBOX_TYPE is unset or "local".
"""
import os;
import shutil;
import subprocess;
import signal;
import time;
import base64;
import from threading { Lock, Thread }
import from pathlib { Path }
import from typing { Any }
import from jac_scale.abstractions.sandbox_environment { SandboxEnvironment }
import from jac_scale.abstractions.models.sandbox_config { SandboxConfig }
import from jac_scale.abstractions.models.sandbox_result { SandboxResult }
import from jac_scale.abstractions.models.sandbox_status {
    SandboxState,
    SandboxStatus,
    SandboxInfo
}
import from jac_scale.abstractions.logger { Logger }

glob _IMAGE_MIME_TYPES: dict = {
         ".png": "image/png",
         ".jpg": "image/jpeg",
         ".jpeg": "image/jpeg",
         ".gif": "image/gif",
         ".webp": "image/webp",
         ".ico": "image/x-icon",
         ".bmp": "image/bmp",
         ".tiff": "image/tiff",
         ".tif": "image/tiff",
         ".svg": "image/svg+xml"
     },
     PROTECTED_FILES: list = ["jac.toml"],
     _WRITE_ALLOWED_PROTECTED: list = ["jac.toml"];

"""Local subprocess sandbox — runs jac start as a child process on the host."""
class LocalSandbox(SandboxEnvironment) {
    has _registry: dict = {},
        _port_pool: list = [],
        _lock: Any = None,
        _base_port: int = 5180,
        _port_count: int = 10;

    def init(
        self: LocalSandbox, config: SandboxConfig, logger: (Logger | None) = None
    ) -> None {
        self.config = config;
        self.logger = logger;
        self._registry = {};
        self._base_port = 5180;
        self._port_count = 10;
        self._port_pool = list(
            range(self._base_port, self._base_port + self._port_count * 2, 2)
        );
        self._lock = Lock();
    }

    def _sandbox_key(self: LocalSandbox, user_id: str, project_id: str) -> str {
        safe_user = user_id or "session";
        safe_project = project_id or "__default__";
        return f"{safe_user}::{safe_project}";
    }

    def _sandbox_id(self: LocalSandbox, user_id: str, project_id: str) -> str {
        return f"local-{user_id}-{project_id}" if project_id else f"local-{user_id}";
    }

    def _find_jac_binary(self: LocalSandbox) -> str {
        candidates = [str(Path.home() / ".jacvenv" / "bin" / "jac")];
        venv = os.environ.get("VIRTUAL_ENV", "");
        if venv {
            candidates.append(os.path.join(venv, "bin", "jac"));
        }
        for p in candidates {
            if os.path.exists(p) {
                return p;
            }
        }
        result = shutil.which("jac");
        if result {
            return result;
        }
        raise FileNotFoundError("Could not find 'jac' binary.");
    }

    def _find_activate_script(self: LocalSandbox) -> str {
        jacvenv_activate = str(Path.home() / ".jacvenv" / "bin" / "activate");
        if os.path.exists(jacvenv_activate) {
            return jacvenv_activate;
        }
        venv = os.environ.get("VIRTUAL_ENV", "");
        if venv {
            activate = os.path.join(venv, "bin", "activate");
            if os.path.exists(activate) {
                return activate;
            }
        }
        jac_bin = self._find_jac_binary();
        activate = os.path.join(os.path.dirname(jac_bin), "activate");
        if os.path.exists(activate) {
            return activate;
        }
        return "";
    }

    def _resolve_path(self: LocalSandbox, preview_dir: str, path: str) -> str {
        candidate = path or ".";
        real_preview = os.path.realpath(preview_dir);
        full = os.path.realpath(
            candidate
                if os.path.isabs(candidate)
                else os.path.join(real_preview, candidate)
        );
        if os.path.commonpath([real_preview, full]) != real_preview {
            raise ValueError("Path is outside sandbox directory");
        }
        return full;
    }

    def _kill_port_listeners(self: LocalSandbox, port: int) -> None {
        try {
            result = subprocess.run(
                f"lsof -i :{port} -t",
                shell=True,
                capture_output=True,
                text=True,
                timeout=5
            );
            pids = result.stdout.strip();
            if pids {
                for pid_str in pids.split("\n") {
                    pid_str = pid_str.strip();
                    if pid_str {
                        try {
                            os.kill(int(pid_str), signal.SIGKILL);
                        } except (ProcessLookupError, ValueError) {
                            ;
                        }
                    }
                }
            }
        } except Exception {
            ;
        }
    }

    def _stop_process(self: LocalSandbox, rec: dict) -> None {
        log_file = rec.get("log_file");
        if log_file {
            try {
                log_file.close();
            } except Exception {
                ;
            }
            rec["log_file"] = None;
        }
        process = rec.get("process");
        if process is not None {
            try {
                os.killpg(os.getpgid(process.pid), signal.SIGTERM);
                process.wait(timeout=5);
            } except (ProcessLookupError, subprocess.TimeoutExpired) {
                try {
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL);
                } except ProcessLookupError {
                    ;
                }
            } finally {
                rec["process"] = None;
            }
        }
        port = rec.get("port", 0);
        if port {
            for check_port in [port, port + 1] {
                self._kill_port_listeners(check_port);
            }
        }
    }

    def _poll_readiness(
        self: LocalSandbox, key: str, port: int, process: Any, log_path: str
    ) -> None {
        import requests;
        vite_url = f"http://localhost:{port}";
        start_time = time.time();
        ready = False;
        while time.time() - start_time < 120 {
            if process.poll() is not None {
                break;
            }
            try {
                if os.path.exists(log_path) {
                    with open(log_path, "r", encoding="utf-8") as lf {
                        log_content = lf.read();
                    }
                    server_ready = "Server ready" in log_content;
                    vite_ready = "VITE v" in log_content and "ready in" in log_content;
                    watching = "Watching for changes" in log_content;
                    if server_ready and (vite_ready or watching) {
                        try {
                            resp = requests.get(vite_url, timeout=3);
                            if 200 <= resp.status_code < 400 {
                                ready = True;
                                break;
                            }
                        } except Exception {
                            ;
                        }
                        if vite_ready {
                            ready = True;
                            break;
                        }
                    }
                    if server_ready {
                        if "Client bundle ready" in log_content
                        or "Client bundle built" in log_content {
                            ready = True;
                            break;
                        }
                    }
                }
            } except Exception {
                ;
            }
            time.sleep(3);
        }
        self._lock.acquire();
        try {
            rec = self._registry.get(key);
            if not rec {
                return;
            }
            if ready {
                rec["status"] = SandboxState.RUNNING;
                rec["needs_install"] = False;
            } else {
                self._stop_process(rec);
                if port not in self._port_pool {
                    self._port_pool.append(port);
                }
                rec["status"] = SandboxState.ERROR;
                rec["port"] = 0;
                rec["process"] = None;
            }
        } finally {
            self._lock.release();
        }
    }

    def create(
        self: LocalSandbox, user_id: str, project_id: str, code_path: str
    ) -> SandboxResult {
        self._lock.acquire();
        try {
            key = self._sandbox_key(user_id, project_id);
            sid = self._sandbox_id(user_id, project_id);

            # Setup preview directory
            preview_suffix = f"-{project_id}" if project_id else "";
            preview_dir = f"/tmp/jac-preview-{user_id}{preview_suffix}";

            if key in self._registry {
                rec = self._registry[key];
                # Stop existing process, reuse port
                previous_port = rec.get("port", 0);
                if rec.get("process") is not None {
                    self._stop_process(rec);
                }
            } else {
                previous_port = 0;
                # Copy code to preview dir (skip if code_path IS the preview dir)
                real_code = os.path.realpath(code_path) if code_path else "";
                real_preview = os.path.realpath(preview_dir);
                if real_code and real_code != real_preview {
                    if os.path.exists(preview_dir) {
                        shutil.rmtree(preview_dir);
                    }
                    if os.path.isdir(code_path) {
                        shutil.copytree(code_path, preview_dir, symlinks=True);
                    } else {
                        os.makedirs(preview_dir, exist_ok=True);
                    }
                } elif not os.path.exists(preview_dir) {
                    os.makedirs(preview_dir, exist_ok=True);
                }
            }

            # Allocate port
            if previous_port
            and previous_port in range(
                self._base_port, self._base_port + self._port_count * 2, 2
            ) {
                port = previous_port;
                if port in self._port_pool {
                    self._port_pool.remove(port);
                }
            } else {
                if not self._port_pool {
                    return SandboxResult(success=False, message="No available ports");
                }
                port = self._port_pool.pop(0);
            }

            main_jac = os.path.join(preview_dir, "main.jac");
            if not os.path.isfile(main_jac) {
                self._port_pool.append(port);
                return SandboxResult(
                    success=False, message="main.jac not found in preview directory"
                );
            }

            # Kill orphan processes
            api_port = port + 1;
            for check_port in [port, api_port] {
                self._kill_port_listeners(check_port);
            }
            time.sleep(0.5);

            # Build shell command
            activate_script = self._find_activate_script();
            jac_bin = self._find_jac_binary();

            # Env sourcing
            src_dir = code_path or "";
            global_env = os.path.join(str(Path.home()), ".jac-ide", "global.env");
            project_env_file = os.path.join(src_dir, ".env") if src_dir else "";
            env_sources = "";
            if os.path.isfile(global_env) {
                env_sources += f"source \"{global_env}\"; ";
            }
            if project_env_file and os.path.isfile(project_env_file) {
                env_sources += f"source \"{project_env_file}\"; ";
            }
            env_prefix = "";
            if env_sources {
                env_prefix = f"set -a; {env_sources}set +a; ";
            }

            needs_install = not (key in self._registry)
            or self._registry.get(key, {}).get("needs_install", True);

            if activate_script {
                if needs_install {
                    shell_cmd = f"{env_prefix}source {activate_script} && jac install && jac start main.jac -p {port} --dev";
                } else {
                    shell_cmd = f"{env_prefix}source {activate_script} && jac start main.jac -p {port} --dev";
                }
            } else {
                if needs_install {
                    shell_cmd = f"{env_prefix}{jac_bin} install && {jac_bin} start main.jac -p {port} --dev";
                } else {
                    shell_cmd = f"{env_prefix}{jac_bin} start main.jac -p {port} --dev";
                }
            }

            log_path = os.path.join(preview_dir, ".jac-preview.log");
            log_file = open(log_path, "w", encoding="utf-8");

            process = subprocess.Popen(
                shell_cmd,
                shell=True,
                executable="/bin/bash",
                cwd=preview_dir,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                preexec_fn=os.setsid
            );

            self._registry[key] = {
                "sandbox_id": sid,
                "port": port,
                "api_port": api_port,
                "process": process,
                "dir": preview_dir,
                "status": SandboxState.STARTING,
                "user_id": user_id,
                "project_id": project_id,
                "source_dir": code_path,
                "needs_install": needs_install,
                "log_file": log_file,
                "log_path": log_path,
                "created_at": time.time()
            };

            # Launch readiness checker
            checker = Thread(
                target=self._poll_readiness,
                args=(key, port, process, log_path),
                daemon=True
            );
            checker.start();

            url = f"http://localhost:{port}";
            return SandboxResult(
                success=True,
                sandbox_id=sid,
                url=url,
                port=port,
                api_port=api_port,
                message="starting"
            );
        } except Exception as e {
            return SandboxResult(success=False, message=str(e));
        } finally {
            self._lock.release();
        }
    }

    def stop(self: LocalSandbox, sandbox_id: str) -> None {
        self._lock.acquire();
        try {
            for (key, rec) in self._registry.items() {
                if rec.get("sandbox_id") == sandbox_id {
                    self._stop_process(rec);
                    port = rec.get("port", 0);
                    if port
                    and port in range(
                        self._base_port, self._base_port + self._port_count * 2, 2
                    ) {
                        if port not in self._port_pool {
                            self._port_pool.append(port);
                        }
                    }
                    rec["port"] = 0;
                    rec["api_port"] = 0;
                    rec["status"] = SandboxState.STOPPED;
                    return;
                }
            }
        } finally {
            self._lock.release();
        }
    }

    def status(self: LocalSandbox, sandbox_id: str) -> SandboxStatus {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                process = rec.get("process");
                state = rec.get("status", SandboxState.STOPPED);
                alive = process is not None and process.poll() is None;
                if not alive
                and state in [SandboxState.RUNNING, SandboxState.STARTING] {
                    state = SandboxState.STOPPED;
                }
                uptime = time.time() - rec.get(
                    "created_at", time.time()
                )
                    if alive
                    else 0.0;
                url = f"http://localhost:{rec.get('port', 0)}" if alive else "";
                return SandboxStatus(
                    state=state,
                    sandbox_id=sandbox_id,
                    uptime_seconds=uptime,
                    url=url,
                    port=rec.get("port", 0)
                );
            }
        }
        return SandboxStatus(state=SandboxState.STOPPED, sandbox_id=sandbox_id);
    }

    def destroy(self: LocalSandbox, sandbox_id: str) -> None {
        self.stop(sandbox_id);
        self._lock.acquire();
        try {
            to_remove = "";
            for (key, rec) in self._registry.items() {
                if rec.get("sandbox_id") == sandbox_id {
                    to_remove = key;
                    preview_dir = rec.get("dir", "");
                    if preview_dir and os.path.exists(preview_dir) {
                        shutil.rmtree(preview_dir, ignore_errors=True);
                    }
                    break;
                }
            }
            if to_remove {
                self._registry.pop(to_remove, None);
            }
        } finally {
            self._lock.release();
        }
    }

    def list_sandboxes(self: LocalSandbox, user_id: str) -> list[SandboxInfo] {
        results: list[SandboxInfo] = [];
        for (key, rec) in self._registry.items() {
            if rec.get("user_id") == user_id {
                results.append(
                    SandboxInfo(
                        sandbox_id=rec.get("sandbox_id", ""),
                        user_id=rec.get("user_id", ""),
                        project_id=rec.get("project_id", ""),
                        state=rec.get("status", SandboxState.STOPPED),
                        url=f"http://localhost:{rec.get('port', 0)}",
                        created_at=rec.get("created_at", 0.0)
                    )
                );
            }
        }
        return results;
    }

    def cleanup_expired(self: LocalSandbox) -> int {
        now = time.time();
        expired: list[str] = [];
        for (key, rec) in self._registry.items() {
            created = rec.get("created_at", now);
            if now - created > self.config.ttl_seconds {
                expired.append(rec.get("sandbox_id", ""));
            }
        }
        for sid in expired {
            self.destroy(sid);
        }
        return len(expired);
    }

    def logs(self: LocalSandbox, sandbox_id: str, offset: int = 0) -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                log_path = rec.get(
                    "log_path", os.path.join(rec.get("dir", ""), ".jac-preview.log")
                );
                if not os.path.exists(log_path) {
                    return {"success": True, "content": "", "offset": 0};
                }
                try {
                    with open(log_path, "r", encoding="utf-8") as f {
                        f.seek(offset);
                        content = f.read();
                    }
                    new_offset = offset + len(content.encode("utf-8"));
                    return {"success": True, "content": content, "offset": new_offset};
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    def write_file(
        self: LocalSandbox, sandbox_id: str, path: str, content: str
    ) -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                basename = os.path.basename(path);
                if basename in PROTECTED_FILES
                and basename not in _WRITE_ALLOWED_PROTECTED {
                    return {
                        "success": True,
                        "skipped": True,
                        "reason": f"Protected file: {basename}"
                    };
                }
                try {
                    full_path = self._resolve_path(rec["dir"], path);
                    parent = os.path.dirname(full_path);
                    if parent and not os.path.exists(parent) {
                        os.makedirs(parent, exist_ok=True);
                    }
                    with open(full_path, "w", encoding="utf-8") as f {
                        f.write(content);
                    }
                    return {"success": True, "path": path};
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    def read_file(self: LocalSandbox, sandbox_id: str, path: str) -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                try {
                    full_path = self._resolve_path(rec["dir"], path);
                    if not os.path.isfile(full_path) {
                        return {"success": False, "error": "File not found"};
                    }
                    ext = os.path.splitext(path)[1].lower();
                    if ext in _IMAGE_MIME_TYPES {
                        with open(full_path, "rb") as f {
                            raw = f.read();
                        }
                        b64 = base64.b64encode(raw).decode("utf-8");
                        return {
                            "success": True,
                            "path": path,
                            "content": b64,
                            "is_binary": True,
                            "mime_type": _IMAGE_MIME_TYPES[ext]
                        };
                    }
                    with open(full_path, "r", encoding="utf-8") as f {
                        file_content = f.read();
                    }
                    return {"success": True, "path": path, "content": file_content};
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    def delete_file(self: LocalSandbox, sandbox_id: str, path: str) -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                basename = os.path.basename(path);
                if basename in PROTECTED_FILES {
                    return {
                        "success": False,
                        "error": f"Cannot delete protected file: {basename}"
                    };
                }
                try {
                    full_path = self._resolve_path(rec["dir"], path);
                    if os.path.isfile(full_path) {
                        os.remove(full_path);
                    } elif os.path.isdir(full_path) {
                        shutil.rmtree(full_path);
                    } else {
                        return {"success": False, "error": "Path not found"};
                    }
                    return {"success": True, "path": path};
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    def list_files(self: LocalSandbox, sandbox_id: str, path: str = ".") -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                try {
                    preview_dir = rec["dir"];
                    base = self._resolve_path(preview_dir, path);
                    real_preview = os.path.realpath(preview_dir);
                    skip_dirs = [".jac", "node_modules", "__pycache__", "dist", ".git"];
                    file_list: list[str] = [];
                    for walk_rec in os.walk(base) {
                        dirpath = walk_rec[0];
                        dirnames = walk_rec[1];
                        filenames = walk_rec[2];
                        kept = [
                            d
                            for d in dirnames
                            if d not in skip_dirs
                        ];
                        dirnames.clear();
                        for d in kept {
                            dirnames.append(d);
                        }
                        for fname in filenames {
                            full = os.path.join(dirpath, fname);
                            rel = os.path.relpath(full, real_preview);
                            file_list.append(rel);
                        }
                    }
                    file_list.sort();
                    return {"success": True, "files": file_list};
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    def exec_command(
        self: LocalSandbox, sandbox_id: str, command: str, timeout: int = 30
    ) -> dict {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                try {
                    result = subprocess.run(
                        command,
                        shell=True,
                        cwd=rec["dir"],
                        capture_output=True,
                        text=True,
                        timeout=timeout
                    );
                    return {
                        "success": True,
                        "exit_code": result.returncode,
                        "stdout": result.stdout,
                        "stderr": result.stderr
                    };
                } except Exception as e {
                    return {"success": False, "error": str(e)};
                }
            }
        }
        return {"success": False, "error": "Sandbox not found"};
    }

    # ---- Convenience methods for preview_manager compatibility ----
    """Get the sandbox record by user_id and project_id (for preview_manager compat)."""
    def get_by_user_project(
        self: LocalSandbox, user_id: str, project_id: str
    ) -> (dict | None) {
        key = self._sandbox_key(user_id, project_id);
        return self._registry.get(key);
    }

    """Get sandbox_id for a user/project pair."""
    def get_sandbox_id(
        self: LocalSandbox, user_id: str, project_id: str
    ) -> (str | None) {
        key = self._sandbox_key(user_id, project_id);
        rec = self._registry.get(key);
        if rec {
            return rec.get("sandbox_id");
        }
        return None;
    }

    """Get the preview directory path for a sandbox."""
    def get_sandbox_dir(self: LocalSandbox, sandbox_id: str) -> (str | None) {
        for (key, rec) in self._registry.items() {
            if rec.get("sandbox_id") == sandbox_id {
                return rec.get("dir");
            }
        }
        return None;
    }
}
