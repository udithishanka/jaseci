# jac-shop — E-Commerce Microservice Example

A small e-commerce app built with 3 microservices behind an API gateway. Can also run as a monolith.

## Project Structure

```
micr-s-example/
├── main.jac                    # entry point (sv {} + cl {})
├── endpoints.sv.jac            # all walkers registered (monolith mode)
├── jac.toml                    # microservice config
├── services/
│   ├── products.jac            # product catalog walkers
│   ├── products_app.jac        # products service entry (sv {})
│   ├── orders.jac              # order management walkers
│   ├── orders_app.jac          # orders service entry (sv {})
│   ├── cart.jac                # shopping cart walkers
│   └── cart_app.jac            # cart service entry (sv {})
├── frontend.cl.jac             # React-like UI
├── frontend.impl.jac           # UI action implementations
└── components/                 # reusable UI components
```

## Services

### Products (`/api/products`)
| Endpoint | Description |
|----------|-------------|
| `POST /walker/SeedCatalog` | Seed sample products |
| `POST /walker/ListProducts` | Browse catalog |
| `POST /walker/GetProduct` | Get product by ID |
| `POST /walker/SearchProducts` | Search by name |

### Orders (`/api/orders`)
| Endpoint | Description |
|----------|-------------|
| `POST /walker/PlaceOrder` | Place order from cart items |
| `POST /walker/ListOrders` | List user's orders |
| `POST /walker/GetOrder` | Get order details |
| `POST /walker/CancelOrder` | Cancel an order |

### Cart (`/api/cart`)
| Endpoint | Description |
|----------|-------------|
| `POST /walker/AddToCart` | Add product to cart |
| `POST /walker/ViewCart` | View cart with total |
| `POST /walker/RemoveFromCart` | Remove item |
| `POST /walker/ClearCart` | Empty cart |

## Running

### Monolith mode
```bash
jac start main.jac
# All endpoints on :8000, Swagger at http://localhost:8000/docs
```

### Microservice mode (after Day 9 orchestrator)
```bash
jac start main.jac
# Gateway on :8000
# Products on :8001 → /api/products/walker/*
# Orders on :8002 → /api/orders/walker/*
# Cart on :8003 → /api/cart/walker/*
```

### Testing services standalone
```bash
# Each service can be tested independently
jac start services/products_app.jac --port 8001 --no-client
jac start services/orders_app.jac --port 8002 --no-client
jac start services/cart_app.jac --port 8003 --no-client
```

## Example Flow

```bash
# 1. Seed products
curl -X POST http://localhost:8001/walker/SeedCatalog

# 2. Browse catalog
curl -X POST http://localhost:8001/walker/ListProducts

# 3. Add to cart
curl -X POST http://localhost:8003/walker/AddToCart \
  -H "Content-Type: application/json" \
  -d '{"product_id": "prod_1", "product_name": "Wireless Headphones", "price": 49.99}'

# 4. View cart
curl -X POST http://localhost:8003/walker/ViewCart

# 5. Place order
curl -X POST http://localhost:8002/walker/PlaceOrder \
  -H "Content-Type: application/json" \
  -d '{"items": [{"product_id": "prod_1", "product_name": "Wireless Headphones", "qty": 1, "price": 49.99}]}'

# 6. View orders
curl -X POST http://localhost:8002/walker/ListOrders
```
