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
         "/user", "/healthz", "/graph"
     };

"""Copy incoming request headers, dropping hop-by-hop headers.

Also ensures X-Trace-Id is present on every forwarded request (either
the inbound one or a freshly-minted UUID). Downstream services pick
it up and thread it through their own logs + sv-import RPC calls.
"""
impl MicroserviceGateway.build_forward_headers
(request: Request) -> dict[str, str] {
    import from jac_scale.microservices._trace_ctx {
        get_current_trace, ensure_trace_id
    }
    fwd: dict[str, str] = {};
    for (key, value) in request.headers.items() {
        if key.lower() not in HOP_BY_HOP_HEADERS {
            fwd[key] = value;
        }
    }
    # Trace-Id is set by the gateway's dispatcher (handle_health path
    # and below). Fall back to the incoming header if the ContextVar
    # isn't set (defensive; shouldn't happen in the dispatcher path).
    trace = get_current_trace() or ensure_trace_id(request.headers.get("X-Trace-Id"));
    fwd["X-Trace-Id"] = trace;
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
    import from jac_scale.microservices._errors { not_found }
    return not_found(path, message="Not found on any service");
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

    import from jac_scale.microservices._errors {
        service_unavailable, gateway_timeout
    }

    if svc.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
        return service_unavailable(svc.name, svc.status.value);
    }

    target_url = self.resolve_target_url(svc, path, str(request.url.query));
    logger.info(f"Proxy: {request.method} {path} -> {target_url}");

    fwd_headers = self.build_forward_headers(request);
    client_addr: str = getattr(getattr(request, "client", None), "host", "unknown");
    fwd_headers["X-Forwarded-For"] = client_addr;

    body: bytes = await request.body();

    result = await raw_forward(request.method, target_url, fwd_headers, body);
    if result is None {
        return gateway_timeout(svc.name);
    }

    (status_code, resp_headers, resp_body) = result;
    return Response(status_code=status_code, headers=resp_headers, content=resp_body);
}

"""Return the aggregated OpenAPI schema across all healthy services.

Fetches each service's /openapi.json, prefixes its paths with the
service's gateway route, and merges. See `_openapi_agg.aggregate_openapi`.
"""
impl MicroserviceGateway.handle_openapi -> Response {
    import from jac_scale.microservices._openapi_agg { aggregate_openapi }
    doc = await aggregate_openapi(self.registry);
    return JSONResponse(status_code=200, content=doc);
}

"""Render the Swagger UI page pointing at our aggregated /openapi.json."""
impl MicroserviceGateway.handle_docs -> Response {
    import from fastapi.openapi.docs { get_swagger_ui_html }
    return get_swagger_ui_html(
        openapi_url="/openapi.json",
        title="Jac Microservice Gateway - API"
    );
}

"""Serve the Prometheus exposition for this gateway's registry.

Returns 503 when prometheus_client is not installed (the 'monitoring'
extra wasn't pulled in). Path routing lands here when
`monitoring.enabled` is set in jac.toml; otherwise /metrics falls
through to passthrough as before.
"""
impl MicroserviceGateway.handle_metrics -> Response {
    import from jac_scale.microservices._metrics { render_metrics }
    import from jac_scale.microservices._errors { error_response }
    (body, ctype) = render_metrics(self._metrics_registry);
    if not body {
        return error_response(
            code="METRICS_UNAVAILABLE",
            message="metrics not available (install prometheus_client)",
            status=503
        );
    }
    return Response(content=body, media_type=ctype);
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
    import time;
    self.app = FastAPI(title="Jac Microservice Gateway");
    gw = self;

    self.bootstrap_admin();

    # Install the trace-id log filter once when the gateway starts up
    # so every subsequent log line gets a [trace=...] prefix.
    import from jac_scale.microservices._trace_ctx {
        install_trace_log_filter,
        set_current_trace, reset_current_trace, ensure_trace_id
    }
    install_trace_log_filter();

    # Build Prometheus metrics (no-ops when prometheus_client is not
    # installed). Only initialized once per gateway instance; spawning
    # a fresh gateway in tests gets a fresh registry to avoid
    # "Duplicated timeseries" errors.
    import from jac_scale.microservices._metrics { build_gateway_metrics }
    import from jac_scale.config_loader { get_scale_config }
    mon_cfg = get_scale_config().get_monitoring_config();
    (self._metrics_registry, self._metrics_requests, self._metrics_duration) = (
        build_gateway_metrics(
            namespace=mon_cfg.get("namespace", "jac_scale"),
            histogram_buckets=mon_cfg.get("histogram_buckets")
        )
    );

    @self.app.middleware("http")
    async def dispatcher(request: Request, call_next: object) -> Response {
        path: str = request.url.path;

        # Stamp the request with a trace id (preserving any inbound
        # X-Trace-Id so clients can correlate upstream logs). The
        # ContextVar is read by build_forward_headers for proxy +
        # passthrough calls, and by downstream jfast_api middleware
        # when the request lands on each service.
        trace_id = ensure_trace_id(request.headers.get("X-Trace-Id"));
        tok = set_current_trace(trace_id);

        start = time.time();
        svc_label: str = "__unmatched__";
        try {
            resp: Response | None = None;
            if path == "/health" {
                svc_label = "__health__";
                resp = gw.handle_health();
            } elif path == "/metrics" {
                svc_label = "__metrics__";
                resp = gw.handle_metrics();
            } elif path == "/openapi.json" {
                svc_label = "__openapi__";
                resp = await gw.handle_openapi();
            } elif path == "/docs" {
                svc_label = "__docs__";
                resp = gw.handle_docs();
            } else {
                # Prefix-match first so we can label the service name on
                # proxy hits even before handle_proxy gets the Response.
                matched = gw.registry.match_route(path);
                if matched {
                    svc_label = matched.name;
                    resp = await gw.handle_proxy(request, path);
                }
                if resp is None {
                    builtin = await gw.handle_builtin_passthrough(request, path);
                    if builtin is not None {
                        svc_label = "__builtin__";
                        resp = builtin;
                    }
                }
                if resp is None {
                    admin = gw.handle_admin(path);
                    if admin is not None {
                        svc_label = "__admin__";
                        resp = admin;
                    }
                }
                if resp is None {
                    static_resp = gw.handle_static(request, path);
                    if static_resp is not None {
                        svc_label = "__static__";
                        resp = static_resp;
                    }
                }
                if resp is None {
                    import from jac_scale.microservices._errors { not_found }
                    resp = not_found(path);
                }
            }
            # Echo trace id so clients can correlate and our e2e can
            # verify end-to-end propagation across the gateway hop.
            resp.headers["X-Trace-Id"] = trace_id;
            # Prometheus metrics (no-op when prometheus_client absent).
            if gw._metrics_requests is not None {
                import from jac_scale.microservices._metrics { classify_outcome }
                outcome = classify_outcome(resp.status_code);
                gw._metrics_requests.labels(
                    service=svc_label, method=request.method, outcome=outcome
                ).inc();
                gw._metrics_duration.labels(
                    service=svc_label, method=request.method
                ).observe(time.time() - start);
            }
            return resp;
        } finally {
            reset_current_trace(tok);
        }
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
