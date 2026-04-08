"""Products Service — entry point.

Registers product walkers as REST endpoints in Swagger.
Run standalone: jac start products_app.jac --port 8001 --no-client
"""

sv {
    import from .services.products { Product, SeedCatalog, ListProducts, GetProduct, SearchProducts }
}
