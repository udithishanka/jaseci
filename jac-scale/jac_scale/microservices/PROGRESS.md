# Microservice Mode v2 Rework — Progress Tracker

Reworking the `scale-micro-service` branch to match `PLAN.md` (sv import based architecture).

## Current Phase: Rework v1 prototype → v2 (sv import) — COMPLETE

### Strategy
Core (jaclang) already has `sv import`, `sv_client.call()`, `ensure_sv_service` hookspec, hash-based ports, BFS discovery. We override the hook and replace our manual patterns with core primitives.

## Task Tracker

### Step 1 — Orchestrator: pre-hook → `@hookimpl ensure_sv_service` ✅
- [x] Add `@hookimpl ensure_sv_service` in `plugin.jac`
- [x] Hook spawns subprocess with hash-based port, waits for `/healthz`, registers URL via `sv_client.register()`
- [x] Simplified `_scale_pre_hook`: removed filename/entry-point guards, use `JAC_SV_SIBLING` env var
- [x] Renamed `JAC_MICROSERVICE_CHILD` → `JAC_SV_SIBLING` for consistency with core terminology
- [x] All existing tests pass (no regressions)

### Step 2 — Deployer: add data isolation + hash ports ✅
- [x] `JAC_DATA_DIR=.jac/data/{module}/` per subprocess env
- [x] Hash-based ports: `18000 + hash(module) % 1000`, 100 retries
- [x] Reuse core's port strategy instead of sequential `_next_port`
- [x] Log files at `.jac/logs/{name}.log`
- [x] Tests updated for new port range

### Step 3 — Gateway: read URLs from `sv_client._registry` ✅
- [x] `resolve_target_url` prefers `sv_client._registry[module]` over `service_entry.url`
- [x] `ServiceProcessManager.start_service` calls `sv_client.register()` on spawn
- [x] `stop_service` calls `sv_client.unregister()` on stop
- [x] Gateway tests still pass with the new resolution path

### Step 4 — Replace `service_call()` with `sv import` ✅
- [x] Deleted `service_client.jac`, `impl/service_client.impl.jac`
- [x] Deleted `impl/service_http.py`
- [x] Deleted `tests/test_service_client.jac`
- [x] Services now use `sv import from X { func }` syntax
- [x] No `sv_service_call` hookimpl needed yet (can add for auth forwarding later)

### Step 5 — Example app rework (`examples/micr-s-example`) ✅
- [x] `products_app.jac`: `def:pub list_products`, `get_product` (via `to sv:`)
- [x] `cart_app.jac`: `def:pub add_to_cart`, `view_cart`, `clear_cart`, `remove_from_cart`
- [x] `orders_app.jac`: `sv import from cart_app { view_cart, clear_cart }` for inter-service
- [x] Deleted `services/products.jac`, `services/orders.jac`, `services/cart.jac` (walkers replaced)
- [x] Deleted `endpoints.sv.jac` (monolith-mode glue no longer needed)
- [x] Frontend: `apiCall` now hits `/api/{service}/function/{name}` instead of `/walker/{name}`
- [x] Removed manual `auth_token` passing in frontend / walker
- [x] Updated `jac.toml`: `[plugins.scale.microservices.routes]` map + legacy services compatibility
- [x] Config loader merges legacy services into routes for backwards-compat

### Step 6 — Migrate `sv { }` → `to sv:` section headers ✅
- [x] `products_app.jac`: `sv { ... }` → `to sv:`
- [x] `cart_app.jac`: `sv { ... }` → `to sv:`
- [x] `orders_app.jac`: `sv { ... }` → `to sv:`
- [x] `main.jac`: `cl { ... }` → `to cl:`
- [x] W0064 deprecation warnings silenced

### Step 7 — Tests & verify ✅
- [x] All 6 test suites pass (93 tests): registry, process_manager, gateway, setup, orchestrator, deployer
- [x] `build_registry` tests updated to cover both new `routes` map and legacy `services` map
- [x] Port assignment tests updated for hash-based range (18000-18999)
- [ ] E2E manual test with fresh example app (pending user verification)
- [ ] New tests for `ensure_sv_service` hookimpl integration (optional)

### Step 8 — Docs update (IN PROGRESS)
- [ ] Update `docs.md` to reflect final v2 state (already mostly aligned)
- [x] Update `PROGRESS.md` marking done items
- [ ] Update `learn-and-do/` Day 7 (inter-service) to use `sv import` instead of `service_call()`

## Architecture Summary (v2)

**What we have now:**
- `@hookimpl ensure_sv_service` in `jac_scale.plugin.JacScalePlugin` — spawns services as subprocesses on first `sv import` call
- `LocalDeployer` with hash-based ports + per-service data dir
- Gateway uses `sv_client._registry` for URL resolution (falls back to entry)
- Example app uses `def:pub` + `sv import` (no more walkers or `service_call()`)
- `jac.toml` uses `[plugins.scale.microservices.routes]` for gateway prefixes
- Legacy `[services.X]` config still supported for backwards compatibility

## PR Readiness

| PR (from PLAN.md) | Branch | Status |
|-------------------|--------|--------|
| 1: Deployer + LocalDeployer | — | Ready to extract |
| 2: Gateway + config | — | Ready to extract |
| 3: Orchestrator + hooks | — | Ready to extract |
| 4: sv_service_call override | — | Deferred (no auth forwarding yet) |
| 5: CLI tooling | — | Ready to extract |
| 6: Example app | — | Ready to extract |
| 7: Docs | — | After final docs pass |

## History
- 2026-04-16 — Merged `main` (67 commits, clean). Parser now prefers `to sv:` section headers; `sv { }` deprecated (W0064).
- 2026-04-16 — Completed Steps 1-7, 93 tests passing. Example app fully on sv import + `to sv:` sections.
