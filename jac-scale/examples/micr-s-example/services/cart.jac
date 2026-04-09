"""Cart Service — shopping cart management.

Endpoints:
  POST /walker/AddToCart     — add item to cart
  POST /walker/ViewCart      — view cart contents
  POST /walker/RemoveFromCart — remove item from cart
  POST /walker/ClearCart     — empty the cart
"""

node CartItem {
    has product_id: str,
        product_name: str,
        price: float,
        qty: int = 1;
}

walker AddToCart {
    """Add a product to the cart. If already in cart, increments qty."""
    has product_id: str, product_name: str = "", price: float = 0.0, qty: int = 1;

    can add with Root entry {
        # Check if product already in cart
        visit [-->];

        # Not found — add new item
        here ++> CartItem(
            product_id=self.product_id,
            product_name=self.product_name,
            price=self.price,
            qty=self.qty
        );
        report {
            "action": "added",
            "product_id": self.product_id,
            "product_name": self.product_name,
            "qty": self.qty
        };
    }

    can check_existing with CartItem entry {
        if here.product_id == self.product_id {
            here.qty += self.qty;
            report {
                "action": "updated",
                "product_id": self.product_id,
                "qty": here.qty
            };
            disengage;
        }
    }
}

walker ViewCart {
    """View all items in the cart with total."""
    has items: list = [];
    has total: float = 0.0;

    can collect with Root entry {
        visit [-->];
    }

    can gather with CartItem entry {
        line_total: float = here.price * float(here.qty);
        self.items.append({
            "product_id": here.product_id,
            "product_name": here.product_name,
            "price": here.price,
            "qty": here.qty,
            "line_total": round(line_total, 2)
        });
        self.total += line_total;
    }

    can done with Root exit {
        report {
            "items": self.items,
            "total": round(self.total, 2),
            "item_count": len(self.items)
        };
    }
}

walker RemoveFromCart {
    """Remove a product from the cart."""
    has product_id: str;

    can search with Root entry {
        for node in [-->] {
            if isinstance(node, CartItem) and node.product_id == self.product_id {
                here del --> node;
                report {"action": "removed", "product_id": self.product_id};
                disengage;
            }
        }
    }
}

walker ClearCart {
    """Remove all items from the cart."""

    can clear with Root entry {
        items = [-->];
        cleared: int = 0;
        for node in items {
            if isinstance(node, CartItem) {
                here del --> node;
                cleared += 1;
            }
        }
        report {"action": "cleared", "items_removed": cleared};
    }
}
