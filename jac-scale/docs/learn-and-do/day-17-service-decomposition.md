# Day 17: Service Decomposition — When & How to Split

## Learn (~1 hour)

### The Hardest Question in Microservices

"How do I decide what should be a separate service?"

Split too much → distributed monolith (all the pain, none of the benefits)
Split too little → you're still a monolith

### Domain-Driven Design (DDD) — The Guide

**Bounded Contexts** from DDD are the best guide for service boundaries:

A bounded context is an area of the business where:
- Terms have specific meanings ("Order" in shipping means something different than in billing)
- Data is owned by one team
- Changes are independent from other areas

```
E-commerce example:

┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│   Catalog    │  │   Orders    │  │  Payments   │  │  Shipping   │
│             │  │             │  │             │  │             │
│ Product     │  │ Order       │  │ Charge      │  │ Shipment    │
│ Category    │  │ LineItem    │  │ Refund      │  │ Tracking    │
│ Price       │  │ Cart        │  │ Invoice     │  │ Address     │
└─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘

Each box = bounded context = potential service
```

### Signs You Should Split

| Signal | Example |
|--------|---------|
| **Different change rates** | Auth changes rarely, orders changes weekly |
| **Different scaling needs** | Search gets 100x more traffic than admin |
| **Team ownership** | Team A owns auth, Team B owns billing |
| **Independent deployability** | You want to ship payments fix without testing orders |
| **Data isolation** | Payment card data must be in a separate, audited system |

### Signs You Should NOT Split

| Signal | Example |
|--------|---------|
| **Tight coupling** | Service A can't do anything without calling B first |
| **Shared mutable state** | Both services read/write the same DB table |
| **Single team** | One person maintains both — splitting adds overhead |
| **Simple CRUD** | A service that just wraps a database table |
| **Premature** | You're splitting because "microservices are cool" |

### The Strangler Fig Pattern

Don't rewrite from scratch. Migrate incrementally:

```
Phase 1: Monolith handles everything
┌─────────────────────────────┐
│  orders + payments + users  │
└─────────────────────────────┘

Phase 2: Extract one service, proxy the rest
┌─────────────────────────────┐     ┌────────────┐
│  orders + users             │────►│  payments   │
│  (payments calls go to new  │     │  (new svc)  │
│   service via gateway)      │     └────────────┘
└─────────────────────────────┘

Phase 3: Extract more
┌──────────┐  ┌────────────┐  ┌────────────┐
│  orders  │  │  payments  │  │   users    │
└──────────┘  └────────────┘  └────────────┘
```

In jac-scale terms:
1. Start with `jac start app.jac` (monolith)
2. Move payments walkers to `services/payments.jac`
3. Enable microservice mode, declare payments as a service
4. The rest stays in the monolith until ready to extract

---

## Do (~2-3 hours)

### Task 1: Analyze a real Jac app for decomposition

Take your test project (or any real Jac app) and identify bounded contexts:

```
Exercise: Given this monolith app.jac with these walkers:

  - list_products, search_products, get_product
  - create_order, get_order, cancel_order
  - charge_payment, refund_payment, get_payment_history
  - register_user, login, update_profile
  - send_notification, get_notifications

Group them into bounded contexts:
  Catalog:      list_products, search_products, get_product
  Orders:       create_order, get_order, cancel_order
  Payments:     charge_payment, refund_payment, get_payment_history
  Auth/Users:   register_user, login, update_profile
  Notifications: send_notification, get_notifications
```

### Task 2: Document the dependency graph

Draw which services call which:

```
Orders → Payments (charge on order creation)
Orders → Notifications (notify on order status change)
Orders → Catalog (get product price)
Auth → Notifications (send welcome email)

Critical path: Orders → Payments (synchronous, must succeed)
Non-critical: Orders → Notifications (can fail gracefully)
```

### Task 3: Practice strangler fig extraction

Start with a monolith, extract one service:

**Before** — `app.jac`:
```jac
walker list_orders { ... }
walker create_order { ... }
walker charge_payment { ... }
walker refund_payment { ... }
```

**After** — extract payments:

`app.jac` (keeps orders):
```jac
walker list_orders { ... }
walker create_order {
    # Now calls payments via service_call instead of direct
    can process with `root entry {
        charge = await service_call("payments", "/charge", body={...});
        ...
    }
}
```

`services/payments.jac` (extracted):
```jac
walker charge { ... }   # same code, moved here
walker refund { ... }   # same code, moved here
```

`jac.toml`:
```toml
[plugins.scale.microservices]
enabled = true

[plugins.scale.microservices.services.payments]
file = "services/payments.jac"
prefix = "/api/payments"
```

### Task 4: Create a decomposition checklist

Write a checklist for your jac-scale projects:

```markdown
## Service Decomposition Checklist

Before extracting a service, verify:

- [ ] The walkers/functions have a clear bounded context
- [ ] The data they use can be isolated (own DB collections)
- [ ] The interface between this and other services is small (few endpoints)
- [ ] There's a clear owner (person/team)
- [ ] The service can fail independently without breaking critical paths
- [ ] You've identified all callers and can add service_call() to them
- [ ] You have contract tests for the interface
- [ ] The service has its own health check
- [ ] You've tested the extracted service independently

After extracting:
- [ ] Monolith tests still pass
- [ ] New service tests pass
- [ ] E2E tests pass
- [ ] Performance is acceptable (network hop added)
```

---

## Milestone

- [ ] Can identify bounded contexts in a Jac app
- [ ] Can draw a dependency graph between services
- [ ] Successfully extracted one service using the strangler fig pattern
- [ ] Created a decomposition checklist for future use
- [ ] Understand when NOT to split (just as important as knowing when to split)

**You now understand**: Domain-Driven Design's bounded contexts as the guide for service boundaries, the strangler fig pattern for incremental migration, how to analyze dependencies between services, and the warning signs of premature decomposition.
