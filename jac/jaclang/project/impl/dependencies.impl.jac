"""Implementation of dependency management for Jac projects."""

# ===============================================================================
# DependencyInstaller Implementation
# ===============================================================================
impl DependencyInstaller.postinit -> None {
    import from jaclang.project.config { get_config }
    if self.config is None {
        self.config = get_config();
    }
    if self.config is None {
        raise ValueError("No jac.toml found. Run 'jac init' to create a project.") ;
    }
    self.packages_dir = self.config.get_packages_dir();
}

impl DependencyInstaller.ensure_packages_dir -> None {
    import sys;
    self.packages_dir.mkdir(parents=True, exist_ok=True);
    packages_str = str(self.packages_dir);
    if packages_str not in sys.path {
        sys.path.insert(0, packages_str);
    }
}

impl DependencyInstaller._run_pip(args: list[str]) -> tuple[int, str, str] {
    import subprocess;
    import sys;
    cmd = [sys.executable, "-m", "pip"] + args;
    if self.verbose {
        print(f"Running: {' '.join(cmd)}");
    }
    try {
        result = subprocess.run(cmd, capture_output=True, text=True);
        return (result.returncode, result.stdout, result.stderr);
    } except Exception as e {
        return (1, "", str(e));
    }
}

impl DependencyInstaller._cleanup_duplicate_dist_info(name: str) -> None {
    # Clean up duplicate dist-info directories for a package.
    # When using pip install --target --upgrade, pip can leave behind old
    # dist-info directories, causing importlib.metadata to find the wrong
    # version. This method finds all dist-info dirs for a package and keeps
    # only the newest one.
    # This fixes GitHub issue #4210 where version conflicts occur due to
    # duplicate dist-info directories in .jac/packages.
    import shutil;
    if not self.packages_dir or not self.packages_dir.exists() {
        return;
    }
    # Normalize name for matching (pip uses underscores in dist-info names)
    normalized_name = name.lower().replace("-", "_");
    # Find all dist-info directories for this package
    dist_infos: list = [];
    for item in self.packages_dir.iterdir() {
        if item.is_dir() and item.name.endswith(".dist-info") {
            # Parse package name from dist-info dir (format: name-version.dist-info)
            dir_name = item.name[:-10];  # Remove .dist-info suffix
            parts = dir_name.rsplit("-", 1);
            if len(parts) == 2 {
                pkg_name = parts[0].lower().replace("-", "_");
                version = parts[1];
                if pkg_name == normalized_name {
                    dist_infos.append((item, version));
                }
            }
        }
    }
    # If there's more than one dist-info, keep only the newest by mtime
    if len(dist_infos) > 1 {
        # Sort by modification time (newest first)
        dist_infos.sort(key=lambda x: float : x[0].stat().st_mtime, reverse=True);
        # Remove all but the newest
        for (dist_info_path, version) in dist_infos[1:] {
            try {
                if self.verbose {
                    print(f"  Cleaning up old dist-info: {dist_info_path.name}");
                }
                shutil.rmtree(dist_info_path);
            } except Exception {
                # Silently ignore cleanup failures
                _ = None;
            }
        }
    }
}

impl DependencyInstaller.install_all(include_dev: bool = False) -> bool {
    import sys;
    self.ensure_packages_dir();
    all_success = True;
    for (name, version) in self.config.dependencies.items() {
        if not self.install_package(name, version) {
            all_success = False;
        }
    }
    if include_dev {
        for (name, version) in self.config.dev_dependencies.items() {
            if not self.install_package(name, version) {
                all_success = False;
            }
        }
    }
    for (name, git_info) in self.config.git_dependencies.items() {
        if isinstance(git_info, dict) {
            git_url = git_info.get("git", "");
            branch = git_info.get("branch", "");
            if not self.install_git_package(name, git_url, branch) {
                all_success = False;
            }
        }
    }
    return all_success;
}

