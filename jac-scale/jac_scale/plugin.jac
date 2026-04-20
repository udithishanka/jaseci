"""File covering plugin implementation."""
import os;
import pathlib;
import from dotenv { load_dotenv }
import from jaclang.cli.registry { get_registry }
import from jaclang.cli.command { Arg, ArgKind, CommandPriority, HookContext }
import from jaclang.cli.console { console }
import from rich.table { Table }
import from jaclang.jac0core.runtime { hookimpl, plugin_manager }
import from jaclang.runtimelib.context { ExecutionContext }
import from jaclang.runtimelib.server { JacAPIServer as JacServer }
import from .context { JScaleExecutionContext }
import from .serve { JacAPIServer }
import from .jserver.jfast_api { JFastApiServer }
import from .config_loader { get_scale_config }
import from .factories.deployment_factory { DeploymentTargetFactory }
import from .factories.registry_factory { ImageRegistryFactory }
import from .factories.utility_factory { UtilityFactory }
import from .abstractions.config.app_config { AppConfig }
import from .user_manager { JacScaleUserManager }
import from jaclang.runtimelib.server { UserManager }
import from jaclang.runtimelib.storage { Storage }

"""Pre-hook for jac start command to handle microservice mode and --scale flag."""
def _scale_pre_hook(context: HookContext) -> None {
    # Microservice mode: services are spawned on-demand by core's BFS
    # discovery + our ensure_sv_service hookimpl. The pre-hook only
    # bootstraps the gateway for client-facing routing when enabled
    # and we're NOT already running as an sv sibling child.
    scale_config = get_scale_config();
    ms_config = scale_config.get_microservices_config();
    is_sv_sibling = os.environ.get("JAC_SV_SIBLING") == "1";

    if ms_config.get("enabled", False) and not is_sv_sibling {
        scale_flag = context.get_arg("scale", False);
        if not scale_flag {
            import from jac_scale.microservices.orchestrator { start_microservice_mode }
            start_microservice_mode(ms_config);
            context.set_data("cancel_execution", True);
            context.set_data("cancel_return_code", 0);
            return;
        }
        # If --scale is set with microservices enabled, fall through to K8s deploy
    }

    scale = context.get_arg("scale", False);
    if scale {
        filename = context.get_arg("filename");
        target = context.get_arg("target", "kubernetes");
        if not os.path.exists(filename) {
            raise FileNotFoundError(f"File not found: '{filename}'");
        }
        code_folder = os.path.dirname(filename) or '.';
        dotenv_path = os.path.join(code_folder, '.env');
        load_dotenv(dotenv_path);
        # Get configuration
        scale_config = get_scale_config();
        # Create logger
        logger = UtilityFactory.create_logger('standard');
        # Get target-specific config
        if target == 'kubernetes' {
            target_config = scale_config.get_kubernetes_config();
        } else {
            # Custom targets load config from [plugins.scale.<target>]
            target_config = scale_config.get_section(target);
        }
        # Create deployment target
        deployment_target = DeploymentTargetFactory.create(
            target, target_config, logger
        );

        # Handle --enable-tls: patch TLS on the live deployment (no redeploy)
        enable_tls = context.get_arg("enable_tls", False);
        if enable_tls {
            if not target_config.get('domain', '') {
                raise ValueError(
                    "No domain configured. Set 'domain' under [plugins.scale.kubernetes] in jac.toml before running --enable-tls."
                );
            }
            if not target_config.get('cert_manager_email', '') {
                raise ValueError(
                    "No cert_manager_email configured. Set 'cert_manager_email' under [plugins.scale.kubernetes] in jac.toml before running --enable-tls."
                );
            }
            app_name = target_config.get('app_name', 'jaseci');
            deployment_target.enable_tls(app_name);
            context.set_data("cancel_execution", True);
            context.set_data("cancel_return_code", 0);
            return;
        }

        build = context.get_arg("build", False);
        experimental = context.get_arg("experimental", False);
        registry = context.get_arg("registry", "dockerhub");
        code_folder = os.path.relpath(code_folder);
        code_folder = pathlib.Path(code_folder).as_posix();
        base_file_path = os.path.basename(filename);
        # Resolve secrets from [plugins.scale.secrets] config
        deployment_target.secrets = scale_config.get_secrets_config();
        # Handle image registry if build is requested
        if build {
            image_registry = ImageRegistryFactory.create(registry, target_config);
            deployment_target.image_registry = image_registry;
        }
        # Create app config
        app_config = AppConfig(
            code_folder=code_folder,
            file_name=base_file_path,
            build=build,
            experimental=experimental
        );
        if experimental {
            console.print(
                "Installing Jaseci packages from repository (experimental mode)..."
            );
        } else {
            console.print("Installing Jaseci packages from PyPI...");
        }
        # Deploy
        result = deployment_target.deploy(app_config);
        if not result.success {
            raise RuntimeError(result.message or "Deployment failed");
        }
        if result.service_url {
            console.print(
                f"Deployment complete! Service available at: {result.service_url}"
            );
        }
        # Cancel normal start execution since we handled it
        context.set_data("cancel_execution", True);
        context.set_data("cancel_return_code", 0);
    }
}

