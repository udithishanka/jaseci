# Day 15: Data Consistency Across Services

## Learn (~1 hour)

### The Biggest Microservice Problem

In a monolith with one database, you use **transactions**:

```sql
BEGIN;
  INSERT INTO orders (item, qty) VALUES ('Widget', 3);
  UPDATE inventory SET qty = qty - 3 WHERE item = 'Widget';
  INSERT INTO payments (amount) VALUES (29.97);
COMMIT;  -- all or nothing
```

In microservices, each service has its own data. There's **no cross-service transaction**. What if orders succeeds but payments fails?

### The Saga Pattern

A **saga** is a sequence of local transactions across services. If one step fails, you run **compensating transactions** to undo previous steps.

```
Happy path:
  1. Orders: create order (status=pending)     ✓
  2. Payments: charge card                      ✓
  3. Inventory: reserve stock                   ✓
  4. Orders: update order (status=confirmed)    ✓

Failure at step 3:
  1. Orders: create order (status=pending)      ✓
  2. Payments: charge card                      ✓
  3. Inventory: reserve stock                   ✗ (out of stock!)
  Compensate:
  C2. Payments: refund charge                   ✓
  C1. Orders: cancel order                      ✓
```

### Two Saga Styles

| Style | How it works | Coordination |
|-------|-------------|-------------|
| **Choreography** | Each service emits events; next service reacts | Decentralized — no coordinator |
| **Orchestration** | A central "saga coordinator" tells each service what to do | Centralized — easier to follow |

**For our jac-scale implementation**: orchestration is simpler. The calling service acts as the coordinator.

### Eventual Consistency

In microservices, data is **eventually consistent** — there's a brief window where services disagree:

```
Time 0:  Orders=pending,   Payments=none       (order created)
Time 1:  Orders=pending,   Payments=charged    (payment processed)
Time 2:  Orders=confirmed, Payments=charged    (order updated) ← consistent!
```

Between Time 0 and Time 2, the system is inconsistent but will converge. This is fine for most use cases — you just need to handle the interim states.

### Idempotency

Network retries mean a service might receive the **same request twice**. The service must produce the same result regardless:

```
POST /walker/charge {amount: 50, idempotency_key: "order-123-payment"}

First call:  charge $50, return charge_id="ch_abc"
Retry:       see idempotency_key exists, return same charge_id="ch_abc" (no double charge!)
```

**Idempotency keys** prevent duplicate processing.

---

## Do (~2-3 hours)

### Task 1: Implement a saga coordinator

```jac
"""Saga pattern implementation for multi-service transactions."""

import logging;

glob logger = logging.getLogger(__name__);

obj SagaStep {
    has name: str,
        service: str,
        endpoint: str,
        body: dict = {},
        compensate_endpoint: str = "",   # endpoint to call on rollback
        compensate_body: dict = {},
        result: dict | None = None,
        executed: bool = False;
}

obj Saga {
    has name: str,
        steps: list[SagaStep] = [],
        executed_steps: list[SagaStep] = [],
        internal_token: str = "";

    """Add a step to the saga."""
    def add_step(
        name: str, service: str, endpoint: str, body: dict = {},
        compensate_endpoint: str = "", compensate_body: dict = {}
    ) -> 'Saga';

    """Execute all steps. If any fails, compensate all previous steps."""
    async def execute -> tuple[bool, dict];
}
```

### Task 2: Implement saga execution

```jac
import from jac_scale.microservices.client { service_call }

:obj:Saga:can:add_step
(name: str, service: str, endpoint: str, body: dict = {},
 compensate_endpoint: str = "", compensate_body: dict = {}) -> Saga {
    self.steps.append(SagaStep(
        name=name, service=service, endpoint=endpoint, body=body,
        compensate_endpoint=compensate_endpoint, compensate_body=compensate_body
    ));
    return self;  # allow chaining
}

:obj:Saga:can:execute
-> tuple[bool, dict] {
    results: dict = {};

    for step in self.steps {
        logger.info(f"Saga '{self.name}' executing step: {step.name}");

        resp = await service_call(
            service=step.service,
            endpoint=step.endpoint,
            body=step.body,
            internal_token=self.internal_token
        );

        if resp.status >= 400 {
            logger.error(f"Saga '{self.name}' step '{step.name}' failed: {resp.status}");
            # Compensate all executed steps in reverse
            await self._compensate();
            return (False, {"failed_step": step.name, "error": resp.text(), "compensated": True});
        }

        step.result = resp.json();
        step.executed = True;
        self.executed_steps.append(step);
        results[step.name] = step.result;
    }

    logger.info(f"Saga '{self.name}' completed successfully");
    return (True, results);
}

async def _compensate(self: Saga) -> None {
    for step in reversed(self.executed_steps) {
        if step.compensate_endpoint {
            logger.info(f"Saga '{self.name}' compensating: {step.name}");
            # Include the original result so the service knows what to undo
            comp_body = {**step.compensate_body};
            if step.result {
                comp_body["original_result"] = step.result;
            }
            await service_call(
                service=step.service,
                endpoint=step.compensate_endpoint,
                body=comp_body,
                internal_token=self.internal_token
            );
        }
    }
}
```

### Task 3: Use saga in order creation

```jac
# In orders.jac
walker create_order_saga {
    has item: str, qty: int, amount: float;

    can process with `root entry {
        saga = Saga(name="create-order", internal_token=self._get_internal_token());

        saga.add_step(
            name="reserve_stock",
            service="inventory",
            endpoint="/reserve",
            body={"item": self.item, "qty": self.qty},
            compensate_endpoint="/release",
            compensate_body={"item": self.item, "qty": self.qty}
        ).add_step(
            name="charge_payment",
            service="payments",
            endpoint="/charge",
            body={"amount": self.amount, "idempotency_key": f"order-{self.item}-{time.time()}"},
            compensate_endpoint="/refund",
            compensate_body={}
        );

        success, results = await saga.execute();

        if success {
            report {"order": "confirmed", "steps": results};
        } else {
            report {"order": "failed", "reason": results};
        }
    }
}
```

### Task 4: Add idempotency to payments service

```jac
# In payments.jac — prevent duplicate charges

glob _processed_keys: dict[str, dict] = {};  # idempotency_key → result

walker charge {
    has amount: float, currency: str = "USD", idempotency_key: str = "";

    can process with `root entry {
        # Check idempotency
        if self.idempotency_key and self.idempotency_key in _processed_keys {
            report _processed_keys[self.idempotency_key];
            return;
        }

        # Process charge
        result = {"charge_id": f"ch_{uuid4()}", "amount": self.amount, "status": "succeeded"};

        # Store for idempotency
        if self.idempotency_key {
            _processed_keys[self.idempotency_key] = result;
        }

        report result;
    }
}
```

---

## Milestone

- [ ] Saga coordinator executes steps sequentially, compensates on failure
- [ ] Saga compensation runs in reverse order
- [ ] Idempotency keys prevent duplicate processing in payments
- [ ] Order creation saga: reserve → charge → confirm (or rollback)
- [ ] Understand eventual consistency and when it's acceptable

**You now understand**: why cross-service transactions don't exist, how the saga pattern provides eventual consistency with compensation, the difference between choreography and orchestration, and why idempotency is critical for reliable inter-service calls.
