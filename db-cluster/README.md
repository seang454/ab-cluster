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
- Optional HAProxy-based TCP proxy

## Shared Platform Flow

This chart uses one common platform model across all database types:

```text
Vault -> ExternalSecret -> Kubernetes Secret -> Database Operator
MinIO/S3 -> Operator-specific backup integration
Prometheus -> Operator/exporter-specific metrics integration
Public DNS -> external HAProxy -> database service
```

The high-level flow is shared, but each subchart keeps its own operator logic.
This chart does not try to force PostgreSQL CRDs or PgBouncer semantics onto
MongoDB, MySQL, Redis, or Cassandra.

## Feature Mapping By Database

Use the same platform concepts, but let each database implement them with its
own operator-native resources:

| Database | Cluster CR | Scheduled backup | Connection proxy / routing | Metrics path | External access |
| --- | --- | --- | --- | --- | --- |
| PostgreSQL | `Cluster` (CloudNativePG) | `ScheduledBackup` | `Pooler` (PgBouncer) + HAProxy | CNPG PodMonitor / PrometheusRule | HAProxy -> `*-postgresql-rw` |
| MongoDB | `PerconaServerMongoDB` | `spec.backup.tasks[]` | operator replica-set service / split horizons | exporter sidecar + PodMonitor + PrometheusRule | HAProxy or split horizons |
| MySQL | `PerconaXtraDBCluster` | `spec.backup.schedule[]` | operator HAProxy | exporter sidecar + PodMonitor + PrometheusRule | operator HAProxy + external TCP proxy |
| Redis | `RedisCluster` | CronJob snapshot backup in this chart | direct Redis service | Redis exporter + ServiceMonitor + PrometheusRule | external TCP proxy |
| Cassandra | `K8ssandraCluster` | `MedusaBackupSchedule` | direct Cassandra service | K8ssandra / Medusa metrics | external TCP proxy |

## Connection Handling By Database

This chart now treats "pooler" as a database-specific connection-handling
feature, not a single shared CRD:

- PostgreSQL: CloudNativePG `Pooler` with PgBouncer
- MySQL: operator-managed HAProxy
- MongoDB: replica set service and client-driver pooling, with split horizons
  when exposing member endpoints externally
- Redis: client-driver pooling, optional external TCP proxy
- Cassandra: driver-native session pooling, optional external TCP proxy

Use the operator-native or driver-native option for each database instead of
trying to force a PostgreSQL-style pooler onto all engines.

The `values.yaml` now exposes this explicitly with a per-database
`connectionHandling` block:

```yaml
postgresql:
  connectionHandling:
    enabled: true
    mode: pooler

mysql:
  connectionHandling:
    enabled: true
    mode: haproxy

mongodb:
  connectionHandling:
    enabled: true
    mode: driver

redis:
  connectionHandling:
    enabled: true
    mode: client

cassandra:
  connectionHandling:
    enabled: true
    mode: driver
```

Only PostgreSQL and MySQL render extra connection-handling resources from this
block today, because MongoDB, Redis, and Cassandra rely on their operator or
client-driver pooling model instead of a standalone pooler object.

## Monitoring By Database

Monitoring is enabled in each chart using the mechanism that fits that operator:

- PostgreSQL: CloudNativePG native `monitoring.enablePodMonitor`
- MongoDB: exporter sidecar plus chart-managed `PodMonitor`
- MySQL: exporter sidecar plus chart-managed `PodMonitor`
- Redis: OpsTree native `redisExporter` plus `serviceMonitor`
- Cassandra: K8ssandra `telemetry.prometheus.enabled`, which allows the operator
  to create `ServiceMonitor` resources

This keeps monitoring "in its own way" per engine instead of forcing a fake
generic PodMonitor across everything.

## Common Values Contract

At the umbrella-chart level, keep the same platform blocks for each database
where they make sense:

- `externalAccess`
- `backup`
- `monitoring`
- `alerts`
- `tls`
- `resources`
- `storage`

Each subchart maps those blocks to its own operator-specific resources.
Examples:

- PostgreSQL uses `backup.schedule.cron` to render `ScheduledBackup`
- MongoDB uses `backup.task.schedule` inside `PerconaServerMongoDB`
- MySQL uses `backup.schedule.cron` inside `PerconaXtraDBCluster`
- Cassandra uses `backup.schedule.cron` to render `MedusaBackupSchedule`
- Redis currently uses its own cluster/exporter logic and does not yet render a
  scheduled backup resource

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
database you need and fill in the client-facing `connection` fields supplied by
the user. Internal/operator credentials keep chart defaults unless you are
intentionally rotating them.

