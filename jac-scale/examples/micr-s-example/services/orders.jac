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
    """Place an order — fetches cart from cart service, creates order, clears cart.

    This is an example of inter-service communication:
    Orders service calls Cart service via service_call() through the gateway.
    Pass Authorization header as auth_token for token propagation.
    """
    has auth_token: str = "";

    can create with Root entry {
        import from jac_scale.microservices.service_client { service_call }

        auth_header: str = self.auth_token;

        # 1. Call cart service to get cart items (inter-service call)
        cart_resp = service_call(
            service="cart",
            endpoint="walker/ViewCart",
            auth_token=auth_header,
            gateway_url="http://127.0.0.1:8000"
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

        # 2. Create the order
        global order_counter;
        order_counter += 1;
        order_id = f"ord_{order_counter}";

        import from datetime { datetime, UTC }
        total: float = 0.0;
        for item in items {
            total += float(item.get("price", 0)) * int(item.get("qty", 1));
        }

        new_order = here ++> Order(
            id=order_id,
            status="confirmed",
            total=round(total, 2),
            created_at=str(datetime.now(UTC))
        );

        if new_order {
            order_node = new_order[0];
            for item in items {
                order_node ++> OrderItem(
                    product_id=str(item.get("product_id", "")),
                    product_name=str(item.get("product_name", "")),
                    qty=int(item.get("qty", 1)),
                    price=float(item.get("price", 0))
                );
            }
        }

        # 3. Call cart service to clear cart (inter-service call)
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
