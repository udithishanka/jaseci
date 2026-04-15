# Day 8: CLI Tooling — `jac setup microservice`

## Learn (~1 hour)

### Why CLI Setup Commands Matter

Making users hand-write TOML config is error-prone. A setup command:

- **Discovers** what's in the project (scans for .jac files)
- **Guides** the user through choices (which files are services?)
- **Generates** correct config (no typos, proper structure)
- **Validates** the result (file exists? prefix conflicts?)

Good CLI tools follow these principles:

1. **Sensible defaults** — works with minimal input
2. **Progressive disclosure** — simple first, advanced options available
3. **Idempotent** — running it twice doesn't break anything
4. **Transparent** — shows what it's about to do before doing it

### How jac-scale Extends the CLI

jac-scale adds commands via the plugin system in `plugin.jac`:

```jac
# In plugin.jac — register_cmd() adds CLI commands
registry.extend_command(
    "setup",                      # parent command
    "microservice",               # subcommand
    "Configure microservice mode",  # description
    setup_microservice_handler     # function to call
);
```

The user then runs: `jac setup microservice`

### TOML Manipulation in Python

Python's `tomllib` reads TOML, but there's no built-in TOML writer. Options:

- **`tomlkit`** — preserves comments and formatting (best for editing existing files)
- **`tomli_w`** — simple writer (good for generating new files)

We'll use `tomlkit` since users might have existing `jac.toml` with comments we should preserve.

```python
import tomlkit

# Read
with open("jac.toml") as f:
    doc = tomlkit.load(f)

# Modify
doc.setdefault("plugins", {}).setdefault("scale", {})
doc["plugins"]["scale"]["microservices"] = {
    "enabled": True,
    "services": {...}
}

# Write back (preserves formatting/comments)
with open("jac.toml", "w") as f:
    tomlkit.dump(doc, f)
```

---

## Do (~2-3 hours)

### Task 1: Create the setup module

**`jac_scale/microservices/setup.jac`**

```jac
"""Interactive CLI for configuring microservice mode."""

import from pathlib { Path }
import from typing { Any }

"""
Scan the project for .jac files, excluding known non-service paths.
Returns a list of relative file paths.
"""
def scan_jac_files(project_root: str = ".") -> list[str];

"""
Derive a service name from a file path.
services/orders.jac → "orders"
src/api/user_service.jac → "user_service"
"""
def derive_service_name(file_path: str) -> str;

"""
Derive a route prefix from a service name.
"orders" → "/api/orders"
"""
def derive_prefix(service_name: str) -> str;

"""
Run the interactive setup flow.
Scans project, prompts user, writes TOML config.
"""
def run_setup(
    project_root: str = ".",
    add_file: str | None = None,
    remove_service: str | None = None,
    list_services: bool = False
) -> None;

"""
Add a single service to existing config.
"""
def add_service_to_config(
    project_root: str,
    file_path: str,
    service_name: str | None = None,
    prefix: str | None = None
) -> None;

"""
Remove a service from existing config.
"""
def remove_service_from_config(project_root: str, service_name: str) -> None;

"""
List currently configured services.
"""
def list_configured_services(project_root: str) -> None;
```

### Task 2: Implement the setup logic

**`jac_scale/microservices/impl/setup.impl.jac`**

