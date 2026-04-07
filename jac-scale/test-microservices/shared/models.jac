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
