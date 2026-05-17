# Traefik DB Gateway Setup

This guide installs Traefik as a shared TCP gateway for database clusters.

The database cluster backend uses this flow:

1. Traefik runs in Kubernetes as the shared TCP gateway.
2. Spring deploys the database cluster.
3. Spring creates an `IngressRouteTCP` for the deployed database.
4. Traefik routes public database traffic to the internal Kubernetes service.

## 1. Check Current Context

Use the correct Kubernetes cluster before installing anything.

```bash
kubectl config current-context
kubectl get nodes -o wide
```

For the second cluster, use the correct kubeconfig if needed:

```bash
export KUBECONFIG=$HOME/.kube/config-cluster2
kubectl get nodes -o wide
```

On Windows PowerShell:

```powershell
$env:KUBECONFIG="C:\Users\M\.kube\config-cluster2"
kubectl get nodes -o wide
```

## 2. Remove Broken Traefik Installs

If a previous install failed or pods are pending, clean it first.

```bash
helm uninstall traefik -n traefik 2>/dev/null || true
helm uninstall traefik -n default 2>/dev/null || true
helm uninstall traefik-db-gateway -n traefik-db-gateway 2>/dev/null || true
```

Delete old namespaces only if they contain no resources you need:

```bash
kubectl delete namespace traefik --ignore-not-found
kubectl delete namespace traefik-db-gateway --ignore-not-found
```

Wait until the namespace is gone:

```bash
kubectl get namespace traefik-db-gateway
```

If it says `NotFound`, continue.

## 3. Add Traefik Helm Repo

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

## 4. Choose Install Mode

Traefik can run as either a `DaemonSet` or a `Deployment`.

### Recommended: DaemonSet

Use `DaemonSet` for the shared database gateway in this platform.

Why:

- One Traefik pod runs on every node.
- Every node can accept database traffic on the same public ports.
- Many database clusters can share the same gateway and same external port.
- This matches the current shared gateway design.

Example:

```text
node1 -> Traefik listens on 15432, 13306, 17017, 16379, 19042
node2 -> Traefik listens on 15432, 13306, 17017, 16379, 19042
node3 -> Traefik listens on 15432, 13306, 17017, 16379, 19042
```

Use this when:

- You do not use a cloud `LoadBalancer`.
- DNS may point to any gateway node.
- You want the same setup as the working first cluster.

Requirement:

- The DB gateway ports must be free on every node.

### Optional: Deployment

Use `Deployment` only when you want one fixed gateway pod.

Example:

```text
DNS -> node1 public IP
Traefik pod pinned to node1
```

Use this when:

- You want only one gateway pod.
- Your DNS always points to one specific node.
- You are testing or running a simpler setup.

Risk:

- If the gateway node has a problem, public database access breaks until DNS or scheduling is changed.
- With `hostNetwork=true`, you should pin the pod to the node that DNS points to.

## 5. Install Traefik DB Gateway as DaemonSet

Create the namespace:

```bash
kubectl create namespace traefik-db-gateway
```

Install Traefik as a DaemonSet:

```bash
helm upgrade --install traefik-db-gateway traefik/traefik \
  --namespace traefik-db-gateway \
  --set deployment.kind=DaemonSet \
  --set updateStrategy.rollingUpdate.maxUnavailable=1 \
  --set updateStrategy.rollingUpdate.maxSurge=0 \
  --set hostNetwork=true \
  --set deployment.dnsPolicy=ClusterFirstWithHostNet \
  --set ports.traefik.port=18080 \
  --set ports.metrics.port=19100 \
  --set ports.web.port=18000 \
  --set ports.websecure.port=18443 \
  --set ports.postgresql.port=15432 \
  --set ports.mysql.port=13306 \
  --set ports.mongodb.port=17017 \
  --set ports.redis.port=16379 \
  --set ports.cassandra.port=19042 \
  --set providers.kubernetesCRD.enabled=true \
  --set providers.kubernetesCRD.allowCrossNamespace=true \
  --set providers.kubernetesIngress.enabled=true
```

Why DaemonSet?

- A DaemonSet runs one Traefik pod on every node.
- Every node can listen on the same database ports.
- This works well when DNS may point to any gateway node IP.

