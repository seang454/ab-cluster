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
  backup:
    schedule:
      enabled: true
      cron: "0 0 2 * * *"

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
- Backup-capable databases in this chart now default to the S3 layout
  `s3://<namespace>/<releaseName>/<clusterName>`. PostgreSQL uses a full
  `destinationPath`, while MongoDB, MySQL, and Cassandra use the namespace as
  the bucket and `<releaseName>/<clusterName>` as the prefix.

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
```

If MinIO is exposed over HTTPS with a private CA, also set
`postgresql.backup.endpointCA.secretName`.

The chart computes release-scoped credential secret names by default, such as
`minio-credentials-<release-name>` and
`minio-backup-credentials-<release-name>`, so multiple releases can coexist in
the same namespace without secret-name collisions.

CloudNativePG scheduled backups use a six-field cron format with seconds:

- Daily at 02:00 UTC: `0 0 2 * * *`
- Every 6 hours: `0 0 */6 * * *`
- Weekly at 03:00 UTC on Sunday: `0 0 3 * * 0`
