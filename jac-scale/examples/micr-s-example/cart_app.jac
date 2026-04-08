"""Cart Service — entry point.

Registers cart walkers as REST endpoints in Swagger.
Run standalone: jac start cart_app.jac --port 8003 --no-client
"""

sv {
    import from .services.cart { CartItem, AddToCart, ViewCart, RemoveFromCart, ClearCart }
}
