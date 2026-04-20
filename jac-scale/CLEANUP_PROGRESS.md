# Cleanup Progress

Live tracker for [CLEANUP_PLAN.md](CLEANUP_PLAN.md). Delete this file when
all three waves are merged.

## Decisions on open questions (2026-04-20)

- **`sv_service_call` scope**: process-global static hookspec on
  `JacAPIServer`, matches existing `ensure_sv_service` pattern. Auth
  flows via ContextVar (already process-global).
- **Gateway `/health` latency**: deferred — out of cleanup scope, belongs
  in a proper metrics module.
- **`JAC_DATA_DIR` in core**: keep in jac-scale. Core's thread-based
  default doesn't need data isolation; subprocess spawning does. It's a
  deployment-strategy concern.

## Wave 1 — Deletes

- [x] 1.1 Planning / tracking docs
  - [x] `PR_PLAN.md`
  - [x] `FOLLOWUPS.md`
  - [x] `microservices/FOLLOWUPS.md`
  - [x] `microservices/PROGRESS.md`
  - [x] `microservices/PLAN.md`
  - [x] `docs/microservice-mode-architecture.md` — deleted, `microservices/docs.md` already covered its content
- [x] 1.2 `docs/learn-and-do/` tutorial series
- [x] 1.3 Scratch fixtures
  - [x] `test-microservices/`
  - [x] `examples/micr-s-example/components/TodoItem.cl.jac`
- [x] 1.4 Unused `JAC_MICROSERVICE_CHILD` env var
- [x] 1.5 Dead gateway auth API — removed `validate_token`, `create_internal_token`, `is_public_path`, `GW_JWT_*`, `PUBLIC_PATHS`, `internal_token_ttl`. Also dropped dead `jwt_config` assignment in `orchestrator.jac:160`. Simplified two `test_gateway.jac` cases that were signing meaningless tokens.
- [x] 1.6 Tests pass — 28 gateway tests, plus deployer/orchestrator/process_manager/setup/registry suites all green

## Wave 2 — Local refactors

- [x] 2.1 Consolidated `pick_free_port` + `resolve_jac_binary` into new `microservices/_util.jac`. Both call sites (plugin.jac hookimpl, process_manager) use it.
- [x] 2.2 JWT globals — done-by-deletion in Wave 1.5.
- [x] 2.3 Dropped v1 `services` schema. v2 `routes` map is now the only supported form. Rewrote `setup.jac` to emit `[plugins.scale.microservices.routes]`, rewrote tests accordingly. Also fixed latent bug in `plugin.jac:scale_cmd` where `build_registry` was called with the inner services dict instead of the full config.
- [x] 2.4 Split gateway middleware into named handlers: `handle_health`, `handle_builtin_passthrough`, `handle_admin`, `handle_proxy`, `handle_static`, plus `build_forward_headers` helper. Dispatcher middleware is now ~15 lines instead of ~140.
- [x] 2.5 Ported `http_forward.py` → `http_forward.impl.jac` using `aiohttp` in Jac (matching `sandbox_proxy.jac` precedent). Added `aiohttp>=3.9.0,<4.0.0` to `pyproject.toml` — gateway hard-requires it on import.
- [x] 2.6 Replaced bubble-sort in `service_registry.impl.jac` with `list.sort(key=lambda p: -len(p[0]))`. Routed orchestrator banner through `console.print` with rich formatting; dropped bare `print()` calls.
- [x] 2.7 Admin-UI bootstrap now skips when `dest_index.mtime >= src_index.mtime` (handles package upgrade + cold start without re-copying on normal restarts).

## Wave 3 — Hookspec-driven

- [ ] 3.1 `sv_service_call` hookspec (core + override + delete sv_auth_client.py)
- [ ] 3.2 Extract `ensure_sv_service` helpers (core or jac-scale fallback)
- [ ] 3.3 `JAC_SV_SIBLING` → CLI flag (optional)

## Notes

### 2026-04-20 — Wave 2 landed

- 86 tests green across 6 suites (deployer 12, orchestrator 4, process_manager 15, registry 14, gateway 28, setup 13).
- Wave 2.3 uncovered a latent bug: `jac scale status` was passing the inner `services` dict to `build_registry` (which expected the full `ms_config`), so the registry was always empty. Fixed.
- Gateway middleware is now testable per-handler; no test rewrites were needed because the split preserved behavior exactly.

### 2026-04-20 — Wave 1 landed

- Also discovered `aiohttp` wasn't in the environment — installed it manually.
  Wave 2.5 (port `http_forward.py` to Jac) should make sure it's a declared
  dependency of jac-scale, since the gateway hard-requires it at import time.
- `orchestrator.jac` had an unused `jwt_config` assignment — removed along
  with its now-unused `get_scale_config` import.
- Dropped 2×JWT-signing ceremony in `test_gateway.jac` — those tests pass an
  `Authorization` header to a middleware that doesn't read it, so the token
  encoding was meaningless.
