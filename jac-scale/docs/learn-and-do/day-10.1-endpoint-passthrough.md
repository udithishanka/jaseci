# Day 10.1: Complete Endpoint Passthrough

## What's Missing

The gateway currently passes through: `/user/*`, `/cl/*`, `/walker/*`, `/function/*`, `/healthz`, `/graph`

But jac-scale has 51 built-in endpoints. Missing from passthrough:

| Missing Route | What it does |
|---------------|-------------|
| `/sso/*` | SSO login/register (Google, Apple, GitHub) |
| `/api-key/*` | API key management for webhooks |
| `/graph/data` | Graph JSON data endpoint |
| `/webhook/*` | Webhook walker endpoints |
| `/ws/*` | WebSocket walker endpoints |
| `/jobs/*` | Scheduler job management |
| `/metrics` | Prometheus metrics |
| `/docs` | Swagger UI |
| `/openapi.json` | OpenAPI schema |
| `/static/client.js` | Client JS bundle |

## Do

Update the gateway's `is_builtin` check to cover all jac-scale routes:

```jac
is_builtin = path.startswith((
    "/user/", "/cl/", "/walker/", "/function/",
    "/sso/", "/api-key/", "/webhook/", "/ws/",
    "/jobs/", "/static/", "/graph"
)) or path in (
    "/user", "/healthz", "/graph", "/metrics",
    "/docs", "/openapi.json", "/redoc"
);
```

## Milestone
- [ ] All 51 jac-scale built-in endpoints accessible through gateway
- [ ] SSO, webhooks, scheduler, metrics all work via gateway
