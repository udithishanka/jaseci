"""Tests for microservices service_call and ServiceResponse."""

import unittest.mock;
import json;
import from jac_scale.microservices.service_client {
    service_call,
    ServiceResponse
}

# =============================================================================
# ServiceResponse
# =============================================================================

test "service response json parses body" {
    resp = ServiceResponse(
        status=200,
        _body=b'{"charge_id": "ch_123", "status": "succeeded"}'
    );
    data = resp.json();
    assert data["charge_id"] == "ch_123";
    assert data["status"] == "succeeded";
}

test "service response text returns string" {
    resp = ServiceResponse(status=200, _body=b"hello world");
    assert resp.text() == "hello world";
}

test "service response stores headers" {
    resp = ServiceResponse(
        status=200,
        _body=b"ok",
        _headers={"Content-Type": "application/json"}
    );
    assert resp._headers["Content-Type"] == "application/json";
}

# =============================================================================
# service_call URL building
# =============================================================================

test "service_call builds correct url" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{"ok": true}';
    mock_resp.headers = {"Content-Type": "application/json"};

    with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
        result = service_call(
            service="payments",
            endpoint="/walker/charge",
            gateway_url="http://127.0.0.1:9000"
        );
        call_kwargs = mock_req.call_args[1];
        assert "http://127.0.0.1:9000/api/payments/walker/charge" == call_kwargs["url"];
    }
}

test "service_call strips leading slash from endpoint" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{}';
    mock_resp.headers = {};

    with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
        service_call(
            service="orders",
            endpoint="walker/list",
            gateway_url="http://gw:8000"
        );
        call_kwargs = mock_req.call_args[1];
        assert "http://gw:8000/api/orders/walker/list" == call_kwargs["url"];
    }
}

# =============================================================================
# Token propagation
# =============================================================================

test "service_call sends internal token header" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{}';
    mock_resp.headers = {};

    with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
        service_call(
            service="payments",
            endpoint="/walker/charge",
            internal_token="svc_token_123",
            gateway_url="http://gw:8000"
        );
        call_kwargs = mock_req.call_args[1];
        assert call_kwargs["headers"]["X-Internal-Token"] == "svc_token_123";
    }
}

test "service_call without token does not send header" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{}';
    mock_resp.headers = {};

    with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
        service_call(
            service="payments",
            endpoint="/walker/charge",
            gateway_url="http://gw:8000"
        );
        call_kwargs = mock_req.call_args[1];
        assert "X-Internal-Token" not in call_kwargs["headers"];
    }
}

# =============================================================================
# Request body
# =============================================================================

test "service_call sends json body" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{"charged": true}';
    mock_resp.headers = {};

    with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
        result = service_call(
            service="payments",
            endpoint="/walker/charge",
            body={"amount": 99.99, "currency": "USD"},
            gateway_url="http://gw:8000"
        );
        call_kwargs = mock_req.call_args[1];
        assert call_kwargs["json"] == {"amount": 99.99, "currency": "USD"};
        assert result.status == 200;
    }
}

# =============================================================================
# Error handling
# =============================================================================

test "service_call returns 502 on connection error" {
    import from requests { ConnectionError }

    with unittest.mock.patch("requests.request", side_effect=ConnectionError("refused")) {
        result = service_call(
            service="payments",
            endpoint="/walker/charge",
            gateway_url="http://gw:8000"
        );
        assert result.status == 502;
        assert "unavailable" in result.text().lower();
    }
}

test "service_call returns actual error status from service" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 500;
    mock_resp.content = b'{"error": "internal server error"}';
    mock_resp.headers = {};

    with unittest.mock.patch("requests.request", return_value=mock_resp) {
        result = service_call(
            service="payments",
            endpoint="/walker/charge",
            gateway_url="http://gw:8000"
        );
        assert result.status == 500;
    }
}

# =============================================================================
# Default gateway URL from env
# =============================================================================

test "service_call uses GATEWAY_URL env var" {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.status_code = 200;
    mock_resp.content = b'{}';
    mock_resp.headers = {};

    with unittest.mock.patch.dict("os.environ", {"GATEWAY_URL": "http://custom-gw:9999"}) {
        with unittest.mock.patch("requests.request", return_value=mock_resp) as mock_req {
            service_call(service="orders", endpoint="/walker/list");
            call_kwargs = mock_req.call_args[1];
            assert call_kwargs["url"].startswith("http://custom-gw:9999");
        }
    }
}
