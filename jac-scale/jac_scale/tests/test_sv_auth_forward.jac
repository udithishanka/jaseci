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

# =============================================================================
# Circuit breaker (ROADMAP P6)
# =============================================================================

import from jac_scale.plugin {
    _breaker_reset, _breaker_record_success, _breaker_record_failure,
    _breaker_should_skip, _BREAKER_TRIP_THRESHOLD
}

test "breaker trips OPEN after N consecutive transport failures and fails fast" {
    # Drive the breaker to OPEN directly via the recorder so we don't
    # have to burn N full retry cycles in the test.
    mod = "breaker_open_test";
    _breaker_reset(mod);

    for _ in range(_BREAKER_TRIP_THRESHOLD) {
        _breaker_record_failure(mod);
    }

    # Breaker should now short-circuit any sv_service_call for this mod.
    # Confirm by checking the skip helper directly - no httpx mock needed
    # because the call path raises before any network I/O.
    assert _breaker_should_skip(mod);

    # And a real sv_service_call should fail fast with the breaker msg.
    # We don't even register the URL: if the breaker opens correctly,
    # the call never gets as far as URL resolution.
    raised_msg = "";
    try {
        JacScalePlugin.sv_service_call(mod, "anything", {});
    } except RuntimeError as e {
        raised_msg = str(e);
    }
    assert "open circuit breaker" in raised_msg;

    _breaker_reset(mod);
}

test "breaker success recorder resets failure count" {
    mod = "breaker_reset_test";
    _breaker_reset(mod);

    # Fail threshold-1 times (one short of tripping)
    for _ in range(_BREAKER_TRIP_THRESHOLD - 1) {
        _breaker_record_failure(mod);
    }
    assert not _breaker_should_skip(mod);

    # A success resets the counter
    _breaker_record_success(mod);

    # Now threshold-1 more failures should NOT trip (counter was reset)
    for _ in range(_BREAKER_TRIP_THRESHOLD - 1) {
        _breaker_record_failure(mod);
    }
    assert not _breaker_should_skip(mod);

    _breaker_reset(mod);
}

test "HALF_OPEN probe success closes the breaker" {
    # Simulate: breaker OPEN, cooldown elapses, probe succeeds.
    # Without waiting 30s we use _breaker_force_cooldown_elapsed.
    import from jac_scale.plugin {
        _breaker_peek, _breaker_force_cooldown_elapsed
    }

    mod = "breaker_half_open_test";
    _breaker_reset(mod);

    for _ in range(_BREAKER_TRIP_THRESHOLD) {
        _breaker_record_failure(mod);
    }
    assert _breaker_should_skip(mod);

    # Force cooldown elapsed, next skip-check transitions OPEN -> HALF_OPEN
    _breaker_force_cooldown_elapsed(mod);
    assert not _breaker_should_skip(mod);
    st = _breaker_peek(mod);
    assert st is not None and st["state"] == "HALF_OPEN";

    # Probe success closes the breaker fully
    _breaker_record_success(mod);
    st = _breaker_peek(mod);
    assert st is not None and st["state"] == "CLOSED";
    assert st["fails"] == 0;

    _breaker_reset(mod);
}

test "application error envelope does NOT trip the breaker" {
    # 5 application-error calls in a row should NOT open the breaker -
    # only transport errors count. Verified by calling through the real
    # hookimpl with a mock that always returns ok=false.
    mod = "breaker_app_err_test";
    _breaker_reset(mod);

    def handler(request: httpx.Request) -> httpx.Response {
        return httpx.Response(
            status_code=200,
            json={"ok": False, "error": {"code": "X", "message": "nope"}}
        );
    }
    transport = httpx.MockTransport(handler);

    original_post = httpx.post;
    def app_err_post(url: str, json: dict = None, headers: dict = None, **kwargs: dict) -> httpx.Response {
        req_headers = dict(headers) if headers else {};
        req = httpx.Request("POST", url, json=json, headers=req_headers);
        return transport.handle_request(req);
    }
    httpx.post = app_err_post;

    try {
        sv_client.register(mod, "http://demo.invalid");
        for _ in range(_BREAKER_TRIP_THRESHOLD) {
            try {
                JacScalePlugin.sv_service_call(mod, "fail", {});
            } except RuntimeError {
                ;
            }
        }
        # Breaker should still be CLOSED - app errors don't count
        assert not _breaker_should_skip(mod);
    } finally {
        httpx.post = original_post;
        sv_client.unregister(mod);
        _breaker_reset(mod);
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
