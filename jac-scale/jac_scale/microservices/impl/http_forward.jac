"""HTTP forwarding helpers for the microservice gateway.

Two modes:

  `raw_forward`    buffered - reads the full upstream body before
                   returning (status, headers, bytes). Used where
                   the caller needs to inspect the body or peek the
                   status (e.g. the 404-try-next loop in
                   `handle_builtin_passthrough`).

  `stream_forward` streaming - opens the request, returns a
                   ForwardResult handle. Caller peeks status, then
                   either calls `to_response()` to get a
                   StreamingResponse (SSE, chunked, large bodies) or
                   `cleanup()` to abort without streaming. The
                   aiohttp session stays alive until the stream
                   completes, so `text/event-stream` + connection
                   keep-alive work end-to-end.

Modeled on the aiohttp usage in jac_scale/providers/proxy/sandbox_proxy.jac.
"""

import logging;
import aiohttp;
import from typing { Any }
import from fastapi.responses { Response, StreamingResponse }

glob _logger = logging.getLogger(__name__),
     _HOP_BY_HOP: set[str] = {"host", "transfer-encoding", "connection", "keep-alive"};


"""Buffered forward: reads the full upstream body before returning.

Used for endpoints where callers inspect the body or the status code
pre-return (e.g. `handle_builtin_passthrough`'s 404-try-next loop).
Returns (status, headers, body) on success or None on transport error.
"""
async def raw_forward(
    method: str,
    url: str,
    headers: dict[str, str],
    body: bytes,
    timeout: int = 30
) -> tuple[int, dict[str, str], bytes] | None {
    try {
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=timeout)
        ) as session {
            async with session.request(
                method=method,
                url=url,
                headers=headers,
                data=body,
                allow_redirects=False
            ) as resp {
                resp_body = await resp.read();
                resp_headers: dict[str, str] = {};
                for (k, v) in resp.headers.items() {
                    if k.lower() not in _HOP_BY_HOP {
                        resp_headers[k] = v;
                    }
                }
                return (resp.status, resp_headers, resp_body);
            }
        }
    } except (aiohttp.ClientError, OSError) as e {
        _logger.error(f"HTTP forward error: {e}");
        return None;
    }
}


"""Handle for a still-open upstream response (ROADMAP P15).

Keeps the aiohttp session + response alive so the caller can decide
whether to build a StreamingResponse (one-shot body or SSE keepalive)
or abort and close the connection. Either `to_response()` or
`cleanup()` MUST be called; otherwise the session leaks a connection
pool slot.
"""
obj ForwardResult {
    has status: int,
        headers: dict[str, str],
        _session: Any,
        _resp: Any;

    """Wrap the open upstream response as a StreamingResponse.

    Transfers ownership: closing the response iterator closes the
    aiohttp session. Safe for SSE (Content-Type: text/event-stream),
    chunked transfer encoding, and large bodies. For small buffered
    bodies the iterator returns one chunk and closes - same visible
    behavior as raw_forward + Response.
    """
    def to_response -> StreamingResponse;

    """Close the upstream response + session without streaming.

    Call this when the caller decides (after peeking `status` +
    `headers`) not to surface this response - e.g. the
    handle_builtin_passthrough 404-try-next loop. Idempotent.
    """
    async def cleanup -> None;
}


impl ForwardResult.to_response -> StreamingResponse {
    resp = self._resp;
    session = self._session;

    async def body_iter {
        try {
            async for chunk in resp.content.iter_chunked(8192) {
                yield chunk;
            }
        } finally {
            try {
                resp.close();
            } except Exception {
                ;
            }
            try {
                await session.close();
            } except Exception {
                ;
            }
        }
    }

    return StreamingResponse(
        body_iter(),
        status_code=self.status,
        headers=self.headers
    );
}


impl ForwardResult.cleanup -> None {
    try {
        self._resp.close();
    } except Exception {
        ;
    }
    try {
        await self._session.close();
    } except Exception {
        ;
    }
}


"""Open a forward request and return a ForwardResult for the caller to
either stream or abort. See ForwardResult docstring for lifecycle
rules. Returns None on transport-level failure (connect refused,
timeout, DNS failure) - caller should emit a 502 gateway_timeout
envelope.
"""
async def stream_forward(
    method: str,
    url: str,
    headers: dict[str, str],
    body: bytes,
    timeout: int = 30
) -> ForwardResult | None {
    session = aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=timeout)
    );
    try {
        resp = await session.request(
            method=method,
            url=url,
            headers=headers,
            data=body,
            allow_redirects=False
        );
    } except (aiohttp.ClientError, OSError) as e {
        _logger.error(f"HTTP stream-forward error: {e}");
        await session.close();
        return None;
    }

    resp_headers: dict[str, str] = {};
    for (k, v) in resp.headers.items() {
        if k.lower() not in _HOP_BY_HOP {
            resp_headers[k] = v;
        }
    }

    return ForwardResult(
        status=resp.status,
        headers=resp_headers,
        _session=session,
        _resp=resp
    );
}
