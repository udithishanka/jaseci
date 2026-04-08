"""Jac Shop — Server-Side Endpoints (Monolith Mode).

In monolith mode, all walkers from all services are registered here.
In microservice mode, each service has its own entry point (services/*_app.jac).
"""

# Products
import from .services.products {
    Product, SeedCatalog, ListProducts, GetProduct, SearchProducts
}

# Orders
import from .services.orders {
    Order, OrderItem, PlaceOrder, ListOrders, GetOrder, CancelOrder
}

# Cart
import from .services.cart {
    CartItem, AddToCart, ViewCart, RemoveFromCart, ClearCart
}