```jac
import from pathlib { Path }
import from jac_scale.microservices.setup {
    scan_jac_files, derive_service_name, derive_prefix,
    run_setup, add_service_to_config, remove_service_from_config, list_configured_services
}

:can:scan_jac_files
(project_root: str = ".") -> list[str] {
    root = Path(project_root);
    exclude_dirs = {".jac", "__pycache__", "node_modules", ".git", "dist", "build"};
    jac_files: list[str] = [];

    for f in root.rglob("*.jac") {
        # Skip excluded directories
        parts = f.relative_to(root).parts;
        if any(part in exclude_dirs for part in parts) {
            continue;
        }
        jac_files.append(str(f.relative_to(root)));
    }

    return sorted(jac_files);
}

:can:derive_service_name
(file_path: str) -> str {
    # services/orders.jac → "orders"
    name = Path(file_path).stem;
    return name;
}

:can:derive_prefix
(service_name: str) -> str {
    return f"/api/{service_name}";
}

:can:run_setup
(project_root: str = ".", add_file: str | None = None,
 remove_service: str | None = None, list_services: bool = False) -> None {

    if list_services {
        list_configured_services(project_root);
        return;
    }
    if remove_service {
        remove_service_from_config(project_root, remove_service);
        return;
    }
    if add_file {
        add_service_to_config(project_root, add_file);
        return;
    }

    # --- Interactive setup flow ---
    import tomlkit;

    toml_path = Path(project_root) / "jac.toml";

    # Load existing or create new
    if toml_path.exists() {
        with open(toml_path) as f {
            doc = tomlkit.load(f);
        }
        print(f"Found existing jac.toml");
    } else {
        doc = tomlkit.document();
        print(f"Creating new jac.toml");
    }

    # Scan for .jac files
    jac_files = scan_jac_files(project_root);
    if not jac_files {
        print("No .jac files found in project.");
        return;
    }

    print(f"\nFound .jac files:");
    for (i, f) in enumerate(jac_files, 1) {
        print(f"  {i}. {f}");
    }

    # Prompt for service selection
    selection = input("\nSelect files to run as microservices (comma-separated numbers): ").strip();
    if not selection {
        print("No services selected. Exiting.");
        return;
    }

    selected_indices = [int(x.strip()) - 1 for x in selection.split(",") if x.strip().isdigit()];
    selected_files = [jac_files[i] for i in selected_indices if 0 <= i < len(jac_files)];

    if not selected_files {
        print("No valid files selected. Exiting.");
        return;
    }

    # Prompt for client entry
    client_entry = input("\nClient UI entry point (leave blank for none): ").strip();

    # Build config
    services_config = tomlkit.table();
    for file_path in selected_files {
        name = derive_service_name(file_path);
        prefix = derive_prefix(name);

        service_table = tomlkit.table();
        service_table.add("file", file_path);
        service_table.add("prefix", prefix);

        services_config.add(name, service_table);
    }

    ms_config = tomlkit.table();
    ms_config.add("enabled", True);
    ms_config.add("gateway_port", 8000);
    ms_config.add("gateway_host", "0.0.0.0");
    ms_config.add("services", services_config);

    if client_entry {
        client_config = tomlkit.table();
        client_config.add("entry", client_entry);
        client_config.add("dist_dir", ".jac/client/dist");
        client_config.add("base_route", "/");
        ms_config.add("client", client_config);
    }

    # Write to TOML
    doc.setdefault("plugins", tomlkit.table());
    doc["plugins"].setdefault("scale", tomlkit.table());
    doc["plugins"]["scale"]["microservices"] = ms_config;

    with open(toml_path, "w") as f {
        tomlkit.dump(doc, f);
    }

    # Print summary
    print(f"\nAdded microservice config to jac.toml:");
    for file_path in selected_files {
        name = derive_service_name(file_path);
        print(f"  - {name:12s} → {derive_prefix(name):20s} ({file_path})");
    }
    if client_entry {
        print(f"  - {'client':12s} → {client_entry}");
    }
    print(f"\nRun `jac start app.jac` to launch locally.");
    print(f"Run `jac start app.jac --scale` to deploy to Kubernetes.");
}

:can:add_service_to_config
(project_root: str, file_path: str, service_name: str | None = None, prefix: str | None = None) -> None {
    import tomlkit;

    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found. Run `jac setup microservice` first.");
        return;
    }

    with open(toml_path) as f {
        doc = tomlkit.load(f);
    }

    name = service_name or derive_service_name(file_path);
    svc_prefix = prefix or derive_prefix(name);

    ms = doc.get("plugins", {}).get("scale", {}).get("microservices", {});
    services = ms.get("services", {});

    if name in services {
        print(f"Service '{name}' already exists. Remove it first with --remove.");
        return;
    }

    service_table = tomlkit.table();
    service_table.add("file", file_path);
    service_table.add("prefix", svc_prefix);
    services[name] = service_table;

    with open(toml_path, "w") as f {
        tomlkit.dump(doc, f);
    }
    print(f"Added service: {name} → {svc_prefix} ({file_path})");
}

:can:remove_service_from_config
(project_root: str, service_name: str) -> None {
    import tomlkit;

    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found.");
        return;
    }

    with open(toml_path) as f {
        doc = tomlkit.load(f);
    }

    services = doc.get("plugins", {}).get("scale", {}).get("microservices", {}).get("services", {});

    if service_name not in services {
        print(f"Service '{service_name}' not found. Current services: {list(services.keys())}");
        return;
    }

    del services[service_name];

    with open(toml_path, "w") as f {
        tomlkit.dump(doc, f);
    }
    print(f"Removed service: {service_name}");
}

:can:list_configured_services
(project_root: str) -> None {
    import tomlkit;

    toml_path = Path(project_root) / "jac.toml";
    if not toml_path.exists() {
        print("No jac.toml found.");
        return;
    }

    with open(toml_path) as f {
        doc = tomlkit.load(f);
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
            print(f"  {name:12s} → {config.get('prefix', '?'):20s} ({config.get('file', '?')})");
        }
    } else {
        print("\nNo services configured.");
    }

    if client {
        print(f"\nClient: {client.get('entry', 'none')}");
    }
}
```

### Task 3: Register the CLI command

Add to `plugin.jac` (you'll wire this in properly on Day 9, for now just test the functions directly):

```python
# test_setup.py — run from test-microservices/
# This simulates what `jac setup microservice` will do

import sys
sys.path.insert(0, "../jac_scale")

from jac_scale.microservices.setup import run_setup, list_configured_services

# Interactive setup
run_setup(project_root=".")

# After setup, list services
print("\n--- Current config ---")
list_configured_services(".")
```

### Task 4: Test all modes

```bash
cd test-microservices

# Interactive setup
python test_setup.py
# Select: 1, 2 (orders.jac, payments.jac)
# Client: client/main.jac

# List services
python -c "from jac_scale.microservices.setup import list_configured_services; list_configured_services('.')"

# Add a service
python -c "from jac_scale.microservices.setup import add_service_to_config; add_service_to_config('.', 'services/notifications.jac')"

# List again (should show 3 services)
python -c "from jac_scale.microservices.setup import list_configured_services; list_configured_services('.')"

# Remove a service
python -c "from jac_scale.microservices.setup import remove_service_from_config; remove_service_from_config('.', 'notifications')"

# Verify jac.toml looks correct
cat jac.toml
```

---

## Milestone

- [ ] `scan_jac_files()` finds .jac files and excludes `.jac/`, `__pycache__/`, etc.
- [ ] Interactive setup prompts for file selection and writes valid TOML
- [ ] `--add` adds a service to existing config
- [ ] `--remove` removes a service from config
- [ ] `--list` shows current microservice config
- [ ] Generated `jac.toml` is valid and can be loaded by `get_scale_config()`

**You now understand**: why CLI setup commands improve developer experience, how to manipulate TOML files programmatically while preserving formatting, and how to design an incremental config workflow (setup → add → remove → list).