"""Print deployment status as a formatted table."""
def _print_deployment_status(status_data: dict) -> None {
    app_name = status_data.get('app_name', 'unknown');
    namespace = status_data.get('namespace', 'default');
    components = status_data.get('components', []);
    urls = status_data.get('urls', {});
    error = status_data.get('error');

    console.print();
    console.print("[bold cyan]  Jac Scale — Deployment Status[/bold cyan]");
    console.print(
        f"  [bold]App:[/bold] {app_name}   [bold]Namespace:[/bold] {namespace}"
    );
    console.print();

    if error {
        console.print(f"  [bold red]Cannot connect to cluster:[/bold red] {error}");
        console.print();
        return;
    }

    table = Table(show_header=True, header_style="bold dim", box=None, padding=(0, 2));
    table.add_column("Component", min_width=18);
    table.add_column("Status", min_width=22);
    table.add_column("Pods", justify="right", min_width=6);

    status_display = {
        'running': '[bold green]● Running[/bold green]',
        'degraded': '[bold yellow]◑ Degraded[/bold yellow]',
        'pending': '[bold yellow]⟳ Pending[/bold yellow]',
        'restarting': '[bold red]↺ Restarting[/bold red]',
        'failed': '[bold red]✗ Failed[/bold red]',
        'not_deployed': '[dim]○ Not Deployed[/dim]',
        'unknown': '[dim]? Unknown[/dim]',

    };

    for comp in components {
        s = comp.get('status', 'unknown');
        ready = comp.get('ready', 0);
        total = comp.get('total', 0);
        icon = status_display.get(s, s);
        if s in ['not_deployed', 'unknown'] {
            pods_str = '—';
        } else {
            pods_str = f"{ready}/{total}";
        }
        table.add_row(comp.get('name', ''), icon, pods_str);
    }

    console.print(table);

    if urls {
        console.print("  [bold]Service URLs[/bold]");
        console.print(f"  [dim]{'─' * 48}[/dim]");
        if 'app' in urls {
            console.print(f"  [bold]Application:[/bold]   {urls['app']}");
        }
        if 'grafana' in urls {
            console.print(f"  [bold]Grafana:[/bold]       {urls['grafana']}");
        }
        if 'redis_insight' in urls {
            console.print(f"  [bold]RedisInsight:[/bold]  {urls['redis_insight']}");
        }
        if 'mongo_express' in urls {
            console.print(f"  [bold]Mongo Express:[/bold] {urls['mongo_express']}");
        }
        console.print();
    }
}

