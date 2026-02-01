import tarfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from kubernetes.client.exceptions import ApiException
from pytest import MonkeyPatch

from jac_scale.targets.kubernetes.utils import kubernetes_utils as utils
from jac_scale.targets.kubernetes.utils.kubernetes_utils import (
    create_tarball,
    ensure_pvc_exists,
    load_env_variables,
    parse_cpu_quantity,
    parse_memory_quantity,
    resolve_env_value,
    validate_resource_limits,
)


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("500m", 0.5),
        ("2", 2.0),
        (" 250 ", 250.0),
    ],
)
def test_parse_cpu_quantity_valid(raw: str, expected: float) -> None:
    assert parse_cpu_quantity(raw) == pytest.approx(expected)


@pytest.mark.parametrize("raw", ["", "m", " m "])
def test_parse_cpu_quantity_invalid(raw: str) -> None:
    with pytest.raises(ValueError):
        parse_cpu_quantity(raw)


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("256Mi", float(256 * 1024**2)),
        ("1Gi", float(1024**3)),
        ("2", 2.0),
    ],
)
def test_parse_memory_quantity_valid(raw: str, expected: float) -> None:
    assert parse_memory_quantity(raw) == pytest.approx(expected)


@pytest.mark.parametrize("raw", ["", "Mi", " Gi "])
def test_parse_memory_quantity_invalid(raw: str) -> None:
    with pytest.raises(ValueError):
        parse_memory_quantity(raw)


def test_validate_resource_limits_accepts_valid_pairs() -> None:
    validate_resource_limits("250m", "500m", "256Mi", "512Mi")


def test_validate_resource_limits_rejects_lower_limits() -> None:
    with pytest.raises(ValueError):
        validate_resource_limits("500m", "250m", None, None)


def test_validate_resource_limits_rejects_invalid_quantity() -> None:
    with pytest.raises(ValueError):
        validate_resource_limits("abc", "1", None, None)


def test_load_env_variables_reads_env_file(tmp_path: Path) -> None:
    env_dir = tmp_path / "app"
    env_dir.mkdir()
    env_file = env_dir / ".env"
    env_file.write_text("VAR1=1\nVAR2=two\n")

    env_vars = load_env_variables(str(env_dir))

    assert {"name": "VAR1", "value": "1"} in env_vars
    assert {"name": "VAR2", "value": "two"} in env_vars


def test_ensure_pvc_exists_skips_when_present() -> None:
    core_v1 = MagicMock()
    core_v1.read_namespaced_persistent_volume_claim.return_value = object()

    ensure_pvc_exists(core_v1, "test-ns", "test-pvc", "5Gi")

    core_v1.create_namespaced_persistent_volume_claim.assert_not_called()


def test_ensure_pvc_exists_creates_when_missing() -> None:
    core_v1 = MagicMock()
    core_v1.read_namespaced_persistent_volume_claim.side_effect = ApiException(
        status=404
    )

    ensure_pvc_exists(
        core_v1,
        namespace="test-ns",
        pvc_name="test-pvc",
        storage_size="10Gi",
        storage_class="fast",
    )

    call_args = core_v1.create_namespaced_persistent_volume_claim.call_args
    assert call_args is not None
    args, kwargs = call_args
    assert kwargs == {}
    assert args[0] == "test-ns"
    body = args[1]
    assert body["metadata"]["name"] == "test-pvc"
    assert body["spec"]["accessModes"] == ["ReadWriteOnce"]
    assert body["spec"]["resources"]["requests"]["storage"] == "10Gi"
    assert body["spec"]["storageClassName"] == "fast"


def test_cluster_type_detects_aws_by_provider(monkeypatch: MonkeyPatch) -> None:
    class Node:
        def __init__(self, provider_id: str) -> None:
            self.spec = SimpleNamespace(provider_id=provider_id)
            self.metadata = SimpleNamespace(labels={})

    class Response:
        def __init__(self) -> None:
            self.items = [Node("aws://12345")]  # type: ignore[arg-type]

    class FakeApi:
        def list_node(self) -> Response:
            return Response()

    monkeypatch.setattr(utils.client, "CoreV1Api", lambda: FakeApi())

    assert utils.cluster_type() == "aws"


def test_create_tarball_captures_files(tmp_path: Path) -> None:
    source_dir = tmp_path / "src"
    source_dir.mkdir()
    file_path = source_dir / "hello.txt"
    file_path.write_text("hello")
    tar_path = tmp_path / "archive.tar.gz"

    create_tarball(str(source_dir), str(tar_path))

    assert tar_path.exists()
    with tarfile.open(tar_path, "r:gz") as tar:
        member_names = tar.getnames()
    assert "./hello.txt" in member_names


def test_create_tarball_missing_source(tmp_path: Path) -> None:
    tar_path = tmp_path / "archive.tar.gz"

    with pytest.raises(FileNotFoundError):
        create_tarball(str(tmp_path / "missing"), str(tar_path))


def test_resolve_env_value_static():
    """Static values pass through unchanged."""
    assert resolve_env_value("my-static-value", "KEY") == "my-static-value"
    assert resolve_env_value("production", "ENV") == "production"


def test_resolve_env_value_substitution(monkeypatch):
    """${VAR} is substituted from environment."""
    monkeypatch.setenv("MY_VAR", "substituted-value")
    assert resolve_env_value("${MY_VAR}", "KEY") == "substituted-value"


def test_resolve_env_value_missing_warns(monkeypatch, capsys):
    """Warning when env var is missing."""
    result = resolve_env_value("${MISSING_VAR}", "API_KEY")
    assert result == ""
    captured = capsys.readouterr()
    assert "MISSING_VAR" in captured.out
    assert "Warning" in captured.out


def test_load_env_variables_merges_config(tmp_path, monkeypatch):
    """Test merging .env file with kubernetes.env config."""
    env_dir = tmp_path / "app"
    env_dir.mkdir()
    env_file = env_dir / ".env"
    env_file.write_text("FILE_VAR=from-file\nOVERRIDE=file-value\n")

    monkeypatch.setenv("CONFIG_VAR", "from-env")
    config_vars = {
        "CONFIG_VAR": "${CONFIG_VAR}",
        "STATIC_VAR": "static-value",
        "OVERRIDE": "config-value"
    }

    env_list = load_env_variables(str(env_dir), config_vars)
    env_dict = {e["name"]: e["value"] for e in env_list}

    assert env_dict["FILE_VAR"] == "from-file"
    assert env_dict["CONFIG_VAR"] == "from-env"
    assert env_dict["STATIC_VAR"] == "static-value"
    assert env_dict["OVERRIDE"] == "config-value"  # Config wins


def test_load_env_variables_backward_compatible(tmp_path):
    """Existing code works without config vars."""
    env_dir = tmp_path / "app"
    env_dir.mkdir()
    env_file = env_dir / ".env"
    env_file.write_text("VAR1=value1\n")

    env_list = load_env_variables(str(env_dir))
    assert {"name": "VAR1", "value": "value1"} in env_list


def test_load_env_variables_only_config(tmp_path, monkeypatch):
    """Works with only config vars, no .env file."""
    env_dir = tmp_path / "app"
    env_dir.mkdir()

    monkeypatch.setenv("API_KEY", "secret123")
    config_vars = {
        "API_KEY": "${API_KEY}",
        "APP_NAME": "my-app"
    }

    env_list = load_env_variables(str(env_dir), config_vars)
    env_dict = {e["name"]: e["value"] for e in env_list}

    assert env_dict["API_KEY"] == "secret123"
    assert env_dict["APP_NAME"] == "my-app"
