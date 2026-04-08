"""Products Service — product catalog.

Endpoints:
  POST /walker/ListProducts    — browse all products
  POST /walker/GetProduct      — get product by ID
  POST /walker/SearchProducts  — search by name
"""

node Product {
    has id: str,
        name: str,
        price: float,
        description: str = "",
        stock: int = 0,
        image: str = "";
}

# Seed catalog on first import
glob _seeded: bool = False;

walker SeedCatalog {
    """Seed the catalog with sample products (run once)."""
    can seed with Root entry {
        global _seeded;
        if _seeded {
            report {"status": "already seeded"};
            disengage;
        }
        products = [
            Product(id="prod_1", name="Wireless Headphones", price=49.99, stock=25, description="Bluetooth over-ear headphones with noise cancellation"),
            Product(id="prod_2", name="USB-C Hub", price=34.99, stock=50, description="7-in-1 USB-C hub with HDMI, USB 3.0, and SD card reader"),
            Product(id="prod_3", name="Mechanical Keyboard", price=89.99, stock=15, description="RGB mechanical keyboard with Cherry MX switches"),
            Product(id="prod_4", name="Laptop Stand", price=29.99, stock=40, description="Adjustable aluminum laptop stand"),
            Product(id="prod_5", name="Webcam HD", price=59.99, stock=30, description="1080p webcam with built-in microphone")
        ];
        for p in products {
            here ++> p;
        }
        _seeded = True;
        report {"status": "seeded", "count": len(products)};
    }
}

walker ListProducts {
    """List all products in the catalog."""
    has items: list = [];

    can collect with Root entry {
        visit [-->];
    }

    can gather with Product entry {
        self.items.append({
            "id": here.id, "name": here.name, "price": here.price,
            "description": here.description, "stock": here.stock
        });
    }

    can done with Root exit {
        report self.items;
    }
}

walker GetProduct {
    """Get a product by ID."""
    has product_id: str;

    can search with Root entry {
        visit [-->];
    }

    can check with Product entry {
        if here.id == self.product_id {
            report {
                "id": here.id, "name": here.name, "price": here.price,
                "description": here.description, "stock": here.stock
            };
        }
    }
}

walker SearchProducts {
    """Search products by name (case-insensitive partial match)."""
    has query: str;
    has results: list = [];

    can search with Root entry {
        visit [-->];
    }

    can check with Product entry {
        if self.query.lower() in here.name.lower() {
            self.results.append({
                "id": here.id, "name": here.name, "price": here.price,
                "stock": here.stock
            });
        }
    }

    can done with Root exit {
        report self.results;
    }
}
