"""Implementations for the Jac Shop frontend."""

impl app.fetchProducts -> None {
    loading = True;
    result = root spawn ListProducts();
    products = result.reports[0] if result.reports else [];
    loading = False;
}

impl app.addToCart(productId: str, name: str, price: float) -> None {
    root spawn AddToCart(product_id=productId, product_name=name, price=price, qty=1);
    fetchCart();
}

impl app.fetchCart -> None {
    result = root spawn ViewCart();
    cart = result.reports[0] if result.reports else {"items": [], "total": 0};
}

impl app.placeOrder -> None {
    cart_data = root spawn ViewCart();
    cart_result = cart_data.reports[0] if cart_data.reports else {"items": []};
    if cart_result.items and cart_result.items.length > 0 {
        root spawn PlaceOrder(items=cart_result.items);
        root spawn ClearCart();
        cart = {"items": [], "total": 0, "item_count": 0};
        currentView = "orders";
        fetchOrders();
    }
}

impl app.fetchOrders -> None {
    result = root spawn ListOrders();
    orders = result.reports[0] if result.reports else [];
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
