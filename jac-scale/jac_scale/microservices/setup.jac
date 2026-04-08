"""Interactive CLI for configuring microservice mode.

Commands:
  jac setup microservice          — interactive setup
  jac setup microservice --list   — show current config
  jac setup microservice --add <file>    — add a service
  jac setup microservice --remove <name> — remove a service
"""

import os;
import tomllib;
import from pathlib { Path }

"""Scan the project for .jac files, excluding build artifacts."""
def scan_jac_files(project_root: str = ".") -> list[str] {
    base_dir = Path(project_root);
    exclude_dirs: set[str] = {".jac", "__pycache__", "node_modules", ".git", "dist", "build", "__jac_gen__"};
    jac_files: list[str] = [];

    for f in base_dir.rglob("*.jac") {
        parts = f.relative_to(base_dir).parts;
        should_skip = False;
        for part in parts {
            if part in exclude_dirs {
                should_skip = True;
            }
        }
        if not should_skip {
            jac_files.append(str(f.relative_to(base_dir)));
        }
    }

    jac_files.sort();
    return jac_files;
}

"""Derive a service name from a file path. orders_app.jac -> orders"""
def derive_service_name(file_path: str) -> str {
    name: str = Path(file_path).stem;
    if name.endswith("_app") {
        name = name[:-4];
    }
    return name;
}

"""Derive a route prefix from a service name. orders -> /api/orders"""
def derive_prefix(service_name: str) -> str {
    return f"/api/{service_name}";
}

"""Run the interactive setup flow — scan project, prompt user, write TOML."""
def run_setup(project_root: str = ".") -> None {
    toml_path = Path(project_root) / "jac.toml";

    jac_files = scan_jac_files(project_root);
    if not jac_files {
        print("No .jac files found in project.");
        return;
    }

    print("\nFound .jac files:");
    for (i, f) in enumerate(jac_files) {
        print(f"  {i + 1}. {f}");
    }

    selection = input("\nSelect files to run as microservices (comma-separated numbers): ").strip();
    if not selection {
        print("No services selected. Exiting.");
        return;
    }

    selected_indices: list[int] = [];
    for x in selection.split(",") {
        stripped = x.strip();
        if stripped.isdigit() {
            selected_indices.append(int(stripped) - 1);
        }
    }

    selected_files: list[str] = [];
    for i in selected_indices {
        if 0 <= i < len(jac_files) {
            selected_files.append(jac_files[i]);
        }
    }

    if not selected_files {
        print("No valid files selected. Exiting.");
        return;
    }

    client_entry = input("\nClient UI entry point (leave blank for none): ").strip();

    # Preserve existing jac.toml content, strip old microservices section
    lines: list[str] = [];
    if toml_path.exists() {
        existing = toml_path.read_text();
        skip_section = False;
        for line in existing.split("\n") {
            if line.strip().startswith("[plugins.scale.microservices") {
                skip_section = True;
            } elif line.strip().startswith("[") and skip_section {
                if not line.strip().startswith("[plugins.scale.microservices") {
                    skip_section = False;
                    lines.append(line);
                }
            } elif not skip_section {
                lines.append(line);
            }
        }
        while lines and not lines[-1].strip() {
            lines.pop();
        }
        lines.append("");
    }

    # Write microservices config
    lines.append("[plugins.scale.microservices]");
    lines.append("enabled = true");
    lines.append("gateway_port = 8000");
    lines.append('gateway_host = "0.0.0.0"');
    lines.append("");

    for file_path in selected_files {
        name = derive_service_name(file_path);
        prefix = derive_prefix(name);
        lines.append(f"[plugins.scale.microservices.services.{name}]");
        lines.append(f'file = "{file_path}"');
        lines.append(f'prefix = "{prefix}"');
        lines.append("");
    }

    if client_entry {
        lines.append("[plugins.scale.microservices.client]");
        lines.append(f'entry = "{client_entry}"');
        lines.append('dist_dir = ".jac/client/dist"');
        lines.append('base_route = "/"');
        lines.append("");
    }

    toml_path.write_text("\n".join(lines));

    print(f"\nAdded microservice config to jac.toml:");
    for file_path in selected_files {
        name = derive_service_name(file_path);
        print(f"  - {name:12s} -> {derive_prefix(name):20s} ({file_path})");
    }
    if client_entry {
        print(f"  - {'client':12s} -> {client_entry}");
    }
    print(f"\nRun `jac start main.jac` to launch locally.");
}

"""Add a single service to existing config."""
def add_service(project_root: str, file_path: str) -> None {
    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found. Run `jac setup microservice` first.");
        return;
    }

    name = derive_service_name(file_path);
    prefix = derive_prefix(name);

    with open(str(toml_path), "rb") as f {
        doc = tomllib.load(f);
    }
    ms = doc.get("plugins", {}).get("scale", {}).get("microservices", {});
    services = ms.get("services", {});
    if name in services {
        print(f"Service '{name}' already exists. Remove it first with --remove.");
        return;
    }

    content = toml_path.read_text();
    content += f"\n[plugins.scale.microservices.services.{name}]\n";
    content += f'file = "{file_path}"\n';
    content += f'prefix = "{prefix}"\n';
    toml_path.write_text(content);

    print(f"Added service: {name} -> {prefix} ({file_path})");
}

"""Remove a service from config by name."""
def remove_service(project_root: str, service_name: str) -> None {
    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found.");
        return;
    }

    content = toml_path.read_text();
    section_header = f"[plugins.scale.microservices.services.{service_name}]";

    if section_header not in content {
        print(f"Service '{service_name}' not found in config.");
        return;
    }

    new_lines: list[str] = [];
    skip_section = False;
    for line in content.split("\n") {
        if line.strip() == section_header {
            skip_section = True;
        } elif line.strip().startswith("[") and skip_section {
            skip_section = False;
            new_lines.append(line);
        } elif not skip_section {
            new_lines.append(line);
        }
    }

    toml_path.write_text("\n".join(new_lines));
    print(f"Removed service: {service_name}");
}

"""List currently configured services."""
def list_services(project_root: str) -> None {
    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found.");
        return;
    }

    with open(str(toml_path), "rb") as f {
        doc = tomllib.load(f);
    }

    ms = doc.get("plugins", {}).get("scale", {}).get("microservices", {});
    enabled = ms.get("enabled", False);
    services = ms.get("services", {});
    client = ms.get("client", {});

    print(f"Microservice mode: {'ENABLED' if enabled else 'DISABLED'}");
    print(f"Gateway: {ms.get('gateway_host', '0.0.0.0')}:{ms.get('gateway_port', 8000)}");

    if services {
        print(f"\nServices ({len(services)}):");
        for (name, config) in services.items() {
            svc_dict: dict = dict(config);
            file_str: str = str(svc_dict.get("file", "?"));
            prefix_str: str = str(svc_dict.get("prefix", "?"));
            print(f"  {name:12s} -> {prefix_str:20s} ({file_str})");
        }
    } else {
        print("\nNo services configured.");
    }

    if client.get("entry") {
        print(f"\nClient: {client['entry']}");
    }
}
