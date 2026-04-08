"""Orchestrates the microservice mode lifecycle: registry -> processes -> gateway."""

import time;
import atexit;
import logging;
import from typing { Any }
import from jac_scale.microservices.service_registry { ServiceRegistry, ServiceEntry, ServiceStatus }
import from jac_scale.microservices.process_manager { ServiceProcessManager }
import from jac_scale.microservices.local_deployer { LocalDeployer }
import from jac_scale.microservices.gateway { MicroserviceGateway }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__);

"""Build a ServiceRegistry from the TOML services config dict."""
def build_registry(services_config: dict[str, Any]) -> ServiceRegistry {
    registry = ServiceRegistry();
    for (name, svc_config) in services_config.items() {
        svc_dict: dict = dict(svc_config);
        svc_entry = ServiceEntry(
            name=name,
            file=str(svc_dict.get("file", "")),
            prefix=str(svc_dict.get("prefix", f"/api/{name}")),
            port=int(svc_dict.get("port", 0)),
            replicas=int(svc_dict.get("replicas", 1))
        );
        registry.register(svc_entry);
        logger.info(f"Registered service: {name} -> {svc_entry.prefix} ({svc_entry.file})");
    }
    return registry;
}

"""
Bootstrap and run microservice mode locally.

1. Reads service config from TOML
2. Builds the ServiceRegistry
3. Starts all service subprocesses
4. Waits for health checks
5. Starts the gateway (blocking)
6. On shutdown: stops all services
"""
def start_microservice_mode(ms_config: dict[str, Any]) -> None {
    services_config = ms_config.get("services", {});

    if not services_config {
        logger.error("No services declared in [plugins.scale.microservices.services]");
        logger.error("Run `jac setup microservice` to configure services.");
        return;
    }

    # 0. Build client if configured
    client_config = ms_config.get("client", {});
    client_entry: str = str(dict(client_config).get("entry", "")) if client_config else "";
    client_dist: str = str(dict(client_config).get("dist_dir", ".jac/client/dist")) if client_config else ".jac/client/dist";

    if client_entry {
        import subprocess;
        import from pathlib { Path }
        dist_path = Path(client_dist);
        index_file = dist_path / "index.html";

        if not index_file.exists() {
            print(f"Building client from {client_entry}...");
            try {
                build_result = subprocess.run(
                    ["jac", "build", client_entry],
                    timeout=120
                );
                if build_result.returncode == 0 {
                    print("Client build complete");
                } else {
                    logger.warning("Client build failed — gateway will start without client UI");
                }
            } except subprocess.TimeoutExpired {
                logger.warning("Client build timed out");
            } except FileNotFoundError {
                logger.warning("jac build command not found");
            }
        } else {
            logger.info("Client already built, skipping build");
        }
    }

    # 1. Build registry
    registry = build_registry(services_config);
    logger.info(f"Registry: {len(registry.entries)} services");

    # 2. Start services via deployer
    deployer = LocalDeployer(registry=registry);
    deployer.deploy_all();
    pm = deployer._ensure_pm();

    # Register cleanup on exit
    atexit.register(deployer.destroy_all);

    # 3. Wait for services to become healthy
    logger.info("Waiting for services to start...");
    max_wait: int = 30;
    start_time: float = time.time();
    all_healthy = False;

    while time.time() - start_time < max_wait {
        results = pm.check_all_health();
        healthy_count: int = 0;
        for v in results.values() {
            if v {
                healthy_count += 1;
            }
        }
        if healthy_count == len(results) {
            all_healthy = True;
            logger.info(f"All {len(results)} services healthy!");
            break;
        }
        logger.info(f"  {healthy_count}/{len(results)} services healthy, waiting...");
        time.sleep(2);
    }

    if not all_healthy {
        for (name, entry) in registry.entries.items() {
            if entry.status != ServiceStatus.HEALTHY {
                logger.warning(f"  {name}: NOT HEALTHY");
            }
        }
        logger.warning("Proceeding with unhealthy services...");
    }

    # 4. Print startup banner
    jwt_config = get_scale_config().get_jwt_config();
    gateway_port: int = int(ms_config.get("gateway_port", 8000));
    gateway_host: str = str(ms_config.get("gateway_host", "0.0.0.0"));
    client_config = ms_config.get("client", {});
    client_dist: str = str(dict(client_config).get("dist_dir", ".jac/client/dist")) if client_config else ".jac/client/dist";

    print("\n" + "=" * 60);
    print("  JAC MICROSERVICE MODE");
    print("=" * 60);
    print(f"\n  Gateway: http://{gateway_host}:{gateway_port}");
    print(f"\n  Services:");
    for (name, entry) in registry.entries.items() {
        status_icon = "OK" if entry.status == ServiceStatus.HEALTHY else "..";
        print(f"    [{status_icon}] {name:12s} {entry.prefix:20s} -> {entry.url}");
    }

    if client_config and dict(client_config).get("entry") {
        print(f"\n  Client: {dict(client_config)['entry']}");
        print(f"  Static: {client_dist}");
    }
    print("\n" + "=" * 60 + "\n");

    # 5. Start gateway (blocking)
    gateway = MicroserviceGateway(
        registry=registry,
        port=gateway_port,
        host=gateway_host,
        client_dist_dir=client_dist
    );
    gateway.start();

    # 6. Cleanup (runs when gateway shuts down)
    deployer.destroy_all();
}
