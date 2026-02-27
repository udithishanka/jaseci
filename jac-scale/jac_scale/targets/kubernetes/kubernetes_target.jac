"""Kubernetes deployment target implementation."""
import os;
import from typing { Any }
import from jac_scale.abstractions.deployment_target { DeploymentTarget }
import from jac_scale.abstractions.config.app_config { AppConfig }
import from jac_scale.abstractions.models.deployment_result { DeploymentResult }
import from jac_scale.abstractions.models.resource_status {
    ResourceStatus,
    ResourceStatusInfo
}
import from jac_scale.abstractions.logger { Logger }
import from jac_scale.targets.kubernetes.kubernetes_config { KubernetesConfig }
import from jac_scale.targets.kubernetes.utils.kubernetes_utils {
    check_deployment_status,
    check_node_ports_available,
    cluster_type,
    create_k8s_secret,
    delete_k8s_secret,
    delete_if_exists,
    delete_namespace,
    detect_ingress_class,
    check_K8s_status,
    ensure_namespace_exists,
    ensure_pvc_exists,
    load_env_variables,
    validate_resource_limits,
    sync_code_to_pvc
}
import from jac_scale.providers.registry.dockerhub { DockerHubRegistry }
import from jac_scale.providers.database.kubernetes_mongo { KubernetesMongoProvider }
import from jac_scale.providers.database.kubernetes_redis { KubernetesRedisProvider }
import from jac_scale.factories.database_factory { DatabaseProviderFactory }
import from jac_scale.factories.registry_factory { ImageRegistryFactory }
import from jac_scale.targets.kubernetes.monitoring { MonitoringDeployer }
import from jac_scale.targets.kubernetes.hpa.hpa { create_hpa }
import time;
import from kubernetes { client, config as k8s_cluster_config }
import from kubernetes.client.exceptions { ApiException }

"""Kubernetes deployment target implementation."""
class KubernetesTarget(DeploymentTarget) {
    has k8s_config: KubernetesConfig,
        secrets: dict[str, str] = {};

    def init(
        self: KubernetesTarget,
        config: KubernetesConfig,
        logger: (Logger | None) = None
    ) -> None {
        self.config = config;
        self.k8s_config = config;
        self.env_list = [];
        self.secrets = {};
        if logger {
            self.logger = logger;
        }
    }

    """Get init containers from all enabled database providers."""
    def _get_database_init_containers(
        self: KubernetesTarget, app_name: str
    ) -> list[dict[(str, Any)]] {
        init_containers = [];
        wait_image = self.k8s_config.wait_image;

        if self.k8s_config.mongodb_enabled {
            mongo_provider = DatabaseProviderFactory.create(
                'kubernetes_mongo', self, {'app_name': app_name}
            );
            init_container = mongo_provider.get_init_container(app_name, wait_image);
            if init_container {
                init_containers.append(init_container);
            }
        }

        if self.k8s_config.redis_enabled {
            redis_provider = DatabaseProviderFactory.create(
                'kubernetes_redis', self, {'app_name': app_name}
            );
            init_container = redis_provider.get_init_container(app_name, wait_image);
            if init_container {
                init_containers.append(init_container);
            }
        }

        return init_containers;
    }

    """Build resource requests and limits configuration."""
    def _build_resource_config(self: KubernetesTarget) -> dict[(str, Any)] {
        resource_requests: dict[(str, str)] = {};
        if self.k8s_config.cpu_request {
            resource_requests['cpu'] = self.k8s_config.cpu_request;
        }
        if self.k8s_config.memory_request {
            resource_requests['memory'] = self.k8s_config.memory_request;
        }

        resource_limits: dict[(str, str)] = {};
        if self.k8s_config.cpu_limit {
            resource_limits['cpu'] = self.k8s_config.cpu_limit;
        }
        if self.k8s_config.memory_limit {
            resource_limits['memory'] = self.k8s_config.memory_limit;
        }

        resources: dict[(str, dict)] = {};
        if resource_requests {
            resources['requests'] = resource_requests;
        }
        if resource_limits {
            resources['limits'] = resource_limits;
        }

        return resources;
    }

    """Build readiness and liveness probe configurations."""
    def _build_probe_config(
        self: KubernetesTarget, health_check_path: str
    ) -> dict[(str, Any)] {
        probe_config = {
            'httpGet': {
                'path': health_check_path,
                'port': self.k8s_config.container_port,
                'scheme': 'HTTP'
            },
            'initialDelaySeconds': self.k8s_config.readiness_initial_delay,
            'periodSeconds': self.k8s_config.readiness_period
        };

        liveness_probe = dict(probe_config);
        liveness_probe['initialDelaySeconds'] = self.k8s_config.liveness_initial_delay;
        liveness_probe['periodSeconds'] = self.k8s_config.liveness_period;
        liveness_probe['failureThreshold'] = self.k8s_config.liveness_failure_threshold;

        return {'readiness': probe_config, 'liveness': liveness_probe};
    }

    """Determine how the application should be exposed: 'ingress', 'loadbalancer', or 'nodeport'."""
    def _resolve_exposure_mode(
        self: KubernetesTarget, cluster_env: str
    ) -> tuple[str, (str | None)] {
        if self.k8s_config.use_ingress {
            detected_class = detect_ingress_class(self.k8s_config.ingress_class_name);
            if detected_class {
                if self.k8s_config.ingress_base_domain {
                    if self.logger {
                        self.logger.info(
                            f"Ingress mode: using IngressClass '{detected_class}' "
                            f"with base domain '{self.k8s_config.ingress_base_domain}'"
                        );
                    }
                    return ('ingress', detected_class);
                } else {
                    if self.logger {
                        self.logger.warn(
                            f"IngressClass '{detected_class}' found but ingress_base_domain "
                            f"is not configured. Falling back to direct service exposure."
                        );
                    }
                }
            }
        }
        if cluster_env == 'aws' {
            return ('loadbalancer', None);
        }
        return ('nodeport', None);
    }