For API-driven deployments, each database block can optionally point at a
pre-created Kubernetes Secret instead of letting Helm render secrets from
plaintext values. When `externalSecretRef` is empty, the chart keeps the
current behavior and creates the Secret from values.

Example:

```yaml
postgresql:
  enabled: true
  connection:
    username: "appuser"
  externalSecretRef: "my-postgresql-app"
  superuserExternalSecretRef: "my-postgresql-superuser"

mongodb:
  enabled: true
  externalSecretRef: "my-mongodb-credentials"

mysql:
  enabled: true
  externalSecretRef: "my-mysql-credentials"

redis:
  enabled: true
  externalSecretRef: "my-redis-credentials"

cassandra:
  enabled: true
  externalSecretRef: "my-cassandra-credentials"
```

Expected Secret payloads:

- PostgreSQL `externalSecretRef`: `username`, `password`. The username should
  match `postgresql.connection.username` or the bootstrap owner.
- PostgreSQL `superuserExternalSecretRef`: `username`, `password`, with
  `username: postgres`.
- MongoDB `externalSecretRef`: `MONGODB_CLUSTER_ADMIN_USER`,
  `MONGODB_CLUSTER_ADMIN_PASSWORD`, `MONGODB_USER_ADMIN_USER`,
  `MONGODB_USER_ADMIN_PASSWORD`, `MONGODB_CLUSTER_MONITOR_USER`,
  `MONGODB_CLUSTER_MONITOR_PASSWORD`, `MONGODB_DATABASE_ADMIN_USER`,
  `MONGODB_DATABASE_ADMIN_PASSWORD`, `MONGODB_BACKUP_USER`,
  `MONGODB_BACKUP_PASSWORD`, `MONGODB_REPLICATION_KEY`.
- MySQL `externalSecretRef`: `root`, `xtrabackup`, `monitor`,
  `clustercheck`, `proxyadmin`, `operator`, `replication`, and
  `init-users.sql`.
- Redis `externalSecretRef`: `username`, `password`. For Redis, create the
  Secret before running Helm so the chart can resolve the password into the
  rendered Redis config when no fallback value is supplied.
- Cassandra `externalSecretRef`: `username`, `password`.

Example:

```yaml
postgresql:
  enabled: true
  connection:
    username: "appuser"
    password: "ClientSuppliedPassword123!"
    port: 15432
  backup:
    schedule:
      enabled: true
      cron: "0 0 2 * * *"

mongodb:
  enabled: true
  connection:
    username: "databaseAdmin"
    password: "ClientSuppliedPassword123!"
    port: 17017
  externalAccess:
    enabled: true
    publicHostnames:
      - mongo-db-0.example.com
      - mongo-db-1.example.com
      - mongo-db-2.example.com
  tls:
    enabled: true
    mode: certManager
  cluster:
    configuration: |
      net:
        tls:
          allowConnectionsWithoutCertificates: true

mysql:
  enabled: true
  connection:
    username: "appuser"
    password: "ClientSuppliedPassword123!"
    port: 13306

redis:
  enabled: true
  connection:
    username: "default"
    password: "ClientSuppliedPassword123!"
    port: 16379

cassandra:
  enabled: true
  connection:
    username: "cassandra"
    password: "ClientSuppliedPassword123!"
    port: 19042
```

The user-facing request contract for this flow lives in the Spring backend
Postman collection at `../spring/a8s-backend/postman/db-cluster.postman_collection.json`.
Spring should map:

```text
request.connection.username -> <database>.connection.username
request.connection.password -> <database>.connection.password
request.connection.port     -> <database>.connection.port
```

For MongoDB replica-set clients connecting through the TCP proxy, use all
member hostnames on port `27017`. Do not use `27018` or `27019`; the hostname
selects the backend, not the port. This path expects MongoDB TLS to stay
enabled so HAProxy can route by TLS SNI.

For production, prefer this pattern instead of storing real passwords in
`values.yaml`:

```text
Vault -> ExternalSecret -> Kubernetes Secret -> database operator secretRef
```

The PostgreSQL chart already references named Secrets through
`superuserSecret` and bootstrap `secret.name`. The same pattern should be used
for the other database operators so credentials stay outside the Helm values.

## Notes

- This chart assumes your storage class already exists.
- The chart no longer tries to create bootstrap resources owned by other
  releases.
