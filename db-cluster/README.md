# db-cluster v4 — Operator-based Multi-Database HA Cluster

An umbrella Helm chart that deploys production-grade database clusters on Kubernetes using dedicated operators for each database type. Each operator provides built-in HA, failover, backup, and monitoring — no manual StatefulSet management needed.

---

## Architecture Overview

```
Kubernetes Cluster (3 nodes × 2CPU / 8GB / 50GB)
│
├── Ingress Controller          → handles web app / UI ingress
├── cert-manager               → issues and renews TLS certificates
├── CloudNativePG Operator     → manages PostgreSQL cluster
├── Percona Operator (PSMDB)   → manages MongoDB cluster
├── Percona Operator (PXC)     → manages MySQL cluster
├── OpsTree Redis Operator     → manages Redis cluster
└── K8ssandra Operator         → manages Cassandra cluster
         │
         └── db-cluster (this Helm chart)
                  │
                 ├── postgresql/  → kind: Cluster (cnpg)
                  ├── mongodb/     → kind: PerconaServerMongoDB
                  ├── mysql/       → kind: PerconaXtraDBCluster
                  ├── redis/       → kind: RedisCluster
                  └── cassandra/   → kind: K8ssandraCluster
```

---

## Databases

Traffic model in this repo:
- Web-facing HTTP/HTTPS: `Ingress Controller + cert-manager`
- App-to-database traffic: `Kubernetes Service + TLS on the database`
- Database services stay internal by default in the example profile
- If you later expose a database to the internet, use its native database port and TLS rather than standard HTTP Ingress

Cloudflare automation flow:

```text
values.yaml / values override
   |
   | zoneName + externalIP + publicHostnames
   v
Cloudflare DNS Job
   |
   | reads token from Kubernetes Secret
   v
Cloudflare API
   |
   v
DNS-only A records for DB hostnames
```

Recommended token handling:

```bash
export CLOUDFLARE_API_TOKEN=YOUR_CLOUDFLARE_API_TOKEN
./setup.sh cloudflare_secret
```

Then enable the feature in values:

```yaml
cloudflare:
  enabled: true
  zoneName: seang.shop
  externalIP: 35.194.146.154
  proxied: false
  apiTokenExistingSecret: cloudflare-api-token
```

### PostgreSQL — CloudNativePG
- **Operator:** CloudNativePG (CNPG)
- **Custom resource:** `kind: Cluster` (`postgresql.cnpg.io/v1`)
- **HA mechanism:** Built into operator — automatic primary election, WAL streaming replication
- **Failover:** Automatic in ~15 seconds — operator promotes a replica
- **Backup:** barmanObjectStore → S3 / GCS (configure in values.yaml)
- **Monitoring:** Native PodMonitor support for Prometheus
- **Extra features:** Separate WAL storage, PostgreSQL parameter tuning, switchover/failover delay control
- **TLS in this chart:** CNPG operator-managed TLS by default; optional custom secret wiring if you explicitly switch modes

### MongoDB — Percona Operator for MongoDB (PSMDB)
- **Operator:** Percona Server for MongoDB Operator
- **Custom resource:** `kind: PerconaServerMongoDB` (`psmdb.percona.com/v1`)
- **HA mechanism:** MongoDB Replica Set — automatic election using Raft consensus
- **Failover:** Automatic in ~10 seconds — replica set votes and elects new primary
- **Backup:** Percona Backup for MongoDB (PBM) → S3 (configure in values.yaml)
- **Replication:** oplog streaming from primary to secondaries
- **TLS in this chart:** Optional cert-manager-managed `ssl` and `sslInternal` secrets

### MySQL — Percona Operator for MySQL (PXC)
- **Operator:** Percona XtraDB Cluster Operator
- **Custom resource:** `kind: PerconaXtraDBCluster` (`pxc.percona.com/v1`)
- **HA mechanism:** Galera multi-primary replication — all nodes can write
- **Failover:** Automatic — HAProxy routes traffic away from failed node
- **Backup:** Built-in scheduled backup to S3 (configure in values.yaml)
- **Extra features:** HAProxy load balancer included, synchronous replication
- **TLS in this chart:** Optional cert-manager-managed `ssl` and `ssl-internal` secrets

