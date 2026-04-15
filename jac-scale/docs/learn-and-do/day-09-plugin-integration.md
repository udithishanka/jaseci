# Day 9: Plugin Integration — Wiring It All Together

## Learn (~1 hour)

### How jac-scale's Plugin System Works

jac-scale uses **pluggy** — a plugin framework where:
1. A **host** defines hook specifications (what hooks exist)
2. **Plugins** implement hooks (what happens when a hook fires)
3. The **plugin manager** calls hooks and collects results

```
Hook: create_server()
  │
  ├── Default (jaclang): returns basic JacAPIServer
  └── jac-scale plugin: returns JFastApiServer with MongoDB, Redis, etc.
```

The plugin with the **highest priority** wins. jac-scale overrides jaclang's defaults.

### The Key Hooks for Microservice Mode

Looking at `plugin.jac`, these hooks are what we need to intercept:

| Hook | What it does | What we change |
|------|-------------|----------------|
| `create_cmd()` | Registers CLI commands | Add `jac setup microservice` |
| `create_server()` | Creates the HTTP server | Return gateway instead of single server |
| `_scale_pre_hook()` | Runs before `jac start` | If microservices enabled: start services + gateway |

### The Integration Point

When `jac start app.jac` runs:

```
Current flow:
  jac start app.jac
    → _scale_pre_hook() — if --scale, deploy to K8s
    → create_server() — create JFastApiServer
    → start server on port 8000

Microservice flow (what we're building):
  jac start app.jac
    → _scale_pre_hook():
        if microservices.enabled:
          1. Read service declarations from TOML
          2. Create ServiceRegistry, register all services
          3. Start ServiceProcessManager (launch subprocesses)
          4. Wait for services to be healthy
          5. Create MicroserviceGateway
          6. Start gateway (this blocks, like the normal server)
          7. On shutdown: stop all services
        elif --scale:
          ... existing K8s deploy flow ...
        else:
          ... existing single-server flow ...
```

### Signal Handling

When the user presses Ctrl+C:
1. Python receives SIGINT
2. The gateway's uvicorn server shuts down
3. We need to **also stop all service subprocesses**

This is done with `atexit` or signal handlers:

```python
import atexit
atexit.register(process_manager.stop_all)
```

---

## Do (~2-3 hours)

### Task 1: Create the orchestrator

This is the main entry point that ties registry + process manager + gateway together.

**`jac_scale/microservices/orchestrator.jac`**

```jac
"""Orchestrates the microservice mode lifecycle: registry → processes → gateway."""

import logging;
import from typing { Any }
import from jac_scale.microservices.registry { ServiceRegistry, ServiceEntry }
import from jac_scale.microservices.process_manager { ServiceProcessManager }
import from jac_scale.microservices.gateway { MicroserviceGateway }

glob logger = logging.getLogger(__name__);

"""
Bootstrap and run microservice mode.
This is the main entry point called from plugin.jac.

1. Reads service config from TOML
2. Builds the ServiceRegistry
3. Starts all service subprocesses
4. Waits for health checks
5. Starts the gateway (blocking)
6. On shutdown: stops all services
"""
def start_microservice_mode(config: dict[str, Any]) -> None;

"""
Build a ServiceRegistry from the TOML config dict.
"""
def build_registry(services_config: dict[str, Any]) -> ServiceRegistry;
```

### Task 2: Implement the orchestrator

**`jac_scale/microservices/impl/orchestrator.impl.jac`**

