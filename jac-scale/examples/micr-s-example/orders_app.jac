"""Orders Service — entry point.

Registers order walkers as REST endpoints in Swagger.
Run standalone: jac start orders_app.jac --port 8002 --no-client
"""

sv {
    import from .services.orders { Order, OrderItem, PlaceOrder, ListOrders, GetOrder, CancelOrder }
}
