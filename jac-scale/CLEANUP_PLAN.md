# `scale-micro-service` Cleanup & Fix Plan

Companion to [BRANCH_REVIEW.md](BRANCH_REVIEW.md). Organized in three waves,
each independently mergeable. Waves 1–2 touch only jac-scale; wave 3 adds
hookspecs to jaclang core (additive, no core behavior change) per the
"don't-modify-core / use-hookspecs" rule.

Status legend: `[ ]` pending · `[x]` done · `[~]` in progress

---

## Wave 1 — Deletes (no risk, ~6k LOC drop)

Pure removals. No behavior change. Should drop before any refactor so later
waves diff against a clean baseline.

### 1.1 Planning / tracking docs

- [ ] Delete [jac-scale/PR_PLAN.md](PR_PLAN.md) (306 LOC)
- [ ] Delete [jac-scale/FOLLOWUPS.md](FOLLOWUPS.md) (163 LOC)
- [ ] Delete [jac-scale/jac_scale/microservices/FOLLOWUPS.md](jac_scale/microservices/FOLLOWUPS.md) (136 LOC)
- [ ] Delete [jac-scale/jac_scale/microservices/PROGRESS.md](jac_scale/microservices/PROGRESS.md) (93 LOC)
- [ ] Delete [jac-scale/jac_scale/microservices/PLAN.md](jac_scale/microservices/PLAN.md) (1052 LOC)
- [ ] Keep ONE user-facing doc: [jac-scale/jac_scale/microservices/docs.md](jac_scale/microservices/docs.md).
      If anything worth keeping lives in `microservice-mode-architecture.md`,
      fold it in before deleting.
- [ ] Delete [jac-scale/docs/microservice-mode-architecture.md](docs/microservice-mode-architecture.md)
      after fold-in (333 LOC)

### 1.2 Tutorial series

Commit `597087f23` already removed these from tracking; working tree still
has them.

- [ ] `rm -rf jac-scale/docs/learn-and-do/` (29 files, ~5000 LOC)
- [ ] Verify nothing under `jac-scale/docs/docs/tutorials/` links into
      `learn-and-do/` before deleting

### 1.3 Scratch / unused fixtures

- [ ] Delete [jac-scale/test-microservices/](test-microservices/) — no test
      imports this directory (grep confirms); v1-schema `jac.toml` confuses
      the config story
- [ ] Delete [jac-scale/examples/micr-s-example/components/TodoItem.cl.jac](examples/micr-s-example/components/TodoItem.cl.jac)
      (47 LOC, unused by example). Verify no import references it.

### 1.4 Unused env var

