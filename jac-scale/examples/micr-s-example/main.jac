"""jac-shop — E-Commerce Microservice App.

In microservice mode (jac.toml microservices.enabled = true):
  - Products, Orders, Cart each run as separate service processes
  - Gateway serves client UI and proxies API calls to services
  - Run: jac start main.jac (launches gateway + 3 services)

In monolith mode (microservices.enabled = false):
  - All endpoints run in a single process
  - Run: jac start main.jac
"""

# Server-side endpoints — all walkers registered for monolith mode
sv {
    import from endpoints {
        Products, Product, ListProducts, GetProduct, SearchProducts,
        Order, PlaceOrder, ListOrders, GetOrder, CancelOrder,
        Cart, AddToCart, ViewCart, RemoveFromCart, ClearCart
    }
}

# Client-side UI
cl {
    import from .frontend { app as ClientApp }

    def:pub app -> any {
        return
            <ClientApp />;
    }
}
