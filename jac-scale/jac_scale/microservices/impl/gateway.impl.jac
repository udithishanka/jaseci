"""Implementation of MicroserviceGateway methods."""

import shutil;

"""Build the target URL by stripping prefix and forwarding the rest.

Resolution order:
  1. JacRuntime.get_sv_registry()[module] - public hookspec (plugins can
     override; KubernetesDeployer will return K8s DNS names here)
  2. service_entry.url - URL from our process manager
  3. Fallback: error (no known URL)
"""
impl MicroserviceGateway.resolve_target_url
(service_entry: ServiceEntry, path: str, query: str) -> str {
    import jaclang;

    # Use the public hookspec; plugins can swap the URL source without
    # the gateway knowing (jaclang core returns sv_client._registry by
    # default; jac-scale's KubernetesDeployer will return DNS URLs).
    registry: dict[str, str] = jaclang.JacRuntime.get_sv_registry();
    base_url: str = registry.get(service_entry.name, service_entry.url);

    remaining: str = path[len(service_entry.prefix):];
    if not remaining {
        remaining = "/";
    }
    target: str = f"{base_url}{remaining}";
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

"""Bootstrap admin UI - copy pre-built bundle to admin_dist_dir if needed.

Skips when the destination index.html is at least as new as the source,
so normal restarts don't re-copy. Refreshes on package upgrade (source
newer) or cold start (destination missing).
"""
impl MicroserviceGateway.bootstrap_admin
-> None {
    admin_dist = Path(self.admin_dist_dir);
    dest_index = admin_dist / "index.html";

    try {
        import from jac_scale.admin { admin_portal }
        admin_pkg_dir = Path(admin_portal.__file__).parent;
        bundled_dist = admin_pkg_dir / "_dist";
        src_index = bundled_dist / "index.html";

        if not (bundled_dist.exists() and src_index.exists()) {
            logger.debug("No pre-built admin UI found in package");
            return;
        }

        if dest_index.exists() and dest_index.stat().st_mtime >= src_index.stat().st_mtime {
            return;
        }

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
    } except (ImportError, ModuleNotFoundError) {
        logger.debug("Admin module not available, skipping admin UI bootstrap");
    }
}

"""Serve an admin asset by path. Returns None if not found."""
impl MicroserviceGateway.serve_admin_asset
(asset_path: str) -> Response | None {
    admin_dist = Path(self.admin_dist_dir);

    if not asset_path or asset_path == "/" {
        target = admin_dist / "index.html";
    } else {
        target = admin_dist / asset_path;
    }

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

"""Paths whose handling is "try every healthy service until non-404"."""
glob _BUILTIN_PREFIXES: tuple = (
    "/user/", "/cl/", "/walker/", "/function/",
    "/sso/", "/api-key/", "/webhook/", "/ws/",
    "/jobs/", "/graph/"
),
     _BUILTIN_EXACT: set[str] = {
         "/user", "/healthz", "/graph", "/metrics",
         "/docs", "/openapi.json", "/redoc"
     };

"""Copy incoming request headers, dropping hop-by-hop headers."""
impl MicroserviceGateway.build_forward_headers
(request: Request) -> dict[str, str] {
    fwd: dict[str, str] = {};
    for (key, value) in request.headers.items() {
        if key.lower() not in HOP_BY_HOP_HEADERS {
            fwd[key] = value;
        }
    }
    return fwd;
}

"""Health endpoint - returns registry summary."""
impl MicroserviceGateway.handle_health -> Response {
    return JSONResponse(
        status_code=200,
        content={
            "status": "healthy",
            "services": self.registry.health_summary()
        }
    );
}

"""Built-in jac-scale routes (/user/*, /walker/*, /function/*, etc.).

Each service only has its own walkers/functions, so we try every healthy
service until one returns non-404. Returns None if `path` isn't a built-in.
"""
impl MicroserviceGateway.handle_builtin_passthrough
(request: Request, path: str) -> Response | None {
    is_builtin = path.startswith(_BUILTIN_PREFIXES) or path in _BUILTIN_EXACT;
    if not is_builtin {
        return None;
    }

    fwd_headers = self.build_forward_headers(request);
    body: bytes = await request.body();
    query: str = str(request.url.query);

    for (svc_name, svc_entry) in self.registry.entries.items() {
        if svc_entry.status in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) and svc_entry.url {
            target_url = f"{svc_entry.url}{path}";
            if query {
                target_url = f"{target_url}?{query}";
            }
            logger.info(f"Passthrough: {request.method} {path} -> {target_url}");

            result = await raw_forward(request.method, target_url, fwd_headers, body);
            if result is not None {
                (sc, rh, rb) = result;
                # If service returned 404, try next service (walker might be elsewhere)
                if sc == 404 {
                    continue;
                }
                return Response(status_code=sc, headers=rh, content=rb);
            }
        }
    }
    return JSONResponse(status_code=404, content={"error": "Not found on any service", "path": path});
}

"""Admin UI routes - /admin redirects, /admin/* serves assets."""
impl MicroserviceGateway.handle_admin
(path: str) -> Response | None {
    if path == "/admin" {
        import from fastapi.responses { RedirectResponse }
        return RedirectResponse(url="/admin/", status_code=302);
    }
    if path.startswith("/admin/") {
        asset_path: str = path[7:];
        return self.serve_admin_asset(asset_path);
    }
    return None;
}

"""Proxy a request to the microservice matched by prefix.

Returns None if no service prefix matches, 503 if the matched service is
not healthy, 502 on forwarding failure.
"""
impl MicroserviceGateway.handle_proxy
(request: Request, path: str) -> Response | None {
    svc = self.registry.match_route(path);
    if not svc {
        return None;
    }

    if svc.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
        return JSONResponse(
            status_code=503,
            content={"error": f"Service '{svc.name}' is {svc.status.value}"}
        );
    }

    target_url = self.resolve_target_url(svc, path, str(request.url.query));
    logger.info(f"Proxy: {request.method} {path} -> {target_url}");

    fwd_headers = self.build_forward_headers(request);
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
    return Response(status_code=status_code, headers=resp_headers, content=resp_body);
}

"""Serve static files or SPA fallback for GET requests."""
impl MicroserviceGateway.handle_static
(request: Request, path: str) -> Response | None {
    if request.method != "GET" {
        return None;
    }

    file_path: str = path.lstrip("/");
    if file_path {
        static_resp = self.serve_static(file_path);
        if static_resp {
            return static_resp;
        }
    }

    accept: str = request.headers.get("accept", "");
    if "text/html" in accept {
        return self.serve_spa_fallback();
    }
    return None;
}

"""Create the FastAPI app and register the dispatcher middleware."""
impl MicroserviceGateway.setup -> FastAPI {
    self.app = FastAPI(title="Jac Microservice Gateway");
    gw = self;

    self.bootstrap_admin();

    @self.app.middleware("http")
    async def dispatcher(request: Request, call_next: object) -> Response {
        path: str = request.url.path;

        if path == "/health" {
            return gw.handle_health();
        }

        builtin = await gw.handle_builtin_passthrough(request, path);
        if builtin is not None {
            return builtin;
        }

        admin = gw.handle_admin(path);
        if admin is not None {
            return admin;
        }

        proxy = await gw.handle_proxy(request, path);
        if proxy is not None {
            return proxy;
        }

        static_resp = gw.handle_static(request, path);
        if static_resp is not None {
            return static_resp;
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
