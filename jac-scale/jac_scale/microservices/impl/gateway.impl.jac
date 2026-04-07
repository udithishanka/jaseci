"""Implementation of MicroserviceGateway methods."""

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

"""Create the FastAPI app and register routes."""
impl MicroserviceGateway.setup -> FastAPI {
    self.app = FastAPI(title="Jac Microservice Gateway");
    gw_ref = self;

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
