"""Products Service — product catalog.

Graph: Root --> Products --> [Product, Product, ...]
"""

node Products {}

node Product {
    has id: str,
        name: str,
        price: float,
        description: str = "",
        stock: int = 0;
}

glob CATALOG: list[dict] = [
    {"id": "prod_1", "name": "Wireless Headphones", "price": 49.99, "stock": 25, "description": "Bluetooth over-ear headphones"},
    {"id": "prod_2", "name": "USB-C Hub", "price": 34.99, "stock": 50, "description": "7-in-1 USB-C hub with HDMI"},
    {"id": "prod_3", "name": "Mechanical Keyboard", "price": 89.99, "stock": 15, "description": "RGB mechanical keyboard"},
    {"id": "prod_4", "name": "Laptop Stand", "price": 29.99, "stock": 40, "description": "Adjustable aluminum laptop stand"},
    {"id": "prod_5", "name": "Webcam HD", "price": 59.99, "stock": 30, "description": "1080p webcam with microphone"}
];

walker ListProducts {
    """List all products."""

    can enter_root with Root entry {
        products_nodes = [-->][?:Products];

        if not products_nodes {
            # Seed on first access
            anchor = (here ++> Products())[0];
            for p in CATALOG {
                anchor ++> Product(
                    id=p["id"], name=p["name"], price=p["price"],
                    stock=p["stock"], description=p["description"]
                );
            }
            products_nodes = [-->][?:Products];
        }

        items: list = [];
        for pnode in products_nodes {
            for p in [pnode -->][?:Product] {
                items.append({
                    "id": p.id, "name": p.name, "price": p.price,
                    "description": p.description, "stock": p.stock
                });
            }
        }
        report items;
    }
}

walker GetProduct {
    """Get a product by ID."""
    has product_id: str;

    can enter_root with Root entry {
        for pnode in [-->][?:Products] {
            for p in [pnode -->][?:Product] {
                if p.id == self.product_id {
                    report {
                        "id": p.id, "name": p.name, "price": p.price,
                        "description": p.description, "stock": p.stock
                    };
                    disengage;
                }
            }
        }
        report {"error": "Product not found"};
    }
}

walker SearchProducts {
    """Search products by name."""
    has query: str;

    can enter_root with Root entry {
        results: list = [];
        for pnode in [-->][?:Products] {
            for p in [pnode -->][?:Product] {
                if self.query.lower() in p.name.lower() {
                    results.append({
                        "id": p.id, "name": p.name, "price": p.price, "stock": p.stock
                    });
                }
            }
        }
        report results;
    }
}
