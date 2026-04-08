"""Inter-service HTTP client with automatic token propagation."""

import os;
import json;
import logging;
import requests;
import from typing { Any }

glob logger = logging.getLogger(__name__);

"""Response wrapper for inter-service calls."""
obj ServiceResponse {
    has status: int,
        _body: str | bytes = b"",
        _headers: dict[str, str] = {};

    """Parse response body as JSON."""
    def json -> Any;

    """Return response body as string."""
    def text -> str;
}

"""
Call another microservice through the gateway.

Resolves the service name to gateway URL + prefix, attaches the internal
token from the current request context, and makes the HTTP call.
"""
def service_call(
    service: str,
    endpoint: str,
    method: str = "POST",
    body: dict[str, Any] | None = None,
    internal_token: str = "",
    auth_token: str = "",
    gateway_url: str = "",
    timeout: int = 30
) -> ServiceResponse {
    if not gateway_url {
        gateway_url = os.environ.get("GATEWAY_URL", "http://127.0.0.1:8000");
    }

    clean_endpoint: str = endpoint.lstrip("/");
    url: str = f"{gateway_url}/api/{service}/{clean_endpoint}";

    req_headers: dict[str, str] = {"Content-Type": "application/json"};
    if auth_token {
        if auth_token.startswith("Bearer ") {
            req_headers["Authorization"] = auth_token;
        } else {
            req_headers["Authorization"] = f"Bearer {auth_token}";
        }
    }
    if internal_token {
        req_headers["X-Internal-Token"] = internal_token;
    }

    logger.info(f"service_call: {method} {url}");

    try {
        resp = requests.request(
            method=method,
            url=url,
            headers=req_headers,
            json=body if body is not None else {},
            timeout=timeout
        );
        status_code: int = int(getattr(resp, "status_code", 502));
        resp_content: bytes = bytes(getattr(resp, "content", b""));
        raw_headers: dict[str, str] = dict(getattr(resp, "headers", {}));
        resp_headers: dict[str, str] = {};
        for (k, v) in raw_headers.items() {
            resp_headers[str(k)] = str(v);
        }
        return ServiceResponse(
            status=status_code,
            _body=resp_content,
            _headers=resp_headers
        );
    } except requests.RequestException as e {
        logger.error(f"service_call failed: {e}");
        return ServiceResponse(status=502, _body=b'{"error": "Service unavailable"}');
    }
}
