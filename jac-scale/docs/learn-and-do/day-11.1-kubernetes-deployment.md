# Day 10: Kubernetes Deployment

## Learn (~1 hour)

### What is Kubernetes?

Kubernetes (K8s) is a system that runs and manages containers across multiple machines. Think of it as "subprocess manager for the cloud."

| Local (Day 3) | Kubernetes |
|---------------|-----------|
| `subprocess.Popen(["jac", "start", ...])` | Create a Deployment (K8s manages the process) |
| `proc.pid` | Pod name |
| `127.0.0.1:8001` | `orders.default.svc.cluster.local:8000` |
| `proc.terminate()` | `kubectl delete deployment orders` |
| Health check via HTTP | K8s liveness/readiness probes |
| One instance | HPA can scale to N instances |

### Key K8s Resources We Need

For each microservice, we create:

**1. Deployment** — "run this container, keep N replicas alive"
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: orders
          image: my-app:latest
          command: ["jac", "start", "services/orders.jac", "--port", "8000", "--no-client"]
          ports:
            - containerPort: 8000
```

**2. Service** — "give this Deployment a stable DNS name"
```yaml
apiVersion: v1
kind: Service
metadata:
  name: orders
spec:
  selector:
    app: orders
  ports:
    - port: 8000
```

Now any pod can reach Orders at `http://orders:8000`.

**3. Ingress** (gateway only) — "expose the gateway to the internet"
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway
spec:
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            backend:
              service:
                name: gateway
                port: 8000
```

### How It Maps to Our Architecture

```
Internet
    │
    ▼
┌─────────────────────┐
│ Ingress              │  ← only the gateway is exposed
└───────┬─────────────┘
        ▼
┌─────────────────────┐
│ Gateway Deployment   │  ← runs MicroserviceGateway
│ Service: gateway     │
└───┬──────────┬──────┘
    │          │
    ▼          ▼
┌──────────┐ ┌──────────┐
│ Orders   │ │ Payments │  ← each is a Deployment + Service
│ Dep+Svc  │ │ Dep+Svc  │
└──────────┘ └──────────┘
        │          │
        ▼          ▼
   ┌───────────────────┐
   │ MongoDB + Redis   │  ← shared, existing pattern
   │ (StatefulSets)    │
   └───────────────────┘
```

### How jac-scale's `KubernetesTarget` Already Works

The existing `jac start app.jac --scale` flow:
1. Builds a Docker image containing the Jac app
2. Pushes it to a registry
3. Creates K8s manifests (Deployment, Service, Ingress, MongoDB, Redis)
4. Applies them via `kubectl`

For microservice mode, we extend this to create **multiple Deployments** from the same image — each with a different `command` targeting a different `.jac` file.

### Same Image, Different Commands

All services share one Docker image (it contains all the code). The difference is the **startup command**:

```
Gateway container:   jac start app.jac --gateway-mode
Orders container:    jac start services/orders.jac --port 8000 --no-client
Payments container:  jac start services/payments.jac --port 8000 --no-client
```

This keeps the Docker build simple — one image, multiple entry points.

---

## Do (~2-3 hours)

### Task 1: Understand the existing K8s target

Read through these files to understand the existing pattern:
- `jac_scale/targets/kubernetes/kubernetes_target.jac` — the main deployment logic
- Look at how it generates Deployment, Service, and Ingress manifests

### Task 2: Create multi-service K8s manifest generator

Add a method that generates manifests for all declared services:

**Concept** (you'll add this to the existing kubernetes target or create a new file):

```jac
"""Generate K8s manifests for microservice mode."""
def generate_microservice_manifests(
    services_config: dict,
    image_name: str,
    namespace: str = "default"
) -> list[dict] {
    manifests: list[dict] = [];

    # 1. Gateway Deployment + Service + Ingress
    manifests.append(create_deployment(
        name="gateway",
        image=image_name,
        command=["jac", "start", "app.jac", "--gateway-mode"],
        port=8000,
        replicas=1,
        env={
            "MICROSERVICE_MODE": "gateway",
            "GATEWAY_PORT": "8000"
        }
    ));
    manifests.append(create_service(name="gateway", port=8000));
    manifests.append(create_ingress(name="gateway", port=8000));

    # 2. One Deployment + Service per declared service
    for (name, svc_config) in services_config.items() {
        manifests.append(create_deployment(
            name=name,
            image=image_name,
            command=["jac", "start", svc_config["file"], "--port", "8000", "--no-client"],
            port=8000,
            replicas=svc_config.get("replicas", 1),
            env=svc_config.get("env", {})
        ));
        manifests.append(create_service(name=name, port=8000));
    }

    return manifests;
}
```

### Task 3: Update gateway for K8s mode

In K8s, the gateway doesn't start subprocesses — it just proxies to K8s Services by DNS name.

Update the registry building to use K8s Service DNS URLs:

```jac
# When running in K8s (--scale), service URLs are DNS-based:
def build_k8s_registry(services_config: dict, namespace: str = "default") -> ServiceRegistry {
    registry = ServiceRegistry();

    for (name, svc_config) in services_config.items() {
        entry = ServiceEntry(
            name=name,
            file=svc_config.get("file", ""),
            prefix=svc_config.get("prefix", f"/api/{name}"),
            port=8000,
            url=f"http://{name}.{namespace}.svc.cluster.local:8000",
            status=ServiceStatus.HEALTHY  # K8s manages health via probes
        );
        registry.register(entry);
    }

    return registry;
}
```

### Task 4: Wire --scale into the microservice flow

Update the plugin integration from Day 9. When `--scale` AND `microservices.enabled`:

```jac
if ms_config.get("enabled", False) {
    if is_scale_deploy {
        # K8s deployment — generate multi-service manifests
        # Reuse existing KubernetesTarget but with per-service Deployments
        import from jac_scale.microservices.orchestrator { deploy_microservices_to_k8s }
        deploy_microservices_to_k8s(scale_config);
    } else {
        # Local mode — subprocesses + gateway
        import from jac_scale.microservices.orchestrator { start_microservice_mode }
        start_microservice_mode(scale_config);
    }
    return;
}
```

### Task 5: Test locally (simulate K8s)

You likely don't have a K8s cluster handy, so test the manifest generation:

```python
# test_k8s_manifests.py
import json
from jac_scale.microservices.k8s import generate_microservice_manifests

