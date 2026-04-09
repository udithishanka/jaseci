"""Orders Service — order management.

Graph: Root --> Orders --> [Order, Order, ...]
Each Order has items as a list in has field.
"""

glob order_counter: int = 0;

node Orders {}

node Order {
    has id: str,
        items: list = [],
        total: float = 0.0,
        status: str = "pending",
        created_at: str = "";
}

walker PlaceOrder {
    """Place an order — calls cart service to get items, creates order, clears cart."""
    has auth_token: str = "";

    can enter_root with Root entry {
        import from jac_scale.microservices.service_client { service_call }

        auth_header: str = self.auth_token;

        # 1. Call cart service to get items (inter-service call)
        cart_resp = service_call(
            service="cart",
            endpoint="walker/ViewCart",
            auth_token=auth_header
        );

        if cart_resp.status != 200 {
            report {"error": "Failed to fetch cart", "status": cart_resp.status};
            disengage;
        }

        cart_data = cart_resp.json();
        cart_reports = cart_data.get("data", {}).get("reports", []);
        if not cart_reports or not cart_reports[0].get("items") {
            report {"error": "Cart is empty"};
            disengage;
        }

        items = cart_reports[0]["items"];

        # 2. Create order
        global order_counter;
        order_counter += 1;
        order_id = f"ord_{order_counter}";

        import from datetime { datetime, UTC }
        total: float = 0.0;
        for item in items {
            total += float(item.get("price", 0)) * int(item.get("qty", 1));
        }

        # Find or create Orders anchor
        orders_anchor: Orders | None = None;
        for node in [-->] {
            if isinstance(node, Orders) {
                orders_anchor = node;
            }
        }
        if orders_anchor is None {
            new_nodes = here ++> Orders();
            orders_anchor = new_nodes[0];
        }

        orders_anchor ++> Order(
            id=order_id,
            items=items,
            total=round(total, 2),
            status="confirmed",
            created_at=str(datetime.now(UTC))
        );

        # 3. Clear cart (inter-service call)
        service_call(
            service="cart",
            endpoint="walker/ClearCart",
            auth_token=auth_header
        );

        report {
            "id": order_id,
            "status": "confirmed",
            "total": round(total, 2),
            "item_count": len(items)
        };
    }
}

walker ListOrders {
    """List all orders."""
    has orders_list: list = [];

    can enter_root with Root entry {
        for node in [-->] {
            if isinstance(node, Orders) {
                for o in [node -->] {
                    if isinstance(o, Order) {
                        self.orders_list.append({
                            "id": o.id,
                            "status": o.status,
                            "total": o.total,
                            "item_count": len(o.items),
                            "created_at": o.created_at
                        });
                    }
                }
            }
        }
        report self.orders_list;
    }
}

walker GetOrder {
    """Get order by ID."""
    has order_id: str;

    can enter_root with Root entry {
        for node in [-->] {
            if isinstance(node, Orders) {
                for o in [node -->] {
                    if isinstance(o, Order) and o.id == self.order_id {
                        report {
                            "id": o.id,
                            "status": o.status,
                            "total": o.total,
                            "items": o.items,
                            "created_at": o.created_at
                        };
                        disengage;
                    }
                }
            }
        }
        report {"error": "Order not found"};
    }
}

walker CancelOrder {
    """Cancel an order by ID."""
    has order_id: str;

    can enter_root with Root entry {
        for node in [-->] {
            if isinstance(node, Orders) {
                for o in [node -->] {
                    if isinstance(o, Order) and o.id == self.order_id {
                        if o.status == "confirmed" {
                            o.status = "cancelled";
                            report {"id": self.order_id, "status": "cancelled"};
                        } else {
                            report {"error": f"Cannot cancel order in '{o.status}' status"};
                        }
                        disengage;
                    }
                }
            }
        }
        report {"error": "Order not found"};
    }
}