"""Jac CLI."""
class JacCmd {
    """Create Jac CLI cmds."""
    @hookimpl
    static def create_cmd {
        """Jac Scale functionality.""";
        registry = get_registry();

        # Extend jac start with --scale and related flags
        registry.extend_command(
            "start",
            args=[
                Arg.create(
                    "scale",
                    typ=bool,
                    default=False,
                    help="Deploy to a target platform instead of running locally",
                    short=""  # Disable auto-generated -s (conflicts with --session)
                ),
                Arg.create(
                    "build",
                    typ=bool,
                    default=False,
                    help="Build and push Docker image (with --scale)",
                    short="b"
                ),
                Arg.create(
                    "experimental",
                    typ=bool,
                    default=False,
                    help="Use experimental mode (install from repo instead of PyPI)",
                    short="e"
                ),
                Arg.create(
                    "target",
                    typ=str,
                    default="kubernetes",
                    help="Deployment target (kubernetes, aws, gcp, etc.)",
                ),
                Arg.create(
                    "registry",
                    typ=str,
                    default="dockerhub",
                    help="Image registry (dockerhub, ecr, gcr, etc.)",
                ),
                Arg.create(
                    "enable-tls",
                    typ=bool,
                    default=False,
                    help="Enable HTTPS via Let's Encrypt (run after pointing your domain CNAME to the NLB)",
                    short=""
                ),

            ],
            pre_hook=_scale_pre_hook,
            source="jac-scale"
        );

        @registry.command(
            name="destroy",
            help="Remove deployment from target platform",
            args=[
                Arg.create(
                    "file_path", kind=ArgKind.POSITIONAL, help="Path to .jac file"
                ),
                Arg.create(
                    "target",
                    typ=str,
                    default="kubernetes",
                    help="Deployment target (kubernetes, aws, gcp, etc.)",
                ),
                Arg.create(
                    "component",
                    typ=str,
                    default="",
                    help="Component to destroy (default: entire deployment). Choices: application, database, cache, monitoring, dashboard",
                ),

            ],
            examples=[
                ("jac destroy app.jac", "Remove entire deployment for app"),
                (
                    "jac destroy app.jac --component application",
                    "Remove only the application"
                ),
                ("jac destroy app.jac --component database", "Remove only MongoDB"),
                ("jac destroy app.jac --component cache", "Remove only Redis"),
                (
                    "jac destroy app.jac --component monitoring",
                    "Remove only monitoring stack"
                ),
                (
                    "jac destroy app.jac --component dashboard",
                    "Remove only dashboards (Mongo Express + RedisInsight)"
                ),

            ],
            group="deployment",
            priority=CommandPriority.PLUGIN,
            source="jac-scale"
        )
        def destroy(
            file_path: str, target: str = "kubernetes", component: str = ""
        ) -> int {
            if not os.path.exists(file_path) {
                raise FileNotFoundError(f"File not found: '{file_path}'");
            }

            valid_components = [
                "application",
                "database",
                "cache",
                "monitoring",
                "dashboard"
            ];
            if component and target != 'kubernetes' {
                console.print(
                    f"[bold red]ERROR:[/bold red] --component is only supported for the 'kubernetes' target."
                );
                return 1;
            }
            if component and component not in valid_components {
                console.print(
                    f"[bold red]ERROR:[/bold red] Invalid component '{component}'. Valid choices: {', '.join(
                        valid_components
                    )}"
                );
                return 1;
            }

            code_folder = os.path.dirname(file_path) or '.';
            dotenv_path = os.path.join(code_folder, '.env');
            load_dotenv(dotenv_path);

            # Get configuration
            scale_config = get_scale_config();

            # Create logger
            logger = UtilityFactory.create_logger('standard');

            # Get target-specific config
            if target == 'kubernetes' {
                target_config = scale_config.get_kubernetes_config();
            } else {
                # Custom targets load config from [plugins.scale.<target>]
                target_config = scale_config.get_section(target);
            }

            app_name = target_config.get('app_name', 'jaseci');
            namespace = target_config.get('namespace', 'default');

            # Warn user and require confirmation before proceeding
            if component {
                console.print(
                    f"[bold red]WARNING:[/bold red] You are about to delete component '{component}' from deployment '{app_name}'."
                );
            } else {
                console.print(
                    f"[bold red]WARNING:[/bold red] You are about to delete namespace '{namespace}' and all its associated resources."
                );
            }
            confirmation = input(
                "Are you sure you want to proceed? (y/n): "
            ).strip().lower();
            if confirmation != 'y' {
                console.print("Destroy cancelled.");
                return 1;
            }

            # Create deployment target and destroy
            deployment_target = DeploymentTargetFactory.create(
                target, target_config, logger
            );
            deployment_target.destroy(app_name, component);

