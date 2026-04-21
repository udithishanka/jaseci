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

# =============================================================================
# Retry with exponential backoff (ROADMAP P5)
# =============================================================================

test "sv_service_call retries on transport error and succeeds on 2nd attempt" {
    # Simulates: pod is coming up, first connect fails; second succeeds.
    # We count how many times httpx.post was called - should be 2.
    call_count: dict = {"n": 0};

    def handler(request: httpx.Request) -> httpx.Response {
        return httpx.Response(
            status_code=200, json={"ok": True, "data": {"result": "ok"}}
        );
    }
    transport = httpx.MockTransport(handler);

    original_post = httpx.post;
    def flaky_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        call_count["n"] = call_count["n"] + 1;
        if call_count["n"] == 1 {
            raise httpx.ConnectError("connection refused");
        }
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = flaky_post;

    try {
        sv_client.register("retry_mod", "http://demo.invalid");
        result = JacScalePlugin.sv_service_call("retry_mod", "ping", {});
        assert result == "ok";
        assert call_count["n"] == 2;  # first failed, second succeeded
    } finally {
        httpx.post = original_post;
        sv_client.unregister("retry_mod");
    }
}

test "sv_service_call gives up after max_attempts on persistent transport error" {
    # Simulates: downstream is genuinely unreachable. All 3 attempts
    # fail; caller gets a RuntimeError mentioning "after N attempts".
    call_count: dict = {"n": 0};

    original_post = httpx.post;
    def broken_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        call_count["n"] = call_count["n"] + 1;
        raise httpx.ConnectError("connection refused");
    }
    httpx.post = broken_post;

    try {
        sv_client.register("dead_mod", "http://demo.invalid");
        raised_msg = "";
        try {
            JacScalePlugin.sv_service_call("dead_mod", "ping", {});
        } except RuntimeError as e {
            raised_msg = str(e);
        }
        assert call_count["n"] == 3;
        assert "3 attempts" in raised_msg;
    } finally {
        httpx.post = original_post;
        sv_client.unregister("dead_mod");
    }
}

test "sv_service_call does NOT retry on application error envelope" {
    # Simulates: downstream returns 200 with ok=false (application-level
    # error). Retrying won't change the answer, so we give up after 1
    # httpx.post call and raise immediately.
    call_count: dict = {"n": 0};

    def handler(request: httpx.Request) -> httpx.Response {
        return httpx.Response(
            status_code=200,
            json={"ok": False, "error": {"code": "X", "message": "deterministic_fail"}}
        );
    }
    transport = httpx.MockTransport(handler);

    original_post = httpx.post;
    def counting_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        call_count["n"] = call_count["n"] + 1;
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = counting_post;

    try {
        sv_client.register("app_err_mod", "http://demo.invalid");
        raised_msg = "";
        try {
            JacScalePlugin.sv_service_call("app_err_mod", "fail", {});
        } except RuntimeError as e {
            raised_msg = str(e);
        }
        # Exactly one call: application errors don't retry
        assert call_count["n"] == 1;
        assert "deterministic_fail" in raised_msg;
    } finally {
        httpx.post = original_post;
        sv_client.unregister("app_err_mod");
    }
}
