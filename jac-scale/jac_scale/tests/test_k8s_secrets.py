"""Tests for Kubernetes secrets feature.

Tests the full secrets pipeline:
- create_k8s_secret / delete_k8s_secret utility functions
- get_secrets_config() config loading from [plugins.scale.secrets]
- Container spec envFrom.secretRef injection via _build_container_config
"""

from pathlib import Path
from unittest.mock import MagicMock

import pytest
from kubernetes.client.exceptions import ApiException
from pytest import MonkeyPatch

from jac_scale.config_loader import JacScaleConfig, reset_scale_config
from jac_scale.targets.kubernetes.kubernetes_target import KubernetesTarget
from jac_scale.targets.kubernetes.utils.kubernetes_utils import (
    create_k8s_secret,
    delete_k8s_secret,
)

# ==============================================================
# create_k8s_secret
# ==============================================================


class TestCreateK8sSecret:
    """Tests for the create_k8s_secret utility function."""

    def test_creates_secret_with_string_data(self) -> None:
        """Secret body uses stringData with correct metadata and type."""
        core_v1 = MagicMock()

        result = create_k8s_secret(
            core_v1,
            "test-ns",
            "app-secrets",
            {"OPENAI_API_KEY": "sk-123", "DB_PASS": "pwd"},
        )

        assert result is True
        core_v1.create_namespaced_secret.assert_called_once()
        body = core_v1.create_namespaced_secret.call_args.kwargs["body"]
        assert body["apiVersion"] == "v1"
        assert body["kind"] == "Secret"
        assert body["metadata"]["name"] == "app-secrets"
        assert body["metadata"]["namespace"] == "test-ns"
        assert body["type"] == "Opaque"
        assert body["stringData"] == {"OPENAI_API_KEY": "sk-123", "DB_PASS": "pwd"}

    def test_returns_false_for_empty_data(self) -> None:
        """Empty secret_data is a no-op — returns False, no API calls."""
        core_v1 = MagicMock()

        result = create_k8s_secret(core_v1, "test-ns", "app-secrets", {})

        assert result is False
        core_v1.create_namespaced_secret.assert_not_called()
        core_v1.replace_namespaced_secret.assert_not_called()

    def test_replaces_on_409_conflict(self) -> None:
        """When secret already exists (409), falls back to replace."""
        core_v1 = MagicMock()
        core_v1.create_namespaced_secret.side_effect = ApiException(status=409)

        result = create_k8s_secret(
            core_v1, "test-ns", "app-secrets", {"KEY": "new-val"}
        )

        assert result is True
        core_v1.create_namespaced_secret.assert_called_once()
        core_v1.replace_namespaced_secret.assert_called_once()
        replace_kwargs = core_v1.replace_namespaced_secret.call_args.kwargs
        assert replace_kwargs["name"] == "app-secrets"
        assert replace_kwargs["body"]["stringData"] == {"KEY": "new-val"}

    def test_raises_on_non_409_api_error(self) -> None:
        """Non-409 API exceptions are re-raised, not swallowed."""
        core_v1 = MagicMock()
        core_v1.create_namespaced_secret.side_effect = ApiException(status=403)

        with pytest.raises(ApiException) as exc_info:
            create_k8s_secret(core_v1, "test-ns", "app-secrets", {"KEY": "val"})
        assert exc_info.value.status == 403
        core_v1.replace_namespaced_secret.assert_not_called()


# ==============================================================
# delete_k8s_secret
# ==============================================================


class TestDeleteK8sSecret:
    """Tests for the delete_k8s_secret utility function."""

    def test_deletes_existing_secret(self) -> None:
        """Deletes a secret by name and namespace."""
        core_v1 = MagicMock()

        delete_k8s_secret(core_v1, "test-ns", "app-secrets")

        core_v1.delete_namespaced_secret.assert_called_once_with(
            name="app-secrets", namespace="test-ns"
        )

    def test_silently_ignores_404(self) -> None:
        """404 (secret doesn't exist) is tolerated — no exception raised."""
        core_v1 = MagicMock()
        core_v1.delete_namespaced_secret.side_effect = ApiException(status=404)

        delete_k8s_secret(core_v1, "test-ns", "nonexistent-secret")

    def test_raises_on_non_404_api_error(self) -> None:
        """Non-404 API exceptions are re-raised."""
        core_v1 = MagicMock()
        core_v1.delete_namespaced_secret.side_effect = ApiException(status=500)

        with pytest.raises(ApiException) as exc_info:
            delete_k8s_secret(core_v1, "test-ns", "app-secrets")
        assert exc_info.value.status == 500