            if component {
                console.print(
                    f"Successfully destroyed component '{component}' from '{app_name}'"
                );
            } else {
                console.print(
                    f"Successfully destroyed deployment '{app_name}' from {target}"
                );
            }
            return 0;
        }

        @registry.command(
            name="status",
            help="Show deployment status of jaseci application on target platform",
            args=[
                Arg.create(
                    "file_path", kind=ArgKind.POSITIONAL, help="Path to .jac file"
                ),
                Arg.create(
                    "target",
                    typ=str,
                    default="kubernetes",
                    help="Deployment target (kubernetes, aws, gcp, etc.)",
                ),

            ],
            examples=[("jac status app.jac", "Show deployment status of app"), ],
            group="deployment",
            priority=CommandPriority.PLUGIN,
            source="jac-scale"
        )
        def status(file_path: str, target: str = "kubernetes") -> int {
            if not os.path.exists(file_path) {
                raise FileNotFoundError(f"File not found: '{file_path}'");
            }
            code_folder = os.path.dirname(file_path) or '.';
            dotenv_path = os.path.join(code_folder, '.env');
            load_dotenv(dotenv_path);

            # Get configuration
            scale_config = get_scale_config();

            # Create logger
            logger = UtilityFactory.create_logger('standard');

            # Get target-specific config
            if target == 'kubernetes' {
                target_config = scale_config.get_kubernetes_config();
            } else {
                # Custom targets load config from [plugins.scale.<target>]
                target_config = scale_config.get_section(target);
            }

            # Create deployment target
            deployment_target = DeploymentTargetFactory.create(
                target, target_config, logger
            );
            app_name = target_config.get('app_name', 'jaseci');

            # Get and display status
            status_data = deployment_target.get_full_status(app_name);
            _print_deployment_status(status_data);
            return 0;
        }

        @registry.command(
            name="setup",
            help="Configure microservice mode — select which Jac files become services",
            args=[
                Arg.create(
                    "subcommand", kind=ArgKind.POSITIONAL,
                    help="Setup type (currently: microservice)"
                ),
                Arg.create(
                    "add", typ=str, default="",
                    help="Add a service file to existing config"
                ),
                Arg.create(
                    "remove", typ=str, default="",
                    help="Remove a service by name"
                ),
                Arg.create(
                    "list", typ=bool, default=False,
                    help="List currently configured services"
                ),
            ],
            examples=[
                ("jac setup microservice", "Interactive setup — select files, write config"),
                ("jac setup microservice --list", "Show current microservice config"),
                ("jac setup microservice --add orders_app.jac", "Add a service"),
                ("jac setup microservice --remove orders", "Remove a service"),
            ],
            group="microservices",
            priority=CommandPriority.PLUGIN,
            source="jac-scale"
        )
        def setup_cmd(
            subcommand: str,
            add: str = "",
            remove: str = "",
            list: bool = False
        ) -> int {
            if subcommand != "microservice" {
                console.print(
                    f"[bold red]Unknown setup type:[/bold red] '{subcommand}'. Use 'microservice'."
                );
                return 1;
            }

            import from jac_scale.microservices.setup {
                run_setup, add_service, remove_service, list_services
            }

            if list {
                list_services(".");
            } elif add {
                add_service(".", add);
            } elif remove {
                remove_service(".", remove);
            } else {
                run_setup(".");
            }
            return 0;
        }

        @registry.command(
            name="scale",
            help="Manage microservice deployments — status, stop, restart, logs",
            args=[
                Arg.create(
                    "action", kind=ArgKind.POSITIONAL,
                    help="Action: status, stop, restart, logs, destroy"
                ),
                Arg.create(
                    "service_name", kind=ArgKind.POSITIONAL, default="",
                    help="Service name (required for stop, restart, logs)"
                ),
                Arg.create(
                    "lines", typ=int, default=50,
                    help="Number of log lines to show (for 'logs' action)"
                ),
            ],
            examples=[
                ("jac scale status", "Show status of all microservices"),
                ("jac scale stop orders", "Stop the orders service"),
                ("jac scale restart cart", "Restart the cart service"),
                ("jac scale logs products", "Show logs for products service"),
                ("jac scale destroy", "Stop all services"),
            ],
            group="microservices",
            priority=CommandPriority.PLUGIN,
            source="jac-scale"
        )
        def scale_cmd(
            action: str,
            service_name: str = "",
            lines: int = 50
        ) -> int {
            import from jac_scale.microservices.orchestrator { build_registry }
            import from jac_scale.microservices.local_deployer { LocalDeployer }

            scale_config = get_scale_config();
            ms_config = scale_config.get_microservices_config();

            if not ms_config.get("enabled", False) {
                console.print("[bold red]Microservice mode is not enabled in jac.toml[/bold red]");
                return 1;
            }

            services_config = ms_config.get("services", {});
            if not services_config {
                console.print("[bold red]No services configured[/bold red]");
                return 1;
            }

            registry = build_registry(services_config);
            deployer = LocalDeployer(registry=registry, target="local");

            if action == "status" {
                svc_status = deployer.status();
                console.print();
                console.print("[bold cyan]  Microservice Status[/bold cyan]");
                console.print();
                for (name, info) in svc_status.items() {
                    status_str = info.get("status", "unknown");
                    running = info.get("running", False);
                    port = info.get("port", 0);
                    pid = info.get("pid");
                    prefix = info.get("prefix", "");
                    if running {
                        console.print(
                            f"  [green]●[/green] {name:12s} {prefix:20s} port={port} pid={pid}"
                        );
                    } else {
                        console.print(
                            f"  [red]○[/red] {name:12s} {prefix:20s} (not running)"
                        );
                    }
                }
                console.print();

            } elif action == "stop" {
                if not service_name {
                    console.print("[bold red]Service name required: jac scale stop <name>[/bold red]");
                    return 1;
                }
                if deployer.stop_service(service_name) {
                    console.print(f"[green]Stopped {service_name}[/green]");
                } else {
                    console.print(f"[red]Failed to stop {service_name}[/red]");
                    return 1;
                }

            } elif action == "restart" {
                if not service_name {
                    console.print("[bold red]Service name required: jac scale restart <name>[/bold red]");
                    return 1;
                }
                if deployer.restart_service(service_name) {
                    console.print(f"[green]Restarted {service_name}[/green]");
                } else {
                    console.print(f"[red]Failed to restart {service_name}[/red]");
                    return 1;
                }

            } elif action == "logs" {
                if not service_name {
                    console.print("[bold red]Service name required: jac scale logs <name>[/bold red]");
                    return 1;
                }
                log_output = deployer.get_logs(service_name, lines);
                console.print(log_output);

            } elif action == "destroy" {
                deployer.destroy_all();
                console.print("[green]All services stopped[/green]");

            } else {
                console.print(f"[bold red]Unknown action:[/bold red] '{action}'");
                console.print("Actions: status, stop, restart, logs, destroy");
                return 1;
            }

            return 0;
        }
    }
}