    """Build Kubernetes service configuration."""
    def _build_service_config(
        self: KubernetesTarget,
        app_name: str,
        cluster_env: str,
        health_check_path: str,
        exposure_mode: str
    ) -> dict[(str, Any)] {
        service_metadata: dict[(str, Any)] = {
            'name': f"{app_name}-service",
            'namespace': self.k8s_config.namespace,
            'labels': {'app': app_name, 'managed': 'jac-scale'}
        };

        if exposure_mode == 'ingress' {
            service_type = 'ClusterIP';
            port_config: dict[(str, Any)] = {
                'protocol': 'TCP',
                'port': 80,
                'targetPort': self.k8s_config.container_port
            };
        } elif exposure_mode == 'loadbalancer' {
            service_type = 'LoadBalancer';
            port_config = {
                'protocol': 'TCP',
                'port': 80,
                'targetPort': self.k8s_config.container_port
            };
            service_metadata['annotations'] = {
                'service.beta.kubernetes.io/aws-load-balancer-type': 'nlb',
                'service.beta.kubernetes.io/aws-load-balancer-healthcheck-path': health_check_path
            };
        } else {
            service_type = 'NodePort';
            port_config = {
                'protocol': 'TCP',
                'port': self.k8s_config.container_port,
                'targetPort': self.k8s_config.container_port,
                'nodePort': self.k8s_config.node_port
            };
        }

        service = {
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': service_metadata,
            'spec': {
                'type': service_type,
                'ports': [port_config],
                'selector': {'app': app_name}
            }
        };
        return service;
    }

    """Build Kubernetes Ingress resource for host-based routing."""
    def _build_ingress_config(
        self: KubernetesTarget, app_name: str, ingress_class_name: str
    ) -> dict[(str, Any)] {
        namespace = self.k8s_config.namespace;
        base_domain = self.k8s_config.ingress_base_domain;
        if namespace == 'default' {
            host = f"{app_name}.{base_domain}";
        } else {
            host = f"{namespace}-{app_name}.{base_domain}";
        }

        ingress = {
            'apiVersion': 'networking.k8s.io/v1',
            'kind': 'Ingress',
            'metadata': {
                'name': f"{app_name}-ingress",
                'namespace': namespace,
                'labels': {'app': app_name, 'managed': 'jac-scale'}
            },
            'spec': {
                'ingressClassName': ingress_class_name,
                'rules': [
                    {
                        'host': host,
                        'http': {
                            'paths': [
                                {
                                    'path': '/',
                                    'pathType': 'Prefix',
                                    'backend': {
                                        'service': {
                                            'name': f"{app_name}-service",
                                            'port': {'number': 80}
                                        }
                                    }
                                }
                            ]
                        }
                    }
                ]
            }
        };
        return ingress;
    }

    """Build the bash command for setting up Jaseci runtime environment."""
    def _build_runtime_setup_command(
        self: KubernetesTarget, app_config: AppConfig
    ) -> list[str] {
        config = self.k8s_config;
        commands = [];

        # Base setup
        commands.append('export DEBIAN_FRONTEND=noninteractive');
        commands.append('apt-get update');

        # Install base packages (curl and unzip needed for Bun installation)
        base_packages = ['git', 'curl', 'unzip'];
        if config.additional_packages {
            base_packages.extend(config.additional_packages);
        }
        commands.append(f"apt-get install -y {' '.join(base_packages)}");

        # Install Bun (required for jac-client frontend builds)
        commands.append('curl -fsSL https://bun.sh/install | bash');
        commands.append('export BUN_INSTALL="$HOME/.bun"');
        commands.append('export PATH="$BUN_INSTALL/bin:$PATH"');

        if app_config.experimental {
            commands.append('rm -rf jaseci');
            clone_cmd = f"git clone --branch {config.jaseci_branch} --single-branch {config.jaseci_repo_url}";
            commands.append(clone_cmd);
            commands.append('cd ./jaseci');
            if config.jaseci_commit {
                commands.append(f"git checkout {config.jaseci_commit}");
            }
            commands.append('git submodule update --init --recursive');
            commands.append('pip install pluggy');
            commands.append('pip install -e ./jac');
            commands.append('pip install -e ./jac-scale');
            commands.append('pip install -e ./jac-client');
            commands.append('pip install -e ./jac-byllm');
            commands.append('cd ..');
        } else {
            packages = config.plugin_versions or {};
            jaclang_v = packages.get('jaclang', 'latest');
            scale_v = packages.get('jac_scale', 'latest');
            client_v = packages.get('jac_client', 'latest');
            byllm_v = packages.get('jac_byllm', 'latest');
            if jaclang_v == 'latest' {
                commands.append('pip install jaclang');
            } else {
                commands.append(f'pip install jaclang=={jaclang_v}');
            }
            if scale_v == 'latest' {
                commands.append('pip install jac-scale');
            } else {
                commands.append(f'pip install jac-scale=={scale_v}');
            }
            if client_v == 'latest' {
                commands.append('pip install jac-client');
            } else {
                commands.append(f'pip install jac-client=={client_v}');
            }
            if byllm_v and byllm_v != 'none' {
                if byllm_v == 'latest' {
                    commands.append('pip install byllm');
                } else {
                    commands.append(f'pip install byllm=={byllm_v}');
                }
            }
        }

        # Change to app directory (project is already copied there via volume mount)
        commands.append(f"cd {config.app_mount_path}");

        # Install requirements
        commands.append('jac install');

        # Start the application
        commands.append(f"jac start {app_config.file_name}");

        # Join all commands
        full_command = ' && '.join(commands);

        return ['bash', '-c', full_command];
    }

    """Build container configuration."""
    def _build_container_config(
        self: KubernetesTarget,
        app_name: str,
        image: str,
        probe_configs: dict[(str, Any)],
        resources_config: dict[(str, Any)],
        command: (list[str] | None) = None,
        working_dir: (str | None) = None,
        volume_mounts: (list[dict[(str, Any)]] | None) = None,
        secret_ref_name: (str | None) = None
    ) -> dict[(str, Any)] {
        container_config = {
            'name': app_name,
            'image': image,
            'ports': [{'containerPort': self.k8s_config.container_port}],
            'env': self.env_list,
            'readinessProbe': probe_configs['readiness'],
            'livenessProbe': probe_configs['liveness']
        };

        if secret_ref_name {
            container_config['envFrom'] = [{'secretRef': {'name': secret_ref_name}}];
        }
        if command {
            container_config['command'] = command;
        }
        if working_dir {
            container_config['workingDir'] = working_dir;
        }
        if volume_mounts {
            container_config['volumeMounts'] = volume_mounts;
        }
        if resources_config {
            container_config['resources'] = resources_config;
        }

        return container_config;
    }

