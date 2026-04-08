"""Implementations for the Jac Shop frontend.

In microservice mode, the client calls the gateway API directly:
  /api/products/walker/ListProducts
  /api/cart/walker/AddToCart
  /api/orders/walker/PlaceOrder
"""

impl app.apiCall(service: str, endpoint: str, body: dict = {}) -> any {
    token = localStorage.getItem("jac_token");
    options: dict = {
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + (token or "")
        }
    };
    options["body"] = JSON.stringify(body or {});
    resp = await fetch(f"/api/{service}/walker/{endpoint}", options);
    return await resp.json();
}

impl app.fetchProducts -> None {
    loading = True;
    data = await apiCall("products", "ListProducts", {});
    products = data.data.reports[0] if data.data and data.data.reports else [];
    loading = False;
}

impl app.addToCart(productId: str, name: str, price: float) -> None {
    await apiCall("cart", "AddToCart", {
        "product_id": productId,
        "product_name": name,
        "price": price,
        "qty": 1
    });
    fetchCart();
}

impl app.fetchCart -> None {
    data = await apiCall("cart", "ViewCart", {});
    cart = data.data.reports[0] if data.data and data.data.reports else {"items": [], "total": 0};
}

impl app.placeOrder -> None {
    cart_data = await apiCall("cart", "ViewCart", {});
    cart_result = cart_data.data.reports[0] if cart_data.data and cart_data.data.reports else {"items": []};
    if cart_result.items and cart_result.items.length > 0 {
        await apiCall("orders", "PlaceOrder", {"items": cart_result.items});
        await apiCall("cart", "ClearCart", {});
        cart = {"items": [], "total": 0, "item_count": 0};
        currentView = "orders";
        fetchOrders();
    }
}

impl app.fetchOrders -> None {
    data = await apiCall("orders", "ListOrders", {});
    orders = data.data.reports[0] if data.data and data.data.reports else [];
}

impl app.handleLogin -> None {
    error = "";
    if not username.trim() or not password {
        error = "Please fill in all fields";
        return;
    }
    loading = True;
    success = await jacLogin(username, password);
    loading = False;
    if success {
        isLoggedIn = True;
        username = "";
        password = "";
    } else {
        error = "Invalid username or password";
    }
}

impl app.handleSignup -> None {
    error = "";
    if not username.trim() or not password {
        error = "Please fill in all fields";
        return;
    }
    if password.length < 4 {
        error = "Password must be at least 4 characters";
        return;
    }
    loading = True;
    result = await jacSignup(username, password);
    loading = False;
    if result["success"] {
        isLoggedIn = True;
        username = "";
        password = "";
    } else {
        error = result["error"] if result["error"] else "Signup failed";
    }
}

impl app.handleLogout -> None {
    jacLogout();
    isLoggedIn = False;
    products = [];
    cart = {};
    orders = [];
    username = "";
    password = "";
    error = "";
    currentView = "products";
}

impl app.handleSubmit(e: any) -> None {
    e.preventDefault();
    if isSignup {
        await handleSignup();
    } else {
        await handleLogin();
    }
}
