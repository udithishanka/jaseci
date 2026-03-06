"""Kubernetes ephemeral pod sandbox provider.

Creates isolated K8s pods for each preview sandbox. Designed to work
both from a local machine (kubeconfig) and from inside a K8s pod
(in-cluster config via ServiceAccount token).
"""
import os;
import time;
import uuid;
import json;
import from threading { Lock, Thread }
import from typing { Any }
import from jac_scale.abstractions.sandbox_environment { SandboxEnvironment }
import from jac_scale.abstractions.models.sandbox_config { SandboxConfig }
import from jac_scale.abstractions.models.sandbox_result { SandboxResult }
import from jac_scale.abstractions.models.sandbox_status {
    SandboxState,
    SandboxStatus,
    SandboxInfo
}
import from jac_scale.abstractions.logger { Logger }
import from jac_scale.factories.ingress_factory { IngressFactory }

glob _SANDBOX_LABEL: str = "jac-sandbox";
glob _INTERNAL_PORT: int = 8000;
glob _CONFIGMAP_SIZE_LIMIT: int = 1048576;  # 1MB

"""Kubernetes ephemeral pod sandbox — creates sibling pods in a dedicated namespace."""
class KubernetesSandbox(SandboxEnvironment) {
    has _registry: dict = {},
        _lock: Any = None,
        _k8s_initialized: bool = False,
        _rbac_provisioned: bool = False,
        _ingress_provider: Any = None,
        _warm_pool: list = [],
        _pool_initialized: bool = False;

    def init(
        self: KubernetesSandbox,
        config: SandboxConfig,
        logger: (Logger | None) = None
    ) -> None {
        self.config = config;
        self.logger = logger;
        self._registry = {};
        self._lock = Lock();
        self._k8s_initialized = False;
        self._rbac_provisioned = False;
        self._ingress_provider = None;
        self._warm_pool = [];
        self._pool_initialized = False;
    }

    def _init_k8s(self: KubernetesSandbox) -> None {
        if self._k8s_initialized {
            return;
        }
        import from kubernetes { config as k8s_config }
        import from kubernetes.config { ConfigException }
        try {
            k8s_config.load_kube_config();
        } except ConfigException {
            k8s_config.load_incluster_config();
        }
        self._k8s_initialized = True;
    }

    def _get_ingress_provider(self: KubernetesSandbox) -> Any {
        if self._ingress_provider is None {
            if self.config.proxy_mode {
                ingress_type = "proxy";
            } elif self.config.tls_enabled
                or self.config.domain_template != "{sandbox_id}.preview.example.com" {
                ingress_type = "kubernetes";
            } else {
                ingress_type = "local";
            }
            self._ingress_provider = IngressFactory.create(ingress_type, {
                "ingress_class": self.config.ingress_class,
                "tls_enabled": self.config.tls_enabled,
                "tls_issuer": self.config.tls_issuer,
                "domain_template": self.config.domain_template
            });
        }
        return self._ingress_provider;
    }

    def _ensure_namespace(self: KubernetesSandbox) -> None {
        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        try {
            core_v1.read_namespace(self.config.namespace);
        } except Exception {
            ns_body = client.V1Namespace(
                metadata=client.V1ObjectMeta(
                    name=self.config.namespace,
                    labels={_SANDBOX_LABEL: "namespace"}
                )
            );
            core_v1.create_namespace(ns_body);
            if self.logger {
                self.logger.info(f"Created namespace: {self.config.namespace}");
            }
        }
    }