Expected result:

```text
traefik-db-gateway-xxxxx   1/1   Running   node1
traefik-db-gateway-yyyyy   1/1   Running   node2
traefik-db-gateway-zzzzz   1/1   Running   node3
```

## 6. Install Traefik DB Gateway as Single-Node Deployment

Use this only if you want a single fixed gateway node.

First choose the node. Example:

```bash
kubectl get nodes -o wide
```

Assume DNS points to `node1`. Install Traefik pinned to `node1`:

```bash
kubectl create namespace traefik-db-gateway

helm upgrade --install traefik-db-gateway traefik/traefik \
  --namespace traefik-db-gateway \
  --set deployment.kind=Deployment \
  --set deployment.replicas=1 \
  --set updateStrategy.type=Recreate \
  --set hostNetwork=true \
  --set deployment.dnsPolicy=ClusterFirstWithHostNet \
  --set nodeSelector."kubernetes\\.io/hostname"=node1 \
  --set ports.traefik.port=18080 \
  --set ports.metrics.port=19100 \
  --set ports.web.port=18000 \
  --set ports.websecure.port=18443 \
  --set ports.postgresql.port=15432 \
  --set ports.mysql.port=13306 \
  --set ports.mongodb.port=17017 \
  --set ports.redis.port=16379 \
  --set ports.cassandra.port=19042 \
  --set providers.kubernetesCRD.enabled=true \
  --set providers.kubernetesCRD.allowCrossNamespace=true \
  --set providers.kubernetesIngress.enabled=true
```

Expected result:

```text
traefik-db-gateway-xxxxx   1/1   Running   node1
```

If the pod is `Pending`, check whether the selected node already uses one of the requested ports.

## 7. Verify Traefik

```bash
kubectl get pods -n traefik-db-gateway -o wide
kubectl get daemonset -n traefik-db-gateway
kubectl describe daemonset traefik-db-gateway -n traefik-db-gateway
```

Check Traefik command args:

```bash
kubectl describe pod -n traefik-db-gateway \
  $(kubectl get pod -n traefik-db-gateway -o jsonpath='{.items[0].metadata.name}')
```

You should see entrypoints like:

```text
--entryPoints.postgresql.address=:15432/tcp
--entryPoints.mysql.address=:13306/tcp
--entryPoints.mongodb.address=:17017/tcp
--entryPoints.redis.address=:16379/tcp
--entryPoints.cassandra.address=:19042/tcp
```

## 8. Verify Traefik CRDs

Spring creates `IngressRouteTCP`, so the CRD must exist.

```bash
kubectl get crd | grep ingressroutes
kubectl get crd | grep ingressroutetcps
```

Check current TCP routes:

```bash
kubectl get ingressroutetcp -A
```

Before deploying a database cluster, this may be empty. After deploying a database cluster, Spring should create a route.

## 9. Configure Spring Backend

Spring must point to the real Traefik gateway name and namespace.

Use:

```yaml
cluster:
  deployment:
    default-shared-gateway-enabled: true
    shared-gateway-traefik-namespace: traefik-db-gateway
    shared-gateway-traefik-name: traefik-db-gateway
```

If using environment variables:

```bash
export DB_CLUSTER_TRAEFIK_NAMESPACE=traefik-db-gateway
export DB_CLUSTER_TRAEFIK_NAME=traefik-db-gateway
```

On Windows PowerShell:

```powershell
$env:DB_CLUSTER_TRAEFIK_NAMESPACE="traefik-db-gateway"
$env:DB_CLUSTER_TRAEFIK_NAME="traefik-db-gateway"
```

Restart Spring after changing this.

## 10. Deploy Database Cluster

Deploy a database cluster from the UI.

After deployment, check:

```bash
kubectl get ingressroutetcp -A
```

For PostgreSQL, you should see a route similar to:

```text
NAMESPACE                               NAME              AGE
ns-user-example                         postgres-tcp      30s
```

Inspect it:

```bash
kubectl describe ingressroutetcp -n <namespace> <route-name>
```

The route should point to the internal database service, for example:

```text
EntryPoints:
  postgresql
Routes:
  Match: HostSNI(`postgres.seang.shop`)
  Services:
    Name: postgres-postgresql-pooler-rw
    Port: 5432
```