# ==============================================================
# get_secrets_config (config loading from jac.toml)
# ==============================================================


class TestGetSecretsConfig:
    """Tests for JacScaleConfig.get_secrets_config() reading from jac.toml."""

    def setup_method(self) -> None:
        """Reset the global config singleton between tests."""
        reset_scale_config()

    def test_returns_secrets_with_env_resolved(
        self, tmp_path: Path, monkeypatch: MonkeyPatch
    ) -> None:
        """Secrets from [plugins.scale.secrets] are returned with ${VAR} resolved."""
        monkeypatch.setenv("MY_API_KEY", "resolved-key-123")

        jac_toml = tmp_path / "jac.toml"
        jac_toml.write_text(
            '[project]\nname = "test"\n\n'
            "[plugins.scale.secrets]\n"
            'MY_API_KEY = "${MY_API_KEY}"\n'
        )

        config = JacScaleConfig(tmp_path)
        secrets = config.get_secrets_config()

        assert secrets["MY_API_KEY"] == "resolved-key-123"

    def test_returns_empty_dict_when_no_secrets_section(self, tmp_path: Path) -> None:
        """Returns {} when [plugins.scale.secrets] is absent (backward compatible)."""
        jac_toml = tmp_path / "jac.toml"
        jac_toml.write_text(
            '[project]\nname = "test"\n\n'
            "[plugins.scale.kubernetes]\n"
            'app_name = "my-app"\n'
        )

        config = JacScaleConfig(tmp_path)
        assert config.get_secrets_config() == {}

    def test_returns_empty_dict_when_no_toml(self, tmp_path: Path) -> None:
        """Returns {} when jac.toml doesn't exist."""
        config = JacScaleConfig(tmp_path)
        assert config.get_secrets_config() == {}


# ==============================================================
# Container config envFrom injection
# ==============================================================


class TestContainerConfigSecretInjection:
    """Tests that _build_container_config correctly adds envFrom.secretRef."""

    def _create_target(self) -> KubernetesTarget:
        """Create a KubernetesTarget with minimal config."""
        from jac_scale.factories.deployment_factory import DeploymentTargetFactory
        from jac_scale.factories.utility_factory import UtilityFactory

        target_config = {
            "app_name": "test-app",
            "namespace": "test-ns",
            "container_port": 8000,
            "node_port": 30001,
        }
        logger = UtilityFactory.create_logger("standard")
        return DeploymentTargetFactory.create("kubernetes", target_config, logger)

    def _probe_configs(self) -> dict:
        return {
            "readiness": {
                "httpGet": {"path": "/docs", "port": 8000},
                "initialDelaySeconds": 10,
                "periodSeconds": 20,
            },
            "liveness": {
                "httpGet": {"path": "/docs", "port": 8000},
                "initialDelaySeconds": 10,
                "periodSeconds": 20,
                "failureThreshold": 80,
            },
        }

    def test_envfrom_added_when_secret_ref_name_provided(self) -> None:
        """envFrom.secretRef is injected when secret_ref_name is set."""
        target = self._create_target()
        container_config = target._build_container_config(
            "test-app",
            "python:3.12-slim",
            self._probe_configs(),
            {},
            secret_ref_name="test-app-secrets",
        )

        assert container_config["envFrom"] == [
            {"secretRef": {"name": "test-app-secrets"}}
        ]

    def test_envfrom_absent_when_no_secret_ref_name(self) -> None:
        """envFrom is omitted when secret_ref_name is None (default)."""
        target = self._create_target()
        container_config = target._build_container_config(
            "test-app",
            "python:3.12-slim",
            self._probe_configs(),
            {},
        )

        assert "envFrom" not in container_config
