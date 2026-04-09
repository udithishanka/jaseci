"""Cart Service — shopping cart.

Graph: Root --> Cart (has items: list of {product_id, product_name, price, qty})
"""

node Cart {
    has items: list = [];
}

walker AddToCart {
    """Add a product to the cart."""
    has product_id: str, product_name: str = "", price: float = 0.0, qty: int = 1;

    can enter_root with Root entry {
        carts = [-->][?:Cart];
        cart: Cart;
        if not carts {
            cart = (here ++> Cart())[0];
        } else {
            cart = carts[0];
        }

        # Check if product already in cart
        for item in cart.items {
            if item.get("product_id") == self.product_id {
                item["qty"] = item.get("qty", 0) + self.qty;
                report {"action": "updated", "product_id": self.product_id, "qty": item["qty"]};
                disengage;
            }
        }

        cart.items.append({
            "product_id": self.product_id,
            "product_name": self.product_name,
            "price": self.price,
            "qty": self.qty
        });
        report {"action": "added", "product_id": self.product_id, "qty": self.qty};
    }
}

walker ViewCart {
    """View cart contents with total."""

    can enter_root with Root entry {
        carts = [-->][?:Cart];
        if not carts {
            report {"items": [], "total": 0, "item_count": 0};
            disengage;
        }
        cart: Cart = carts[0];

        total: float = 0.0;
        display_items: list = [];
        for item in cart.items {
            line_total: float = float(item.get("price", 0)) * int(item.get("qty", 1));
            display_items.append({
                "product_id": item.get("product_id", ""),
                "product_name": item.get("product_name", ""),
                "price": item.get("price", 0),
                "qty": item.get("qty", 1),
                "line_total": round(line_total, 2)
            });
            total += line_total;
        }
        report {"items": display_items, "total": round(total, 2), "item_count": len(cart.items)};
    }
}

walker RemoveFromCart {
    """Remove a product from the cart."""
    has product_id: str;

    can enter_root with Root entry {
        carts = [-->][?:Cart];
        if not carts {
            report {"error": "Cart not found"};
            disengage;
        }
        cart: Cart = carts[0];

        new_items: list = [];
        for item in cart.items {
            if item.get("product_id") != self.product_id {
                new_items.append(item);
            }
        }
        cart.items = new_items;
        report {"action": "removed", "product_id": self.product_id};
    }
}

walker ClearCart {
    """Empty the cart."""

    can enter_root with Root entry {
        carts = [-->][?:Cart];
        if not carts {
            report {"action": "cleared", "items_removed": 0};
            disengage;
        }
        cart: Cart = carts[0];
        cleared: int = len(cart.items);
        cart.items = [];
        report {"action": "cleared", "items_removed": cleared};
    }
}