impl DependencyInstaller.install_package(name: str, version: str = "") -> bool {
    import sys;
    self.ensure_packages_dir();
    if version {
        if version.startswith(("=", ">", "<", "~", "!")) {
            spec = f"{name}{version}";
        } else {
            spec = f"{name}=={version}";
        }
    } else {
        spec = name;
    }
    print(f"Installing {spec}...");
    (returncode, stdout, stderr) = self._run_pip(
        ["install", "--target", str(self.packages_dir), "--upgrade", spec]
    );
    if returncode == 0 {
        # Clean up duplicate dist-info directories (fixes GitHub issue #4210)
        # pip --target --upgrade can leave behind old dist-info dirs
        self._cleanup_duplicate_dist_info(name);
        print(f"  {name} installed successfully");
        return True;
    } else {
        print(f"  Failed to install {name}: {stderr}", file=sys.stderr);
        return False;
    }
}

impl DependencyInstaller.install_git_package(
    name: str, git_url: str, branch: str = ""
) -> bool {
    import sys;
    self.ensure_packages_dir();
    if branch {
        spec = f"git+{git_url}@{branch}";
    } else {
        spec = f"git+{git_url}";
    }
    print(f"Installing {name} from git...");
    (returncode, stdout, stderr) = self._run_pip(
        ["install", "--target", str(self.packages_dir), "--upgrade", spec]
    );
    if returncode == 0 {
        print(f"  {name} installed successfully from git");
        return True;
    } else {
        print(f"  Failed to install {name} from git: {stderr}", file=sys.stderr);
        return False;
    }
}

impl DependencyInstaller.uninstall_package(name: str) -> bool {
    import shutil;
    import sys;
    package_dir = self.packages_dir / name;
    package_info_dir = None;
    for item in self.packages_dir.iterdir() {
        if item.name.lower() == name.lower().replace("-", "_") {
            package_dir = item;
            break;
        }
        if (
            item.name.lower().startswith(f"{name.lower().replace('-', '_')}-")
            and item.suffix == ".dist-info"
        ) {
            package_info_dir = item;
        }
    }
    removed = False;
    if package_dir.exists() {
        print(f"Removing {name}...");
        try {
            shutil.rmtree(package_dir);
            removed = True;
        } except Exception as e {
            print(f"  Failed to remove {name}: {e}", file=sys.stderr);
        }
    }
    if package_info_dir and package_info_dir.exists() {
        try {
            shutil.rmtree(package_info_dir);
            removed = True;
        } except Exception as e {
            print(f"  Failed to remove {name} metadata: {e}", file=sys.stderr);
        }
    }
    if removed {
        print(f"  {name} removed successfully");
        return True;
    } else {
        print(f"  Package {name} not found in packages directory", file=sys.stderr);
        return False;
    }
}

impl DependencyInstaller.is_installed(name: str) -> bool {
    if not self.packages_dir.exists() {
        return False;
    }
    normalized_name = name.lower().replace("-", "_");
    for item in self.packages_dir.iterdir() {
        item_name = item.name.lower().replace("-", "_");
        if item_name == normalized_name {
            return True;
        }
        if item_name.startswith(f"{normalized_name}_")
        and item.name.endswith(".dist-info") {
            return True;
        }
    }
    return False;
}

impl DependencyInstaller.list_installed -> list[str] {
    if not self.packages_dir.exists() {
        return [];
    }
    packages = [];
    seen: set[str] = set();
    for item in self.packages_dir.iterdir() {
        if item.name.endswith(".dist-info") {
            # Strip .dist-info suffix first, then get package name
            stem = item.name[:-10];  # len(".dist-info") == 10
            # Package name is everything before the version (first -)
            parts = stem.split("-");
            if len(parts) >= 2 {
                # Handle package names with hyphens
                # Version starts with a digit, so find the first part that starts with digit
                name_parts = [];
                for (i, part) in enumerate(parts) {
                    if part and part[0].isdigit() {
                        break;
                    }
                    name_parts.append(part);
                }
                name = "-".join(name_parts) if name_parts else parts[0];
            } else {
                name = stem;
            }
            if name and name not in seen {
                seen.add(name);
                packages.append(name);
            }
        }
    }
    return sorted(packages);
}

