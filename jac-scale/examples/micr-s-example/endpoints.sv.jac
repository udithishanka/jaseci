"""Jac Shop — Server-Side Endpoints (Monolith Mode).

In monolith mode, all walkers from all services are registered here.
In microservice mode, each service has its own entry point (*_app.jac).
"""

# Products
import from services.products {
    Products, Product, ListProducts, GetProduct, SearchProducts
}

# Orders
import from services.orders {
    Order, PlaceOrder, ListOrders, GetOrder, CancelOrder
}

# Cart
import from services.cart {
    Cart, AddToCart, ViewCart, RemoveFromCart, ClearCart
}