    def _ensure_rbac(self: KubernetesSandbox) -> None {
        if self._rbac_provisioned {
            return;
        }
        import from kubernetes { client }
        rbac_v1 = client.RbacAuthorizationV1Api();
        role_name = "jac-sandbox-manager";
        binding_name = "jac-sandbox-manager-binding";
        namespace = self.config.namespace;

        # Create Role
        role_body = {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {"name": role_name, "namespace": namespace},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["pods", "pods/exec", "pods/log",
                                  "services", "configmaps"],
                    "verbs": ["create", "get", "list", "watch", "delete",
                              "update", "patch"]
                },
                {
                    "apiGroups": ["networking.k8s.io"],
                    "resources": ["ingresses"],
                    "verbs": ["create", "get", "list", "delete", "update"]
                }
            ]
        };
        try {
            rbac_v1.read_namespaced_role(role_name, namespace);
        } except Exception {
            rbac_v1.create_namespaced_role(namespace, role_body);
        }

        # Create RoleBinding — bind to the default ServiceAccount in the
        # namespace where the main app is running (usually 'default')
        app_namespace = os.environ.get("POD_NAMESPACE", "default");
        app_sa = os.environ.get("POD_SERVICE_ACCOUNT", "default");
        binding_body = {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {"name": binding_name, "namespace": namespace},
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "Role",
                "name": role_name
            },
            "subjects": [
                {
                    "kind": "ServiceAccount",
                    "name": app_sa,
                    "namespace": app_namespace
                }
            ]
        };
        try {
            rbac_v1.read_namespaced_role_binding(binding_name, namespace);
        } except Exception {
            rbac_v1.create_namespaced_role_binding(namespace, binding_body);
        }

        self._rbac_provisioned = True;
        if self.logger {
            self.logger.info(
                f"RBAC provisioned: Role={role_name}, "
                f"Binding={binding_name} in ns={namespace}"
            );
        }
    }

    """Get the actual K8s pod name for a sandbox (may differ for warm pods)."""
    def _get_pod_name(self: KubernetesSandbox, sandbox_id: str) -> str {
        entry = self._registry.get(sandbox_id);
        return entry.get("pod_name", sandbox_id) if entry else sandbox_id;
    }

    def _generate_id(self: KubernetesSandbox, user_id: str, project_id: str) -> str {
        short = str(uuid.uuid4())[:8];
        # K8s names must be lowercase, alphanumeric, max 63 chars
        safe_user = user_id[:20].lower().replace("_", "-");
        safe_proj = project_id[:10].lower().replace("_", "-") if project_id else "def";
        return f"jac-sbx-{safe_user}-{safe_proj}-{short}";
    }

    def _create_configmap(
        self: KubernetesSandbox,
        sandbox_id: str,
        code_path: str,
        namespace: str
    ) -> str {
        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        cm_name = f"{sandbox_id}-code";

        # Walk code_path and collect files
        data: dict[str, str] = {};
        binary_data: dict[str, bytes] = {};
        total_size = 0;

        if os.path.isdir(code_path) {
            skip_dirs = [".jac", "node_modules", "__pycache__", "dist", ".git"];
            for walk_entry in os.walk(code_path) {
                dirpath = walk_entry[0];
                dirnames = walk_entry[1];
                filenames = walk_entry[2];
                kept = [d for d in dirnames if d not in skip_dirs];
                dirnames.clear();
                for d in kept {
                    dirnames.append(d);
                }
                for fname in filenames {
                    full = os.path.join(dirpath, fname);
                    rel = os.path.relpath(full, code_path);
                    try {
                        with open(full, "r", encoding="utf-8") as f {
                            content = f.read();
                        }
                        total_size += len(content.encode("utf-8"));
                        if total_size > _CONFIGMAP_SIZE_LIMIT {
                            if self.logger {
                                self.logger.warn(
                                    f"Code exceeds ConfigMap limit ({_CONFIGMAP_SIZE_LIMIT} bytes), "
                                    f"truncating at {rel}"
                                );
                            }
                            break;
                        }
                        # ConfigMap keys: replace / with -- for flat storage
                        safe_key = rel.replace("/", "--");
                        data[safe_key] = content;
                    } except UnicodeDecodeError {
                        ;  # Skip binary files in ConfigMap
                    }
                }
            }
        }

        cm = client.V1ConfigMap(
            metadata=client.V1ObjectMeta(
                name=cm_name,
                namespace=namespace,
                labels={
                    _SANDBOX_LABEL: "true",
                    "jac-sandbox-id": sandbox_id
                }
            ),
            data=data
        );
        core_v1.create_namespaced_config_map(namespace, cm);
        return cm_name;
    }

    def _build_pod_spec(
        self: KubernetesSandbox,
        sandbox_id: str,
        cm_name: str,
        user_id: str,
        project_id: str
    ) -> dict {
        import from kubernetes { client }

        # Security context
        security_context = None;
        if self.config.security_context_enabled {
            security_context = client.V1SecurityContext(
                run_as_non_root=True,
                run_as_user=1000,
                read_only_root_filesystem=False,
                allow_privilege_escalation=False
            );
        }

        # Resource limits
        resources = client.V1ResourceRequirements(
            limits={
                "cpu": self.config.cpu_limit,
                "memory": self.config.memory_limit
            },
            requests={
                "cpu": "100m",
                "memory": "64Mi"
            }
        );

        # Init container to unpack ConfigMap files into /app
        init_container = client.V1Container(
            name="code-setup",
            image=self.config.base_image,
            command=["sh", "-c",
                "cd /code-flat && for f in *; do "
                "  target=$(echo \"$f\" | sed 's/--/\\//g'); "
                "  mkdir -p \"/app/$(dirname \"$target\")\"; "
                "  cp \"$f\" \"/app/$target\"; "
                "done && echo 'Code copied to /app'"
            ],
            volume_mounts=[
                client.V1VolumeMount(
                    name="code-configmap", mount_path="/code-flat",
                    read_only=True
                ),
                client.V1VolumeMount(
                    name="app-data", mount_path="/app"
                )
            ]
        );

        # Main container
        main_container = client.V1Container(
            name="sandbox",
            image=self.config.base_image,
            command=["bash", "-c",
                f"cd /app && jac install 2>/dev/null; "
                f"jac start main.jac -p {_INTERNAL_PORT} --dev"
            ],
            ports=[client.V1ContainerPort(container_port=_INTERNAL_PORT)],
            resources=resources,
            security_context=security_context,
            volume_mounts=[
                client.V1VolumeMount(
                    name="app-data", mount_path="/app"
                ),
                client.V1VolumeMount(
                    name="tmp-scratch", mount_path="/tmp"
                )
            ],
            env=[
                client.V1EnvVar(name="JAC_SANDBOX_ID", value=sandbox_id),
                client.V1EnvVar(name="JAC_SANDBOX_USER", value=user_id),
                client.V1EnvVar(name="JAC_SANDBOX_PROJECT", value=project_id),
                client.V1EnvVar(name="CHOKIDAR_USEPOLLING", value="1"),
                client.V1EnvVar(name="WATCHPACK_POLLING", value="true")
            ]
        );

        # Volumes
        volumes = [
            client.V1Volume(
                name="code-configmap",
                config_map=client.V1ConfigMapVolumeSource(name=cm_name)
            ),
            client.V1Volume(
                name="app-data",
                empty_dir=client.V1EmptyDirVolumeSource()
            ),
            client.V1Volume(
                name="tmp-scratch",
                empty_dir=client.V1EmptyDirVolumeSource(
                    size_limit=self.config.storage_limit
                )
            )
        ];

        pod = client.V1Pod(
            metadata=client.V1ObjectMeta(
                name=sandbox_id,
                namespace=self.config.namespace,
                labels={
                    _SANDBOX_LABEL: "true",
                    "jac-sandbox-id": sandbox_id,
                    "jac-sandbox-user": user_id,
                    "jac-sandbox-project": project_id
                }
            ),
            spec=client.V1PodSpec(
                init_containers=[init_container],
                containers=[main_container],
                volumes=volumes,
                restart_policy="Never",
                active_deadline_seconds=self.config.ttl_seconds,
                termination_grace_period_seconds=10
            )
        );
        return pod;
    }

    def _create_service(
        self: KubernetesSandbox, sandbox_id: str, namespace: str
    ) -> str {
        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        svc_name = f"{sandbox_id}-svc";

        svc = client.V1Service(
            metadata=client.V1ObjectMeta(
                name=svc_name,
                namespace=namespace,
                labels={
                    _SANDBOX_LABEL: "true",
                    "jac-sandbox-id": sandbox_id
                }
            ),
            spec=client.V1ServiceSpec(
                selector={"jac-sandbox-id": sandbox_id},
                ports=[client.V1ServicePort(
                    port=_INTERNAL_PORT,
                    target_port=_INTERNAL_PORT,
                    protocol="TCP"
                )],
                type="ClusterIP"
            )
        );
        core_v1.create_namespaced_service(namespace, svc);
        return svc_name;
    }

    # ---- Warm Pool Methods ----

    """Build a pod spec for warm pool pods.

    Warm pods start with a signal-file loop: they wait for /app/.jac-start
    to exist before running jac install + jac start. This allows code
    injection via kubectl exec before the app launches.
    """
    def _build_warm_pod_spec(
        self: KubernetesSandbox, pod_name: str
    ) -> Any {
        import from kubernetes { client }

        security_context = None;
        if self.config.security_context_enabled {
            security_context = client.V1SecurityContext(
                run_as_non_root=True,
                run_as_user=1000,
                read_only_root_filesystem=False,
                allow_privilege_escalation=False
            );
        }

        resources = client.V1ResourceRequirements(
            limits={
                "cpu": self.config.cpu_limit,
                "memory": self.config.memory_limit
            },
            requests={
                "cpu": "100m",
                "memory": "64Mi"
            }
        );

        main_container = client.V1Container(
            name="sandbox",
            image=self.config.base_image,
            command=["bash", "-c",
                "while [ ! -f /app/.jac-start ]; do sleep 0.5; done; "
                f"cd /app && jac install 2>/dev/null; "
                f"jac start main.jac -p {_INTERNAL_PORT} --dev"
            ],
            ports=[client.V1ContainerPort(container_port=_INTERNAL_PORT)],
            resources=resources,
            security_context=security_context,
            volume_mounts=[
                client.V1VolumeMount(name="app-data", mount_path="/app"),
                client.V1VolumeMount(name="tmp-scratch", mount_path="/tmp")
            ],
            env=[
                client.V1EnvVar(name="JAC_SANDBOX_ID", value="warm-pool"),
                client.V1EnvVar(name="CHOKIDAR_USEPOLLING", value="1"),
                client.V1EnvVar(name="WATCHPACK_POLLING", value="true")
            ]
        );

        volumes = [
            client.V1Volume(
                name="app-data",
                empty_dir=client.V1EmptyDirVolumeSource()
            ),
            client.V1Volume(
                name="tmp-scratch",
                empty_dir=client.V1EmptyDirVolumeSource(
                    size_limit=self.config.storage_limit
                )
            )
        ];

        pod = client.V1Pod(
            metadata=client.V1ObjectMeta(
                name=pod_name,
                namespace=self.config.namespace,
                labels={
                    _SANDBOX_LABEL: "true",
                    "jac-sandbox-pool": "warm"
                }
            ),
            spec=client.V1PodSpec(
                containers=[main_container],
                volumes=volumes,
                restart_policy="Never",
                active_deadline_seconds=self.config.ttl_seconds,
                termination_grace_period_seconds=10
            )
        );
        return pod;
    }

    """Ensure the warm pool is at the configured size.

    Lists existing warm pods, creates new ones to fill the pool.
    Intended to be called in a background thread.
    """
    def _ensure_warm_pool(self: KubernetesSandbox) -> None {
        if self.config.warm_pool_size <= 0 {
            return;
        }
        try {
            import from kubernetes { client }
            core_v1 = client.CoreV1Api();
            namespace = self.config.namespace;

            # List existing warm pods
            existing = core_v1.list_namespaced_pod(
                namespace,
                label_selector=f"{_SANDBOX_LABEL}=true,jac-sandbox-pool=warm"
            );
            warm_count = 0;
            for p in existing.items {
                if p.status.phase in ["Pending", "Running"] {
                    warm_count += 1;
                    # Track in our pool list
                    pn = p.metadata.name;
                    self._lock.acquire();
                    try {
                        if pn not in self._warm_pool {
                            self._warm_pool.append(pn);
                        }
                    } finally {
                        self._lock.release();
                    }
                }
            }

            # Create pods to reach target size
            needed = self.config.warm_pool_size - warm_count;
            for i in range(needed) {
                pod_name = f"jac-warm-{str(uuid.uuid4())[:8]}";
                pod_spec = self._build_warm_pod_spec(pod_name);
                core_v1.create_namespaced_pod(namespace, pod_spec);
                self._lock.acquire();
                try {
                    self._warm_pool.append(pod_name);
                } finally {
                    self._lock.release();
                }
                if self.logger {
                    self.logger.info(f"Created warm pool pod: {pod_name}");
                }
            }
            self._pool_initialized = True;
        } except Exception as e {
            if self.logger {
                self.logger.warn(f"Warm pool error: {str(e)}");
            }
        }
    }

    """Claim a warm pod from the pool for an active sandbox.

    Relabels the pod with the sandbox_id and marks it as active.
    Returns the pod name if claimed, None if pool is empty.
    """
    def _claim_warm_pod(
        self: KubernetesSandbox,
        sandbox_id: str,
        user_id: str,
        project_id: str
    ) -> (str | None) {
        self._lock.acquire();
        try {
            if not self._warm_pool {
                return None;
            }
            pod_name = self._warm_pool.pop(0);
        } finally {
            self._lock.release();
        }

        try {
            import from kubernetes { client }
            core_v1 = client.CoreV1Api();
            namespace = self.config.namespace;

            # Verify pod is still running
            pod = core_v1.read_namespaced_pod_status(pod_name, namespace);
            if pod.status.phase not in ["Pending", "Running"] {
                return None;
            }

            # Relabel pod from warm → active
            body = {
                "metadata": {
                    "labels": {
                        _SANDBOX_LABEL: "true",
                        "jac-sandbox-id": sandbox_id,
                        "jac-sandbox-pool": "active",
                        "jac-sandbox-user": user_id,
                        "jac-sandbox-project": project_id
                    }
                }
            };
            core_v1.patch_namespaced_pod(pod_name, namespace, body);
            return pod_name;
        } except Exception as e {
            if self.logger {
                self.logger.warn(f"Failed to claim warm pod {pod_name}: {str(e)}");
            }
            return None;
        }
    }

    """Inject project files into a running pod via kubectl exec tar."""
    def _inject_code(
        self: KubernetesSandbox, pod_name: str, code_path: str
    ) -> bool {
        import from kubernetes { client }
        import from kubernetes.stream { stream }
        core_v1 = client.CoreV1Api();
        namespace = self.config.namespace;

        if not os.path.isdir(code_path) {
            return False;
        }

        try {
            import tarfile;
            import io;

            skip_dirs = {".jac", "node_modules", "__pycache__", "dist", ".git"};
            tar_buffer = io.BytesIO();

            with tarfile.open(fileobj=tar_buffer, mode="w:gz") as tar {
                for walk_entry in os.walk(code_path) {
                    dirpath = walk_entry[0];
                    dirnames = walk_entry[1];
                    filenames = walk_entry[2];
                    # Filter out skip dirs
                    kept = [d for d in dirnames if d not in skip_dirs];
                    dirnames.clear();
                    for d in kept {
                        dirnames.append(d);
                    }
                    for fname in filenames {
                        full = os.path.join(dirpath, fname);
                        arcname = os.path.relpath(full, code_path);
                        try {
                            tar.add(full, arcname=arcname);
                        } except Exception {
                            ;  # Skip files that can't be read
                        }
                    }
                }
            }

            tar_data = tar_buffer.getvalue();

            # Pipe tar into pod via exec
            import base64;
            encoded = base64.b64encode(tar_data).decode("ascii");

            # Split into chunks to avoid command-line length limits
            chunk_size = 65536;
            chunks = [
                encoded[i:i + chunk_size]
                for i in range(0, len(encoded), chunk_size)
            ];

            # Write chunks to a temp file inside the pod, then extract
            stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["sh", "-c", "rm -f /tmp/code.tar.gz"],
                stderr=True, stdout=True, stdin=False, tty=False
            );

            for chunk in chunks {
                stream(
                    core_v1.connect_get_namespaced_pod_exec,
                    pod_name, namespace,
                    container="sandbox",
                    command=["sh", "-c",
                        f"echo -n '{chunk}' >> /tmp/code.b64"
                    ],
                    stderr=True, stdout=True, stdin=False, tty=False
                );
            }

            # Decode and extract
            stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["sh", "-c",
                    "base64 -d /tmp/code.b64 > /tmp/code.tar.gz && "
                    "tar xzf /tmp/code.tar.gz -C /app && "
                    "rm -f /tmp/code.b64 /tmp/code.tar.gz"
                ],
                stderr=True, stdout=True, stdin=False, tty=False
            );

            if self.logger {
                self.logger.info(
                    f"Injected code into pod {pod_name} "
                    f"({len(tar_data)} bytes compressed)"
                );
            }
            return True;
        } except Exception as e {
            if self.logger {
                self.logger.warn(f"Code injection failed for {pod_name}: {str(e)}");
            }
            return False;
        }
    }

    """Signal a warm pod to start the jac application."""
    def _signal_start(self: KubernetesSandbox, pod_name: str) -> None {
        import from kubernetes { client }
        import from kubernetes.stream { stream }
        core_v1 = client.CoreV1Api();
        namespace = self.config.namespace;
        stream(
            core_v1.connect_get_namespaced_pod_exec,
            pod_name, namespace,
            container="sandbox",
            command=["touch", "/app/.jac-start"],
            stderr=True, stdout=True, stdin=False, tty=False
        );
    }

    def _poll_pod_readiness(
        self: KubernetesSandbox, sandbox_id: str
    ) -> None {
        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        namespace = self.config.namespace;
        start_time = time.time();
        ready = False;

        # Warm pods have a different pod name than sandbox_id
        entry = self._registry.get(sandbox_id);
        pod_name = entry.get("pod_name", sandbox_id) if entry else sandbox_id;

        while time.time() - start_time < 120 {
            try {
                pod = core_v1.read_namespaced_pod_status(
                    pod_name, namespace
                );
                phase = pod.status.phase;
                if phase == "Running" {
                    # Check container readiness
                    container_statuses = pod.status.container_statuses or [];
                    for cs in container_statuses {
                        if cs.name == "sandbox" and cs.ready {
                            ready = True;
                            break;
                        }
                    }
                    if ready {
                        break;
                    }
                    # Even if not marked ready, if Running, check logs
                    try {
                        log_content = core_v1.read_namespaced_pod_log(
                            pod_name, namespace,
                            container="sandbox", tail_lines=50
                        );
                        if "Server ready" in log_content {
                            ready = True;
                            break;
                        }
                    } except Exception {
                        ;
                    }
                } elif phase in ["Failed", "Succeeded"] {
                    break;
                }
            } except Exception {
                ;
            }
            time.sleep(3);
        }

        self._lock.acquire();
        try {
            entry = self._registry.get(sandbox_id);
            if entry {
                if ready {
                    entry["status"] = SandboxState.RUNNING;
                } else {
                    entry["status"] = SandboxState.ERROR;
                }
            }
        } finally {
            self._lock.release();
        }
    }

    def create(
        self: KubernetesSandbox,
        user_id: str,
        project_id: str,
        code_path: str
    ) -> SandboxResult {
        try {
            self._init_k8s();
            self._ensure_namespace();
            self._ensure_rbac();
        } except Exception as e {
            return SandboxResult(
                success=False,
                message=f"K8s initialization failed: {str(e)}"
            );
        }

        # Bootstrap warm pool on first use
        if self.config.warm_pool_size > 0 and not self._pool_initialized {
            replenish = Thread(
                target=self._ensure_warm_pool, daemon=True
            );
            replenish.start();
        }

        # Enforce max_per_user
        self._lock.acquire();
        try {
            user_count = 0;
            for (sid, entry) in self._registry.items() {
                if entry.get("user_id") == user_id
                and entry.get("status") not in [
                    SandboxState.STOPPED, SandboxState.ERROR
                ] {
                    user_count += 1;
                }
            }
            if user_count >= self.config.max_per_user {
                return SandboxResult(
                    success=False,
                    message=f"Max sandboxes per user ({self.config.max_per_user}) reached"
                );
            }
        } finally {
            self._lock.release();
        }

        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        namespace = self.config.namespace;
        sandbox_id = self._generate_id(user_id, project_id);

        # --- Warm start path ---
        if self.config.warm_pool_size > 0 {
            claimed_pod = self._claim_warm_pod(
                sandbox_id, user_id, project_id
            );
            if claimed_pod {
                try {
                    # Inject code into the warm pod
                    injected = self._inject_code(claimed_pod, code_path);
                    if not injected {
                        self._cleanup_k8s_resources(sandbox_id, namespace);
                        return SandboxResult(
                            success=False,
                            message="Failed to inject code into warm pod"
                        );
                    }

                    # Signal the pod to start
                    self._signal_start(claimed_pod);

                    # Get URL via ingress provider
                    ingress = self._get_ingress_provider();
                    svc_name = "";
                    if not self.config.proxy_mode {
                        svc_name = self._create_service(sandbox_id, namespace);
                    }
                    url = ingress.create_route(
                        sandbox_id, svc_name, _INTERNAL_PORT, namespace,
                        {
                            "domain_template": self.config.domain_template,
                            "ingress_class": self.config.ingress_class,
                            "tls_enabled": self.config.tls_enabled,
                            "tls_issuer": self.config.tls_issuer,
                            "ingress_annotations": self.config.ingress_annotations
                        }
                    );

                    # Register
                    self._lock.acquire();
                    try {
                        self._registry[sandbox_id] = {
                            "sandbox_id": sandbox_id,
                            "user_id": user_id,
                            "project_id": project_id,
                            "pod_name": claimed_pod,
                            "namespace": namespace,
                            "status": SandboxState.STARTING,
                            "url": url,
                            "port": _INTERNAL_PORT,
                            "created_at": time.time(),
                            "warm_start": True
                        };
                    } finally {
                        self._lock.release();
                    }

                    # Poll readiness in background
                    checker = Thread(
                        target=self._poll_pod_readiness,
                        args=(sandbox_id,),
                        daemon=True
                    );
                    checker.start();

                    # Replenish pool in background
                    replenish = Thread(
                        target=self._ensure_warm_pool, daemon=True
                    );
                    replenish.start();

                    if self.logger {
                        self.logger.info(
                            f"Warm start: {sandbox_id} on pod {claimed_pod}"
                        );
                    }

                    return SandboxResult(
                        success=True, sandbox_id=sandbox_id,
                        url=url, port=_INTERNAL_PORT,
                        message="warm-starting"
                    );
                } except Exception as e {
                    self._cleanup_k8s_resources(sandbox_id, namespace);
                    return SandboxResult(success=False, message=str(e));
                }
            }
        }

        # --- Cold start path ---
        try {
            # 1. Create ConfigMap with project code
            cm_name = self._create_configmap(sandbox_id, code_path, namespace);

            # 2. Create Pod
            pod_spec = self._build_pod_spec(
                sandbox_id, cm_name, user_id, project_id
            );
            core_v1.create_namespaced_pod(namespace, pod_spec);

            # 3. Create Service (skip in proxy mode)
            svc_name = "";
            if not self.config.proxy_mode {
                svc_name = self._create_service(sandbox_id, namespace);
            }

            # 4. Create Ingress route
            ingress = self._get_ingress_provider();
            url = ingress.create_route(
                sandbox_id, svc_name, _INTERNAL_PORT, namespace,
                {
                    "domain_template": self.config.domain_template,
                    "ingress_class": self.config.ingress_class,
                    "tls_enabled": self.config.tls_enabled,
                    "tls_issuer": self.config.tls_issuer,
                    "ingress_annotations": self.config.ingress_annotations
                }
            );

            # 5. Register
            self._lock.acquire();
            try {
                self._registry[sandbox_id] = {
                    "sandbox_id": sandbox_id,
                    "user_id": user_id,
                    "project_id": project_id,
                    "pod_name": sandbox_id,
                    "configmap": cm_name,
                    "namespace": namespace,
                    "status": SandboxState.STARTING,
                    "url": url,
                    "port": _INTERNAL_PORT,
                    "created_at": time.time(),
                    "warm_start": False
                };
            } finally {
                self._lock.release();
            }

            # 6. Poll readiness in background
            checker = Thread(
                target=self._poll_pod_readiness,
                args=(sandbox_id,),
                daemon=True
            );
            checker.start();

            return SandboxResult(
                success=True, sandbox_id=sandbox_id,
                url=url, port=_INTERNAL_PORT,
                message="cold-starting"
            );
        } except Exception as e {
            # Clean up on failure
            self._cleanup_k8s_resources(sandbox_id, namespace);
            return SandboxResult(success=False, message=str(e));
        }
    }

    def _cleanup_k8s_resources(
        self: KubernetesSandbox, sandbox_id: str, namespace: str
    ) -> None {
        import from kubernetes { client }
        import from kubernetes.client.exceptions { ApiException }
        core_v1 = client.CoreV1Api();

        # Find actual pod name (warm pods have different names)
        entry = self._registry.get(sandbox_id);
        pod_name = entry.get("pod_name", sandbox_id) if entry else sandbox_id;

        # Delete pod
        try {
            core_v1.delete_namespaced_pod(pod_name, namespace);
        } except ApiException {
            ;
        }
        # Delete service (skip in proxy mode — no per-sandbox service)
        if not self.config.proxy_mode {
            try {
                core_v1.delete_namespaced_service(f"{sandbox_id}-svc", namespace);
            } except ApiException {
                ;
            }
        }
        # Delete configmap (skip for warm pods — no configmap)
        if not (entry and entry.get("warm_start")) {
            try {
                core_v1.delete_namespaced_config_map(f"{sandbox_id}-code", namespace);
            } except ApiException {
                ;
            }
        }
        # Delete ingress
        try {
            ingress = self._get_ingress_provider();
            ingress.delete_route(sandbox_id, namespace);
        } except Exception {
            ;
        }
    }

    def stop(self: KubernetesSandbox, sandbox_id: str) -> None {
        self._init_k8s();
        entry = self._registry.get(sandbox_id);
        namespace = entry.get("namespace", self.config.namespace) if entry
            else self.config.namespace;
        self._cleanup_k8s_resources(sandbox_id, namespace);
        self._lock.acquire();
        try {
            if sandbox_id in self._registry {
                self._registry[sandbox_id]["status"] = SandboxState.STOPPED;
            }
        } finally {
            self._lock.release();
        }
    }

    def status(self: KubernetesSandbox, sandbox_id: str) -> SandboxStatus {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return SandboxStatus(
                state=SandboxState.STOPPED, sandbox_id=sandbox_id
            );
        }
        # Check actual pod status
        try {
            self._init_k8s();
            import from kubernetes { client }
            core_v1 = client.CoreV1Api();
            pod_name = self._get_pod_name(sandbox_id);
            pod = core_v1.read_namespaced_pod_status(
                pod_name, entry.get("namespace", self.config.namespace)
            );
            phase = pod.status.phase;
            if phase == "Running" {
                state = SandboxState.RUNNING;
            } elif phase == "Pending" {
                state = SandboxState.STARTING;
            } elif phase in ["Failed", "Unknown"] {
                state = SandboxState.ERROR;
            } else {
                state = SandboxState.STOPPED;
            }
        } except Exception {
            state = entry.get("status", SandboxState.STOPPED);
        }
        uptime = time.time() - entry.get("created_at", time.time())
            if state == SandboxState.RUNNING else 0.0;
        return SandboxStatus(
            state=state, sandbox_id=sandbox_id,
            uptime_seconds=uptime,
            url=entry.get("url", ""),
            port=entry.get("port", 0)
        );
    }

    def destroy(self: KubernetesSandbox, sandbox_id: str) -> None {
        self.stop(sandbox_id);
        self._lock.acquire();
        try {
            self._registry.pop(sandbox_id, None);
        } finally {
            self._lock.release();
        }
    }

    def list_sandboxes(self: KubernetesSandbox, user_id: str) -> list[SandboxInfo] {
        results: list[SandboxInfo] = [];
        for (sid, entry) in self._registry.items() {
            if entry.get("user_id") == user_id {
                results.append(SandboxInfo(
                    sandbox_id=sid,
                    user_id=entry.get("user_id", ""),
                    project_id=entry.get("project_id", ""),
                    state=entry.get("status", SandboxState.STOPPED),
                    url=entry.get("url", ""),
                    created_at=entry.get("created_at", 0.0)
                ));
            }
        }
        return results;
    }

    def cleanup_expired(self: KubernetesSandbox) -> int {
        self._init_k8s();
        import from kubernetes { client }
        core_v1 = client.CoreV1Api();
        namespace = self.config.namespace;
        expired: list[str] = [];

        try {
            pods = core_v1.list_namespaced_pod(
                namespace, label_selector=f"{_SANDBOX_LABEL}=true"
            );
            now = time.time();
            for pod in pods.items {
                created = pod.metadata.creation_timestamp;
                if created {
                    import from datetime { timezone }
                    age = now - created.replace(tzinfo=timezone.utc).timestamp();
                    if age > self.config.ttl_seconds {
                        expired.append(pod.metadata.name);
                    }
                }
            }
        } except Exception {
            ;
        }

        for sid in expired {
            self.destroy(sid);
        }
        return len(expired);
    }

    def logs(self: KubernetesSandbox, sandbox_id: str, offset: int = 0) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);
            log_content = core_v1.read_namespaced_pod_log(
                pod_name, namespace,
                container="sandbox"
            );
            if offset > 0 {
                if offset >= len(log_content) {
                    return {"success": True, "content": "", "offset": offset};
                }
                log_content = log_content[offset:];
            }
            new_offset = offset + len(log_content);
            return {"success": True, "content": log_content, "offset": new_offset};
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    def write_file(
        self: KubernetesSandbox, sandbox_id: str, path: str, content: str
    ) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            import from kubernetes.stream { stream }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);

            # Ensure parent directory exists
            parent_dir = os.path.dirname(path);
            if parent_dir {
                stream(
                    core_v1.connect_get_namespaced_pod_exec,
                    pod_name, namespace,
                    container="sandbox",
                    command=["mkdir", "-p", f"/app/{parent_dir}"],
                    stderr=True, stdout=True, stdin=False, tty=False
                );
            }

            # Write file content via exec
            # Use base64 encoding to safely transfer content
            import base64;
            encoded = base64.b64encode(content.encode("utf-8")).decode("utf-8");
            stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["sh", "-c", f"echo '{encoded}' | base64 -d > /app/{path}"],
                stderr=True, stdout=True, stdin=False, tty=False
            );
            return {"success": True, "path": path};
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    def read_file(
        self: KubernetesSandbox, sandbox_id: str, path: str
    ) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            import from kubernetes.stream { stream }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);
            result = stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["cat", f"/app/{path}"],
                stderr=True, stdout=True, stdin=False, tty=False
            );
            return {"success": True, "path": path, "content": result};
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    def delete_file(
        self: KubernetesSandbox, sandbox_id: str, path: str
    ) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            import from kubernetes.stream { stream }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);
            stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["rm", "-rf", f"/app/{path}"],
                stderr=True, stdout=True, stdin=False, tty=False
            );
            return {"success": True, "path": path};
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    def list_files(
        self: KubernetesSandbox, sandbox_id: str, path: str = "."
    ) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            import from kubernetes.stream { stream }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);
            result = stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["find", f"/app/{path}", "-type", "f",
                         "-not", "-path", "*/node_modules/*",
                         "-not", "-path", "*/.jac/*",
                         "-not", "-path", "*/__pycache__/*",
                         "-not", "-path", "*/dist/*"],
                stderr=True, stdout=True, stdin=False, tty=False
            );
            files = [
                os.path.relpath(f.strip(), "/app")
                for f in result.strip().split("\n")
                if f.strip()
            ];
            files.sort();
            return {"success": True, "files": files};
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    def exec_command(
        self: KubernetesSandbox, sandbox_id: str, command: str, timeout: int = 30
    ) -> dict {
        entry = self._registry.get(sandbox_id);
        if not entry {
            return {"success": False, "error": "Sandbox not found"};
        }
        try {
            self._init_k8s();
            import from kubernetes { client }
            import from kubernetes.stream { stream }
            core_v1 = client.CoreV1Api();
            namespace = entry.get("namespace", self.config.namespace);
            pod_name = self._get_pod_name(sandbox_id);
            result = stream(
                core_v1.connect_get_namespaced_pod_exec,
                pod_name, namespace,
                container="sandbox",
                command=["bash", "-c", command],
                stderr=True, stdout=True, stdin=False, tty=False
            );
            return {
                "success": True, "exit_code": 0,
                "stdout": result, "stderr": ""
            };
        } except Exception as e {
            return {"success": False, "error": str(e)};
        }
    }

    # ---- Convenience methods for preview_manager compatibility ----

    def get_sandbox_id(
        self: KubernetesSandbox, user_id: str, project_id: str
    ) -> (str | None) {
        for (sid, entry) in self._registry.items() {
            if entry.get("user_id") == user_id
            and entry.get("project_id") == project_id {
                return sid;
            }
        }
        return None;
    }
}
