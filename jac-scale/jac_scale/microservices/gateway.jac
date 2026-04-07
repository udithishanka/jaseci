"""API Gateway — path-based reverse proxy for microservices."""

import logging;
import mimetypes;
import uvicorn;
import from pathlib { Path }
import from fastapi { FastAPI, Request }
import from fastapi.responses { HTMLResponse, JSONResponse, Response }
import from jac_scale.microservices.service_registry { ServiceRegistry, ServiceEntry, ServiceStatus }
import from jac_scale.microservices.impl.http_forward { raw_forward }

glob logger = logging.getLogger(__name__),
     HOP_BY_HOP_HEADERS: set[str] = {"host", "transfer-encoding", "connection", "keep-alive"};

"""API Gateway that routes requests to microservices by path prefix."""
obj MicroserviceGateway {
    has registry: ServiceRegistry,
        app: FastAPI | None = None,
        port: int = 8000,
        host: str = "0.0.0.0",
        client_dist_dir: str = ".jac/client/dist";

    """Create the FastAPI app and register routes."""
    def setup -> FastAPI;

    """Build the target URL by stripping prefix and resolving walker/function path."""
    def resolve_target_url(service_entry: ServiceEntry, path: str, query: str) -> str;

    """Serve a static file from the client dist directory. Returns None if not found."""
    def serve_static(file_path: str) -> Response | None;

    """Serve index.html for SPA fallback. Returns None if no index.html exists."""
    def serve_spa_fallback -> Response | None;

    """Start the gateway server (blocking)."""
    def start -> None;
}
