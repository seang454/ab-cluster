# db-cluster v4

Helm umbrella chart for PostgreSQL, MongoDB, MySQL, Redis, and Cassandra.
The app release renders only database workloads and release-specific
Kubernetes resources. Cluster-wide bootstrap services are installed separately.

## What this chart includes

- PostgreSQL `Cluster`
- MongoDB `PerconaServerMongoDB`
- MySQL `PerconaXtraDBCluster`
- Redis `RedisCluster`
- Cassandra `K8ssandraCluster`
- Native `Secret` objects for database credentials
- Database Services, Ingresses, and CRs
- Optional Cloudflare DNS job for exposed hostnames
- Optional HAProxy-based TCP proxy

## What this chart does not include

- Vault
- Vault Transit
- External Secrets Operator
- Longhorn UI ingress
- Longhorn installation itself

## Install

```bash
helm dependency build ./db-cluster/
helm upgrade --install my-db ./db-cluster/ \
  --namespace databases \
  --create-namespace
```

## Values

The default `values.yaml` keeps all databases disabled. Enable only the
databases you need and fill in the credential fields that apply to them.

Example:

```yaml
postgresql:
  enabled: true
  credentials:
    superuser: "YourSecurePassword!"
    admin: "YourSecurePassword!"

mongodb:
  enabled: true
  credentials:
    clusterAdminPassword: "YourSecurePassword!"
    userAdminPassword: "YourSecurePassword!"
    clusterMonitorPassword: "YourSecurePassword!"
    databaseAdminPassword: "YourSecurePassword!"
    backupPassword: "YourSecurePassword!"
    replicationKey: "YourSecureKey!"

mysql:
  enabled: true
  credentials:
    rootPassword: "YourSecurePassword!"
    replicationPassword: "YourSecurePassword!"
    monitorPassword: "YourSecurePassword!"
    clusterCheckPassword: "YourSecurePassword!"

redis:
  enabled: true
  auth:
    password: "YourSecurePassword!"

cassandra:
  enabled: true
  credentials:
    password: "YourSecurePassword!"
```

## Notes

- This chart assumes your storage class already exists.
- The chart no longer tries to create bootstrap resources owned by other
  releases.
- If you are using Spring or another caller to deploy the OCI chart, point it
  at the new chart version and keep the override file to non-empty request
  fields only.