### Redis — OpsTree Redis Operator
- **Operator:** OpsTree Redis Operator
- **Custom resource:** `kind: RedisCluster` (`redis.redis.opstreelabs.in/v1beta2`)
- **HA mechanism:** Redis Cluster mode — data sharded across leader nodes
- **Failover:** Automatic — followers promoted to leader on failure
- **Default topology in this chart:** `cluster.instances: 3` creates 3 leader pods and 3 follower pods
- **Monitoring:** Optional Redis Exporter sidecar for Prometheus
- **TLS in this chart:** Optional cert-manager-managed TLS secret wired into the operator `TLS` block

### Cassandra — K8ssandra Operator
- **Operator:** K8ssandra Operator
- **Custom resource:** `kind: K8ssandraCluster` (`k8ssandra.io/v1alpha1`)
- **HA mechanism:** Cassandra ring — no single leader, all nodes are peers
- **Failover:** No failover needed — ring continues without the failed node
- **Backup:** Medusa backup → S3 (configure in values.yaml)
- **Extra features:** Multi-datacenter support, Reaper for repairs
- **Bootstrap note:** Cassandra pods can stay `Running` but not `Ready` (`1/2`) for several minutes while the ring forms and auth/system tables initialize
- **TLS in this chart:** Client and internode encryption via K8ssandra encryption-store secrets

---

## Prerequisites

### 1. Kubernetes cluster
Your cluster must be running. Set up by kubespray:
```bash
kubectl get nodes   # verify all nodes are Ready
```

### 2. Longhorn (storage — required before this chart)
```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --version 1.11.1

kubectl rollout status deployment/longhorn-driver-deployer -n longhorn-system
```

> Longhorn must be installed separately because it requires its own namespace. Everything else — operators and databases — installs automatically with this chart.

---

## Installation

Operators can be installed automatically by the umbrella chart, but in this repo the supported workflow is:

```bash
./setup.sh install_operators
./setup.sh deploy
```

If operators are already installed and healthy, `./setup.sh deploy` is usually enough.

### 1. Clone the chart
```bash
git clone https://github.com/seang454/db-cluster
cd db-cluster
```

### 2. Add Helm repos
```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo add k8ssandra https://helm.k8ssandra.io/stable
helm repo update
```

### 3. Edit values.yaml — enable databases and set passwords
```yaml
postgresql:
  enabled: true    # installs CloudNativePG operator + PostgreSQL cluster
  credentials:
    superuserPassword: "YourSecurePassword!"
    appUserPassword: "YourSecurePassword!"

mongodb:
  enabled: true    # installs Percona PSMDB operator + MongoDB cluster
  credentials:
    clusterAdminPassword: "YourSecurePassword!"
    userAdminPassword: "YourSecurePassword!"
    replicationKey: "YourSecureKey!"

mysql:
  enabled: false   # flip to true to install PXC operator + MySQL

redis:
  enabled: false   # flip to true to install Redis operator + Redis

cassandra:
  enabled: false   # flip to true to install K8ssandra operator + Cassandra
```

Important:
- Setting `enabled: false` for a database that is already deployed and then rerunning `deploy` or `upgrade` will usually remove that database's Kubernetes objects from the cluster.
- Treat `enabled: false` as an uninstall signal for that component, not a harmless toggle.

### 4. Download dependencies and deploy
```bash
helm dependency update ./db-cluster/

helm install my-db ./db-cluster/ \
  --namespace databases \
  --create-namespace \
  --timeout 10m
```

`--timeout 10m` gives operators enough time to start before databases are created.

### 5. Verify everything is running
```bash
# Watch all pods come up
kubectl get pods -n databases -w

# Check operators
kubectl get deployment -n databases

# Check database clusters
kubectl get cluster -n databases           # PostgreSQL
kubectl get psmdb -n databases             # MongoDB
kubectl get pxc -n databases               # MySQL
kubectl get rediscluster -n databases      # Redis
kubectl get k8ssandracluster -n databases  # Cassandra
```

Readiness notes:
- A pod like `k8ssandra-operator-crd-upgrader-job-...` showing `0/1 Completed` is healthy. It is a Job and `Completed` is its success state.
- Cassandra pods may show `1/2 Running` during bootstrap. That means the sidecar is ready but the Cassandra process is still joining the ring.
- Cassandra pods are spread across different nodes when possible; this chart uses anti-affinity to avoid placing all Cassandra pods on one host.