services = {
    "orders": {"file": "services/orders.jac", "prefix": "/api/orders", "replicas": 2},
    "payments": {"file": "services/payments.jac", "prefix": "/api/payments", "replicas": 1}
}

manifests = generate_microservice_manifests(services, image_name="myapp:latest")

for m in manifests:
    print(f"--- {m['kind']}: {m['metadata']['name']} ---")
    print(json.dumps(m, indent=2)[:200])
    print()

# Verify:
# - 1 gateway Deployment + Service + Ingress
# - 2 service Deployments + Services (orders, payments)
# - orders has replicas: 2
# - Each has the correct jac start command
```

If you have minikube or Docker Desktop K8s:
```bash
jac start app.jac --scale
# Should create per-service Deployments instead of a single one
```

---

## Milestone

- [ ] Understand how K8s Deployments, Services, and Ingress work
- [ ] Manifest generator creates per-service Deployments with correct `command`
- [ ] Gateway Deployment uses K8s Service DNS for service URLs
- [ ] Same Docker image, different commands per service
- [ ] `jac start --scale` with microservices enabled generates multi-service manifests
- [ ] (If K8s available) Full deployment works end-to-end

**You now understand**: how Kubernetes maps to the local subprocess model, how K8s Service DNS replaces `127.0.0.1:port`, how to generate per-service Deployments from a single image, and how the gateway switches between subprocess management (local) and DNS-based routing (K8s).

---

## Congratulations!

You've completed the 10-day program. Here's what you built:

| Day | Component | What it does |
|-----|-----------|-------------|
| 1 | Module skeleton + TOML config | Foundation |
| 2 | ServiceRegistry | Tracks services, matches paths |
| 3 | ServiceProcessManager | Starts/stops/health-checks subprocesses |
| 4 | MicroserviceGateway | Path-based reverse proxy |
| 5 | Static file serving | SPA + assets from gateway |
| 6 | JWT auth | Gateway-level auth + header injection |
| 7 | service_call() | Inter-service HTTP with token propagation |
| 8 | jac setup microservice | CLI tooling for config |
| 9 | Orchestrator + plugin.jac | Full local flow |
| 10 | K8s manifests | Production deployment |

### What's Next

- **Testing**: Write proper pytest tests for each component
- **Error handling**: Handle edge cases (port conflicts, service crashes during startup)
- **HMR**: File watching + per-service restart in dev mode
- **Admin dashboard**: Service health panel in the admin UI
- **WebSocket proxying**: Extend gateway to proxy WebSocket connections
- **Metrics**: Per-service metrics aggregation at the gateway
