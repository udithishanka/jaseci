# Day 10: Deployment Interface & CLI Tooling

## Learn (~1 hour)

### Why an Abstraction Layer?

When you run services locally, you manage subprocesses. In Kubernetes, you manage pods. The operations are the same — deploy, stop, restart, status, logs — but the implementation is completely different.

A **deployment interface** gives you one API that works everywhere:

```
jac scale status          # same command, local or K8s
jac scale stop orders     # kills subprocess locally, scales to 0 in K8s
jac scale restart cart    # restart subprocess locally, rolling restart in K8s
```

### The Strategy Pattern

This is the **Strategy Pattern** — define an interface, swap implementations:

```
ServiceDeployer (interface)
├── deploy_service(name)
├── stop_service(name)
├── restart_service(name)
├── scale_service(name, replicas)
├── status()
├── get_logs(name, lines)
├── destroy_all()
└── deploy_all()

LocalDeployer(ServiceDeployer)       # subprocess management
KubernetesDeployer(ServiceDeployer)  # K8s API (future)
```

### Local vs K8s — Same Interface, Different Behavior

| Operation | LocalDeployer | KubernetesDeployer |
|-----------|--------------|-------------------|
| `deploy_service` | `subprocess.Popen(["jac", "start", ...])` | `kubectl apply -f deployment.yaml` |
| `stop_service` | `proc.terminate()` | `kubectl scale --replicas=0` |
| `restart_service` | kill + start | `kubectl rollout restart` |
| `scale_service` | Only 1 replica | `kubectl scale --replicas=N` |
| `status` | Check PID + `/healthz` | `kubectl get pods` |
| `get_logs` | Read process output | `kubectl logs` |
| `destroy_all` | Kill all subprocesses | `kubectl delete deployment` |

---

## Do (~2-3 hours)

### What Was Built

1. **`deployer.jac`** — Abstract `ServiceDeployer` interface with all lifecycle methods
2. **`local_deployer.jac`** — `LocalDeployer` wrapping `ServiceProcessManager` with the deployer interface
3. **`plugin.jac`** — `jac scale` CLI command registered with status/stop/restart/logs/destroy actions
4. **Orchestrator updated** — uses `LocalDeployer` instead of raw `ServiceProcessManager`

### CLI Commands

```bash
# Show status of all microservices
jac scale status

# Stop a single service
jac scale stop orders

# Restart a service
jac scale restart cart

# View service logs
jac scale logs products

# Stop all services
jac scale destroy
```

### How to Extend for K8s (Future)

Create `KubernetesDeployer(ServiceDeployer)` that:
- Uses `KubernetesTarget` for deployment
- Manages K8s Deployments/Services via kubectl or Python kubernetes client
- Maps service names to K8s Deployment names
- Uses `kubectl logs` for log retrieval

The CLI commands stay the same — only the deployer implementation changes.

---

## Milestone

- [ ] `ServiceDeployer` abstract interface exists
- [ ] `LocalDeployer` wraps process manager with deployer API
- [ ] `jac scale status` shows all services with health
- [ ] `jac scale stop/restart/logs/destroy` work
- [ ] Orchestrator uses `LocalDeployer`
- [ ] 12 tests covering deploy, stop, restart, scale, status, logs, destroy

**You now understand**: the Strategy Pattern for deployment abstraction, how a single CLI interface can target multiple platforms, and how to extend the system for new deployment targets.
