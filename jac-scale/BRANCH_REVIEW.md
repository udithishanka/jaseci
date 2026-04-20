# `scale-micro-service` Branch Review

Independent review against `main`. Focuses on AI-generated bloat, workarounds
the branch introduces on top of existing primitives, and patterns that
diverge from the rest of the repo.

## 1. What the branch delivers

**Scope**: 38 commits, ~13,000 line delta, net-new microservice mode for jac-scale.

**Production code** (`jac-scale/jac_scale/microservices/`, ~1,600 LOC):

| File | Purpose |
|------|---------|
| [service_registry.jac](jac_scale/microservices/service_registry.jac) + impl | `ServiceEntry` records, longest-prefix route match |
| [process_manager.jac](jac_scale/microservices/process_manager.jac) + impl | subprocess spawn / stop / health-check |
| [deployer.jac](jac_scale/microservices/deployer.jac) / [local_deployer.jac](jac_scale/microservices/local_deployer.jac) + impl | `ServiceDeployer` abstract + local impl wrapping `ServiceProcessManager` |
| [gateway.jac](jac_scale/microservices/gateway.jac) + impl | FastAPI reverse proxy, static files, admin UI, JWT helpers |
| [impl/http_forward.py](jac_scale/microservices/impl/http_forward.py) | raw aiohttp forwarding helper (Python, not Jac) |
| [orchestrator.jac](jac_scale/microservices/orchestrator.jac) | builds registry, spawns services, starts gateway |
| [setup.jac](jac_scale/microservices/setup.jac) | `jac setup microservice` interactive CLI |
| [sv_auth_client.py](jac_scale/microservices/sv_auth_client.py) | auth-forwarding client injected into `sv_client._test_clients` |

**Plugin integration** ([plugin.jac](jac_scale/plugin.jac)): `_scale_pre_hook`
intercepts `jac start`, a new `@hookimpl ensure_sv_service` spawns sibling
subprocesses, plus two new commands: `jac setup microservice` and
`jac scale <action>`.

**Support code**: ~1,450 LOC of tests across 6 files, an e-commerce example app
under [examples/micr-s-example/](examples/micr-s-example/), and a scratch
fixture at [test-microservices/](test-microservices/).

**Docs** (~7,500 LOC, ~60% of the branch delta):
[learn-and-do/](docs/learn-and-do/) (29 files, Day-01…Day-20 tutorial series),
[microservice-mode-architecture.md](docs/microservice-mode-architecture.md),
[microservices/docs.md](jac_scale/microservices/docs.md), plus four overlapping
trackers: [PR_PLAN.md](PR_PLAN.md) (306), [FOLLOWUPS.md](FOLLOWUPS.md) (163),
[microservices/FOLLOWUPS.md](jac_scale/microservices/FOLLOWUPS.md) (136),
[microservices/PLAN.md](jac_scale/microservices/PLAN.md) (1052),
[microservices/PROGRESS.md](jac_scale/microservices/PROGRESS.md) (93).

---

## 2. AI-generated bloat

### 2.1 Documentation-to-code ratio

The branch contains more markdown than production code. A single feature has
**seven** separate planning / tracking documents with overlapping content:

- [PR_PLAN.md](PR_PLAN.md), [FOLLOWUPS.md](FOLLOWUPS.md), and
  [microservices/FOLLOWUPS.md](jac_scale/microservices/FOLLOWUPS.md) each list
  the same ~15 PRs in slightly different formats.
- [microservices/PLAN.md](jac_scale/microservices/PLAN.md) is 1,052 lines,
  describes one architecture in the early sections and a *reworked* v2
  architecture in the later sections (`sv import` integration) — i.e. a
  rolling design journal rather than a plan.
- [microservices/PROGRESS.md](jac_scale/microservices/PROGRESS.md) is a
  step-by-step "✅ COMPLETE" changelog with dated "History" entries.