- If you are using Spring or another caller to deploy the OCI chart, point it
  at the new chart version and keep the override file to non-empty request
  fields only.
- Backup-capable databases in this chart default to `backup.enabled: false`.
  When enabled, they use the S3 layout
  `s3://<namespace>/<releaseName>/<clusterName>`. PostgreSQL uses a full
  `destinationPath`, while MongoDB, MySQL, and Cassandra use the namespace as
  the bucket and `<releaseName>/<clusterName>` as the prefix.
- When you deploy the whole umbrella chart from an API, only pass overrides for
  the database blocks included in the request. Each subchart keeps its own
  logic and should only change if that block is enabled or explicitly
  overridden.
- Do not force PostgreSQL-only resources such as `Pooler` onto other database
  types. Use the equivalent operator-native feature instead.
- For MongoDB, do not set `clusterAuthX509.attributes` unless your TLS
  certificates are issued with a matching subject DN. A mismatch causes
  `mongod` to fail with `InvalidSSLConfiguration`.

## PostgreSQL Backups To MinIO

The PostgreSQL chart supports CloudNativePG backups to S3-compatible object
storage such as MinIO. Point the backup section at the MinIO service and
reference the MinIO credentials secret.

Example:

```yaml
postgresql:
  enabled: true
  backup:
    enabled: true
    provider: s3
    destinationPath: "s3://{{ .Release.Namespace }}/{{ .Release.Name }}/{{ include \"postgresql.fullname\" . }}"
    endpointURL: "http://my-minio-minio.storage.svc:9000"
    s3Credentials:
      accessKeyId:
        secretName: minio-credentials-<release-name>
        key: root-user
      secretAccessKey:
        secretName: minio-credentials-<release-name>
        key: root-password
    retentionPolicy: "7d"
    schedule:
      enabled: true
      cron: "0 0 2 * * *"
  pooler:
    enabled: true
  databases:
    - name: reporting
      owner: appuser
```

If MinIO is exposed over HTTPS with a private CA, also set
`postgresql.backup.endpointCA.secretName`.

The chart computes a release-scoped MinIO credential secret name by default:
`minio-credentials-<release-name>`. That single Secret includes both the raw
keys used by PostgreSQL and the rendered `credentials` file used by MongoDB,
MySQL, and Cassandra, so multiple releases can coexist in the same namespace
without secret-name collisions. The chart only renders that `ExternalSecret`
when at least one enabled database backup still resolves to the default
`minio-credentials-<release-name>` secret.

CloudNativePG scheduled backups use a six-field cron format with seconds:

- Daily at 02:00 UTC: `0 0 2 * * *`
- Every 6 hours: `0 0 */6 * * *`
- Weekly at 03:00 UTC on Sunday: `0 0 3 * * 0`

## PostgreSQL Optional CRDs

The PostgreSQL subchart can now render additional CloudNativePG resources when
requested through values. All of them are opt-in, so an API-driven Helm
upgrade can target only the PostgreSQL features present in the request body
without changing other database subcharts.

The chart defaults now enable:

- `postgresql.pooler`
- PostgreSQL `PrometheusRule` alerts

The chart defaults now keep CNPG-managed `PodMonitor` generation disabled for
the cluster and pooler. In some environments the operator can fail cluster
bootstrap while creating those auxiliary monitoring objects. If you want
Prometheus scraping, prefer the chart's standalone `PodMonitor` resources.

- `postgresql.pooler`: renders a `Pooler` CRD for PgBouncer.
- `postgresql.cluster.monitoring.enablePodMonitor`: when set `true`, asks CNPG to generate a `PodMonitor` for the `Cluster`.
- `postgresql.pooler.monitoring.enablePodMonitor`: when set `true`, asks CNPG to generate a `PodMonitor` for the `Pooler`.
- `postgresql.cluster.monitoring.standalonePodMonitor`: renders a chart-managed `PodMonitor` that scrapes CNPG instance pods on the `metrics` port.
- `postgresql.pooler.monitoring.standalonePodMonitor`: renders a chart-managed `PodMonitor` that scrapes PgBouncer pooler pods on the `metrics` port.

Example:

```yaml
postgresql:
  enabled: true
  pooler:
    enabled: true
    type: rw
    instances: 2
```

can I deploy like this when I release the the whole chart for the subchart it should be apply specificly on the chart I run request to deploy should not effect to other chart if the reqest from API DO NOT REQEUST it but please keep still deploy the whole helm chart that store to database cluster but effect the subchart of each cluster on the request parth from api (request like push , get , patch , etc)
