# Day 1: What Are Microservices?

## Learn (~1 hour)

### The Core Idea

A **monolith** is one big application where all features live in a single process:

```
┌─────────────────────────────────┐
│         Single Process          │
│  Orders + Users + Payments +    │
│  Auth + Admin + everything      │
└─────────────────────────────────┘
```

This is what `jac start app.jac` does today — one process, one `ModuleIntrospector`, all walkers share a namespace.

**Microservices** decompose this into independent processes that talk over the network:

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Orders  │  │  Users   │  │ Payments │
│  :8001   │  │  :8002   │  │  :8003   │
└──────────┘  └──────────┘  └──────────┘
      ▲            ▲             ▲
      └────────────┼─────────────┘
                   │
            ┌──────────────┐
            │   Gateway    │
            │   :8000      │
            └──────────────┘
                   ▲
                   │
                Client
```

### Why Would You Want This?

| Benefit | What it means |
|---------|--------------|
| **Independent deployment** | Update orders without restarting payments |
| **Fault isolation** | Orders crashes, payments keeps running |
| **Independent scaling** | Scale payments to 10 instances, keep orders at 1 |
| **Team ownership** | Team A owns orders.jac, Team B owns payments.jac |

### Why Would You NOT Want This?

| Downside | What it means |
|----------|--------------|
| **Network complexity** | Services talk over HTTP instead of function calls — slower, can fail |
| **Data consistency** | No shared database transactions across services |
| **Operational overhead** | More processes to monitor, deploy, debug |
| **Overkill for small apps** | A 500-line app doesn't need to be split |

This is why **microservice mode is off by default** in our design. Most Jac apps are fine as monoliths.

### The API Gateway Pattern

The **gateway** is the single entry point that clients talk to. It:
1. Receives all HTTP requests
2. Matches the URL path to the right service
3. Forwards (proxies) the request to that service
4. Returns the response to the client

The client never talks to services directly — it only knows the gateway URL.

```
Client: GET /api/orders/list
         │
         ▼
Gateway: "path starts with /api/orders → forward to Orders service"
         │
         ▼
Orders:  GET /walker/list → executes walker → returns JSON
```

### Key Concept: Path-Based Routing

Each service "owns" a URL prefix:
- `/api/orders/*` → Orders service
- `/api/users/*` → Users service
- `/api/payments/*` → Payments service

The gateway strips the prefix and forwards the remainder.

### Reading (optional)

- [microservices.io — What are Microservices?](https://microservices.io/patterns/microservices.html) (10 min)
- [microservices.io — API Gateway pattern](https://microservices.io/patterns/apigateway.html) (10 min)

---

## Do (~2-3 hours)

### Task 1: Create the module skeleton

Create the directory structure for the microservices module:

```bash
mkdir -p jac_scale/microservices/impl
```

Create empty init file:

**`jac_scale/microservices/__init__.jac`**
```jac
"""Microservice mode — decomposes a Jac project into independent service processes."""
```

### Task 2: Add TOML config schema

Open `jac_scale/plugin_config.jac` and add the `microservices` section to the config schema (inside `get_config_schema`'s return dict, under `"options"`):

```jac
"microservices": {
    "type": "dict",
    "default": {},
    "description": "Microservice mode — run declared Jac files as independent service processes behind an API gateway",
    "nested": {
        "enabled": {
            "type": "bool",
            "default": False,
            "description": "Enable microservice mode (off by default)"
        },
        "gateway_port": {
            "type": "int",
            "default": 8000,
            "description": "Gateway port (external-facing)"
        },
        "gateway_host": {
            "type": "string",
            "default": "0.0.0.0",
            "description": "Gateway host"
        },
        "services": {
            "type": "dict",
            "default": {},
            "description": "Service declarations — each key is a service name, value has file, prefix, port, env"
        },
        "client": {
            "type": "dict",
            "default": {},
            "description": "Client UI build settings",
            "nested": {
                "entry": {
                    "type": "string",
                    "default": "",
                    "description": "jac-client entry point (e.g., client/main.jac)"
                },
                "dist_dir": {
                    "type": "string",
                    "default": ".jac/client/dist",
                    "description": "Build output directory"
                },
                "base_route": {
                    "type": "string",
                    "default": "/",
                    "description": "SPA base route"
                }
            }
        }
    }
}
```

### Task 3: Create the test project

Create a test project you'll use throughout the 10 days:

```bash
mkdir -p test-microservices/services test-microservices/shared test-microservices/client
```

**`test-microservices/services/orders.jac`**
```jac
walker list_orders {
    can process with `root entry {
        report [
            {"id": 1, "item": "Widget", "qty": 3},
            {"id": 2, "item": "Gadget", "qty": 1}
        ];
    }
}

walker create_order {
    has item: str, qty: int = 1;

    can process with `root entry {
        report {"id": 3, "item": self.item, "qty": self.qty, "status": "created"};
    }
}
```

**`test-microservices/services/payments.jac`**
```jac
walker charge {
    has amount: float, currency: str = "USD";

    can process with `root entry {
        report {"charge_id": "ch_123", "amount": self.amount, "currency": self.currency, "status": "succeeded"};
    }
}

walker refund {
    has charge_id: str;

    can process with `root entry {
        report {"refund_id": "rf_456", "charge_id": self.charge_id, "status": "refunded"};
    }
}
```

**`test-microservices/shared/models.jac`**
```jac
"""Shared types used by multiple services."""

obj Order {
    has id: int,
        item: str,
        qty: int = 1,
        status: str = "pending";
}

obj Payment {
    has charge_id: str,
        amount: float,
        currency: str = "USD",
        status: str = "pending";
}
```

**`test-microservices/jac.toml`**
```toml
[plugins.scale.microservices]
enabled = true

[plugins.scale.microservices.services.orders]
file = "services/orders.jac"
prefix = "/api/orders"

[plugins.scale.microservices.services.payments]
file = "services/payments.jac"
prefix = "/api/payments"
```

### Task 4: Verify config loading

Test that your new config section parses correctly:

```bash
cd test-microservices
python -c "
from jac_scale.config_loader import get_scale_config
config = get_scale_config()
ms = config.get('microservices', {})
print('enabled:', ms.get('enabled', False))
print('services:', list(ms.get('services', {}).keys()))
"
```

Expected output:
```
enabled: True
services: ['orders', 'payments']
```

---

## Milestone

- [ ] `jac_scale/microservices/` directory exists with `__init__.jac`
- [ ] `plugin_config.jac` has the `microservices` schema section
- [ ] `test-microservices/` project exists with two service files and a `jac.toml`
- [ ] Config loading works — you can read `microservices.enabled` and `microservices.services` from TOML

**You now understand**: what microservices are, when to use them, what an API gateway does, and you have the foundation to build on.
