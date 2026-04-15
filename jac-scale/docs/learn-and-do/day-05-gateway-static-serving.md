# Day 5: Static File Serving & SPA Routing

## Learn (~1 hour)

### What Are Static Assets?

When you build a frontend app (React, Vue, jac-client), the output is a set of **static files**:

```
.jac/client/dist/
├── index.html          # The single HTML page
├── assets/
│   ├── app-abc123.js   # Bundled JavaScript
│   ├── app-def456.css  # Bundled CSS
│   └── logo.png        # Images, fonts, etc.
```

These files don't change at runtime — the server just reads them from disk and sends them. No processing needed.

### How Web Servers Serve Static Files

```
Client: GET /assets/app-abc123.js
         │
Server:  1. Map URL path to file path: ./dist/assets/app-abc123.js
         2. Read the file from disk
         3. Detect MIME type from extension: .js → application/javascript
         4. Send file with Content-Type header
```

**MIME types** tell the browser how to handle the file:

| Extension | MIME Type |
|-----------|-----------|
| `.html` | `text/html` |
| `.js` | `application/javascript` |
| `.css` | `text/css` |
| `.png` | `image/png` |
| `.json` | `application/json` |
| `.woff2` | `font/woff2` |

### SPA Fallback Routing

A **Single Page Application** (SPA) handles routing in the browser with JavaScript. The server only serves one HTML file — `index.html` — and the JS code shows the right "page."

**The problem**: if a user navigates to `/dashboard/settings` and refreshes, the browser sends `GET /dashboard/settings` to the server. The server has no file at that path — it only has `index.html`. Without SPA fallback, you get a 404.

**SPA fallback**: if no static file matches the path AND it's not an API route, serve `index.html` and let the client-side router handle it.

```
Request: GET /dashboard/settings
  │
  ├── Is it an API route (/api/*)? → No
  ├── Does a static file exist at dist/dashboard/settings? → No
  └── Serve dist/index.html (SPA fallback)
      └── Browser JS reads URL, renders Settings page
```

### How jac-scale Already Does This

Look at `jac_scale/impl/serve.static.impl.jac` — it already:
1. Searches multiple directories for static files
2. Detects MIME types
3. Has SPA fallback (root asset endpoint)

We'll follow the same pattern in the gateway.

---

## Do (~2-3 hours)

### Task 1: Add static serving to the Gateway

Update the gateway to serve static files AND proxy API requests.

**Update `jac_scale/microservices/gateway.jac`** — add these method signatures:

```jac
obj MicroserviceGateway {
    # ... existing fields ...
    has client_dist_dir: str = ".jac/client/dist";

    # ... existing methods ...

    """Serve a static file from the client dist directory."""
    def serve_static(file_path: str) -> Response | None;

    """Serve index.html for SPA fallback."""
    def serve_spa_fallback -> Response | None;
}
```

### Task 2: Implement static serving

**Update `jac_scale/microservices/impl/gateway.impl.jac`** — add static file handling:

```jac
import mimetypes;
import from pathlib { Path }
import from fastapi.responses { HTMLResponse }

:obj:MicroserviceGateway:can:serve_static
(file_path: str) -> Response | None {
    # Try to find the file in dist directory
    dist = Path(self.client_dist_dir);
    target = dist / file_path;

    # Security: prevent path traversal (../../etc/passwd)
    try {
        target = target.resolve();
        if not str(target).startswith(str(dist.resolve())) {
            return None;
        }
    } except Exception {
        return None;
    }

    if not target.is_file() {
        return None;
    }

    # Read file and detect MIME type
    mime_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream";

    if mime_type.startswith("text/") or mime_type in ("application/javascript", "application/json") {
        content = target.read_text();
        return Response(content=content, media_type=mime_type);
    } else {
        content = target.read_bytes();
        return Response(content=content, media_type=mime_type);
    }
}

:obj:MicroserviceGateway:can:serve_spa_fallback
-> Response | None {
    index = Path(self.client_dist_dir) / "index.html";
    if index.is_file() {
        return HTMLResponse(content=index.read_text());
    }
    return None;
}
```

### Task 3: Update the catch-all route to try static files first

Modify the `setup()` method's catch-all handler to check in this order:
1. Is it an API route? → proxy to service
2. Is it a static file? → serve it
3. Otherwise → SPA fallback (serve index.html)

```jac
# Update the catch-all in setup()
@self.app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request) -> Response {
    path = request.url.path;

    # 1. Try API proxy (if path matches a service prefix)
    entry = self.registry.match_route(path);
    if entry {
        return await self.proxy_handler(request);
    }

    # 2. Try static file (GET only)
    if request.method == "GET" {
        # Strip leading slash for file path
        file_path = path.lstrip("/");
        static_resp = self.serve_static(file_path);
        if static_resp {
            return static_resp;
        }

        # 3. SPA fallback — serve index.html for navigation requests
        accept = request.headers.get("accept", "");
        if "text/html" in accept {
            fallback = self.serve_spa_fallback();
            if fallback {
                return fallback;
            }
        }
    }

    return JSONResponse(status_code=404, content={"error": "Not found", "path": path});
}
```

### Task 4: Create a test client build

Create a minimal static client to test with:

```bash
mkdir -p test-microservices/.jac/client/dist/assets
```

**`test-microservices/.jac/client/dist/index.html`**
```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Test Microservice Client</title>
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <div id="app">
    <h1>Microservice Client</h1>
    <p>Current path: <span id="path"></span></p>
    <nav>
      <a href="/dashboard">Dashboard</a> |
      <a href="/orders">Orders</a>
    </nav>
  </div>
  <script src="/assets/app.js"></script>
</body>
</html>
```

**`test-microservices/.jac/client/dist/assets/app.js`**
```javascript
document.getElementById('path').textContent = window.location.pathname;
```

**`test-microservices/.jac/client/dist/assets/app.css`**
```css
body { font-family: system-ui; max-width: 600px; margin: 2rem auto; }
nav { margin-top: 1rem; }
```

### Task 5: Test the full routing

Start the gateway and verify all three routing modes:

```bash
# Terminal 1: Start services (you can use the Day 3 test script)
# Terminal 2: Start gateway on :8000

# Test API proxy:
curl http://localhost:8000/api/orders/list_orders
# → Should proxy to orders service

# Test static file:
curl http://localhost:8000/assets/app.js
# → Should return the JavaScript file

# Test SPA fallback:
curl -H "Accept: text/html" http://localhost:8000/dashboard
# → Should return index.html (even though /dashboard doesn't exist as a file)

# Test 404:
curl http://localhost:8000/api/nonexistent/thing
# → Should return 404 JSON
```

---

## Milestone

- [ ] Gateway serves static files from `.jac/client/dist/` with correct MIME types
- [ ] SPA fallback: unknown HTML paths serve `index.html`
- [ ] Path traversal attack blocked (can't request `../../etc/passwd`)
- [ ] Routing priority works: API routes → static files → SPA fallback → 404
- [ ] Opening `http://localhost:8000/` in a browser shows the test HTML page

**You now understand**: how static file serving works, what SPA fallback routing is and why you need it, and how to combine API proxying with static serving in one gateway. Tomorrow you add JWT auth.
