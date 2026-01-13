# kubernetes-backend-deployment

## Work topics — Explanations and answers

### Volumes and persistence

- Role of a Volume in a Kubernetes deployment

A Kubernetes Volume provides a directory accessible to one or more containers in a Pod. Volumes decouple storage lifetime from the container process: data written to a volume can outlive a container restart and, when backed by persistent storage, can remain available across Pod rescheduling. Volumes enable stateful workloads (databases, queues) running inside Pods to persist data reliably instead of relying on ephemeral container filesystem storage.

- Meaning and implications of `storageClassName` in a `PersistentVolumeClaim`

`storageClassName` in a `PersistentVolumeClaim` (PVC) specifies which StorageClass the PVC should use to bind to a PersistentVolume (PV). A StorageClass encodes the provisioner and parameters used to create volumes (example: `hostPath` for local dev, CSI drivers for cloud disks, or host-local). The chosen StorageClass influences:

	- the type of backing storage (block vs file), performance characteristics, and replication options;
	- whether volumes are dynamically provisioned (created on demand) or must be pre-provisioned;
	- provider-specific features (encryption at rest, snapshot support, IOPS tiers).

Omitting `storageClassName` uses the cluster default StorageClass. For local clusters (kind, minikube, Docker Desktop) default classes differ from cloud providers; when you need particular capabilities (e.g., ReadWriteMany, SSD tier), explicitly set the StorageClass.

- What happens if the MySQL Pod is deleted or recreated?

If the MySQL Pod is deleted or recreated but uses a PVC that is bound to a PV with persistent backing, the data directory (mounted from the PVC) remains intact. When the Pod is rescheduled (new Pod created by its Deployment or StatefulSet), Kubernetes re-attaches the same PersistentVolumeClaim to the new Pod, preserving data. If the PVC is ephemeral (no persistent backing) or uses an inappropriate StorageClass, data may be lost.

Note: Pod-level resources (like container-local temp files) are lost on restart; persistent data must be placed on a mounted Volume backed by a PVC.

- How a `PersistentVolumeClaim` is bound to a physical volume

Binding happens through the Kubernetes control plane:

	1. A user creates a PVC requesting size and access modes. If a matching PV already exists and satisfies the claim, Kubernetes binds them.
	2. If no PV exists and the requested StorageClass supports dynamic provisioning, the provisioner (CSI driver or in-tree provisioner) creates a new PV according to StorageClass parameters and then binds it to the PVC.

The PV describes the actual backing (e.g., hostPath, iSCSI, AWS EBS, Azure Disk, local SSD) and the PV/PVC binding is recorded by the API server.

- How the cluster provisions or deletes the underlying storage

Provisioning and deletion are handled by the StorageClass provisioner (a CSI driver or legacy in-tree provisioner). For dynamic provisioning:

	- When a PVC requests storage, the provisioner creates a volume on the underlying storage system (local disk, network storage, cloud block/storage service) using the parameters in the StorageClass.
	- When the PVC is deleted (and the PV's `reclaimPolicy` is `Delete`), the provisioner will delete the underlying storage resource. If the `reclaimPolicy` is `Retain`, the PV remains and the admin must manually handle cleanup.

On local development clusters the provisioner may create hostPath or loopback-backed volumes; in production clusters the provisioner will call out to the cloud or storage system to create real block volumes.

### Ingress and health probes

- Purpose of an `Ingress` resource in Kubernetes

An `Ingress` defines rules that map external HTTP(S) requests to Services within the cluster. It lets you expose multiple Services under the same IP or hostname, configure path-based routing, TLS termination, and host-based routing. The Ingress itself is a resource that only describes the desired routing; an Ingress Controller implements those rules and performs the actual traffic handling.

- Difference between an `Ingress` and an Ingress Controller

`Ingress` is a Kubernetes API object that declares routing rules. An Ingress Controller is the runtime component (typically a deployment in the cluster) that watches `Ingress` objects and configures a proxy (nginx, Traefik, HAProxy, Envoy, etc.) to implement the routing rules. Without a running Ingress Controller, Ingress objects have no effect.

- What are liveness and readiness probes, and why are they important?

Liveness and readiness probes are container-level diagnostics that the kubelet uses to manage Pod lifecycle and traffic routing:

	- Liveness probe: detects when a container is unhealthy and should be restarted. Useful for recovering from deadlocks or unrecoverable errors inside the process.
	- Readiness probe: indicates whether a container is ready to receive traffic. Services and Ingress controllers use readiness to decide whether endpoints should receive requests.

Using probes avoids sending traffic to a pod that is still initializing or has entered an unhealthy state. They improve availability and enable graceful rolling updates.

- How the path/prefix configured in an Ingress relates to application routes

Ingress path rules map HTTP request paths to Services. If your Ingress exposes a path prefix (for example `/your_namespace`), you must ensure the backend service receives the expected path. Two common approaches:

	1. **Rewrite at the Ingress**: Configure the Ingress Controller to strip the prefix before forwarding (for example, nginx `rewrite-target`), so the backend sees `/clients` instead of `/your_namespace/clients`.
	2. **App-level prefix handling**: Configure the application to serve under the prefix (mount routes under `/your_namespace`) or make the app aware of a `ROOT_PATH` so no rewrite is necessary.

If neither is configured, requests may return 404s because the backend expects different paths.

- How to configure an application to respect a prefix path behind a proxy/Ingress

There are several techniques:

	- **Ingress rewrite rule:** Use the Ingress Controller's rewrite annotations (e.g., `nginx.ingress.kubernetes.io/rewrite-target`) to remove the prefix before forwarding.
	- **Reverse proxy headers:** Ensure the proxy preserves headers like `X-Forwarded-For` and `X-Forwarded-Proto` and the application understands them for URL generation and redirects.
	- **Application configuration:** Many frameworks support a `SCRIPT_NAME`, `ROOT_PATH`, or `APPLICATION_ROOT` configuration option to set the base path. Configure the app to use this value so it constructs correct routes and links.
	- **Base URL handling in code:** Prefix all route definitions with the namespace prefix, or mount the application under a subpath in the web framework.

Choose the approach that best fits your control over the app or the Ingress. For third-party or hard-to-change apps, using the Ingress rewrite is often easiest.

- How the Ingress controller determines whether a backend service is "healthy"

Ingress controllers typically rely on Kubernetes Endpoints and the readiness state of the Pods backing a Service. The controller queries the Service's endpoints and only forwards traffic to endpoints that are marked ready by the kubelet (i.e., their readinessProbe passed). Some Ingress implementations also support active health checks performed by the proxy itself; others pass traffic only to endpoints reported by the Kubernetes API.

Therefore, correct readiness probes are the primary mechanism to control traffic routing: if a Pod is not ready, the Service's endpoints will exclude it and the Ingress controller will not route requests to it.