# ===============================================================================
# DependencyResolver Implementation
# ===============================================================================
impl DependencyResolver.postinit -> None {
    import from jaclang.project.config { get_config }
    if self.config is None {
        self.config = get_config();
    }
    if self.config is None {
        raise ValueError("No jac.toml found.") ;
    }
}

impl DependencyResolver.parse_spec(spec: str) -> tuple[str, str] {
    import re;
    spec = spec.strip();
    # Handle npm scoped packages: @scope/name@version
    npm_scoped_m = re.match(r"^(@[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+)@(.+)$", spec);
    if npm_scoped_m {
        return (npm_scoped_m.group(1), npm_scoped_m.group(2));
    }
    # Handle npm style: name@version
    npm_m = re.match(r"^([a-zA-Z0-9_-]+)@(.+)$", spec);
    if npm_m {
        return (npm_m.group(1), npm_m.group(2));
    }
    # Handle Python style: name>=version, name~=version, etc.
    py_m = re.match(r"^([a-zA-Z0-9_-]+)\s*([<>=!~]+.+)?$", spec);
    if py_m {
        name = py_m.group(1);
        version = py_m.group(2) or "";
        return (name, version);
    }
    # Handle scoped packages without version: @scope/name
    if spec.startswith("@") and "/" in spec {
        return (spec, "");
    }
    return (spec, "");
}

impl DependencyResolver.resolve(include_dev: bool = False) -> list[ResolvedDependency] {
    resolved = [];
    for (name, version) in self.config.dependencies.items() {
        resolved.append(ResolvedDependency(name=name, version=version, source="pypi"));
    }
    if include_dev {
        for (name, version) in self.config.dev_dependencies.items() {
            resolved.append(
                ResolvedDependency(name=name, version=version, source="pypi")
            );
        }
    }
    for (name, git_info) in self.config.git_dependencies.items() {
        if isinstance(git_info, dict) {
            resolved.append(
                ResolvedDependency(
                    name=name, version=git_info.get("branch", "main"), source="git"
                )
            );
        }
    }
    return resolved;
}

# ===============================================================================
# Package Search Path Management Implementation
# ===============================================================================
impl add_packages_to_path(
    config: JacConfig | None = None
) -> None {
    import sys;
    import from jaclang.project.config { get_config }
    import from jaclang.pycore.helpers { setup_jac_packages_finder }
    if config is None {
        config = get_config();
    }
    if config is None {
        return;
    }
    packages_dir = config.get_packages_dir();
    packages_str = str(packages_dir);
    if packages_dir.exists() and packages_str not in sys.path {
        sys.path.insert(0, packages_str);
        # Register our custom finder to ensure importlib.metadata finds
        # distributions from .jac/packages first (fixes GitHub issue #4210)
        setup_jac_packages_finder(packages_str);
    }
}

impl remove_packages_from_path(config: JacConfig | None = None) -> None {
    import sys;
    import from jaclang.project.config { get_config }
    import from jaclang.pycore.helpers { remove_jac_packages_finder }
    if config is None {
        config = get_config();
    }
    if config is None {
        return;
    }
    packages_dir = config.get_packages_dir();
    packages_str = str(packages_dir);
    if packages_str in sys.path {
        sys.path.remove(packages_str);
        # Remove our custom finder when removing the packages path
        remove_jac_packages_finder();
    }
}

impl is_packages_in_path(config: JacConfig | None = None) -> bool {
    import sys;
    import from jaclang.project.config { get_config }
    if config is None {
        config = get_config();
    }
    if config is None {
        return False;
    }
    packages_dir = config.get_packages_dir();
    return str(packages_dir) in sys.path;
}
