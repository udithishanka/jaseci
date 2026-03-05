"""Sandbox routing proxy for jac-scale.

Routes wildcard subdomain traffic to sandbox pod IPs by watching K8s pods
with configurable label selectors and maintaining an in-memory routing table.
Handles both HTTP and WebSocket (for dev server HMR support).

Environment variables:
    SANDBOX_NAMESPACE: K8s namespace to watch (default: jac-sandboxes)
    SANDBOX_LABEL: Label selector for sandbox pods (default: jac-sandbox=true)
    INTERNAL_PORT: Port on sandbox pods (default: 8000)
    PROXY_PORT: Port for this proxy to listen on (default: 8080)
"""

import os
import asyncio
import logging

import aiohttp
from aiohttp import web, WSMsgType

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sandbox-proxy")

SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "jac-sandboxes")
SANDBOX_LABEL = os.environ.get("SANDBOX_LABEL", "jac-sandbox=true")
INTERNAL_PORT = int(os.environ.get("INTERNAL_PORT", "8000"))
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8080"))

# Routing table: sandbox_id -> {"ip": str, "phase": str}
routes: dict[str, dict] = {}


# ── K8s Pod Watcher ──────────────────────────────────────────────────────

async def watch_pods():
    """Watch sandbox pods and maintain routing table."""
    from kubernetes_asyncio import client, config, watch

    try:
        config.load_incluster_config()
    except Exception:
        await config.load_kube_config()

    v1 = client.CoreV1Api()
    w = watch.Watch()

    while True:
        try:
            log.info(f"Starting pod watch on {SANDBOX_NAMESPACE} ({SANDBOX_LABEL})")
            async for event in w.stream(
                v1.list_namespaced_pod,
                namespace=SANDBOX_NAMESPACE,
                label_selector=SANDBOX_LABEL,
                timeout_seconds=300,
            ):
                etype = event["type"]
                pod = event["object"]
                pod_ip = pod.status.pod_ip if pod.status else None
                labels = pod.metadata.labels or {}
                sandbox_id = labels.get("jac-sandbox-id", pod.metadata.name)

                if etype == "DELETED":
                    if routes.pop(sandbox_id, None):
                        log.info(f"Removed route: {sandbox_id}")
                elif pod_ip:
                    phase = pod.status.phase or "Unknown"
                    # Check container readiness
                    ready = False
                    if pod.status.container_statuses:
                        for cs in pod.status.container_statuses:
                            if cs.name == "sandbox" and cs.ready:
                                ready = True
                    old = routes.get(sandbox_id)
                    routes[sandbox_id] = {
                        "ip": pod_ip,
                        "phase": phase,
                        "ready": ready,
                    }
                    if not old:
                        log.info(f"New route: {sandbox_id} -> {pod_ip} ({phase})")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning(f"Watch error: {e}, reconnecting in 3s...")
            await asyncio.sleep(3)


# ── Loading Page ─────────────────────────────────────────────────────────

LOADING_HTML = """<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="2">
<style>
body { background: #0d0e11; color: #a1a1b0; font-family: system-ui;
       display: flex; align-items: center; justify-content: center;
       height: 100vh; margin: 0; }
.loader { text-align: center; }
.spinner { width: 32px; height: 32px; border: 3px solid #22232d;
           border-top: 3px solid #f97316; border-radius: 50%;
           animation: spin 1s linear infinite; margin: 0 auto 16px; }
@keyframes spin { to { transform: rotate(360deg); } }
</style>
</head><body>
<div class="loader">
<div class="spinner"></div>
<p>Starting preview server...</p>
<p style="font-size:12px;color:#5c5c6e">This page will auto-refresh</p>
</div>
</body></html>"""


# ── Request Handlers ─────────────────────────────────────────────────────

def _get_sandbox_id(request: web.Request) -> str:
    """Extract sandbox_id from Host header: jac-sbx-xxx.mars.ninja -> jac-sbx-xxx."""
    host = request.host.split(":")[0]  # strip port if present
    return host.split(".")[0]


async def health(request: web.Request) -> web.Response:
    return web.Response(text=f"ok ({len(routes)} routes)")


async def handle_request(request: web.Request) -> web.Response:
    sandbox_id = _get_sandbox_id(request)
    route = routes.get(sandbox_id)

    if not route:
        return web.Response(status=502, text="Sandbox not found", content_type="text/plain")

    if not route["ready"]:
        return web.Response(status=200, text=LOADING_HTML, content_type="text/html")

    # WebSocket upgrade
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await handle_websocket(request, route["ip"])

    # HTTP proxy
    target = f"http://{route['ip']}:{INTERNAL_PORT}{request.path_qs}"
    try:
        timeout = aiohttp.ClientTimeout(total=30)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            headers = {k: v for k, v in request.headers.items()
                       if k.lower() not in ("host", "transfer-encoding")}
            body = await request.read()
            async with session.request(
                request.method, target, headers=headers, data=body,
                allow_redirects=False,
            ) as resp:
                resp_headers = {k: v for k, v in resp.headers.items()
                                if k.lower() not in ("transfer-encoding", "connection")}
                return web.Response(
                    status=resp.status,
                    headers=resp_headers,
                    body=await resp.read(),
                )
    except Exception as e:
        log.warning(f"Proxy error for {sandbox_id}: {e}")
        return web.Response(status=502, text=f"Proxy error: {e}")


async def handle_websocket(request: web.Request, pod_ip: str) -> web.WebSocketResponse:
    """Bidirectional WebSocket proxy for Vite HMR."""
    ws_client = web.WebSocketResponse(
        protocols=[p for p in request.headers.getall("Sec-WebSocket-Protocol", [])]
    )
    await ws_client.prepare(request)

    target = f"ws://{pod_ip}:{INTERNAL_PORT}{request.path_qs}"
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(target) as ws_backend:
                async def client_to_backend():
                    async for msg in ws_client:
                        if msg.type == WSMsgType.TEXT:
                            await ws_backend.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await ws_backend.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                async def backend_to_client():
                    async for msg in ws_backend:
                        if msg.type == WSMsgType.TEXT:
                            await ws_client.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await ws_client.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                await asyncio.gather(
                    client_to_backend(),
                    backend_to_client(),
                    return_exceptions=True,
                )
    except Exception as e:
        log.warning(f"WS proxy error: {e}")

    return ws_client


# ── App Setup ────────────────────────────────────────────────────────────

async def on_startup(app: web.Application):
    app["watcher"] = asyncio.create_task(watch_pods())
    log.info(f"Sandbox proxy started on :{PROXY_PORT}")


async def on_cleanup(app: web.Application):
    app["watcher"].cancel()


app = web.Application()
app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)
app.router.add_route("*", "/_proxy/health", health)
app.router.add_route("*", "/{path_info:.*}", handle_request)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=PROXY_PORT)
