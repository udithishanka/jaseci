"""Raw HTTP call for inter-service communication — plain Python for aiohttp compatibility."""

import aiohttp
import json
import logging

logger = logging.getLogger(__name__)


async def call_service_http(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict | None = None,
    timeout: int = 30,
) -> tuple[int, bytes, dict[str, str]] | None:
    """Make an HTTP call to another service. Returns (status, body, headers) or None on error."""
    try:
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=timeout)
        ) as session:
            json_body = json.dumps(body) if body else None
            if json_body:
                headers["Content-Type"] = "application/json"

            async with session.request(
                method=method,
                url=url,
                headers=headers,
                data=json_body.encode() if json_body else None,
                allow_redirects=False,
            ) as resp:
                resp_body = await resp.read()
                resp_headers = dict(resp.headers)
                return (resp.status, resp_body, resp_headers)
    except (aiohttp.ClientError, OSError) as e:
        logger.error(f"Service call error: {e}")
        return None