"""Jac Scale Plugin Implementation."""
class JacScalePlugin {
    @hookimpl
    static def create_j_context(user_root: (str | None)) -> ExecutionContext {
        # Storage backend configured via environment (MONGODB_URI, etc.)
        ctx = JScaleExecutionContext();
        if user_root is not None {
            ctx.set_user_root(user_root);
        }
        return ctx;
    }

    """Create the API server instance.

    Note: jac-scale doesn't bind the port until run_server is called.
    Port fallback is handled in run_server.
    """
    @hookimpl
    static def create_server(
        jac_server: JacServer, host: str, port: int
    ) -> JFastApiServer {
        return JFastApiServer([]);
    }

    """Provide jac-scale's enhanced JacAPIServer class."""
    @hookimpl
    static def get_api_server_class -> type {
        return JacAPIServer;
    }

    """Provide jac-scale's UserManager."""
    @hookimpl
    static def get_user_manager(base_path: str) -> UserManager {
        return JacScaleUserManager(base_path=base_path);
    }

    """Provide jac-scale's storage backend.

    This overrides the core store() to use jac-scale's StorageFactory,
    which supports cloud backends (S3, GCS, Azure) via configuration.
    """
    @hookimpl
    static def store(
        base_path: str = "./storage", create_dirs: bool = True
    ) -> Storage {
        import from .factories.storage_factory { StorageFactory }
        return StorageFactory.get_default(base_path, create_dirs);
    }

