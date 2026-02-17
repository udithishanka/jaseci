# Horizontal Scaling: Multi-Node HPA Support for jac-scale

## Problem Statement

PR [#4384](https://github.com/jaseci-labs/jaseci/pull/4384) adds Horizontal Pod Autoscaling (HPA) support to jac-scale, enabling automatic scaling of Jaseci application pods based on CPU utilization. However, **HPA breaks on multi-node Kubernetes clusters**.

When HPA scales beyond 1 replica, new pods scheduled on different nodes hit a `Multi-Attach error` because all application pods share the same `ReadWriteOnce` (RWO) PersistentVolumeClaim (PVC) for application code. RWO volumes can only be mounted by pods on a **single node** at a time.

### Live Test Evidence (AWS EKS, 8-node cluster)

**Configuration:**

```toml
[plugins.scale.kubernetes]
min_replicas = 2
max_replicas = 4
cpu_utilization_target = 50
```

**Result:**

```
$ kubectl get pods -n algo-test2 -o wide
NAME                                READY   STATUS     NODE
algo-test2-7cf8b89f88-hjt5g         1/1     Running    ip-192-168-20-98     # PVC attached here
algo-test2-7cf8b89f88-9q29l         0/1     Init:0/3   ip-192-168-102-222   # STUCK

$ kubectl describe pod algo-test2-7cf8b89f88-9q29l
Events:
  Warning  FailedAttachVolume  attachdetach-controller
  Multi-Attach error for volume "pvc-962831ba-..."
  Volume is already used by pod(s) algo-test2-7cf8b89f88-hjt5g
```

HPA requested 2 replicas. Pod 1 runs fine on node `ip-192-168-20-98`. Pod 2 was scheduled on a different node (`ip-192-168-102-222`) and is permanently stuck because the RWO volume can only attach to one node at a time.

This works on single-node dev clusters (minikube/kind) because all pods are on the same node — which is why it wasn't caught during initial testing.

---

## Root Cause Analysis

### Current Architecture (PR #4384)

```
User Machine ──(kubectl cp)──> Sync Pod ──> RWO PVC ({app_name}-code-pvc)
                                                 │
                                    ┌────────────┴────────────┐
                                    │                         │
                              App Pod 1                 App Pod 2
                              (Node A)                  (Node B)
                              ✓ Mounts PVC              ✗ Multi-Attach Error
```

**Code distribution flow:**

1. `sync_code_to_pvc()` creates a temporary sync pod that mounts the PVC
2. User's code is tarball'd and `kubectl cp`'d to the sync pod
3. Code is extracted to PVC at `/data/workspace/`
4. Sync pod is deleted
5. Each app pod has an init container (`build-app`) that mounts the PVC and uses `rsync` to copy code from PVC (`/code/workspace/`) to an emptyDir (`/app/`)
6. The main container runs from the emptyDir at `/app/`

**Critical detail:** The main application container only mounts the **emptyDir** (`/app`), NOT the PVC. The PVC is exclusively a code delivery mechanism used during the init container phase. The running app never reads from or writes to the PVC.

**The problem:** Step 5 requires every app pod's init container to mount the PVC. With RWO access mode, this only works if all pods are on the same node. On multi-node clusters, pods on different nodes cannot mount the volume.

### Kubernetes Volume Access Modes

| Access Mode | Abbreviation | Behavior |
|-------------|-------------|----------|
| ReadWriteOnce | RWO | Volume can be mounted as read-write by pods on a **single node** |
| ReadOnlyMany | ROX | Volume can be mounted as read-only by pods on **many nodes** |
| ReadWriteMany | RWX | Volume can be mounted as read-write by pods on **many nodes** |

Default storage classes on all major platforms use RWO:

- **AWS EKS**: `gp2`, `gp3` (EBS) → RWO
- **GCP GKE**: `standard`, `standard-rwo` (Persistent Disk) → RWO
- **Azure AKS**: `default`, `managed-premium` (Managed Disk) → RWO
- **Local (minikube/kind/k3s)**: `hostpath`, `local-path` → RWO

RWX is never available by default on any cluster. It always requires additional setup (NFS provisioner, EFS CSI driver, Azure Files, etc.).

---

## Approaches Considered

### 1. User-Configured RWX Storage Class

**Approach:** Add `pvc_access_mode` and `storage_class` fields to `KubernetesConfig`. User sets `pvc_access_mode = "ReadWriteMany"` with their cloud's RWX storage class.

```toml
[plugins.scale.kubernetes]
pvc_access_mode = "ReadWriteMany"
storage_class = "efs-sc"  # AWS: efs-sc, GCP: standard-rwx, Azure: azurefile, Local: nfs
```

| Pros | Cons |
|------|------|
| Simple implementation | Requires user to know their cloud's storage class |
| True multi-node scaling | Not cloud-agnostic (different storage class per provider) |
| PVC stays on app pods | RWX storage class never available by default |
| | Doesn't work on local clusters without NFS provisioner setup |

**Rejected:** Violates the requirement of zero user configuration and universal compatibility.

### 2. RWO PVC + nodeAffinity

**Approach:** Keep RWO PVC. When `max_replicas > 1`, detect which node the PVC is bound to and pin all app pods to that node via `nodeAffinity`.

| Pros | Cons |
|------|------|
| Zero user configuration | All pods pinned to one node |
| Works on any cluster | Defeats the purpose of multi-node scaling |
| Simple implementation | One node becomes a bottleneck |
| | Single point of failure for all replicas |

**Rejected:** Does not achieve multi-node scaling. All pods on one node limits both capacity and fault tolerance.

### 3. Bake Code into Docker Image

**Approach:** Use `jac build` to create a Docker image with code baked in. Push to a registry. Each pod pulls the same image.

| Pros | Cons |
|------|------|
| Most production-ready | Requires container registry (DockerHub, ECR, etc.) |
| Pods truly independent | Slower redeploy cycle (build + push + pull) |
| Immutable deployments | Extra user configuration for registry credentials |

**Rejected:** Requires container registry setup — not zero configuration. (Note: This already works in jac-scale via the `build=True` path for users who want it.)

### 4. ConfigMap for Code

**Approach:** Pack application code into a Kubernetes ConfigMap. Mount it in app pods.

| Pros | Cons |
|------|------|
| Works on any cluster | 1MB etcd limit per ConfigMap |
| Zero configuration | Won't work for larger applications |
| No shared storage needed | Binary files are problematic |

**Rejected:** 1MB limit makes this impractical for real-world applications.

### 5. Auto-Deployed NFS Server

**Approach:** jac-scale deploys a small NFS server pod that mounts the RWO PVC and re-exports it via NFS. Create an NFS-backed PV/PVC with RWX access.

| Pros | Cons |
|------|------|
| Works on any cluster | Requires privileged containers (security concern) |
| Zero user configuration | External NFS server image dependency |
| PVC stays on app pods | NFS performance overhead |
| | More complex failure modes |
| | NFS server pod is a SPOF |

**Rejected:** Privileged container requirement is a security concern. External image dependency adds fragility.

### 6. Code-Server Pattern (Chosen)

**Approach:** Deploy a lightweight HTTP server pod that is the **only** pod mounting the PVC. App pods fetch code via HTTP during init.

| Pros | Cons |
|------|------|
| Works on ANY cluster | Extra deployment (code-server pod + service) |
| Zero user configuration | Code-server is SPOF for new pod creation |
| True multi-node scaling | Init container adds ~2-5s retry if timing issue |
| No privileged containers | |
| Minimal resource footprint | |
| Uses existing busybox image | |

**Chosen:** Best balance of universality, simplicity, and zero configuration.

---

## Chosen Solution: Code-Server Pattern

### Architecture

```
User Machine ──(kubectl cp)──> Sync Pod ──> RWO PVC ({app_name}-code-pvc)
                                                 │
                                          Code-Server Pod (1 replica)
                                          mounts PVC, serves code via HTTP
                                          busybox httpd on port 8080
                                                 │
                                          ClusterIP Service
                                          {app_name}-code-server:8080
                                                 │
                                    ┌────────────┼────────────┐
                                    │            │            │
                              App Pod 1    App Pod 2    App Pod N
                              (Node A)     (Node B)     (Node C)
                              init: wget   init: wget   init: wget
                              → emptyDir   → emptyDir   → emptyDir
```

### How It Works

1. **Code sync** (unchanged): `sync_code_to_pvc()` uploads user's code to the RWO PVC via a temporary sync pod.

2. **Code-server deployment** (new): A single-replica Deployment running `busybox httpd` that:
   - Mounts the RWO PVC (it's the only pod that does)
   - On startup, creates a tarball of the code (`tar czf /tmp/code.tar.gz --exclude='.jac' .`)
   - Serves the tarball via HTTP on port 8080

3. **Code-server service** (new): A ClusterIP Service (`{app_name}-code-server:8080`) for in-cluster discovery.

4. **App pod init container** (modified): Instead of mounting the PVC and using `rsync`, the init container:
   - Uses `wget` to download `http://{app_name}-code-server:8080/code.tar.gz`
   - Extracts the tarball to the emptyDir at `/app/`
   - Includes a retry loop (`until wget ... ; do sleep 2; done`) for resilience

5. **App pod volumes** (modified): Only contains `emptyDir` — NO PVC mount. App pods are free to schedule on any node.

6. **Main container** (unchanged): Still runs from emptyDir at `/app/`. Behavior is identical to current implementation.

### Lifecycle

| Event | Behavior |
|-------|----------|
| First deploy | PVC created → code synced → code-server deployed → app pods fetch code |
| Re-deploy | Code re-synced to PVC → code-server restarted (fresh tarball) → app pods fetch new code |
| HPA scale-up | New pod starts → init container downloads from code-server → pod ready |
| Code-server crash | K8s auto-restarts (Deployment). New pod re-tars code from PVC. |
| App pod restart | Init container re-downloads code from code-server |
| Destroy | Code-server deployment + service deleted, PVC deleted, app deployment deleted |

### Resource Footprint

The code-server pod is minimal:

- **Image**: `busybox:1.36` (already used by jac-scale)
- **CPU**: 50m request / 100m limit
- **Memory**: 32Mi request / 64Mi limit
- **Storage**: Uses existing PVC (no additional storage)

---

## Impact on Related PRs

| PR | Description | Impact |
|----|-------------|--------|
| #4384 | HPA support | This is the fix for #4384's multi-node limitation |
| #4546 | Zero-downtime rolling deployment | Compatible — rolling updates work since app pods don't mount PVC |
| #4571 | Code-sync node-pin fix | No longer needed — app pods don't mount PVC, so node pinning is unnecessary |

## Behavior Matrix

| Scenario | Before (PR #4384) | After (Code-Server) |
|----------|-------------------|---------------------|
| Single replica | Works | Works |
| HPA multi-replica, same node | Works | Works |
| HPA multi-replica, different nodes | **Multi-Attach crash** | Works |
| Re-deploy (code update) | Works | Works |
| `build=True` (Docker image) | Works | Works (code-server not used) |
| Node failure (PVC node) | Pod lost | Code-server lost, existing app pods unaffected |
| Pod restart | Init re-copies from PVC | Init re-downloads from code-server |

---

## Implementation Details

### Files Modified

Only **one file** needs modification:

**`jac-scale/jac_scale/targets/kubernetes/kubernetes_target.jac`**

1. Add `_deploy_code_server()` method — creates the code-server Deployment + Service
2. Modify `_build_volumes_config()` — replace PVC-based init container with HTTP-based one
3. Update `deploy()` — pass `apps_v1` to `_build_volumes_config()`
4. Update `destroy()` — clean up code-server Deployment + Service
5. Update `_wait_for_deletion()` — check code-server resources

### No Configuration Changes

Zero changes to:

- `KubernetesConfig` (no new fields)
- `jac.toml` (no new options)
- `config_loader.impl.jac` (no new defaults)

The solution is fully automatic and transparent to users.

---

## Testing Strategy

1. **Unit tests**: Run existing `pytest jac-scale` to verify no regressions
2. **Local cluster test**: Deploy on minikube/kind with `min_replicas=2`, verify both pods start
3. **Multi-node test**: Deploy on a multi-node cluster (EKS/GKE/k3s multi-node), verify HPA creates pods on different nodes
4. **Re-deploy test**: Update code and re-deploy, verify code-server serves fresh code
5. **Destroy test**: Run destroy, verify all resources (including code-server) are cleaned up

### Expected kubectl output (multi-node)

```
$ kubectl get pods -n <namespace> -o wide
NAME                                     READY   STATUS    NODE
myapp-code-server-abc123-xyz             1/1     Running   node-1    # PVC here
myapp-7cf8b89f88-hjt5g                   1/1     Running   node-1    # App replica
myapp-7cf8b89f88-9q29l                   1/1     Running   node-2    # App replica (different node!)
myapp-7cf8b89f88-kl2mn                   1/1     Running   node-3    # App replica (different node!)
```