### What happens step by step

```
helm install my-db ./db-cluster/ --timeout 10m
       │
       ├── Step 1: Installs operator Helm charts as dependencies
       │           cloudnative-pg, psmdb-operator, pxc-operator,
       │           redis-operator, k8ssandra-operator
       │           → each becomes a Deployment in the databases namespace
       │
       ├── Step 2: Wait Jobs run (Helm hook, weight -5)
       │           each Job polls kubectl rollout status
       │           until the operator Deployment is fully Ready
       │           → timeout after 300s per operator
       │
       └── Step 3: Database CRDs apply
                   kind: Cluster           → CNPG creates PostgreSQL StatefulSet
                   kind: PerconaServerMongoDB → Percona creates MongoDB StatefulSet
                   kind: PerconaXtraDBCluster → Percona creates MySQL StatefulSet
                   kind: RedisCluster      → OpsTree creates Redis StatefulSet
                   kind: K8ssandraCluster  → K8ssandra creates Cassandra StatefulSet
```

## Upgrade

```bash
# Update values.yaml, then:
helm upgrade my-db ./db-cluster/ \
  --namespace databases
```

---

## Scaling

Each database scales by changing `instances` in values.yaml and running helm upgrade. You must add a new node to the Kubernetes cluster first — podAntiAffinity prevents two pods of the same database landing on the same machine.

```yaml
# Example — scale PostgreSQL from 3 to 4
postgresql:
  cluster:
    instances: 4   # requires 4th node ready
```

```bash
helm upgrade my-db ./db-cluster/ --namespace databases
```

---

## Backup

### Enable backup per database
Set `backup.enabled: true` in values.yaml and provide S3/GCS credentials:

```yaml
postgresql:
  backup:
    enabled: true
    destinationPath: "s3://my-bucket/postgresql"
    credentialSecret: "gcs-credentials"
    retentionPolicy: "7d"

mongodb:
  backup:
    enabled: true
    s3:
      bucket: my-bucket
      region: ap-southeast-1
      credentialSecret: "aws-s3-secret"
```

### Longhorn snapshots (easiest — covers all databases)
```
Longhorn UI → Recurring Jobs → Add
Name:     daily-backup
Task:     snapshot
Cron:     0 2 * * *
Retain:   7
```

---

## Failover

All databases handle failover automatically. No action needed. Approximate failover times:

| Database | Failover time | Mechanism |
|---|---|---|
| PostgreSQL | ~15 seconds | CNPG operator promotes replica |
| MongoDB | ~10 seconds | Replica set election |
| MySQL | ~5 seconds | HAProxy reroutes, Galera re-syncs |
| Redis | Automatic | Cluster promotes follower to leader |
| Cassandra | None needed | Ring continues, node rejoins later |

Your application needs retry logic to handle the brief failover window. Most database drivers support this natively via connection pool settings.

---

## Resource usage (3 nodes × 2CPU / 8GB)

| Database | CPU request | RAM request | Storage |
|---|---|---|---|
| PostgreSQL ×3 | 1.5 cores | 1.5Gi | 30Gi + 6Gi WAL |
| MongoDB ×3 | 1.5 cores | 3Gi | 30Gi |
| Redis ×3 leaders + ×3 followers | 0.6 cores | 0.8Gi | 30Gi |
| MySQL ×3 | 1.5 cores | 1.5Gi | 30Gi |
| Cassandra ×3 | about 1.35 cores steady-state, higher during bootstrap | about 4.8Gi | 30Gi |

**Recommended enabled combination on 3 small nodes:**
- PostgreSQL + MongoDB + Redis (fits comfortably)
- PostgreSQL + MongoDB + Redis + Cassandra is usually too much for 3 small workers unless Cassandra requests are reduced
- Do NOT enable all 5 at once — insufficient RAM

---

## Connecting to databases

### PostgreSQL
```bash
# Get primary service
kubectl get svc -n databases | grep postgresql

# Connect
kubectl exec -it -n databases \
  $(kubectl get pod -n databases -l cnpg.io/cluster=my-db-postgresql,role=primary -o name) \
  -- psql -U postgres appdb
```

### MongoDB
```bash
kubectl exec -it -n databases \
  my-db-mongodb-rs0-0 \
  -- mongo -u clusterAdmin -p SecureMongoPassword123!
```