- [ ] Remove `child_env["JAC_MICROSERVICE_CHILD"] = "1"` at
      [plugin.jac:744](jac_scale/plugin.jac#L744) — never read anywhere
- [ ] Remove docs references in `docs.md` (none expected after Wave 1.1)

### 1.5 Dead gateway auth API (choose one)

`validate_token`, `create_internal_token`, `is_public_path`, `PUBLIC_PATHS`,
`GW_JWT_EXP_DAYS`, `internal_token_ttl` are defined but unused by the
middleware. Tests keep them alive.

**Recommended: delete.** Gateway is a pure passthrough today; services
handle auth. If auth-at-gateway becomes a future requirement, reintroduce
with a design rather than preserving stubs.

- [ ] Delete method decls in [gateway.jac:52-58](jac_scale/microservices/gateway.jac#L52-L58)
      and impls in [gateway.impl.jac:149-189](jac_scale/microservices/impl/gateway.impl.jac#L149-L189)
- [ ] Delete `GW_JWT_EXP_DAYS`, `PUBLIC_PATHS`, `internal_token_ttl` from
      [gateway.jac:16-31](jac_scale/microservices/gateway.jac#L16-L31)
- [ ] Delete the seven test cases in
      [tests/test_gateway.jac:456-513](jac_scale/tests/test_gateway.jac#L456-L513)
- [ ] Keep `GW_JWT_SECRET` / `GW_JWT_ALGORITHM` only if the tests that use
      them for request signing (L147, L165) are still needed

### 1.6 Wave 1 verification

- [ ] `jac test jac_scale/tests/` passes
- [ ] Branch still builds; example app still runs end-to-end

---

## Wave 2 — Local refactors (jac-scale only)

No jaclang changes. Consolidates duplication, removes import-time side
effects, and picks one config schema.

### 2.1 Consolidate duplicated helpers

Create `jac-scale/jac_scale/microservices/_util.jac` (or `.py` only if a
concrete Jac blocker surfaces — in which case document it precisely, not
"type checker limitation"):

```jac
def pick_free_port(name: str, base: int = 18000, retries: int = 100) -> int;
def resolve_jac_binary -> str;
```

- [ ] Move `18000 + hash(name) % 1000` loop from
      [plugin.jac:705-724](jac_scale/plugin.jac#L705-L724) and
      [process_manager.impl.jac:9-31](jac_scale/microservices/impl/process_manager.impl.jac#L9-L31)
      into `pick_free_port`
- [ ] Move `shutil.which("jac")` → `sys.executable`-parent block from
      [plugin.jac:748-760](jac_scale/plugin.jac#L748-L760) and
      [process_manager.impl.jac:44-57](jac_scale/microservices/impl/process_manager.impl.jac#L44-L57)
      into `resolve_jac_binary`
- [ ] Update both call sites

### 2.2 Move JWT globals inside `setup()`

[gateway.jac:15-21](jac_scale/microservices/gateway.jac#L15-L21) loads
`jac.toml` at import time. Day-10.7 doc already flagged this.

- [ ] Drop `glob _jwt_config = get_scale_config().get_jwt_config()` etc.
- [ ] Add `has jwt_secret: str = ""`, `has jwt_algorithm: str = ""` on
      `MicroserviceGateway`
- [ ] Populate from config inside `MicroserviceGateway.setup()` (or the
      constructor, if `setup()` can be called multiple times)
- [ ] Update tests in [test_gateway.jac:147,165](jac_scale/tests/test_gateway.jac#L147)
      to pass the secret through the `gw` instance rather than the module
      glob — or simply drop those tests if Wave 1.5 deleted the feature

### 2.3 Pick one config schema

Either v1 (`[plugins.scale.microservices.services.<name>]` with
file/prefix/port/replicas) or v2 (`[plugins.scale.microservices.routes]`
flat name→prefix map). **Recommend v2** — matches the `sv import`
philosophy (service = any sv-imported module).

- [ ] In [config_loader.impl.jac:344-372](jac_scale/impl/config_loader.impl.jac#L344-L372),
      delete the `legacy_services` merge branch; return `routes` only
- [ ] In [orchestrator.jac:build_registry](jac_scale/microservices/orchestrator.jac#L23-L60),
      delete the legacy-services loop
- [ ] Update [setup.jac:117-130](jac_scale/microservices/setup.jac#L117-L130)
      to write the v2 `[routes]` table, not `[services.<name>]`
- [ ] Update [plugin_config.jac:275-322](jac_scale/plugin_config.jac#L275-L322)
      schema to describe `routes` (dict name→string) instead of `services`
- [ ] Update [examples/micr-s-example/jac.toml](examples/micr-s-example/jac.toml)
      if it still uses v1
- [ ] Update [tests/test_orchestrator.jac](jac_scale/tests/test_orchestrator.jac)
      fixtures

### 2.4 Split the gateway middleware

[gateway.impl.jac:200-339](jac_scale/microservices/impl/gateway.impl.jac#L200-L339)
is one 140-line closure. Break out each branch into a named method on
`MicroserviceGateway` so each is independently testable:

- [ ] `def handle_health -> Response`
- [ ] `def handle_builtin_passthrough(request, path) -> Response | None`
- [ ] `def handle_admin(path) -> Response | None`
- [ ] `def handle_proxy(request, path) -> Response | None`
- [ ] `def handle_static(request, path) -> Response | None`
- [ ] Middleware becomes a thin dispatcher that calls these in order
- [ ] Write one test per handler (most already exist; re-target them to
      the new methods)

### 2.5 Port `http_forward.py` to Jac

The aiohttp-in-Jac blocker is bogus — see
[sandbox_proxy.jac:4-21](jac_scale/providers/proxy/sandbox_proxy.jac#L4-L21).

- [ ] Rewrite [http_forward.py](jac_scale/microservices/impl/http_forward.py)
      as `impl/http_forward.impl.jac`, modeled on `sandbox_proxy.jac`'s
      aiohttp usage
- [ ] Delete the `.py` file
- [ ] If a real Jac blocker surfaces, document the exact error in a
      comment (with the failing line) rather than the vague current note

### 2.6 Deregister on shutdown + less-chatty startup

- [ ] [orchestrator.jac:166-181](jac_scale/microservices/orchestrator.jac#L166-L181)
      banner: route through `logger.info` (match rest of jac-scale) or
      `console.print` — pick one and stick to it
- [ ] Bubble-sort in
      [service_registry.impl.jac:51-62](jac_scale/microservices/impl/service_registry.impl.jac#L51-L62)
      → replace with `pairs.sort(key=lambda p: -len(p[0]))`

### 2.7 Admin-UI bootstrap caching

- [ ] [gateway.impl.jac:bootstrap_admin](jac_scale/microservices/impl/gateway.impl.jac#L72-L107)
      should no-op if the destination `index.html` mtime ≥ source. Current
      code re-copies on every cold start when `.jac/admin/` was cleaned.

### 2.8 Wave 2 verification

- [ ] All tests pass
- [ ] Example app cold-start still works
- [ ] `jac setup microservice` writes v2 schema; `jac start main.jac` reads it

---

## Wave 3 — Hookspec-driven fixes (additive core changes)

**Scope**: add hookspecs and small helpers to jaclang core. Do NOT change
core behavior — default impls keep the old logic bit-for-bit. Plugin uses
the new hooks to express the delta cleanly.

### 3.1 Add `sv_service_call` hookspec in jaclang core

**Why**: today `sv_client.call()` at
[jac/jaclang/runtimelib/sv_client.jac:136-167](../jac/jaclang/runtimelib/sv_client.jac#L136-L167)
does a raw `httpx.post` with no way for plugins to inject headers. That's
why this branch hijacks `_test_clients` via `sv_auth_client.py`.

Tasks (in jaclang, additive):

- [ ] Add hookspec on `JacAPIServer` in
      [jac/jaclang/jac0core/runtime.jac](../jac/jaclang/jac0core/runtime.jac):
      `static def sv_service_call(module_name: str, func_name: str, args: dict) -> Any`
- [ ] Add default impl in
      [jac/jaclang/jac0core/impl/runtime.impl.jac](../jac/jaclang/jac0core/impl/runtime.impl.jac)
      that is a byte-for-byte move of the current `sv_client.call` body
- [ ] Update `sv_client.call()` to delegate to
      `JacRuntime.sv_service_call(module_name, func_name, args)` — behavior
      identical when no plugin overrides it
- [ ] Add a core test asserting the delegation

Then in jac-scale:

- [ ] Add `@hookimpl static def sv_service_call` in
      [jac_scale/plugin.jac](jac_scale/plugin.jac). Body:
      1. read `Authorization` from the request ContextVar (the one
         currently in `sv_auth_client.py`)
      2. `httpx.post(f"{url}/function/{func_name}", json=args, headers={...})`
      3. unwrap the TransportResponse envelope
- [ ] Delete [sv_auth_client.py](jac_scale/microservices/sv_auth_client.py)
      entirely
- [ ] Delete the `register_test_client(...)` call inside
      [plugin.jac:812-814](jac_scale/plugin.jac#L812-L814)
- [ ] Move the ContextVar + `set_current_auth`/`reset_current_auth` into
      `plugin.jac` (or a new `microservices/_auth_ctx.jac`)
- [ ] Update middleware at
      [jserver/impl/jfast_api.impl.jac:850-892](jac_scale/jserver/impl/jfast_api.impl.jac#L850-L892)
      to import from the new location

**Result**: ~115 LOC removed, no more duck-typing into a test-only registry.

### 3.2 Shrink `ensure_sv_service` hookimpl

**Why**: [plugin.jac:688-824](jac_scale/plugin.jac#L688-L824) is a 130-line
near-copy of core's default
([runtime.impl.jac:1724-1793](../jac/jaclang/jac0core/impl/runtime.impl.jac#L1724-L1793)).
Deltas: subprocess vs thread, env vars, auth-client registration.

**Preferred**: extract seams in core (additive, behavior-preserving):

- [ ] In jaclang, split
      [JacAPIServer.ensure_sv_service](../jac/jaclang/jac0core/impl/runtime.impl.jac#L1724)
      into three helpers: `_pick_sv_port(module_name)`,
      `_wait_sv_healthy(base_url, proc_or_thread, timeout)`,
      `_register_sv_url(module_name, base_url)`. Default impl composes
      them; behavior unchanged.
- [ ] Export the helpers so plugins can import them.

Then in jac-scale, the hookimpl becomes:

```jac
@hookimpl
static def ensure_sv_service(module_name: str, base_path: str) -> None {
    if module_name in sv_client._registry { return; }
    port = core._pick_sv_port(module_name);
    proc = _spawn_subprocess(module_name, base_path, port);  # jac-scale helper
    core._wait_sv_healthy(f"http://127.0.0.1:{port}", proc, timeout=15.0);
    core._register_sv_url(module_name, f"http://127.0.0.1:{port}");
    atexit.register(lambda: proc.poll() is None and proc.terminate());
}
```

- [ ] Drops ~100 lines from `plugin.jac`
- [ ] Delete duplicate port loop in `plugin.jac` (already consolidated in
      Wave 2.1, this just removes the last caller)

**Fallback if core helpers can't be added**: put
`_pick_sv_port` / `_wait_sv_healthy` inside
`jac_scale/microservices/_util.jac` (Wave 2.1 already created that
module). The hookimpl still shrinks to ~20 lines, at the cost of
duplicating those helpers across core and jac-scale.

### 3.3 Remove `JAC_SV_SIBLING` env var (optional)

Core already has `is_sv_sibling: bool` on `JacAPIServer`
([server.jac:221](../jac/jaclang/runtimelib/server.jac#L221)). The env-var
sentinel in this branch exists to tell child subprocesses "you are a
sibling, skip orchestration."

Two options:

- **Option A (preferred)**: extend `jac start` CLI with a hidden
  `--is-sv-sibling` flag that sets the constructor arg. Child subprocess
  command becomes `jac start x.jac --port N --no_client --is-sv-sibling`.
  Delete the env var everywhere.
- **Option B**: leave `JAC_SV_SIBLING=1` as-is. It works; it's just
  uglier than a proper CLI flag.

- [ ] Decide Option A vs B
- [ ] If A: add flag in core CLI, remove env var from
      [plugin.jac:745](jac_scale/plugin.jac#L745),
      [process_manager.impl.jac:67](jac_scale/microservices/impl/process_manager.impl.jac#L67),
      [plugin.jac:32](jac_scale/plugin.jac#L32)

### 3.4 Wave 3 verification

- [ ] Core default impls of the new hookspecs behave identically (add core
      regression test for `sv_service_call` default path)
- [ ] jac-scale plugin overrides deliver the same auth / subprocess
      behavior as before
- [ ] End-to-end: the example app's inter-service call
      (`orders_app` → `cart_app`) propagates the user's JWT correctly

---

## Suggested commit breakdown

Each wave is mergeable in isolation. Within a wave, commit per numbered
section so a bisect can point at a single concern.

| Commit | Contents |
|---|---|
| `chore(jac-scale): remove microservice planning docs` | Wave 1.1–1.2 |
| `chore(jac-scale): delete unused scratch fixtures and example leftovers` | Wave 1.3 |
| `refactor(jac-scale): drop unused env var and dead gateway auth helpers` | Wave 1.4–1.5 |
| `refactor(jac-scale): consolidate port-assign and jac-binary helpers` | Wave 2.1 |
| `refactor(jac-scale): load JWT config at gateway setup time` | Wave 2.2 |
| `refactor(jac-scale): drop v1 services config schema, keep routes only` | Wave 2.3 |
| `refactor(jac-scale): split gateway middleware into named handlers` | Wave 2.4 |
| `refactor(jac-scale): port http_forward to jac, match sandbox_proxy pattern` | Wave 2.5 |
| `refactor(jac-scale): lint and style cleanup (bubble sort, logger, admin cache)` | Wave 2.6–2.7 |
| `feat(jaclang): add sv_service_call hookspec` | Wave 3.1 core side |
| `feat(jac-scale): override sv_service_call, delete sv_auth_client` | Wave 3.1 plugin side |
| `refactor(jaclang): extract ensure_sv_service helpers` | Wave 3.2 core side |
| `refactor(jac-scale): shrink ensure_sv_service hookimpl using core helpers` | Wave 3.2 plugin side |
| (optional) `feat(jaclang): add --is-sv-sibling CLI flag` + follow-up | Wave 3.3 |

---

## Expected impact

| Metric | Before | After waves 1–2 | After wave 3 |
|---|---|---|---|
| Branch LOC delta | +13,022 | ~+6,500 | ~+5,000 |
| Docs / trackers | 7 files, ~2300 LOC | 1 file (`docs.md`) | same |
| Duplicated port-assign blocks | 3 (incl. core) | 2 (incl. core) | 1 (core only) |
| Private-core-API usage (`_test_clients`) | yes | yes | no |
| `plugin.jac` `ensure_sv_service` LOC | 137 | 137 | ~25 |
| `.py` files in `microservices/` | 2 | 0 | 0 |

---

## Open questions

- [ ] Is the `sv_service_call` hookspec scoped per-server instance or
      process-global? Affects whether jac-scale's hookimpl needs to look
      up the current server context.
- [ ] Do we want the gateway `/health` to report inter-service call
      latency, or is that deferred to proper metrics (out of scope for
      this cleanup)?
- [ ] Should `JAC_DATA_DIR` become a core concern (it's currently set by
      jac-scale; core's default `ensure_sv_service` doesn't isolate data)?
