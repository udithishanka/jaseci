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
        Product, SeedCatalog, ListProducts, GetProduct, SearchProducts,
        Order, OrderItem, PlaceOrder, ListOrders, GetOrder, CancelOrder,
        CartItem, AddToCart, ViewCart, RemoveFromCart, ClearCart
    }
}

# Client-side UI — served as static SPA by the gateway (or jac-client in monolith)
cl {
    import from .frontend { app as ClientApp }

    def:pub app -> any {
        return
            <ClientApp />;
    }
}
