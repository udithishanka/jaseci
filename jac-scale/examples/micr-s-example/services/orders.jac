"""Orders Service — order management.

Endpoints:
  POST /walker/PlaceOrder   — create an order from cart items
  POST /walker/ListOrders   — list user's orders
  POST /walker/GetOrder     — get order by ID
  POST /walker/CancelOrder  — cancel an order
"""

glob order_counter: int = 0;

node OrderItem {
    has product_id: str,
        product_name: str,
        qty: int,
        price: float;
}

node Order {
    has id: str,
        status: str = "pending",
        total: float = 0.0,
        created_at: str = "";
}

walker PlaceOrder {
    """Place an order from a list of items."""
    has items: list = [];  # [{product_id, product_name, qty, price}]

    can create with Root entry {
        global order_counter;
        order_counter += 1;
        order_id = f"ord_{order_counter}";

        import from datetime { datetime, UTC }
        total: float = 0.0;
        for item in self.items {
            total += float(item.get("price", 0)) * int(item.get("qty", 1));
        }

        new_order = here ++> Order(
            id=order_id,
            status="confirmed",
            total=round(total, 2),
            created_at=str(datetime.now(UTC))
        );

        # Attach order items
        if new_order {
            order_node = new_order[0];
            for item in self.items {
                order_node ++> OrderItem(
                    product_id=item.get("product_id", ""),
                    product_name=item.get("product_name", ""),
                    qty=int(item.get("qty", 1)),
                    price=float(item.get("price", 0))
                );
            }
        }

        report {
            "id": order_id,
            "status": "confirmed",
            "total": round(total, 2),
            "item_count": len(self.items)
        };
    }
}

walker ListOrders {
    """List all orders for the current user."""
    has orders: list = [];

    can collect with Root entry {
        visit [-->];
    }

    can gather with Order entry {
        self.orders.append({
            "id": here.id,
            "status": here.status,
            "total": here.total,
            "created_at": here.created_at
        });
    }

    can done with Root exit {
        report self.orders;
    }
}

walker GetOrder {
    """Get order details by ID, including items."""
    has order_id: str;
    has found_items: list = [];

    can search with Root entry {
        visit [-->];
    }

    can check with Order entry {
        if here.id == self.order_id {
            visit [-->];
        }
    }

    can gather_item with OrderItem entry {
        self.found_items.append({
            "product_id": here.product_id,
            "product_name": here.product_name,
            "qty": here.qty,
            "price": here.price
        });
    }

    can done with Root exit {
        report self.found_items;
    }
}

walker CancelOrder {
    """Cancel an order by ID."""
    has order_id: str;

    can search with Root entry {
        visit [-->];
    }

    can cancel with Order entry {
        if here.id == self.order_id {
            if here.status == "confirmed" {
                here.status = "cancelled";
                report {"id": self.order_id, "status": "cancelled"};
            } else {
                report {"error": f"Cannot cancel order in '{here.status}' status"};
            }
        }
    }
}
