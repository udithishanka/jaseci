"""Implementation of MicroserviceGateway methods."""

import shutil;

"""Build the target URL by stripping prefix and forwarding the rest."""
impl MicroserviceGateway.resolve_target_url
(service_entry: ServiceEntry, path: str, query: str) -> str {
    remaining: str = path[len(service_entry.prefix):];
    if not remaining {
        remaining = "/";
    }
    target: str = f"{service_entry.url}{remaining}";
    if query {
        target = f"{target}?{query}";
    }
    return target;
}

"""Serve a static file from the client dist directory. Returns None if not found."""
impl MicroserviceGateway.serve_static
(file_path: str) -> Response | None {
    dist = Path(self.client_dist_dir);
    target = dist / file_path;

    # Prevent path traversal
    try {
        resolved = target.resolve();
        dist_resolved = dist.resolve();
        if not str(resolved).startswith(str(dist_resolved)) {
            return None;
        }
    } except OSError {
        return None;
    }

    if not target.is_file() {
        return None;
    }

    (content_type, _) = mimetypes.guess_type(str(target));
    if content_type is None {
        content_type = "application/octet-stream";
    }

    if content_type.startswith("text/") or content_type in ("application/javascript", "application/json") {
        return Response(content=target.read_text(encoding="utf-8"), media_type=content_type);
    }
    return Response(content=target.read_bytes(), media_type=content_type);
}

"""Serve index.html for SPA fallback. Returns None if no index.html exists."""
impl MicroserviceGateway.serve_spa_fallback
-> Response | None {
    index = Path(self.client_dist_dir) / "index.html";
    if index.is_file() {
        return HTMLResponse(content=index.read_text(encoding="utf-8"));
    }
    return None;
}

"""Bootstrap admin UI — copy pre-built bundle to admin_dist_dir if needed."""
impl MicroserviceGateway.bootstrap_admin
-> None {
    admin_dist = Path(self.admin_dist_dir);
    index_file = admin_dist / "index.html";

    # Already deployed
    if index_file.exists() {
        return;
    }

    # Find pre-built bundle from the installed package
    try {
        import from jac_scale.admin { admin_portal }
        admin_pkg_dir = Path(admin_portal.__file__).parent;
        bundled_dist = admin_pkg_dir / "_dist";

        if bundled_dist.exists() and (bundled_dist / "index.html").exists() {
            logger.info("Deploying pre-built admin UI to gateway");
            admin_dist.mkdir(parents=True, exist_ok=True);
            for item in bundled_dist.iterdir() {
                dest = admin_dist / item.name;
                if item.is_dir() {
                    if dest.exists() {
                        shutil.rmtree(dest);
                    }
                    shutil.copytree(item, dest);
                } else {
                    shutil.copy2(item, dest);
                }
            }
        } else {
            logger.debug("No pre-built admin UI found in package");
        }
    } except (ImportError, ModuleNotFoundError) {
        logger.debug("Admin module not available, skipping admin UI bootstrap");
    }
}

"""Serve an admin asset by path. Returns None if not found."""
impl MicroserviceGateway.serve_admin_asset
(asset_path: str) -> Response | None {
    admin_dist = Path(self.admin_dist_dir);

    # Determine target file
    if not asset_path or asset_path == "/" {
        target = admin_dist / "index.html";
    } else {
        target = admin_dist / asset_path;
    }

    # Path traversal protection
    try {
        resolved = target.resolve();
        dist_resolved = admin_dist.resolve();
        if not str(resolved).startswith(str(dist_resolved)) {
            return None;
        }
    } except OSError {
        return None;
    }

    if not target.is_file() {
        # SPA fallback for admin — serve index.html for non-file paths
        index = admin_dist / "index.html";
        if index.is_file() {
            return HTMLResponse(content=index.read_text(encoding="utf-8"));
        }
        return None;
    }

    (content_type, _) = mimetypes.guess_type(str(target));
    if content_type is None {
        content_type = "application/octet-stream";
    }

    if content_type.startswith("text/") or content_type in ("application/javascript", "application/json") {
        return Response(content=target.read_text(encoding="utf-8"), media_type=content_type);
    }
    return Response(content=target.read_bytes(), media_type=content_type);
}

"""Create the FastAPI app and register routes."""
impl MicroserviceGateway.setup -> FastAPI {
    self.app = FastAPI(title="Jac Microservice Gateway");
    gw_ref = self;

    # Bootstrap admin UI on setup
    self.bootstrap_admin();

    @self.app.middleware("http")
    async def proxy_middleware(request: Request, call_next: object) -> Response {
        path: str = request.url.path;

        # Health endpoint
        if path == "/health" {
            return JSONResponse(
                status_code=200,
                content={
                    "status": "healthy",
                    "services": gw_ref.registry.health_summary()
                }
            );
        }

        # Admin UI — /admin and /admin/*
        if path == "/admin" {
            import from fastapi.responses { RedirectResponse }
            return RedirectResponse(url="/admin/", status_code=302);
        }
        if path.startswith("/admin/") {
            admin_path: str = path[7:];  # strip "/admin/"
            admin_resp = gw_ref.serve_admin_asset(admin_path);
            if admin_resp {
                return admin_resp;
            }
        }

        # 1. Try API proxy (if path matches a service prefix)
        svc = gw_ref.registry.match_route(path);

        if svc {
            if svc.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
                return JSONResponse(
                    status_code=503,
                    content={"error": f"Service '{svc.name}' is {svc.status.value}"}
                );
            }

            target_url = gw_ref.resolve_target_url(svc, path, str(request.url.query));
            logger.info(f"Proxy: {request.method} {path} -> {target_url}");

            fwd_headers: dict[str, str] = {};
            for (key, value) in request.headers.items() {
                if key.lower() not in HOP_BY_HOP_HEADERS {
                    fwd_headers[key] = value;
                }
            }
            client_addr: str = getattr(getattr(request, "client", None), "host", "unknown");
            fwd_headers["X-Forwarded-For"] = client_addr;

            body: bytes = await request.body();

            result = await raw_forward(request.method, target_url, fwd_headers, body);
            if result is None {
                return JSONResponse(
                    status_code=502,
                    content={"error": f"Failed to reach service '{svc.name}'"}
                );
            }

            (status_code, resp_headers, resp_body) = result;
            return Response(
                status_code=status_code,
                headers=resp_headers,
                content=resp_body
            );
        }

        # 2. Try static file (GET only)
        if request.method == "GET" {
            file_path: str = path.lstrip("/");
            if file_path {
                static_resp = gw_ref.serve_static(file_path);
                if static_resp {
                    return static_resp;
                }
            }

            # 3. SPA fallback — serve index.html for HTML navigation requests
            accept: str = request.headers.get("accept", "");
            if "text/html" in accept {
                fallback = gw_ref.serve_spa_fallback();
                if fallback {
                    return fallback;
                }
            }
        }

        return JSONResponse(status_code=404, content={"error": "Not found", "path": path});
    }

    return self.app;
}

"""Start the gateway server (blocking)."""
impl MicroserviceGateway.start -> None {
    if self.app is None {
        self.setup();
    }
    logger.info(f"Gateway starting on {self.host}:{self.port}");
    uvicorn.run(
        getattr(self, "app"),
        host=self.host,
        port=self.port
    );
}
