"""Orders service — manages order creation and listing."""

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
