# minio

Standalone Helm chart for deploying MinIO as S3-compatible object storage in Kubernetes.
It is suitable as a PostgreSQL backup destination for operators that support S3 endpoints.

## Install

```bash
helm upgrade --install my-minio ./minio \
  --namespace storage \
  --create-namespace
```

## Install With Vault-managed credentials

This repo already provides a `ClusterSecretStore` named `vault-backend`.
Store MinIO credentials in Vault at `databases/minio` with these fields:

- `root-user`
- `root-password`

Apply the `ExternalSecret` for the `storage` namespace:

```bash
kubectl apply -f ./minio/externalsecret-storage.yaml
```

Deploy MinIO with the Vault-backed values file:

```bash
helm upgrade --install my-minio ./minio \
  --namespace storage \
  --create-namespace \
  -f ./minio/values.vault.yaml
```

If PostgreSQL backups run in the `databases` namespace, also apply:

```bash
kubectl apply -f ./minio/externalsecret-databases.yaml
```

## What it deploys

- MinIO `Deployment`
- credentials `Secret`
- persistent volume claim
- internal `Service`
- optional console `Ingress`
- optional bucket provisioning `Job`

## Important values

```yaml
auth:
  rootUser: minioadmin
  rootPassword: "change-this-minio-password"

ingress:
  enabled: true
  host: minio.example.com
  tls:
    enabled: true
    secretName: minio-tls

bucketProvisioning:
  enabled: true
  bucket: postgresql-backups
```

## PostgreSQL backup example

For a PostgreSQL operator that accepts S3-compatible storage settings, point backups at the MinIO service:

- endpoint: `http://my-minio-minio.storage.svc.cluster.local:9000`
- bucket: `postgresql-backups`
- access key: value from the MinIO root user secret
- secret key: value from the MinIO root password secret

The exact PostgreSQL backup YAML depends on the operator you use.