## 11. Open GCP Firewall Ports

The VM firewall must allow the public database ports.

Check existing firewall rules:

```bash
gcloud compute firewall-rules list \
  --format="table(name,network,direction,sourceRanges.list(),allowed[].map().firewall_rule().list())"
```

Create the rule if missing:

```bash
gcloud compute firewall-rules create db-external-port-ranges \
  --network default \
  --allow tcp:15432-15999,tcp:13306-13999,tcp:17017-17999,tcp:16379-16999,tcp:19042-19999 \
  --source-ranges 0.0.0.0/0
```

## 12. DNS Requirements

Your database hostname must point to a node external IP where Traefik is running.

Example:

```text
postgres.seang.shop -> 34.151.80.25
```

Check DNS:

```bash
nslookup postgres.seang.shop
```

Test TCP:

```bash
nc -vz postgres.seang.shop 15432
```

On Windows PowerShell:

```powershell
Test-NetConnection postgres.seang.shop -Port 15432
```

## 13. Common Errors

### Error: `Additional property dnsPolicy is not allowed`

Wrong:

```bash
--set dnsPolicy=ClusterFirstWithHostNet
```

Correct:

```bash
--set deployment.dnsPolicy=ClusterFirstWithHostNet
```

### Error: `maxUnavailable should be greater than 0 when using hostNetwork`

Add:

```bash
--set updateStrategy.rollingUpdate.maxUnavailable=1
```

### Error: `maxSurge may not be set when maxUnavailable is non-zero`

Add:

```bash
--set updateStrategy.rollingUpdate.maxSurge=0
```

### Pod Pending: `node(s) didn't have free ports`

Something else is already using one of the requested host ports.

Check on each node:

```bash
sudo ss -ltnp | egrep ':15432|:13306|:17017|:16379|:19042|:18080|:19100|:18000|:18443'
```

Free the conflicting process or change the Traefik port.

For `DaemonSet`, the port must be free on every node.

For `Deployment`, the port must be free only on the selected gateway node.

### `kubectl get ingressroutetcp -A` is empty

This means Spring has not created the TCP route yet.

Check:

1. Database cluster deploy finished.
2. Spring has correct Traefik namespace/name.
3. `default-shared-gateway-enabled` is true.
4. Traefik CRDs exist.
5. Backend logs do not show `IngressRouteTCP creation failed`.

## 14. Shared Gateway Routing Model

One shared Traefik gateway can serve many database clusters.

Example:

```text
postgres-a.seang.shop:15432 -> ns-a/postgres-a-postgresql-pooler-rw:5432
postgres-b.seang.shop:15432 -> ns-b/postgres-b-postgresql-pooler-rw:5432
postgres-c.seang.shop:15432 -> ns-c/postgres-c-postgresql-pooler-rw:5432
```

All PostgreSQL clusters can share port `15432` because Traefik routes by hostname using `HostSNI`.

Flow:

```text
Spring deploys database cluster
Spring creates IngressRouteTCP
Traefik reads IngressRouteTCP
Traefik routes hostname + port to the correct Kubernetes service
```

Important:

- Clients must connect using the database hostname, not only the raw IP.
- For PostgreSQL TLS/SNI routing, the hostname is how Traefik chooses the correct backend.

## 15. Expected Database Ports

| Engine | Traefik entrypoint | Public port | Backend service port |
| --- | --- | ---: | ---: |
| PostgreSQL | `postgresql` | `15432` | `5432` |
| MySQL | `mysql` | `13306` | `3306` |
| MongoDB | `mongodb` | `17017` | `27017` |
| Redis | `redis` | `16379` | `6379` |
| Cassandra | `cassandra` | `19042` | `9042` |

## 16. Quick Health Checklist

```bash
kubectl get pods -n traefik-db-gateway -o wide
kubectl get crd | grep ingressroute
kubectl get ingressroutetcp -A
kubectl get svc -A | grep -Ei 'postgres|mysql|mongo|redis|cassandra'
```

External check:

```bash
nc -vz <database-hostname> <database-port>
```

PowerShell:

```powershell
Test-NetConnection <database-hostname> -Port <database-port>
```