### MySQL
```bash
kubectl exec -it -n databases \
  my-db-mysql-pxc-0 \
  -- mysql -u root -p
```

### Redis
```bash
kubectl exec -it -n databases \
  my-db-redis-leader-0 \
  -- redis-cli -a SecureRedisPassword123!
```

### Cassandra
```bash
kubectl exec -it -n databases \
  my-db-cassandra-dc1-default-sts-0 \
  -- cqlsh -u cassandra
```

---

## Uninstall

```bash
# Remove the chart
helm uninstall my-db -n databases

# PersistentVolumeClaims are NOT deleted automatically — data is safe
# To delete data (IRREVERSIBLE):
kubectl delete pvc -n databases --all
```

---

## Troubleshooting

```bash
# Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager
kubectl logs -n databases deployment/psmdb-operator
kubectl logs -n databases deployment/pxc-operator
kubectl logs -n databases deployment/redis-operator

# Check cluster events
kubectl describe cluster my-db-postgresql -n databases
kubectl describe psmdb my-db-mongodb -n databases
kubectl describe pxc my-db-mysql -n databases
kubectl describe rediscluster my-db-redis -n databases
kubectl describe k8ssandracluster my-db-cassandra -n databases

# Check pod logs
kubectl logs -n databases my-db-postgresql-1 -c postgres
kubectl logs -n databases my-db-mongodb-rs0-0 -c mongod
```

---

## Version reference

| Component | Version |
|---|---|
| CloudNativePG operator | 1.22.0 |
| PostgreSQL | 16 |
| Percona PSMDB operator | 1.15.0 |
| MongoDB | 7.0 |
| Percona PXC operator | 1.14.0 |
| MySQL | 8.0 (XtraDB) |
| OpsTree Redis operator | latest |
| Redis | 7.2 |
| K8ssandra operator | latest |
| Cassandra | 4.1.3 |
| Longhorn | 1.11.1 |

---

## Maintainer

