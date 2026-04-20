"""Tests for sv-to-sv Authorization header forwarding via the plugin's
sv_service_call hookimpl.

Covers:
  - _auth_ctx.set/get/reset semantics
  - plugin override reads the current auth token and forwards it
  - no auth set -> no header added
"""

import httpx;
import from jaclang.runtimelib { sv_client }
import from jac_scale.microservices._auth_ctx {
    set_current_auth, reset_current_auth, get_current_auth
}
import from jac_scale.plugin { JacScalePlugin }

# =============================================================================
# _auth_ctx
# =============================================================================

test "set/get/reset auth context round-trips" {
    tok = set_current_auth("Bearer abc");
    assert get_current_auth() == "Bearer abc";
    reset_current_auth(tok);
    assert get_current_auth() == "";
}

test "set_current_auth None stores empty string" {
    tok = set_current_auth(None);
    assert get_current_auth() == "";
    reset_current_auth(tok);
}

# =============================================================================
# Plugin sv_service_call override forwards Authorization header
# =============================================================================

test "sv_service_call forwards Authorization header when auth set" {
    captured: dict = {};

    def handler(request: httpx.Request) -> httpx.Response {
        captured["auth"] = request.headers.get("Authorization", "");
        return httpx.Response(
            status_code=200,
            json={"ok": True, "data": {"result": "echoed"}}
        );
    }

    transport = httpx.MockTransport(handler);

    # Monkeypatch httpx.post so the plugin hookimpl uses our MockTransport
    original_post = httpx.post;
    def mock_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = mock_post;

    try {
        sv_client.register("demo_mod", "http://demo.invalid");
        tok = set_current_auth("Bearer xyz");
        try {
            result = JacScalePlugin.sv_service_call("demo_mod", "echo", {"x": 1});
        } finally {
            reset_current_auth(tok);
        }

        assert captured["auth"] == "Bearer xyz";
        assert result == "echoed";
    } finally {
        httpx.post = original_post;
        sv_client.unregister("demo_mod");
    }
}

test "sv_service_call omits Authorization when no auth context" {
    captured: dict = {"auth": "sentinel"};

    def handler(request: httpx.Request) -> httpx.Response {
        captured["auth"] = request.headers.get("Authorization", "");
        return httpx.Response(
            status_code=200,
            json={"ok": True, "data": {"result": "ok"}}
        );
    }

    transport = httpx.MockTransport(handler);

    original_post = httpx.post;
    def mock_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = mock_post;

    try {
        sv_client.register("demo_mod2", "http://demo.invalid");
        # Do not set auth; context var default is ""
        result = JacScalePlugin.sv_service_call("demo_mod2", "echo", {});
        assert captured["auth"] == "";
        assert result == "ok";
    } finally {
        httpx.post = original_post;
        sv_client.unregister("demo_mod2");
    }
}

test "sv_service_call surfaces application-level error from envelope" {
    def handler(request: httpx.Request) -> httpx.Response {
        return httpx.Response(
            status_code=200,
            json={"ok": False, "error": {"code": "X", "message": "boom"}}
        );
    }
    transport = httpx.MockTransport(handler);

    original_post = httpx.post;
    def mock_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = mock_post;

    try {
        sv_client.register("demo_mod3", "http://demo.invalid");
        raised = False;
        try {
            JacScalePlugin.sv_service_call("demo_mod3", "fail", {});
        } except RuntimeError as e {
            raised = "boom" in str(e);
        }
        assert raised;
    } finally {
        httpx.post = original_post;
        sv_client.unregister("demo_mod3");
    }
}
