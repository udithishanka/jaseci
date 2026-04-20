"""Raw HTTP forwarding for the microservice gateway.

Modeled on the aiohttp usage in jac_scale/providers/proxy/sandbox_proxy.jac.
Returns (status, headers, body) on success or None on error.
"""

import logging;
import aiohttp;

glob _logger = logging.getLogger(__name__),
     _HOP_BY_HOP: set[str] = {"host", "transfer-encoding", "connection", "keep-alive"};

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
