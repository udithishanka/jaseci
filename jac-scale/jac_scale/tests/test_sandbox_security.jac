"""Tests for sandbox pod security hardening (capabilities, seccomp, SA token, storage limits)."""

import unittest.mock;
import from typing { Any }
import from jac_scale.abstractions.models.sandbox_config { SandboxConfig }
import from jac_scale.providers.sandbox.kubernetes_sandbox { KubernetesSandbox }

# Helper to build pod specs (casts return to Any to satisfy type checker since
# _build_pod_spec is annotated -> dict but actually returns V1Pod).
def _make_pod(
    security_enabled: bool = True,
    app_limit: str = "1Gi",
    sandbox_id: str = "sbx",
    cm_name: str = "cm"
) -> Any {
    config = SandboxConfig(
        security_context_enabled=security_enabled, app_storage_limit=app_limit
    );
    sandbox = KubernetesSandbox(config=config);
    pod: Any = sandbox._build_pod_spec(sandbox_id, cm_name, "user1", "proj1");
    return pod;
}

def _make_warm_pod(
    security_enabled: bool = True, app_limit: str = "1Gi", pod_name: str = "warm"
) -> Any {
    config = SandboxConfig(
        security_context_enabled=security_enabled, app_storage_limit=app_limit
    );
    sandbox = KubernetesSandbox(config=config);
    pod: Any = sandbox._build_warm_pod_spec(pod_name);
    return pod;
}

def _find_volume(pod: Any, name: str) -> Any {
    for v in pod.spec.volumes {
        if v.name == name {
            return v;
        }
    }
    return None;
}

# ---- SandboxConfig: app_storage_limit ----
test "sandbox config app_storage_limit default is 1Gi" {
    config = SandboxConfig();
    assert config.app_storage_limit == "1Gi";
}

test "sandbox config from_dict parses app_storage_limit" {
    cfg = SandboxConfig.from_dict({"app_storage_limit": "2Gi"});
    assert cfg.app_storage_limit == "2Gi";
}

test "sandbox config from_dict uses default app_storage_limit when missing" {
    cfg = SandboxConfig.from_dict({});
    assert cfg.app_storage_limit == "1Gi";
}

# ---- _build_pod_spec security hardening ----
test "build_pod_spec drops all capabilities when security context enabled" {
    pod = _make_pod(security_enabled=True);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc is not None;
    assert sc.capabilities is not None;
    assert "ALL" in sc.capabilities.drop;
}

test "build_pod_spec sets seccomp RuntimeDefault when security context enabled" {
    pod = _make_pod(security_enabled=True);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc.seccomp_profile is not None;
    assert sc.seccomp_profile.type == "RuntimeDefault";
}

test "build_pod_spec disables SA token automount" {
    pod = _make_pod(security_enabled=True);
    assert not pod.spec.automount_service_account_token;
}

test "build_pod_spec sets app_storage_limit on app-data volume" {
    pod = _make_pod(app_limit="2Gi");
    app_vol: Any = _find_volume(pod, "app-data");
    assert app_vol is not None , "app-data volume must exist";
    assert app_vol.empty_dir.size_limit == "2Gi";
}

test "build_pod_spec has no security context when disabled" {
    pod = _make_pod(security_enabled=False);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc is None;
}

test "build_pod_spec disables SA token even when security context disabled" {
    pod = _make_pod(security_enabled=False);
    assert not pod.spec.automount_service_account_token;
}

test "build_pod_spec init container runs chown" {
    pod = _make_pod(security_enabled=True);
    init: Any = pod.spec.init_containers[0];
    cmd_str: str = str(" ".join(init.command));
    assert "chown -R 1000:1000 /app" in cmd_str;
}

test "build_pod_spec sets allow_privilege_escalation false and run_as_non_root" {
    pod = _make_pod(security_enabled=True);
    sc: Any = pod.spec.containers[0].security_context;
    assert not sc.allow_privilege_escalation;
    assert sc.run_as_non_root;
    assert sc.run_as_user == 1000;
}

# ---- _build_warm_pod_spec security hardening ----
test "warm pod spec drops all capabilities when security context enabled" {
    pod = _make_warm_pod(security_enabled=True);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc is not None;
    assert "ALL" in sc.capabilities.drop;
}

test "warm pod spec sets seccomp RuntimeDefault" {
    pod = _make_warm_pod(security_enabled=True);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc.seccomp_profile.type == "RuntimeDefault";
}

test "warm pod spec disables SA token automount" {
    pod = _make_warm_pod(security_enabled=True);
    assert not pod.spec.automount_service_account_token;
}

test "warm pod spec sets app_storage_limit on app-data volume" {
    pod = _make_warm_pod(app_limit="3Gi");
    app_vol: Any = _find_volume(pod, "app-data");
    assert app_vol is not None , "app-data volume must exist";
    assert app_vol.empty_dir.size_limit == "3Gi";
}

test "warm pod spec has no security context when disabled" {
    pod = _make_warm_pod(security_enabled=False);
    sc: Any = pod.spec.containers[0].security_context;
    assert sc is None;
}

# ---- Consistency: both builders produce same security settings ----
test "both pod builders produce identical security settings" {
    config = SandboxConfig(security_context_enabled=True, app_storage_limit="1Gi");
    sandbox = KubernetesSandbox(config=config);
    pod: Any = sandbox._build_pod_spec("sbx-c", "cm-c", "user1", "proj1");
    warm: Any = sandbox._build_warm_pod_spec("warm-c");

    sc1: Any = pod.spec.containers[0].security_context;
    sc2: Any = warm.spec.containers[0].security_context;

    assert sc1.run_as_non_root == sc2.run_as_non_root;
    assert sc1.run_as_user == sc2.run_as_user;
    assert sc1.allow_privilege_escalation == sc2.allow_privilege_escalation;
    assert sc1.capabilities.drop == sc2.capabilities.drop;
    assert sc1.seccomp_profile.type == sc2.seccomp_profile.type;

    assert pod.spec.automount_service_account_token == warm.spec.automount_service_account_token;
}
