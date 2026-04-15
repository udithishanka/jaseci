# Day 10.5: Admin Dashboard & API Docs for Microservices

## The Problem

In monolith mode, jac-scale provides:

- Admin dashboard at `/admin/` with user management, graph viz, LLM telemetry
- Swagger docs at `/docs` showing all walkers
- Graph visualization at `/graph`

In microservice mode:

- Admin dashboard is served by the gateway (already done)
- But admin API endpoints (`/admin/users`, `/admin/metrics`) need to route to a service
- Swagger docs show each service's walkers separately — no unified view
- Graph visualization shows per-service graphs — no cross-service view

## What to Build

### Admin API Passthrough

Admin endpoints should route to services:

```jac
# /admin/api/* routes should go to services
if path.startswith("/admin/") and not has_extension {
    # Admin UI SPA routes → serve index.html
} else {
    # Admin API routes → passthrough
}
```

### Unified OpenAPI Schema

The gateway should aggregate OpenAPI schemas from all services into one:

```
GET /docs → Gateway Swagger showing:
  - Products: ListProducts, GetProduct, SearchProducts
  - Orders: PlaceOrder, ListOrders, GetOrder, CancelOrder
  - Cart: AddToCart, ViewCart, RemoveFromCart, ClearCart

Each endpoint prefixed with /api/{service}/
```

Implementation:

1. Fetch `/openapi.json` from each service on startup
2. Merge schemas, adding service prefix to paths
3. Serve merged schema at gateway's `/openapi.json`

### Gateway-Level Graph View

Add a gateway graph endpoint that shows service topology:

```
GET /graph →
{
    "services": ["products", "orders", "cart"],
    "connections": [
        {"from": "orders", "to": "cart", "type": "service_call"}
    ]
}
```

## Milestone

- [ ] Admin API endpoints accessible through gateway
- [ ] Unified Swagger docs showing all services' walkers
- [ ] Gateway-level service topology view
