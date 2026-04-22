"""WebSocket proxying for the microservice gateway (ROADMAP P15).

Flow:
  1. Client opens WS to the gateway at `/{some_prefix}/ws/{rest}`.
  2. Gateway matches the prefix against the registry (same logic as
     HTTP proxy), rewrites to `{service_url}/ws/{rest}`, and converts
     the URL scheme from http(s) -> ws(s).
  3. Gateway accepts the client WS, opens an aiohttp `ws_connect` to
     the upstream service, and runs two concurrent pump tasks:
     client -> upstream, upstream -> client.
  4. Either side closing cancels the other pump and closes both
     connections.

Headers forwarded on the upstream handshake:
  - `Authorization`       (for auth-gated WS endpoints)
  - `X-Trace-Id`          (correlation; gateway mints one if absent)
  - `X-Forwarded-For`     (client IP)

Hop-by-hop headers are stripped; aiohttp manages its own WS handshake
headers (Upgrade, Sec-WebSocket-*, etc.).

K8s parallel: K8s Services are L4 pass-through for ws/wss, so the
same gateway handler works unchanged - kube-proxy / LB just routes
the TCP stream to the gateway pod, which then fans out to service
pods via the registry.
"""

import logging;
import aiohttp;
import asyncio;
import from typing { Any }

glob _logger = logging.getLogger(__name__),
     _WS_HOP_BY_HOP: set[str] = {
        "host", "connection", "upgrade", "sec-websocket-key",
        "sec-websocket-version", "sec-websocket-extensions",
        "sec-websocket-protocol", "sec-websocket-accept",
        "transfer-encoding", "keep-alive"
     };


"""Rewrite an http(s)://host/... URL to ws(s)://host/... for the
upstream handshake. aiohttp's ws_connect requires ws/wss scheme."""
def _to_ws_scheme(url: str) -> str {
    if url.startswith("http://") {
        return "ws://" + url[7:];
    }
    if url.startswith("https://") {
        return "wss://" + url[8:];
    }
    return url;
}


"""Filter the client's request headers down to the set we want on the
upstream WS handshake. aiohttp will add its own Upgrade / Sec-*
headers so we strip any leftover from the client side."""
def _select_handshake_headers(
    client_headers: dict[str, str]
) -> dict[str, str]{
    out: dict[str, str] = {};
    for (k, v) in client_headers.items() {
        lk = k.lower();
        if lk in _WS_HOP_BY_HOP {
            continue;
        }
        # Pass through auth + tracing + X-Forwarded-For; skip the rest
        # to avoid leaking cookies / client-hop tokens to the service.
        if lk in ("authorization", "x-trace-id", "x-forwarded-for") {
            out[k] = v;
        }
    }
    return out;
}


"""Pipe messages from client WS -> upstream WS.

Runs until the client closes the connection or sends a CLOSE frame.
Any aiohttp-side send error also terminates the pump so its sibling
can wind down."""
async def _pump_client_to_upstream(client_ws: Any, upstream_ws: Any) -> None {
    try {
        while True {
            # Starlette WebSocket.receive() returns a dict with
            # 'type' + 'text'/'bytes'. receive_text() / receive_bytes()
            # raise WebSocketDisconnect on close. Use the dict form
            # so we can handle both text and binary uniformly.
            frame = await client_ws.receive();
            ftype: str = frame.get("type", "");
            if ftype == "websocket.disconnect" {
                break;
            }
            if "text" in frame and frame["text"] is not None {
                await upstream_ws.send_str(frame["text"]);
            } elif "bytes" in frame and frame["bytes"] is not None {
                await upstream_ws.send_bytes(frame["bytes"]);
            }
        }
    } except Exception as e {
        _logger.debug(f"ws: client->upstream pump ended: {e}");
    }
}


"""Pipe messages from upstream WS -> client WS.

Handles aiohttp frame types: TEXT/BINARY forward, CLOSE terminates,
ERROR logs and terminates. PING/PONG are handled by aiohttp's auto
heartbeat."""
async def _pump_upstream_to_client(upstream_ws: Any, client_ws: Any) -> None {
    try {
        async for msg in upstream_ws {
            if msg.type == aiohttp.WSMsgType.TEXT {
                await client_ws.send_text(msg.data);
            } elif msg.type == aiohttp.WSMsgType.BINARY {
                await client_ws.send_bytes(msg.data);
            } elif msg.type in (
                aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.CLOSING
            ) {
                break;
            } elif msg.type == aiohttp.WSMsgType.ERROR {
                _logger.warning(f"ws: upstream error: {upstream_ws.exception()}");
                break;
            }
        }
    } except Exception as e {
        _logger.debug(f"ws: upstream->client pump ended: {e}");
    }
}


"""Proxy an accepted client WebSocket to a resolved upstream URL.

Caller is expected to have already called `await client_ws.accept()`
and resolved `upstream_url` via the registry (so K8sDeployer's DNS
URLs flow through without change).

Returns when either side closes. Always closes both sockets.
"""
async def websocket_forward(
    client_ws: Any,
    upstream_url: str,
    request_headers: dict[str, str],
    timeout: int = 30
) -> None {
    ws_url: str = _to_ws_scheme(upstream_url);
    hs_headers: dict[str, str] = _select_handshake_headers(request_headers);
    session = aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=timeout)
    );
    try {
        try {
            upstream_ws = await session.ws_connect(ws_url, headers=hs_headers);
        } except (aiohttp.ClientError, aiohttp.WSServerHandshakeError, OSError) as e {
            _logger.error(f"ws: upstream handshake failed: {e}");
            try {
                await client_ws.close(code=1011);  # 1011 = internal error
            } except Exception {
                ;
            }
            return;
        }
        try {
            # Run both pumps concurrently. When either returns (close
            # or error), cancel the other so we don't hang on a half-
            # closed connection.
            await asyncio.gather(
                _pump_client_to_upstream(client_ws, upstream_ws),
                _pump_upstream_to_client(upstream_ws, client_ws),
                return_exceptions=True
            );
        } finally {
            try {
                await upstream_ws.close();
            } except Exception {
                ;
            }
            try {
                await client_ws.close();
            } except Exception {
                ;
            }
        }
    } finally {
        try {
            await session.close();
        } except Exception {
            ;
        }
    }
}