- The `docs/learn-and-do/` directory contains a 20-day tutorial series
  tangential to the feature itself (Day-16 "API versioning", Day-19
  "Performance & caching", etc.). Commit `597087f23` *removes these from
  tracking*, but the files still exist in the working tree.
- [microservices/docs.md](jac_scale/microservices/docs.md) and
  [docs/microservice-mode-architecture.md](docs/microservice-mode-architecture.md)
  both describe the same architecture.

None of these ships to end-users; the actual user-facing doc is `docs.md`.
Everything else is internal scaffolding that should be deleted before merge.

### 2.2 Example-app leftovers

- [examples/micr-s-example/components/TodoItem.cl.jac](examples/micr-s-example/components/TodoItem.cl.jac)
  (47 LOC) in an *e-commerce* example — copy-pasted from a template.
- [test-microservices/](test-microservices/) at the repo root contains an
  empty `client/`, trivial `services/orders.jac` and `services/payments.jac`,
  and a v1-schema `jac.toml`. No test references it — appears to be a manual
  scratch directory that was accidentally committed.

---

## 3. Workarounds that introduce new debt

### 3.1 `http_forward.py` — "Jac type checker aiohttp limitations"

[impl/http_forward.py:1](jac_scale/microservices/impl/http_forward.py#L1)
opens with:

> `"""Raw HTTP forwarding — plain Python to work around Jac type checker aiohttp limitations."""`

But the repo already uses `aiohttp` directly in Jac — see
[providers/proxy/sandbox_proxy.jac:4-21](jac_scale/providers/proxy/sandbox_proxy.jac#L4-L21)
where `aiohttp.ClientSession | None` is a typed `has` field and the module
imports `aiohttp`, `WSMsgType`, `web` without trouble. The claimed blocker
either never existed or was worked around via the wrong mechanism; the
tech-debt doc then *rationalises* the workaround
([day-10.7-technical-debt.md:31,70](docs/learn-and-do/day-10.7-technical-debt.md#L31))
as "Accept until Jac type checker supports aiohttp stubs."

### 3.2 `sv_auth_client.py` — duck-typing into a private test API

[sv_auth_client.py:8-9](jac_scale/microservices/sv_auth_client.py#L8-L9):

> `"This avoids modifying jaclang — we use the existing _test_clients duck-typed extension point to inject auth-forwarding behavior."`

- `register_test_client()` in
  [jac/jaclang/runtimelib/sv_client.jac:40-41](../jac/jaclang/runtimelib/sv_client.jac#L40-L41)
  is explicitly *"testing only"*. This branch wires it in as the production
  auth transport.
- The module's own [PLAN.md Decision 2](jac_scale/microservices/PLAN.md) and
  [FOLLOWUPS.md L44-L50](FOLLOWUPS.md#L44-L50) acknowledge the correct fix:
  add an `sv_service_call` hookspec to core. That PR was deferred; the
  duck-type hack ships instead.
- The duck-typed `_Response` class only implements `.json()` — will break
  silently if `sv_client.call()` ever inspects `.status_code` or errors.
- Cross-module hidden state: the `ContextVar` in `sv_auth_client` is set
  inside a middleware in
  [jserver/impl/jfast_api.impl.jac:850-855](jac_scale/jserver/impl/jfast_api.impl.jac#L850-L855).
  Any future middleware reorder silently breaks auth forwarding.
- `.py` file in a tree where neighbours are `.jac` + `.impl.jac` — no
  technical reason, given the sandbox_proxy precedent above.

### 3.3 `ensure_sv_service` reimplementation in plugin.jac

[plugin.jac:688-824](jac_scale/plugin.jac#L688-L824) is a ~130-line
reimplementation of core's default `ensure_sv_service` at
[jac/jaclang/jac0core/impl/runtime.impl.jac:1724-1793](../jac/jaclang/jac0core/impl/runtime.impl.jac#L1724-L1793).
The only substantive differences:

1. Subprocess instead of in-process thread (the actual reason for overriding).
2. Extra env vars `JAC_SV_SIBLING=1` and `JAC_MICROSERVICE_CHILD=1`.
3. Registers an `AuthForwardingClient` in `_test_clients`.

Everything else — port picking, health polling, registration — is a
line-by-line copy. Extracting the shared pieces into helpers in core (or
accepting a `spawn_strategy` callable) would eliminate ~100 lines from this
plugin.

### 3.4 Env-var "defense-in-depth" that is actually redundant

Core already has an `is_sv_sibling: bool` constructor parameter on
`JacAPIServer` that prevents recursive eager-spawn
([jac/jaclang/runtimelib/server.jac:221](../jac/jaclang/runtimelib/server.jac#L221),
[impl/server.impl.jac:1815](../jac/jaclang/runtimelib/impl/server.impl.jac#L1815)).
This branch adds **two** environment-variable sentinels layered on top:

- `JAC_SV_SIBLING=1` — set by both
  [plugin.jac:745](jac_scale/plugin.jac#L745) and
  [process_manager.impl.jac:67](jac_scale/microservices/impl/process_manager.impl.jac#L67);
  checked only in [plugin.jac:32](jac_scale/plugin.jac#L32).
- `JAC_MICROSERVICE_CHILD=1` — set in
  [plugin.jac:744](jac_scale/plugin.jac#L744); never read.

The tech-debt doc
[day-10.7-technical-debt.md:38](docs/learn-and-do/day-10.7-technical-debt.md#L38)
flags this as *"fragile"* then rationalises keeping it as "defense-in-depth."
The env vars duplicate a signal core already carries and should be removed.

---

## 4. Code duplication

### 4.1 Hash-based port assignment — 3× copies

The `18000 + hash(module) % 1000`, 100-retry loop is duplicated:

| Location | Purpose |
|---|---|
| [jac/jaclang/jac0core/impl/runtime.impl.jac:1739-1756](../jac/jaclang/jac0core/impl/runtime.impl.jac#L1739-L1756) | core default (pre-existing) |
| [jac_scale/plugin.jac:706-723](jac_scale/plugin.jac#L706-L723) | plugin's `ensure_sv_service` hookimpl |
| [microservices/impl/process_manager.impl.jac:14-31](jac_scale/microservices/impl/process_manager.impl.jac#L14-L31) | process manager's `_assign_port` |

Both branch copies take a different `name` input (`module_name` vs
`service_entry.name`), so they can return different ports for what is
logically the same service. Consolidate through a helper in core or a single
helper in `microservices/`.

### 4.2 `jac` binary resolution — 2× copies

The `shutil.which("jac")` → `sys.executable`-parent fallback block appears
verbatim in [plugin.jac:748-760](jac_scale/plugin.jac#L748-L760) and
[process_manager.impl.jac:44-57](jac_scale/microservices/impl/process_manager.impl.jac#L44-L57).
Lift into a utility.

### 4.3 v1/v2 "backward compatibility" that has no prior version

[config_loader.impl.jac:344-372](jac_scale/impl/config_loader.impl.jac#L344-L372)
and [orchestrator.jac:23-60](jac_scale/microservices/orchestrator.jac#L23-L60)
carry dual support for both `[plugins.scale.microservices.routes]` (v2) and
`[plugins.scale.microservices.services.*]` (v1). This feature has never
shipped — the "backwards compatibility" is between local dev iterations, not
external consumers. [setup.jac:127-129](jac_scale/microservices/setup.jac#L127-L129)
still writes the v1 schema; the in-tree fixture
[test-microservices/jac.toml](test-microservices/jac.toml) is also v1. Pick
one, delete the other.

---

## 5. Anti-patterns vs. the rest of the repo

### 5.1 Dead gateway auth API preserved for tests

`MicroserviceGateway` exposes `validate_token`, `create_internal_token`,
`is_public_path`, plus three module-level globals `GW_JWT_SECRET`,
`GW_JWT_ALGORITHM`, `GW_JWT_EXP_DAYS`, `PUBLIC_PATHS`, and an
`internal_token_ttl` `has` field.

The actual `proxy_middleware` in
[gateway.impl.jac:200-339](jac_scale/microservices/impl/gateway.impl.jac#L200-L339)
never calls any of them — it comments *"Auth is handled by the services
themselves — gateway just passes the Authorization header through"*
([L276-L278](jac_scale/microservices/impl/gateway.impl.jac#L276-L278)).

Yet [tests/test_gateway.jac:456-513](jac_scale/tests/test_gateway.jac#L456-L513)
asserts these helpers exist and work. The tests keep the dead code alive.
This is the classic "keep the API around so tests pass after the real
behaviour was removed" pattern. Either:
- delete the helpers + tests (gateway is a pure passthrough), or
- wire them into the middleware.

### 5.2 Import-time config side effects

[gateway.jac:15-21](jac_scale/microservices/gateway.jac#L15-L21) calls
`get_scale_config().get_jwt_config()` at module import and stores the
secret/algorithm in `glob`s. Consequences:

- Importing `gateway` silently reads `jac.toml` from disk.
- Test isolation requires re-importing the module after mutating config.
- Secret rotation requires a restart.

[day-10.7-technical-debt.md:37](docs/learn-and-do/day-10.7-technical-debt.md#L37)
flags this as LOW priority: *"Load at `setup()` time"* — acknowledged debt
that was never fixed.

### 5.3 Gateway middleware is one 140-line closure

[gateway.impl.jac:201-339](jac_scale/microservices/impl/gateway.impl.jac#L201-L339)
inlines an `async def proxy_middleware(request, call_next)` that handles:
health, "built-in route passthrough" (tries every service, skips 404s —
acknowledged as O(N) in
[day-10.7-technical-debt.md:18](docs/learn-and-do/day-10.7-technical-debt.md#L18)),
admin redirects, admin asset serving, proxy prefix match, static files, SPA
fallback, final 404. Each branch is independently testable but lives in one
closure captured by `setup()`. Other jac-scale modules (see
[jserver/impl/jfast_api.impl.jac](jac_scale/jserver/impl/jfast_api.impl.jac))
keep per-method route handlers split into separate `impl` functions — the
microservices module does not.

### 5.4 Bubble-sort in `_rebuild_prefix_index`

[service_registry.impl.jac:51-62](jac_scale/microservices/impl/service_registry.impl.jac#L51-L62)
manually bubble-sorts `pairs` by prefix length, when
`pairs.sort(key=lambda p: -len(p[0]))` does the same. n is tiny so perf
doesn't matter, but it's a tell that the author was avoiding higher-order
functions — style mismatch with the rest of the Jac codebase, which uses
lambdas and comprehensions freely.

### 5.5 `.py` files in a `.jac` tree

Before this branch, `jac_scale/` contained `.py` only in `_optdeps/` (stub
for an optional dep). The branch introduces two new production `.py` files
inside `microservices/` and `microservices/impl/` side-by-side with `.jac`
modules. The stated reasons (type-checker limitations) don't hold — see 3.1.

### 5.6 `start_service` mutates a module-level registry

[process_manager.impl.jac:96-98](jac_scale/microservices/impl/process_manager.impl.jac#L96-L98)
and `.143-145` call `sv_client.register()` / `unregister()` directly. That's
reaching into another subsystem's private `_registry` dict from inside a
deployer method. The cleaner shape — matching
[ensure_sv_service](../jac/jaclang/runtimelib/sv_client.jac#L100-L123) — is
to have the deployer emit events / return URLs, and a single registration
seam live at one layer.

### 5.7 Startup `print()` vs. `logger`

[orchestrator.jac:166-181](jac_scale/microservices/orchestrator.jac#L166-L181)
emits the startup banner via bare `print()`, but uses `logger.info(...)` for
everything else nearby. Mixed logging strategy; rest of jac-scale is
consistent on `console.print` / `logger`.

### 5.8 Gateway pre-bootstraps admin UI on every cold start

[gateway.impl.jac:72-107](jac_scale/microservices/impl/gateway.impl.jac#L72-L107)
walks the bundled admin dist on boot, `rmtree`-ing and recopying
subdirectories if `admin_dist_dir/index.html` is missing. Runs
synchronously before serving traffic. Fine for dev, but no cache / version
check — the copy repeats for every fresh working directory.

### 5.9 Silent `except Exception` in `ensure_sv_service`

[plugin.jac:792-794](jac_scale/plugin.jac#L792-L794) uses a bare `except
Exception { time.sleep(0.1) }` inside the health-check poll loop. Any
misconfigured endpoint that raises synchronously will be silently retried
for 15 s. Core's equivalent
([jac/jaclang/jac0core/impl/runtime.impl.jac:1783](../jac/jaclang/jac0core/impl/runtime.impl.jac#L1783))
does the same thing — inherited anti-pattern, not introduced — but worth
noting.

---

## 6. Concrete delete / consolidate list

| Item | Action |
|---|---|
| [docs/learn-and-do/](docs/learn-and-do/) (29 files) | Delete — already untracked per commit `597087f23` |
| [PR_PLAN.md](PR_PLAN.md), [FOLLOWUPS.md](FOLLOWUPS.md), [microservices/FOLLOWUPS.md](jac_scale/microservices/FOLLOWUPS.md), [microservices/PROGRESS.md](jac_scale/microservices/PROGRESS.md) | Collapse into one tracker or delete pre-merge |
| [microservices/PLAN.md](jac_scale/microservices/PLAN.md) (1052 LOC) | Prune to final architecture doc |
| [microservice-mode-architecture.md](docs/microservice-mode-architecture.md) | Merge into `microservices/docs.md` |
| [test-microservices/](test-microservices/) | Delete or gitignore (scratch dir) |
| [examples/micr-s-example/components/TodoItem.cl.jac](examples/micr-s-example/components/TodoItem.cl.jac) | Delete (unused by example) |
| Duplicate port-assign / jac-binary-resolve | Extract to one helper, call from both sites |
| `JAC_MICROSERVICE_CHILD` env var | Delete (never read) |
| `JAC_SV_SIBLING` env var | Consider replacing with existing `is_sv_sibling` constructor arg |
| v1 `services.*` config schema | Pick one; drop the other + the merge logic |
| Dead auth helpers on `MicroserviceGateway` | Either wire into middleware or delete + delete tests |
| [impl/http_forward.py](jac_scale/microservices/impl/http_forward.py) | Port to `.jac` (sandbox_proxy precedent) |
| [sv_auth_client.py](jac_scale/microservices/sv_auth_client.py) | Replace with proper `sv_service_call` hookspec in core (deferred PR 0) |
| [plugin.jac](jac_scale/plugin.jac) `ensure_sv_service` | Factor helpers so only spawn-strategy + post-registration differ |
| Module-level JWT globals in `gateway.jac` | Load inside `setup()`; inject via constructor for tests |

---

## 7. Bottom line

The production surface is small (~1,600 LOC across the microservices module,
plus ~800 in the plugin) and functionally on-track — 93 tests pass per the
branch's own status doc. The rest of the 13k-line delta is:

- duplicate/overlapping planning documents (~3,000 LOC)
- abandoned tutorial series (~5,000 LOC)
- dual-schema "backwards compat" with no prior version
- two Python escape hatches into jaclang internals that both have proper
  hookspecs planned but deferred

Paths forward, in order of impact:

1. **Delete the doc/tracking files** that are not user-facing (≥5000 LOC
   drop without touching code).
2. **Land the core hookspec** (`sv_service_call`, per
   [PLAN.md Decision 2](jac_scale/microservices/PLAN.md)) so
   `sv_auth_client.py` can go away and the plugin's `ensure_sv_service`
   reimplementation can shrink to the 3 lines that are actually different.
3. **Pick one config schema** and delete the merge logic.
4. **Kill or wire** the dead auth helpers on the gateway.
5. Port `http_forward.py` to `.jac` using `sandbox_proxy.jac` as the
   template.