    """Build volumes and build container configuration for code sync via code-server."""
    def _build_volumes_config(
        self: KubernetesTarget,
        app_name: str,
        app_config: AppConfig,
        namespace: str,
        core_v1: Any,
        apps_v1: Any
    ) -> dict[str, Any] {
        pvc_name = f"{app_name}-code-pvc";
        pvc_size = self.k8s_config.pvc_size;
        sync_image = self.k8s_config.busybox_image;

        ensure_pvc_exists(core_v1, namespace, pvc_name, pvc_size);
        if self.logger {
            self.logger.info('Syncing application code to PVC');
        }
        sync_code_to_pvc(
            core_v1, namespace, pvc_name, app_config.code_folder, app_name, sync_image
        );

        # Deploy code-server to serve code from PVC over HTTP
        self._deploy_code_server(app_name, namespace, apps_v1, core_v1);

        # Init container fetches code from code-server via wget (no PVC mount needed)
        code_server_url = f"http://{app_name}-code-server:8080/code.tar.gz";
        build_container = {
            'name': 'build-app',
            'image': self.k8s_config.busybox_image,
            'command': [
                'sh',
                '-c',
                f"until wget -q -O {self.k8s_config.app_mount_path}/code.tar.gz {code_server_url}; do sleep 2; done && tar xzf {self.k8s_config.app_mount_path}/code.tar.gz -C {self.k8s_config.app_mount_path}/ && rm {self.k8s_config.app_mount_path}/code.tar.gz"
            ],
            'volumeMounts': [
                {'name': 'app-code', 'mountPath': self.k8s_config.app_mount_path}
            ]
        };

        # Only emptyDir - no PVC mount on app pods, so they can schedule on any node
        volumes = [{'name': 'app-code', 'emptyDir': {}}];

        return {'volumes': volumes, 'build_container': build_container};
    }

    """Deploy code-server: a single-replica busybox httpd that serves code from the PVC over HTTP."""
    def _deploy_code_server(
        self: KubernetesTarget,
        app_name: str,
        namespace: str,
        apps_v1: Any,
        core_v1: Any
    ) -> None {
        code_server_name = f"{app_name}-code-server";
        code_server_labels = {'app': code_server_name};
        pvc_name = f"{app_name}-code-pvc";

        # Code-server Deployment spec
        deployment_body = {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'name': code_server_name,
                'namespace': namespace,
                'labels': {** code_server_labels, 'managed': 'jac-scale'}
            },
            'spec': {
                'replicas': 1,
                'selector': {'matchLabels': code_server_labels},
                'template': {
                    'metadata': {'labels': code_server_labels},
                    'spec': {
                        'containers': [
                            {
                                'name': 'code-server',
                                'image': self.k8s_config.busybox_image,
                                'command': [
                                    'sh',
                                    '-c',
                                    f"tar czf /tmp/code.tar.gz -C {self.k8s_config.workspace_path} --exclude='.jac' . && httpd -f -p 8080 -h /tmp"
                                ],
                                'ports': [{'containerPort': 8080}],
                                'volumeMounts': [
                                    {
                                        'name': 'code-source',
                                        'mountPath': self.k8s_config.code_mount_path,
                                        'readOnly': True
                                    }
                                ]
                            }
                        ],
                        'volumes': [
                            {
                                'name': 'code-source',
                                'persistentVolumeClaim': {'claimName': pvc_name}
                            }
                        ]
                    }
                }
            }
        };

