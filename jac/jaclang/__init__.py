"""The Jac Programming Language."""

import os
import sys

from jaclang.meta_importer import JacMetaImporter

# Register JacMetaImporter BEFORE loading plugins, so .jac modules can be imported
if not any(isinstance(f, JacMetaImporter) for f in sys.meta_path):
    sys.meta_path.insert(0, JacMetaImporter())


def _setup_jac_packages_path() -> None:
    """Set up .jac/packages path early if in a Jac project.

    This function is called during jaclang initialization to ensure that
    .jac/packages is added to sys.path and importlib.metadata before any
    user code is loaded. This fixes GitHub issue #4210 where package version
    conflicts occur because venv packages shadow .jac/packages packages.
    """
    # Only try once per process
    if getattr(_setup_jac_packages_path, "_done", False):
        return
    _setup_jac_packages_path._done = True

    # Look for jac.toml in current directory or parents
    cwd = os.getcwd()
    search_dir = cwd
    jac_toml = None
    for _ in range(10):  # Max 10 levels up
        candidate = os.path.join(search_dir, "jac.toml")
        if os.path.isfile(candidate):
            jac_toml = candidate
            break
        parent = os.path.dirname(search_dir)
        if parent == search_dir:
            break
        search_dir = parent

    if not jac_toml:
        return

    # Found a jac.toml - check for .jac/packages
    project_root = os.path.dirname(jac_toml)
    packages_dir = os.path.join(project_root, ".jac", "packages")

    if not os.path.isdir(packages_dir):
        return

    # Add to sys.path if not already there
    if packages_dir not in sys.path:
        sys.path.insert(0, packages_dir)

    # Set up the custom MetaPathFinder for importlib.metadata
    from jaclang.pycore.helpers import setup_jac_packages_finder

    setup_jac_packages_finder(packages_dir)


# Set up .jac/packages early (fixes GitHub issue #4210)
_setup_jac_packages_path()

# Import compiler first to ensure generated parsers exist before pycore.parser is loaded
# Backwards-compatible import path for older plugins/tests.
# Prefer `jaclang.pycore.runtime` going forward.
import jaclang.pycore.runtime as _runtime_mod
from jaclang import compiler as _compiler  # noqa: F401
from jaclang.pycore.helpers import get_disabled_plugins, load_plugins_with_disabling
from jaclang.pycore.runtime import (
    JacRuntime,
    JacRuntimeImpl,
    JacRuntimeInterface,
    plugin_manager,
)

sys.modules.setdefault("jaclang.runtimelib.runtime", _runtime_mod)

plugin_manager.register(JacRuntimeImpl)

# Load external plugins with disabling support
# Disabling can be configured via JAC_DISABLED_PLUGINS env var or jac.toml [plugins].disabled
# Use "*" to disable all external plugins, "package:*" for all from a package,
# or "package:plugin" for specific plugins
_disabled_list = get_disabled_plugins()
if _disabled_list:
    # Use qualified blocking for fine-grained control
    load_plugins_with_disabling(plugin_manager, _disabled_list)
else:
    # No disabling - load all plugins normally
    plugin_manager.load_setuptools_entrypoints("jac")

__all__ = ["JacRuntimeInterface", "JacRuntime"]