**seang454** — [github.com/seang454/db-cluster](https://github.com/seang454/db-cluster)

---

## HashiCorp Vault — Secret Management

All database passwords are stored in Vault. No plaintext secrets exist in Kubernetes etcd.

### How it works

```
values.yaml (first deploy only)
    │
    ▼
vault setup-job (runs once)
    │  pushes secrets into
    ▼
HashiCorp Vault (encrypted store)
    │
    ▼
Vault agent sidecar (injected into every DB pod)
    │  injects secrets at runtime as
    ▼
/vault/secrets/<db-name> (file inside pod)
```

### Step 1 — Install Vault HA (with Transit auto-unseal)

This project uses **Transit unseal** — no cloud KMS, no GCP service account needed.
The `vault-transit` subchart deploys automatically as part of this Helm chart.

```bash
# Add Vault Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install main Vault HA (injector disabled — ESO handles secrets, not Vault agent)
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "injector.enabled=false" \
  --set "server.extraEnvironmentVars.VAULT_TRANSIT_TOKEN=placeholder"

# Wait for Vault pods to start
kubectl get pods -n vault -w
```

> The transit Vault (`vault-transit` subchart) deploys automatically when you run
> `helm install my-db ./db-cluster/`. It initializes itself, creates the transit key,
> and stores the unseal token in a K8s Secret that main Vault reads on startup.

### Step 2 — Initialize and unseal transit Vault (once only)

The `vault-transit` setup-job handles this automatically. Verify it completed:

```bash
# Check setup-job completed
kubectl get jobs -n vault-transit

# Check transit Vault is running and unsealed
kubectl exec -it vault-transit-0 -n vault-transit -- vault status

# View the stored init data (keep these safe)
kubectl get secret vault-transit-init -n vault-transit -o yaml
```

If the setup-job failed, you can run it manually:

```bash
# Manual init (only if setup-job failed)
kubectl exec -it vault-transit-0 -n vault-transit -- \
  vault operator init -key-shares=1 -key-threshold=1

# Manual unseal
kubectl exec -it vault-transit-0 -n vault-transit -- \
  vault operator unseal <unseal-key>
```

### Step 3 — Initialize main Vault HA

```bash
# Initialize main Vault (only once ever)
kubectl exec -it vault-0 -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3

# SAVE ALL OUTPUT — 5 unseal keys + 1 root token
# Store in a password manager, NOT in git

# With transit unseal, main Vault unseals itself automatically after this
# Verify all 3 pods are unsealed
kubectl exec -it vault-0 -n vault -- vault status
kubectl exec -it vault-1 -n vault -- vault status
kubectl exec -it vault-2 -n vault -- vault status
# sealed: false = good
```

### Step 4 — Store root token as K8s Secret

```bash
kubectl create secret generic my-db-vault-root-token \
  --from-literal=token=<your-root-token> \
  --namespace databases
```

### Step 1 — Install Vault

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "injector.enabled=true"

# Wait for pods
kubectl get pods -n vault -w
```

### Step 2 — Initialize Vault (once only)

```bash
kubectl exec -it vault-0 -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3

# SAVE ALL OUTPUT — you need unseal keys + root token
# Store them somewhere safe (password manager, not in git)
```

### Step 3 — Unseal Vault (after every restart)

```bash
# Each vault pod needs 3 of 5 keys
kubectl exec -it vault-0 -n vault -- vault operator unseal <key-1>
kubectl exec -it vault-0 -n vault -- vault operator unseal <key-2>
kubectl exec -it vault-0 -n vault -- vault operator unseal <key-3>

kubectl exec -it vault-1 -n vault -- vault operator unseal <key-1>
kubectl exec -it vault-1 -n vault -- vault operator unseal <key-2>
kubectl exec -it vault-1 -n vault -- vault operator unseal <key-3>

kubectl exec -it vault-2 -n vault -- vault operator unseal <key-1>
kubectl exec -it vault-2 -n vault -- vault operator unseal <key-2>
kubectl exec -it vault-2 -n vault -- vault operator unseal <key-3>
```

### Step 4 — Store root token as Kubernetes Secret

The setup-job needs the root token to configure Vault:

```bash
kubectl create secret generic my-db-vault-root-token \
  --from-literal=token=<your-root-token> \
  --namespace databases
```

### Step 5 — Deploy with passwords via --set (never in values.yaml)

**FIX 3** — Never put real passwords in `values.yaml`. Instead pass them from environment variables at deploy time:

```bash
# Set passwords as environment variables first
export PG_PASS="YourRealSecurePostgresPassword!"
export MONGO_PASS="YourRealSecureMongoPassword!"
export MONGO_REPL="YourRealSecureReplicationKey!"
export MYSQL_PASS="YourRealSecureMysqlPassword!"
export REDIS_PASS="YourRealSecureRedisPassword!"
export CASS_PASS="YourRealSecureCassandraPassword!"

# Deploy — passwords passed via --set, never written to any file
helm dependency update ./db-cluster/
helm install my-db ./db-cluster/ -n databases --create-namespace \
  --set "vault.postgresql.superuserPassword=$PG_PASS" \
  --set "vault.postgresql.appPassword=$PG_PASS" \
  --set "vault.mongodb.clusterAdminPassword=$MONGO_PASS" \
  --set "vault.mongodb.userAdminPassword=$MONGO_PASS" \
  --set "vault.mongodb.replicationKey=$MONGO_REPL" \
  --set "vault.mysql.rootPassword=$MYSQL_PASS" \
  --set "vault.mysql.appPassword=$MYSQL_PASS" \
  --set "vault.mysql.replicationPassword=$MYSQL_PASS" \
  --set "vault.mysql.monitorPassword=$MYSQL_PASS" \
  --set "vault.mysql.clusterCheckPassword=$MYSQL_PASS" \
  --set "vault.redis.password=$REDIS_PASS" \
  --set "vault.cassandra.password=$CASS_PASS"
```

In CI/CD (GitHub Actions, GitLab CI), store passwords as **repository secrets** and reference them as `${{ secrets.PG_PASS }}`.

```

The `vault-setup` job runs automatically and pushes all secrets into Vault.

### Step 6 — Remove passwords from values.yaml

After the setup-job completes successfully, remove all passwords from `values.yaml` — they now live only in Vault:

```yaml
vault:
  secrets:
    postgresql:
      superuserPassword: ""   # managed in Vault now
      appPassword: ""
    # etc...
```

### Verify Vault injection is working

```bash
# Check vault agent sidecar is running alongside DB pod
kubectl describe pod my-db-postgresql-1 -n databases | grep vault

# Read injected secret file inside pod
kubectl exec -it my-db-postgresql-1 -n databases \
  -- cat /vault/secrets/postgresql

# Check vault agent logs
kubectl logs my-db-postgresql-1 -c vault-agent -n databases
```

### Rotate a secret

```bash
# Login to Vault
kubectl exec -it vault-0 -n vault -- vault login <root-token>

# Update the secret
kubectl exec -it vault-0 -n vault -- vault kv put databases/postgresql \
  superuser-password="NewSecurePassword!" \
  app-password="NewSecurePassword!"

# Vault agent picks up new value on next lease renewal (within 24h)
# To force immediate rotation, restart the DB pods:
kubectl rollout restart statefulset -n databases
```

### Check all secrets stored in Vault

```bash
# List all secret paths
kubectl exec -it vault-0 -n vault -- vault kv list databases/

# Read a specific secret
kubectl exec -it vault-0 -n vault -- vault kv get databases/postgresql
kubectl exec -it vault-0 -n vault -- vault kv get databases/mongodb
kubectl exec -it vault-0 -n vault -- vault kv get databases/mysql
kubectl exec -it vault-0 -n vault -- vault kv get databases/redis
kubectl exec -it vault-0 -n vault -- vault kv get databases/cassandra
```

---

## Hybrid Secret Management — Vault + External Secrets Operator

This chart uses the **hybrid approach** — Vault stores and manages all secrets, and the External Secrets Operator (ESO) automatically syncs them into standard Kubernetes Secrets. Database operators read K8s Secrets normally — they don't know or care about Vault.

### How the hybrid approach works

```
HashiCorp Vault
(encrypted secret store)
        │
        │  ESO reads from Vault every 1h
        ▼
External Secrets Operator
(kind: ClusterSecretStore + ExternalSecret)
        │
        │  creates and updates automatically
        ▼
Kubernetes Secret
(standard k8s secret — operators read this)
        │
        │  mounted as env/file by operator
        ▼
Database pods
(PostgreSQL, MongoDB, MySQL, Redis, Cassandra)
```

### Why hybrid is better than sidecar-only

| | Sidecar inject only | Hybrid (Vault + ESO) |
|---|---|---|
| Operators need changes | ✅ Yes — add annotations | ❌ No — read K8s Secrets normally |
| Secret in K8s etcd | ❌ No | ✅ Yes but synced from Vault |
| Audit trail | ✅ Vault logs | ✅ Vault logs |
| Auto rotation | ✅ Via lease | ✅ Via refreshInterval |
| Works with any operator | ❌ Needs sidecar support | ✅ Yes — universal |
| Complexity | High | Medium |

### Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Installs automatically with this chart — but you can also install separately:
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace
```

### Verify ESO is syncing secrets

```bash
# List all ExternalSecrets and their sync status
kubectl get externalsecret -n databases

# Check sync status of a specific ExternalSecret
kubectl describe externalsecret my-db-postgresql-credentials -n databases

# Verify the K8s Secret was created by ESO
kubectl get secret my-db-postgresql-credentials -n databases

# Check ClusterSecretStore connection to Vault
kubectl get clustersecretstore vault-backend
kubectl describe clustersecretstore vault-backend
```

### What ESO status means

| Status | Meaning |
|---|---|
| `SecretSynced` | Vault → K8s Secret sync successful |
| `SecretSyncedError` | Sync failed — check Vault connection |
| `InvalidStoreConfig` | ClusterSecretStore misconfigured |

### Force a secret refresh

```bash
# ESO refreshes automatically every 1h (set by refreshInterval in ExternalSecret)
# To force immediate refresh — add an annotation to trigger reconcile
kubectl annotate externalsecret my-db-postgresql-credentials \
  force-sync=$(date +%s) \
  --overwrite \
  -n databases
```

### Rotate a secret

```bash
# 1. Update secret in Vault
kubectl exec -it vault-0 -n vault -- vault kv put databases/postgresql \
  superuser-password="NewSecurePassword!" \
  app-password="NewSecurePassword!"

# 2. ESO picks up change within 1h automatically
# 3. Or force immediate sync (see above)
# 4. Restart DB pods to pick up new secret
kubectl rollout restart statefulset -n databases
```
kubectl create secret generic vault-transit-token \
  --namespace vault \
  --from-literal=token= \
  --dry-run=client -o yaml | kubectl apply -f -