        # Code-server Service spec
        service_body = {
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'name': code_server_name,
                'namespace': namespace,
                'labels': {** code_server_labels, 'managed': 'jac-scale'}
            },
            'spec': {
                'type': 'ClusterIP',
                'ports': [{'port': 8080, 'targetPort': 8080}],
                'selector': code_server_labels
            }
        };

        # Delete existing code-server deployment to force re-tar of fresh code
        delete_if_exists(
            apps_v1.delete_namespaced_deployment,
            code_server_name,
            namespace,
            'Deployment'
        );
        time.sleep(self.k8s_config.resource_deletion_wait);

        # Create code-server deployment
        apps_v1.create_namespaced_deployment(namespace=namespace, body=deployment_body);
        if self.logger {
            self.logger.info(f"Deployed code-server '{code_server_name}'");
        }

        # Create code-server service (if not exists)
        try {
            core_v1.read_namespaced_service(name=code_server_name, namespace=namespace);
        } except ApiException as e {
            if e.status == 404 {
                core_v1.create_namespaced_service(
                    namespace=namespace, body=service_body
                );
                if self.logger {
                    self.logger.info(
                        f"Created code-server service '{code_server_name}'"
                    );
                }
            } else {
                raise ;
            }
        }
    }

    """Deploy all enabled databases."""
    def _deploy_databases(
        self: KubernetesTarget,
        app_name: str,
        namespace: str,
        apps_v1: Any,
        core_v1: Any
    ) -> None {
        if self.k8s_config.mongodb_enabled {
            mongodb_name = f"{app_name}-mongodb";
            mongodb_service_name = f"{mongodb_name}-service";
            mongo_provider = DatabaseProviderFactory.create(
                'kubernetes_mongo', self, {'app_name': app_name}
            );
            mongo_result = mongo_provider.deploy({});
            self.env_list.append(
                {'name': 'MONGODB_URI', 'value': mongo_result['connection_string']}
            );
            try {
                apps_v1.read_namespaced_stateful_set(
                    name=mongodb_name, namespace=namespace
                );
            } except ApiException as e {
                if (e.status == 404) {
                    apps_v1.create_namespaced_stateful_set(
                        namespace=namespace, body=mongo_result['deployment']
                    );
                } else {
                    raise ;
                }
            }
            try {
                core_v1.read_namespaced_service(
                    name=mongodb_service_name, namespace=namespace
                );
            } except ApiException as e {
                if (e.status == 404) {
                    core_v1.create_namespaced_service(
                        namespace=namespace, body=mongo_result['service']
                    );
                } else {
                    raise ;
                }
            }
        }

        if self.k8s_config.redis_enabled {
            redis_name = f"{app_name}-redis";
            redis_service_name = f"{redis_name}-service";
            redis_provider = DatabaseProviderFactory.create(
                'kubernetes_redis', self, {'app_name': app_name}
            );
            redis_result = redis_provider.deploy({});
            self.env_list.append(
                {'name': 'REDIS_URL', 'value': redis_result['connection_string']}
            );
            try {
                apps_v1.read_namespaced_deployment(
                    name=redis_name, namespace=namespace
                );
            } except ApiException as e {
                if (e.status == 404) {
                    apps_v1.create_namespaced_deployment(
                        namespace=namespace, body=redis_result['deployment']
                    );
                } else {
                    raise ;
                }
            }
            try {
                core_v1.read_namespaced_service(
                    name=redis_service_name, namespace=namespace
                );
            } except ApiException as e {
                if (e.status == 404) {
                    core_v1.create_namespaced_service(
                        namespace=namespace, body=redis_result['service']
                    );
                } else {
                    raise ;
                }
            }
        }
    }

    """Wait for deployment to be ready and check status."""
    def _wait_for_deployment(
        self: KubernetesTarget,
        app_name: str,
        namespace: str,
        health_check_path: str,
        cluster_env: str,
        exposure_mode: str = 'nodeport'
    ) -> str {
        path = health_check_path;
        deployment_details = "";
        if exposure_mode == 'ingress' {
            base_domain = self.k8s_config.ingress_base_domain;
            if namespace == 'default' {
                host = f"{app_name}.{base_domain}";
            } else {
                host = f"{namespace}-{app_name}.{base_domain}";
            }
            ingress_url = f"http://{host}";
            time.sleep(10);
            (deployment_status, deployment_details) = check_deployment_status(
                self.k8s_config.node_port,
                path,
                nlb_url=ingress_url,
                namespace=namespace,
                app_name=app_name
            );
            if not deployment_status {
                if self.logger {
                    self.logger.warn(
                        f"Could not reach app via Ingress host '{host}'. "
                        f"Ensure DNS for '*.{base_domain}' points to the Ingress Controller."
                    );
                }
                deployment_details = f"Ingress created at {host} (DNS may need configuration)";
            }
        } elif cluster_env == 'aws' {
            time.sleep(self.k8s_config.aws_nlb_wait);
            nlb_url = None;
            try {
                try {
                    k8s_cluster_config.load_kube_config();
                } except ConfigException {
                    k8s_cluster_config.load_incluster_config();
                }
                core_v1 = client.CoreV1Api();
                service_obj = core_v1.read_namespaced_service(
                    f"{app_name}-service", namespace
                );
                nlb_ingress = service_obj.status.load_balancer.ingress;
                if (nlb_ingress and (len(nlb_ingress) > 0)) {
                    endpoint = nlb_ingress[0].hostname or nlb_ingress[0].ip;
                    nlb_url = f"http://{endpoint}";
                } else {
                    if self.logger {
                        self.logger.info(
                            f"NLB is being provisioned. Run 'kubectl get svc {app_name}-service -n {namespace}' to get the endpoint."
                        );
                    }
                }
            } except Exception as e {
                if self.logger {
                    self.logger.warn(f"Could not retrieve NLB endpoint: {e}");
                }
            }
            if (nlb_url) {
                (deployment_status, deployment_details) = check_deployment_status(
                    self.k8s_config.node_port,
                    path,
                    nlb_url=nlb_url,
                    namespace=namespace,
                    app_name=app_name
                );
                if not (deployment_status) {
                    raise Exception(
                        "Deployment failed: Application failed to deploy."
                    ) ;
                }
            }
        } else {
            (deployment_status, deployment_details) = check_deployment_status(
                self.k8s_config.node_port, path, namespace=namespace, app_name=app_name
            );
            if deployment_status is False {
                raise Exception("Deployment failed: Application failed to deploy.") ;
            }
        }
        return deployment_details;
    }

    """Handle image registry if build is requested."""
    def _handle_image_registry(
        self: KubernetesTarget, app_name: str, app_config: AppConfig
    ) -> str {
        image_name = self.k8s_config.docker_image_name or f"{app_name}:latest";
        repository_name: str;
        if app_config.build and self.image_registry {
            # Build and push image
            full_image = self.image_registry.build_and_push(
                app_config.code_folder, image_name
            );
            repository_name = full_image;
        } elif app_config.build {
            # Create registry if not set
            registry_config = {
                'app_name': app_name,
                'docker_username': self.k8s_config.docker_username,
                'docker_password': self.k8s_config.docker_password,
                'docker_image_name': image_name
            };
            image_registry = ImageRegistryFactory.create('dockerhub', registry_config);
            full_image = image_registry.build_and_push(
                app_config.code_folder, image_name
            );
            repository_name = full_image;
        } else {
            repository_name = self.k8s_config.python_image;
        }
        return repository_name;
    }

    def deploy(self: KubernetesTarget, app_config: AppConfig) -> DeploymentResult {
        # 1. Initialize and validate
        app_name = app_config.app_name or self.k8s_config.app_name;
        namespace = os.getenv('K8s_NAMESPACE') or self.k8s_config.namespace;
        success_status = False;
        details = {};

        if self.logger {
            self.logger.info(
                f"Deploying application '{app_name}' to Kubernetes",
                {'namespace': namespace, 'build': app_config.build}
            );
        }

        try {
            validate_resource_limits(
                self.k8s_config.cpu_request,
                self.k8s_config.cpu_limit,
                self.k8s_config.memory_request,
                self.k8s_config.memory_limit
            );
            details["validate_resource_limits"] = "Successful";
            # 2. Initialize Kubernetes clients
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            apps_v1 = client.AppsV1Api();
            core_v1 = client.CoreV1Api();
            check_K8s_status();
            ensure_namespace_exists(namespace);

            # 3. Load environment variables
            self.env_list = load_env_variables(app_config.code_folder);
            details["load_env_variables"] = "Successful";

            # 3b. Create K8s Secret from resolved secrets if configured
            secret_ref_name: str | None = None;
            if self.secrets {
                secret_ref_name = f"{app_name}-secrets";
                if create_k8s_secret(
                    core_v1, namespace, secret_ref_name, self.secrets
                ) {
                    if self.logger {
                        self.logger.info(f"Created K8s Secret '{secret_ref_name}'");
                    }
                } else {
                    secret_ref_name = None;
                }
            }

            # 4. Determine cluster type and exposure mode
            cluster_env = cluster_type();
            (exposure_mode, resolved_ingress_class) = self._resolve_exposure_mode(
                cluster_env
            );

            # 4b. On local clusters with nodeport mode, verify NodePorts are not bound
            if exposure_mode == 'nodeport' {
                check_node_ports_available(
                    node_port=self.k8s_config.node_port,
                    prometheus_node_port=(
                        self.k8s_config.prometheus_node_port
                            if self.k8s_config.monitoring_enabled
                            else None
                    ),
                    grafana_node_port=(
                        self.k8s_config.grafana_node_port
                            if self.k8s_config.monitoring_enabled
                            else None
                    ),
                    current_namespace=namespace
                );
            }

            # 5. Handle image registry if build is requested
            repository_name = self._handle_image_registry(app_name, app_config);

            # 6. Get health check path
            health_check_path = self.k8s_config.health_check_path;

            # 7. Get database init containers
            init_containers = self._get_database_init_containers(app_name);

            # 8. Build configurations
            volumes = [];
            resources_config = self._build_resource_config();
            probe_configs = self._build_probe_config(health_check_path);

            # 9. Build container configuration
            container_config = self._build_container_config(
                app_name,
                repository_name,
                probe_configs,
                resources_config,
                secret_ref_name=secret_ref_name
            );

            # 10. Handle volumes and build container if not building image
            if not app_config.build {
                volumes_config = self._build_volumes_config(
                    app_name, app_config, namespace, core_v1, apps_v1
                );
                details["sync_code_to_pvc"] = "Successful";
                volumes = volumes_config['volumes'];
                build_container = volumes_config['build_container'];
                init_containers.append(build_container);
                # Build runtime setup command
                command = self._build_runtime_setup_command(app_config);
                container_config = self._build_container_config(
                    app_name,
                    self.k8s_config.python_image,
                    probe_configs,
                    resources_config,
                    command=command,
                    working_dir=self.k8s_config.app_mount_path,
                    volume_mounts=[
                        {
                            'name': 'app-code',
                            'mountPath': self.k8s_config.app_mount_path
                        }
                    ],
                    secret_ref_name=secret_ref_name
                );
            }

            # 11. Build service and deployment
            service = self._build_service_config(
                app_name, cluster_env, health_check_path, exposure_mode
            );
            deployment = {
                'apiVersion': 'apps/v1',
                'kind': 'Deployment',
                'metadata': {
                    'name': app_name,
                    'namespace': namespace,
                    'labels': {'app': app_name, 'managed': 'jac-scale'}
                },
                'spec': {
                    'replicas': 1,
                    'selector': {'matchLabels': {'app': app_name}},
                    'template': {
                        'metadata': {'labels': {'app': app_name}},
                        'spec': {
                            'initContainers': init_containers,
                            'containers': [container_config],
                            'volumes': volumes
                        }
                    }
                }
            };

            # 12. Delete existing resources if they exist
            delete_if_exists(
                apps_v1.delete_namespaced_deployment, app_name, namespace, 'Deployment'
            );
            details["delete_previous_existing_resources"] = "Successful";
            time.sleep(self.k8s_config.resource_deletion_wait);

            # 13. Deploy databases
            self._deploy_databases(app_name, namespace, apps_v1, core_v1);
            details["deploy_databases"] = "Successful";
            # 14. Deploy main application
            if self.logger {
                self.logger.info(f'Deploying Jaseci-app app...');
            }
            apps_v1.create_namespaced_deployment(namespace=namespace, body=deployment);
            details["create_jaseci_application_deployment"] = "Successful";
            try {
                core_v1.read_namespaced_service(
                    name=f"{app_name}-service", namespace=namespace
                );
            } except ApiException as e {
                if (e.status == 404) {
                    core_v1.create_namespaced_service(
                        namespace=namespace, body=service
                    );
                } else {
                    raise ;
                }
            }
            details["create_jaseci_application_service"] = "Successful";
            # 14b. Create Ingress resource if in ingress mode
            if exposure_mode == 'ingress' and resolved_ingress_class {
                ingress_resource = self._build_ingress_config(
                    app_name, resolved_ingress_class
                );
                networking_v1 = client.NetworkingV1Api();
                ingress_name = f"{app_name}-ingress";
                try {
                    networking_v1.read_namespaced_ingress(
                        name=ingress_name, namespace=namespace
                    );
                    networking_v1.replace_namespaced_ingress(
                        name=ingress_name, namespace=namespace, body=ingress_resource
                    );
                } except ApiException as e {
                    if e.status == 404 {
                        networking_v1.create_namespaced_ingress(
                            namespace=namespace, body=ingress_resource
                        );
                    } else {
                        raise ;
                    }
                }
                details["create_ingress_resource"] = "Successful";
            }
            # 16. Enable horizontal pod autoscaling
            create_hpa(
                namespace=namespace,
                deployment_name=app_name,
                min_replicas=self.k8s_config.min_replicas,
                max_replicas=self.k8s_config.max_replicas,
                cpu_target=self.k8s_config.cpu_utilization_target
            );
            details["create_horizontal_auto_scaler"] = "Successful";
            # 15. Deploy monitoring stack (Prometheus / Grafana) if enabled
            monitoring = MonitoringDeployer(self.k8s_config, self.logger);
            monitoring.deploy(app_name, namespace, apps_v1, core_v1, cluster_env);
            details["deploy_monitoring"] = "Successful";

            # 16. Wait for deployment and get service URL
            deployment_details = self._wait_for_deployment(
                app_name,
                namespace,
                health_check_path,
                cluster_env,
                exposure_mode=exposure_mode
            );
            details["health_check_of_deployment"] = deployment_details;
            service_url = self.get_service_url(app_name);

            success_status = True;
            return DeploymentResult(
                success=success_status,
                service_url=service_url,
                message=f"Application '{app_name}' deployed successfully",
                details=details
            );
        } except Exception as e {
            if self.logger {
                self.logger.error(f"Error deploying application '{app_name}': {e}");
            }
            return DeploymentResult(
                success=success_status,
                message=f"Deployment failed for application '{app_name}': {e}",
                details=details
            );
        }
    }

    """Wait for resources to be completely deleted."""
    def _wait_for_deletion(
        self: KubernetesTarget,
        app_name: str,
        namespace: str,
        apps_v1: Any,
        core_v1: Any,
        max_wait: int = 60,
        poll_interval: float = 1.0
    ) -> None {
        elapsed = 0.0;
        while elapsed < max_wait {
            resources_exist = False;

            # Check deployment
            try {
                apps_v1.read_namespaced_deployment(name=app_name, namespace=namespace);
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Check service
            try {
                core_v1.read_namespaced_service(
                    name=f"{app_name}-service", namespace=namespace
                );
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Check ingress
            try {
                networking_v1 = client.NetworkingV1Api();
                networking_v1.read_namespaced_ingress(
                    name=f"{app_name}-ingress", namespace=namespace
                );
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Check code-server deployment
            code_server_name = f"{app_name}-code-server";
            try {
                apps_v1.read_namespaced_deployment(
                    name=code_server_name, namespace=namespace
                );
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Check code-server service
            try {
                core_v1.read_namespaced_service(
                    name=code_server_name, namespace=namespace
                );
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Check MongoDB resources if enabled
            if self.k8s_config.mongodb_enabled {
                mongodb_name = f"{app_name}-mongodb";
                try {
                    apps_v1.read_namespaced_stateful_set(
                        name=mongodb_name, namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
                try {
                    core_v1.read_namespaced_service(
                        name=f"{mongodb_name}-service", namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
            }

            # Check Redis resources if enabled
            if self.k8s_config.redis_enabled {
                redis_name = f"{app_name}-redis";
                try {
                    apps_v1.read_namespaced_deployment(
                        name=redis_name, namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
                try {
                    core_v1.read_namespaced_service(
                        name=f"{redis_name}-service", namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
            }

            # Check monitoring resources (Prometheus / Grafana) if enabled
            if self.k8s_config.monitoring_enabled {
                prometheus_name = f"{app_name}-prometheus";
                try {
                    apps_v1.read_namespaced_deployment(
                        name=prometheus_name, namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
                try {
                    core_v1.read_namespaced_service(
                        name=f"{prometheus_name}-service", namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
                grafana_name = f"{app_name}-grafana";
                try {
                    apps_v1.read_namespaced_deployment(
                        name=grafana_name, namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
                try {
                    core_v1.read_namespaced_service(
                        name=f"{grafana_name}-service", namespace=namespace
                    );
                    resources_exist = True;
                } except ApiException as e {
                    if e.status != 404 {
                        raise ;
                    }
                }
            }

            # Check PVCs
            try {
                pvcs = core_v1.list_namespaced_persistent_volume_claim(namespace);
                for pvc in pvcs.items {
                    if pvc.metadata.name.startswith(app_name) {
                        resources_exist = True;
                        break;
                    }
                }
            } except Exception { }

            # Check code sync pod
            try {
                core_v1.read_namespaced_pod(
                    name=f"{app_name}-code-sync", namespace=namespace
                );
                resources_exist = True;
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # If no resources exist, deletion is complete
            if not resources_exist {
                if self.logger {
                    self.logger.info(
                        f"All resources for '{app_name}' have been deleted"
                    );
                }
                return;
            }
            time.sleep(poll_interval);
            elapsed = elapsed + poll_interval;
        }

        if self.logger {
            self.logger.warn(
                f"Timeout waiting for resources to be deleted after {max_wait} seconds"
            );
        }
    }

    """Destroy all enabled databases."""
    def _destroy_databases(
        self: KubernetesTarget,
        app_name: str,
        namespace: str,
        apps_v1: Any,
        core_v1: Any
    ) -> None {
        if self.k8s_config.mongodb_enabled {
            mongodb_name = f"{app_name}-mongodb";
            delete_if_exists(
                apps_v1.delete_namespaced_stateful_set,
                mongodb_name,
                namespace,
                'StatefulSet'
            );
            delete_if_exists(
                core_v1.delete_namespaced_service,
                f"{mongodb_name}-service",
                namespace,
                'Service'
            );
        }

        if self.k8s_config.redis_enabled {
            redis_name = f"{app_name}-redis";
            delete_if_exists(
                apps_v1.delete_namespaced_deployment,
                redis_name,
                namespace,
                'Deployment'
            );
            delete_if_exists(
                core_v1.delete_namespaced_service,
                f"{redis_name}-service",
                namespace,
                'Service'
            );
        }
    }

    def destroy(self: KubernetesTarget, app_name: str) -> None {
        if self.logger {
            self.logger.info(f"Destroying application '{app_name}' from Kubernetes");
        }

        try {
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            apps_v1 = client.AppsV1Api();
            core_v1 = client.CoreV1Api();
            autoscaling_v2 = client.AutoscalingV2Api();
            namespace = self.k8s_config.namespace;

            # Delete HPA
            delete_if_exists(
                autoscaling_v2.delete_namespaced_horizontal_pod_autoscaler,
                f"{app_name}-hpa",
                namespace,
                'HorizontalPodAutoscaler'
            );

            # Delete main deployment and service
            delete_if_exists(
                apps_v1.delete_namespaced_deployment, app_name, namespace, 'Deployment'
            );
            delete_if_exists(
                core_v1.delete_namespaced_service,
                f"{app_name}-service",
                namespace,
                'Service'
            );

            # Delete Ingress resource if it exists
            networking_v1 = client.NetworkingV1Api();
            delete_if_exists(
                networking_v1.delete_namespaced_ingress,
                f"{app_name}-ingress",
                namespace,
                'Ingress'
            );

            # Delete K8s Secret if it exists
            delete_k8s_secret(core_v1, namespace, f"{app_name}-secrets");

            # Delete code-server deployment and service (before PVC deletion)
            code_server_name = f"{app_name}-code-server";
            delete_if_exists(
                apps_v1.delete_namespaced_deployment,
                code_server_name,
                namespace,
                'Deployment'
            );
            delete_if_exists(
                core_v1.delete_namespaced_service,
                code_server_name,
                namespace,
                'Service'
            );

            # Delete monitoring stack (Prometheus / Grafana)
            monitoring = MonitoringDeployer(self.k8s_config, self.logger);
            monitoring.destroy(app_name, namespace, apps_v1, core_v1);

            # Delete databases
            self._destroy_databases(app_name, namespace, apps_v1, core_v1);

            # Delete code sync pod and PVCs
            delete_if_exists(
                core_v1.delete_namespaced_pod,
                f"{app_name}-code-sync",
                namespace,
                'Pod'
            );

            # Delete PVCs
            pvcs = core_v1.list_namespaced_persistent_volume_claim(namespace);
            for pvc in pvcs.items {
                if pvc.metadata.name.startswith(app_name) {
                    try {
                        core_v1.delete_namespaced_persistent_volume_claim(
                            name=pvc.metadata.name, namespace=namespace
                        );
                    } except Exception { }
                }
            }

            # Wait for all resources to be completely deleted
            if self.logger {
                self.logger.info(
                    f"Waiting for all resources to be deleted for '{app_name}'..."
                );
            }
            self._wait_for_deletion(app_name, namespace, apps_v1, core_v1);

            # Delete namespace if not the default one
            if namespace != 'default' {
                delete_namespace(namespace);
                if self.logger {
                    self.logger.info(
                        f"Waiting for namespace '{namespace}' to be deleted..."
                    );
                }
                ns_deleted = False;
                ns_elapsed = 0.0;
                ns_max_wait = 120;
                ns_poll = 2.0;
                while ns_elapsed < ns_max_wait {
                    try {
                        core_v1.read_namespace(name=namespace);
                        time.sleep(ns_poll);
                        ns_elapsed = ns_elapsed + ns_poll;
                    } except ApiException as e {
                        if e.status == 404 {
                            ns_deleted = True;
                            break;
                        }
                        raise ;
                    }
                }
                if self.logger {
                    if ns_deleted {
                        self.logger.info(f"Namespace '{namespace}' deleted");
                    } else {
                        self.logger.warning(
                            f"Timed out waiting for namespace '{namespace}' to be deleted"
                        );
                    }
                }
            }

            if self.logger {
                self.logger.info(f"Application '{app_name}' destroyed successfully");
            }
        } except Exception as e {
            if self.logger {
                self.logger.error(f"Error destroying application '{app_name}': {e}");
            }
            raise ;
        }
    }

    def get_status(self: KubernetesTarget, app_name: str) -> ResourceStatusInfo {
        try {
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            apps_v1 = client.AppsV1Api();
            core_v1 = client.CoreV1Api();
            namespace = self.k8s_config.namespace;

            deployment = apps_v1.read_namespaced_deployment(
                name=app_name, namespace=namespace
            );

            replicas = deployment.spec.replicas or 0;
            ready_replicas = deployment.status.ready_replicas or 0;

            if ready_replicas == replicas and replicas > 0 {
                status = ResourceStatus.RUNNING;
            } elif ready_replicas > 0 {
                status = ResourceStatus.PENDING;
            } else {
                status = ResourceStatus.FAILED;
            }

            return ResourceStatusInfo(
                status=status, replicas=replicas, ready_replicas=ready_replicas
            );
        } except Exception as e {
            if self.logger {
                self.logger.error(f"Failed to get status for '{app_name}': {e}");
            }
            return ResourceStatusInfo(status=ResourceStatus.UNKNOWN, message=str(e));
        }
    }

    def scale(self: KubernetesTarget, app_name: str, replicas: int) -> None {
        if self.logger {
            self.logger.info(
                f"Scaling application '{app_name}' to {replicas} replicas"
            );
        }

        try {
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            apps_v1 = client.AppsV1Api();
            namespace = self.k8s_config.namespace;

            deployment = apps_v1.read_namespaced_deployment(
                name=app_name, namespace=namespace
            );
            deployment.spec.replicas = replicas;

            apps_v1.patch_namespaced_deployment(
                name=app_name, namespace=namespace, body=deployment
            );

            if self.logger {
                self.logger.info(
                    f"Successfully scaled '{app_name}' to {replicas} replicas"
                );
            }
        } except Exception as e {
            if self.logger {
                self.logger.error(f"Failed to scale '{app_name}': {e}");
            }
            raise ;
        }
    }

    def get_service_url(self: KubernetesTarget, app_name: str) -> (str | None) {
        try {
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            namespace = self.k8s_config.namespace;

            # Check for Ingress resource first (indicates ingress mode)
            try {
                networking_v1 = client.NetworkingV1Api();
                ingress_obj = networking_v1.read_namespaced_ingress(
                    name=f"{app_name}-ingress", namespace=namespace
                );
                if ingress_obj.spec.rules and len(ingress_obj.spec.rules) > 0 {
                    host = ingress_obj.spec.rules[0].host;
                    if host {
                        return f"http://{host}";
                    }
                }
            } except ApiException as e {
                if e.status != 404 {
                    raise ;
                }
            }

            # Fallback to service-based URL
            core_v1 = client.CoreV1Api();
            service = core_v1.read_namespaced_service(
                name=f"{app_name}-service", namespace=namespace
            );
            cluster_env = cluster_type();
            if cluster_env == 'aws' {
                lb_ingress = service.status.load_balancer.ingress;
                if lb_ingress and len(lb_ingress) > 0 {
                    endpoint = lb_ingress[0].hostname or lb_ingress[0].ip;
                    return f"http://{endpoint}";
                }
            } else {
                node_port = self.k8s_config.node_port;
                return f"http://localhost:{node_port}";
            }
        } except Exception as e {
            if self.logger {
                self.logger.debug(f"Could not get service URL for '{app_name}': {e}");
            }
        }
        return None;
    }

    """Get comprehensive status of all deployed components for this application.

    Makes 4 bulk API calls instead of one per component:
      1. list_namespaced_deployment
      2. list_namespaced_stateful_set
      3. list_namespaced_pod  (to detect crash-looping pods)
      4. read_namespaced_service  (app URL)
    """
    def get_full_status(self: KubernetesTarget, app_name: str) -> dict {
        try {
            try {
                k8s_cluster_config.load_kube_config();
            } except ConfigException {
                k8s_cluster_config.load_incluster_config();
            }
            apps_v1 = client.AppsV1Api();
            core_v1 = client.CoreV1Api();
        } except Exception as e {
            return {
                'app_name': app_name,
                'namespace': self.k8s_config.namespace,
                'error': str(e),
                'components': [],
                'urls': {}
            };
        }

        namespace = self.k8s_config.namespace;
        components = [];
        urls = {};

        # 1. Bulk-fetch all Deployments
        dep_map = {};
        try {
            for d in apps_v1.list_namespaced_deployment(namespace=namespace).items {
                dep_map[d.metadata.name] = d;
            }
        } except Exception { }

        # 2. Bulk-fetch all StatefulSets
        sts_map = {};
        try {
            for s in apps_v1.list_namespaced_stateful_set(namespace=namespace).items {
                sts_map[s.metadata.name] = s;
            }
        } except Exception { }

        # 3. Bulk-fetch pods to detect crash-looping (restart_count > 0)
        #    Keyed by the pod's 'app' label → True if any container has restarts
        restarting_apps = {};
        try {
            for pod in core_v1.list_namespaced_pod(namespace=namespace).items {
                pod_labels = pod.metadata.labels;
                if pod_labels and 'app' in pod_labels {
                    pod_app = pod_labels['app'];
                    if pod.status and pod.status.container_statuses {
                        for cs in pod.status.container_statuses {
                            if cs.restart_count and cs.restart_count > 0 {
                                restarting_apps[pod_app] = True;
                            }
                        }
                    }
                }
            }
        } except Exception { }

        # Resolve status for each component from the cached maps
        component_defs = [
            {'k8s_name': app_name, 'display': 'Jaseci App', 'is_sts': False},
            {'k8s_name': f"{app_name}-redis", 'display': 'Redis', 'is_sts': False},
            {'k8s_name': f"{app_name}-mongodb", 'display': 'MongoDB', 'is_sts': True},
            {
                'k8s_name': f"{app_name}-prometheus",
                'display': 'Prometheus',
                'is_sts': False
            },
            {'k8s_name': f"{app_name}-grafana", 'display': 'Grafana', 'is_sts': False},

        ];

        grafana_running = False;
        for cdef in component_defs {
            k8s_name = cdef['k8s_name'];
            display_name = cdef['display'];
            if cdef['is_sts'] {
                resource_map = sts_map;
            } else {
                resource_map = dep_map;
            }
            if k8s_name in resource_map {
                r = resource_map[k8s_name];
                replicas = r.spec.replicas or 0;
                ready = r.status.ready_replicas or 0;
                if ready == replicas and replicas > 0 {
                    status = 'running';
                } elif ready > 0 {
                    status = 'degraded';
                } elif k8s_name in restarting_apps {
                    # Pods exist but are crash-looping
                    status = 'restarting';
                } else {
                    status = 'pending';
                }
                components.append(
                    {
                        'name': display_name,
                        'status': status,
                        'ready': ready,
                        'total': replicas
                    }
                );
                if display_name == 'Grafana' {
                    grafana_running = True;
                }
            } else {
                components.append(
                    {
                        'name': display_name,
                        'status': 'not_deployed',
                        'ready': 0,
                        'total': 0
                    }
                );
            }
        }

        # 4. Application service URL — check Ingress first
        is_aws = cluster_type() == 'aws';
        try {
            networking_v1 = client.NetworkingV1Api();
            ingress_obj = networking_v1.read_namespaced_ingress(
                name=f"{app_name}-ingress", namespace=namespace
            );
            if ingress_obj.spec.rules and len(ingress_obj.spec.rules) > 0 {
                host = ingress_obj.spec.rules[0].host;
                if host {
                    urls['app'] = f"http://{host}";
                }
            }
        } except ApiException { }

        if 'app' not in urls {
            try {
                svc = core_v1.read_namespaced_service(
                    name=f"{app_name}-service", namespace=namespace
                );
                if is_aws {
                    lb_ingress = svc.status.load_balancer.ingress;
                    if lb_ingress and len(lb_ingress) > 0 {
                        endpoint = lb_ingress[0].hostname or lb_ingress[0].ip;
                        urls['app'] = f"http://{endpoint}";
                    }
                } else {
                    urls['app'] = f"http://localhost:{self.k8s_config.node_port}";
                }
            } except Exception { }
        }

        # Grafana URL (NodePort on local, LoadBalancer on AWS)
        if grafana_running {
            if is_aws {
                try {
                    svc = core_v1.read_namespaced_service(
                        name=f"{app_name}-grafana-service", namespace=namespace
                    );
                    ingress = svc.status.load_balancer.ingress;
                    if ingress and len(ingress) > 0 {
                        endpoint = ingress[0].hostname or ingress[0].ip;
                        urls['grafana'] = f"http://{endpoint}";
                    }
                } except Exception { }
            } else {
                urls['grafana'] = f"http://localhost:{self.k8s_config.grafana_node_port}";
            }
        }

        return {
            'app_name': app_name,
            'namespace': namespace,
            'components': components,
            'urls': urls
        };
    }
}
