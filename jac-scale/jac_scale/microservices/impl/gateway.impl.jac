"""Implementation of MicroserviceGateway methods."""

"""Build the target URL by stripping prefix and forwarding the rest.

URL structure: /api/{service}/walker/{name} or /api/{service}/function/{name}
The prefix (/api/{service}) is stripped, the remainder (/walker/{name}) is
forwarded directly to the service.
"""
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

        # Find the service that owns this path
        svc = gw_ref.registry.match_route(path);

        if not svc {
            return JSONResponse(
                status_code=404,
                content={"error": "No service matches this path", "path": path}
            );
        }

        if svc.status not in (ServiceStatus.HEALTHY, ServiceStatus.STARTING) {
            return JSONResponse(
                status_code=503,
                content={"error": f"Service '{svc.name}' is {svc.status.value}"}
            );
        }

        target_url = gw_ref.resolve_target_url(svc, path, str(request.url.query));
        logger.info(f"Proxy: {request.method} {path} -> {target_url}");

        # Build forwarding headers
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