```jac
import time;
import atexit;
import logging;
import from jac_scale.microservices.orchestrator { start_microservice_mode, build_registry }
import from jac_scale.microservices.registry { ServiceRegistry, ServiceEntry }
import from jac_scale.microservices.process_manager { ServiceProcessManager }
import from jac_scale.microservices.gateway { MicroserviceGateway }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__);

:can:build_registry
(services_config: dict) -> ServiceRegistry {
    registry = ServiceRegistry();

    for (name, svc_config) in services_config.items() {
        entry = ServiceEntry(
            name=name,
            file=svc_config.get("file", ""),
            prefix=svc_config.get("prefix", f"/api/{name}"),
            port=svc_config.get("port", 0),
            replicas=svc_config.get("replicas", 1),
            env=svc_config.get("env", {})
        );
        registry.register(entry);
        logger.info(f"Registered service: {name} → {entry.prefix} ({entry.file})");
    }

    return registry;
}

:can:start_microservice_mode
(config: dict) -> None {
    ms_config = config.get("microservices", {});
    services_config = ms_config.get("services", {});

    if not services_config {
        logger.error("No services declared in [plugins.scale.microservices.services]");
        logger.error("Run `jac setup microservice` to configure services.");
        return;
    }

    # 1. Build registry
    registry = build_registry(services_config);
    logger.info(f"Registry: {len(registry.entries)} services");

    # 2. Start service subprocesses
    pm = ServiceProcessManager(registry=registry);
    pm.start_all();

    # Register cleanup on exit
    atexit.register(pm.stop_all);

    # 3. Wait for services to become healthy
    logger.info("Waiting for services to start...");
    max_wait = 30;  # seconds
    start_time = time.time();

    while time.time() - start_time < max_wait {
        results = pm.check_all_health();
        all_healthy = all(results.values());
        healthy_count = sum(1 for v in results.values() if v);

        if all_healthy {
            logger.info(f"All {len(results)} services healthy!");
            break;
        }

        logger.info(f"  {healthy_count}/{len(results)} services healthy, waiting...");
        time.sleep(2);
    } else {
        # Some services didn't become healthy
        for (name, healthy) in results.items() {
            if not healthy {
                logger.warning(f"  {name}: NOT HEALTHY");
            }
        }
        logger.warning("Proceeding with unhealthy services...");
    }

    # 4. Print startup banner
    jwt_config = get_scale_config().get_jwt_config();
    gateway_port = ms_config.get("gateway_port", 8000);
    gateway_host = ms_config.get("gateway_host", "0.0.0.0");

    print("\n" + "=" * 60);
    print("  JAC MICROSERVICE MODE");
    print("=" * 60);
    print(f"\n  Gateway: http://{gateway_host}:{gateway_port}");
    print(f"\n  Services:");
    for (name, entry) in registry.entries.items() {
        status_icon = "OK" if entry.status.value == "healthy" else "..";
        print(f"    [{status_icon}] {name:12s} {entry.prefix:20s} → {entry.url}");
    }

    client_config = ms_config.get("client", {});
    if client_config.get("entry") {
        print(f"\n  Client: {client_config['entry']}");
        print(f"  Static: {client_config.get('dist_dir', '.jac/client/dist')}");
    }
    print("\n" + "=" * 60 + "\n");

    # 5. Start gateway (blocking)
    gateway = MicroserviceGateway(
        registry=registry,
        port=gateway_port,
        host=gateway_host,
        jwt_secret=jwt_config["secret"],
        jwt_algorithm=jwt_config["algorithm"],
        client_dist_dir=client_config.get("dist_dir", ".jac/client/dist")
    );
    gateway.start();

    # 6. Cleanup (runs when gateway shuts down)
    pm.stop_all();
}
```

### Task 3: Wire into plugin.jac

This is the critical integration point. You need to modify `plugin.jac` to detect microservice mode and call the orchestrator.

Find the `_scale_pre_hook` function (or the hook that runs before `jac start`). Add a check **at the top**, before the existing `--scale` logic:

```jac
# Add this check early in the jac start flow:

scale_config = get_scale_config();
ms_config = scale_config.get("microservices", {});

if ms_config.get("enabled", False) and not is_scale_deploy {
    # Microservice mode — launch gateway + services locally
    import from jac_scale.microservices.orchestrator { start_microservice_mode }
    start_microservice_mode(scale_config);
    return;  # Don't continue to normal single-server start
}
```

Also register the `jac setup microservice` CLI command:

```jac
# In create_cmd() hook:
registry.extend_command(
    "setup",
    "microservice",
    "Configure microservice mode — select which Jac files become services",
    _setup_microservice_handler
);

def _setup_microservice_handler(args: Any) -> None {
    import from jac_scale.microservices.setup { run_setup }
    run_setup(
        project_root=".",
        add_file=getattr(args, "add", None),
        remove_service=getattr(args, "remove", None),
        list_services=getattr(args, "list", False)
    );
}
```

### Task 4: End-to-end test

```bash
cd test-microservices

# Make sure jac.toml has microservices enabled (from Day 8)
cat jac.toml

# Start in microservice mode!
jac start app.jac

# Expected output:
# ============================================================
#   JAC MICROSERVICE MODE
# ============================================================
#
#   Gateway: http://0.0.0.0:8000
#
#   Services:
#     [OK] orders       /api/orders          → http://127.0.0.1:8001
#     [OK] payments     /api/payments        → http://127.0.0.1:8002
#
#   Client: client/main.jac
#   Static: .jac/client/dist
#
# ============================================================

# In another terminal:
curl http://localhost:8000/health
curl http://localhost:8000/api/orders/list_orders
curl http://localhost:8000/api/payments/charge -X POST -H "Content-Type: application/json" -d '{"amount": 50}'

# Ctrl+C should stop gateway AND all service subprocesses
```

---

## Milestone

- [ ] `start_microservice_mode()` orchestrates the full lifecycle
- [ ] `jac start app.jac` detects `microservices.enabled` and launches gateway + services
- [ ] Startup banner shows all services, their status, and the gateway URL
- [ ] Ctrl+C cleanly shuts down gateway and all service subprocesses
- [ ] `jac setup microservice` is a registered CLI command
- [ ] Full flow works: setup → start → curl endpoints → shutdown

**You now understand**: how the plugin hook system works, how to intercept `jac start` to change behavior, how orchestration ties components together, and how signal handling ensures clean shutdown.
