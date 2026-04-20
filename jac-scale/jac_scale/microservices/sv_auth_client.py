"""Auth-forwarding client for sv-to-sv RPC calls.

jaclang's sv_client.call() uses bare httpx without forwarding headers.
For microservices that require JWT auth, we register a custom client
via sv_client.register_test_client() that reads the current request's
Authorization header from a ContextVar and forwards it downstream.

This avoids modifying jaclang — we use the existing _test_clients
duck-typed extension point to inject auth-forwarding behavior.

Usage:
    from jac_scale.microservices.sv_auth_client import (
        AuthForwardingClient,
        set_current_auth,
        reset_current_auth,
    )

    # At sv service registration time (ensure_sv_service hook):
    client = AuthForwardingClient(base_url)
    sv_client.register_test_client(module_name, client)

    # In FastAPI middleware:
    token = set_current_auth(request.headers.get("Authorization"))
    try:
        response = await call_next(request)
    finally:
        reset_current_auth(token)
"""

from __future__ import annotations

import logging
from contextvars import ContextVar
from typing import Any

import httpx

logger = logging.getLogger(__name__)

# Per-request auth token. Set by middleware, read by AuthForwardingClient.post().
_auth_token: ContextVar[str] = ContextVar("_sv_auth_token", default="")


def set_current_auth(token: str | None) -> Any:
    """Set the current request's Authorization header value.

    Returns a Token object; pass to reset_current_auth() to clean up.
    Stores the full header value (e.g., 'Bearer xyz...') or empty string.
    """
    return _auth_token.set(token or "")


def reset_current_auth(token_obj: Any) -> None:
    """Reset the auth context var to its previous value."""
    _auth_token.reset(token_obj)


def get_current_auth() -> str:
    """Return the current auth token (for debugging)."""
    return _auth_token.get("")


class _Response:
    """Minimal duck-typed response for sv_client.call compatibility.

    sv_client.call expects: resp.json() -> dict
    """

    def __init__(self, data: Any) -> None:
        self._data = data

    def json(self) -> Any:
        return self._data


class AuthForwardingClient:
    """Duck-typed client registered via sv_client.register_test_client().

    sv_client.call does: _test_clients[name].post(path, json=args)

    We implement .post() to make a real httpx call with the current
    request's Authorization header forwarded.
    """

    def __init__(self, base_url: str, timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def post(
        self,
        path: str,
        json: Any = None,
        headers: dict[str, str] | None = None,
    ) -> _Response:
        """Make an HTTP POST to the target service with forwarded auth."""
        req_headers: dict[str, str] = dict(headers) if headers else {}

        token = _auth_token.get("")
        if token and "Authorization" not in req_headers:
            req_headers["Authorization"] = token

        url = f"{self.base_url}{path}"
        try:
            resp = httpx.post(
                url, json=json, headers=req_headers, timeout=self.timeout
            )
            data = resp.json()
        except Exception as e:
            logger.error(f"sv-to-sv call failed for {url}: {e}")
            data = {
                "ok": False,
                "error": {"code": "RPC_ERROR", "message": str(e)},
            }
        return _Response(data)
