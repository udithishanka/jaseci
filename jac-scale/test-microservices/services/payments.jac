"""Payments service — handles charges and refunds."""

walker charge {
    has amount: float, currency: str = "USD";

    can process with `root entry {
        report {
            "charge_id": "ch_123",
            "amount": self.amount,
            "currency": self.currency,
            "status": "succeeded"
        };
    }
}

walker refund {
    has charge_id: str;

    can process with `root entry {
        report {
            "refund_id": "rf_456",
            "charge_id": self.charge_id,
            "status": "refunded"
        };
    }
}