    """Spawn a sibling sv-service as a subprocess via LocalDeployer.

    Overrides core's default (which spawns an in-process thread). We spawn
    as a subprocess so each service has its own ModuleIntrospector, graph,
    and lifecycle — matching K8s pod semantics in production.

    Called by sv_client._ensure_available when a consumer does
    sv import from X and X is not yet registered.
    """
    @hookimpl
    static def ensure_sv_service(module_name: str, base_path: str) -> None {
        import os;
        import socket;
        import time;
        import urllib.request;
        import from jaclang.runtimelib { sv_client }
        import from pathlib { Path }

        # Idempotent: skip if already registered
        if module_name in sv_client._registry {
            return;
        }
        if module_name in sv_client._test_clients {
            return;
        }

        # Hash-based port: deterministic per module name, 100 retries
        base_port = 18000 + (hash(module_name) % 1000);
        port = base_port;
        bind_ok = False;
        for _ in range(100) {
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1);
            try {
                s.bind(('127.0.0.1', port));
                s.close();
                bind_ok = True;
                break;
            } except OSError {
                s.close();
                port = port + 1;
            }
        }
        if not bind_ok {
            raise RuntimeError(f"Could not find free port near {base_port}");
        }

        # Resolve module path: look for {module_name}.jac in base_path
        base_dir = Path(base_path);
        module_file = base_dir / f"{module_name}.jac";
        if not module_file.exists() {
            raise RuntimeError(
                f"sv-to-sv service '{module_name}': file not found at {module_file}"
            );
        }

        # Per-service data isolation: .jac/data/{module_name}/
        data_dir = base_dir / ".jac" / "data" / module_name;
        data_dir.mkdir(parents=True, exist_ok=True);

        # Spawn subprocess with JAC_DATA_DIR, JAC_MICROSERVICE_CHILD,
        # and JAC_SV_SIBLING to prevent recursive orchestration
        import subprocess;
        child_env = dict(os.environ);
        child_env["JAC_DATA_DIR"] = str(data_dir);
        child_env["JAC_MICROSERVICE_CHILD"] = "1";
        child_env["JAC_SV_SIBLING"] = "1";

        cmd = [
            "jac", "start", str(module_file),
            "--port", str(port), "--no_client"
        ];

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=child_env,
            cwd=str(base_dir)
        );

        # Wait for service to become responsive
        base_url = f"http://127.0.0.1:{port}";
        deadline = time.time() + 15.0;
        healthy = False;
        while time.time() < deadline {
            if proc.poll() is not None {
                raise RuntimeError(
                    f"sv-to-sv service '{module_name}' subprocess exited (code {proc.returncode})"
                );
            }
            try {
                with urllib.request.urlopen(f"{base_url}/healthz", timeout=1) as resp {
                    if resp.status < 500 {
                        healthy = True;
                        break;
                    }
                }
            } except Exception {
                time.sleep(0.1);
            }
        }

        if not healthy {
            proc.terminate();
            raise RuntimeError(
                f"sv-to-sv service '{module_name}' did not become healthy at {base_url}"
            );
        }

        sv_client.register(module_name, base_url);

        # Register cleanup
        import atexit;
        def _cleanup {
            if proc.poll() is None {
                proc.terminate();
            }
        }
        atexit.register(_cleanup);
    }
}

# Pluggy's varnames() puts parameters with defaults into kwargnames, not argnames.
# But _multicall only passes argnames to hook implementations.
# JacRuntimeInterfaceImpl strips defaults via generate_plugin_helpers, so we must too.
import inspect;
glob func = JacScalePlugin.create_j_context,
     sig = inspect.signature(func),
     sig_nodef = sig.replace(
         parameters=[
             p.replace(default=inspect.Parameter.empty) for p in sig.parameters.values()
         ]
     );

with entry {
    func.__signature__ = sig_nodef;
    plugin_manager.register(JacScalePlugin());
}
