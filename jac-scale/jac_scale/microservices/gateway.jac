"""API Gateway — path-based reverse proxy for microservices."""

import jwt;
import logging;
import mimetypes;
import uvicorn;
import time;
import from pathlib { Path }
import from fastapi { FastAPI, Request }
import from fastapi.responses { HTMLResponse, JSONResponse, Response }
import from jac_scale.microservices.service_registry { ServiceRegistry, ServiceEntry, ServiceStatus }
import from jac_scale.microservices.impl.http_forward { raw_forward }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__),
     HOP_BY_HOP_HEADERS: set[str] = {"host", "transfer-encoding", "connection", "keep-alive"},
     _jwt_config = get_scale_config().get_jwt_config(),
     GW_JWT_SECRET: str = _jwt_config['secret'],
     GW_JWT_ALGORITHM: str = _jwt_config['algorithm'],
     GW_JWT_EXP_DAYS: int = int(_jwt_config['exp_delta_days']),
     PUBLIC_PATHS: set[str] = {"/health", "/healthz", "/auth/login", "/auth/register", "/auth/refresh", "/docs", "/openapi.json", "/redoc"};

"""API Gateway that routes requests to microservices by path prefix."""
obj MicroserviceGateway {
    has registry: ServiceRegistry,
        app: FastAPI | None = None,
        port: int = 8000,
        host: str = "0.0.0.0",
        client_dist_dir: str = ".jac/client/dist",
        admin_dist_dir: str = ".jac/admin",
        internal_token_ttl: int = 30;

    """Create the FastAPI app and register routes."""
    def setup -> FastAPI;

    """Build the target URL by stripping prefix and resolving walker/function path."""
    def resolve_target_url(service_entry: ServiceEntry, path: str, query: str) -> str;

    """Serve a static file from the client dist directory. Returns None if not found."""
    def serve_static(file_path: str) -> Response | None;

    """Serve index.html for SPA fallback. Returns None if no index.html exists."""
    def serve_spa_fallback -> Response | None;

    """Bootstrap admin UI — copy pre-built bundle to admin_dist_dir if needed."""
    def bootstrap_admin -> None;

    """Serve an admin asset by path. Returns None if not found."""
    def serve_admin_asset(asset_path: str) -> Response | None;

    """Validate a JWT token. Returns decoded payload or None."""
    def validate_token(token: str) -> dict | None;

    """Create a short-lived internal service token for service-to-service calls."""
    def create_internal_token(user_id: str, user_email: str) -> str;

    """Check if a path is public (no auth required)."""
    def is_public_path(path: str) -> bool;

    """Start the gateway server (blocking)."""
    def start -> None;
}
