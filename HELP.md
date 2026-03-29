# `setup.sh` Command Guide

This project uses `setup.sh` to manage the full database platform lifecycle.
The script is split into commands because the stack has multiple dependency layers:

- storage
- Vault and unseal
- operators
- database custom resources
- port forwarding and maintenance

You do not always want to reinstall everything. Sometimes you only want to fix one layer.

## Main Commands

1. `./setup.sh`
Use this for the normal end-to-end install with the current `db-cluster/values.yaml`.

Why:
- It runs the stack in the correct order.
- Storage, Vault, operators, and databases depend on each other.
- Running these parts manually in the wrong order often causes failures.

2. `./setup.sh small_setup`
Use this for smaller clusters.

Why:
- The default profile may ask for more CPU than the cluster has.
- This uses `db-cluster/values.small-cluster.yaml`, which is reduced for limited worker capacity.

3. `./setup.sh preflight`
Use this before installing.

Why:
- It checks whether worker-node CPU is enough for the enabled databases.
- It prevents long deployments that later fail with `Pending` pods.
- It is still based on requested resources and can be optimistic if an operator adds extra containers during startup.

## Build And Install Steps

4. `./setup.sh repos`
Use this when Helm repositories are missing or outdated.

Why:
- Helm cannot install charts if repo metadata is missing or stale.

5. `./setup.sh longhorn`
Use this when you want to install or repair Longhorn.

Why:
- Databases need persistent storage.
- If Longhorn is not healthy, PVCs will not bind and stateful workloads will fail.

6. `./setup.sh ingress_nginx`
Use this when you want to install or repair the nginx ingress controller.

Why:
- The web UIs in this repo use standard Kubernetes `Ingress`.
- The current chart defaults use `ingressClassName: nginx`.
- Without a working ingress controller, `vault.seang.shop` and `longhorn.seang.shop` will not be reachable.

7. `./setup.sh deps`
Use this when you want to update local chart dependencies.

Why:
- The umbrella chart depends on packaged child charts.
- This refreshes those before deploy.

8. `./setup.sh vault_transit`
Use this when you only want to install transit Vault.

Why:
- Transit Vault is used to auto-unseal the main Vault cluster.
- It must exist before the main Vault unseal flow can work.

9. `./setup.sh vault_install`
Use this when you want to install the main Vault cluster only.

Why:
- Sometimes you want to validate Vault health before deploying databases.

10. `./setup.sh vault_init`
Use this after Vault installation.

Why:
- Vault is not usable until it is initialized and unsealed.
- Later steps depend on the root token secret created from this step.

11. `./setup.sh install_operators`
Use this when you only want the Kubernetes operators.

Why:
- Operators are the controllers that manage PostgreSQL, MongoDB, MySQL, Redis, and Cassandra custom resources.
- Without them, the database resources will not reconcile.

12. `./setup.sh deploy`
Use this after storage, Vault, and operators are ready.

Why:
- This creates the main application resources and database custom resources.
- If you changed a deployed database to `enabled: false`, `deploy` will usually remove that database's live Kubernetes objects.

13. `./setup.sh operator_plugins`
Use this when you want to rerun the standalone operator installer script.

Why:
- It gives you a separate way to install or repair operators without rerunning the full setup.

## Status And Operations

14. `./setup.sh status`
Use this for a quick platform health check.

Why:
- It shows pods and PVCs across the main namespaces.

15. `./setup.sh clusters`
Use this to inspect database custom resources.

Why:
- Operators manage custom resources like `cluster`, `psmdb`, `pxc`, `rediscluster`, and `k8ssandracluster`.
- This gives a database-level view instead of just pod-level output.

16. `./setup.sh vault_status`
Use this when secret sync or authentication looks broken.

Why:
- If Vault is sealed or unhealthy, the rest of the platform will often fail indirectly.

17. `./setup.sh upgrade`
Use this after changing values or secrets.

Why:
- It reapplies the Helm release without requiring full teardown and reinstall.

18. `./setup.sh sync`
Use this when External Secrets need to refresh.

Why:
- It forces Kubernetes secrets to sync again from Vault.

19. `./setup.sh vault_list`
Use this to list secret paths in Vault.

Why:
- Useful for confirming database secrets exist where expected.

20. `./setup.sh vault_get <db>`
Use this to inspect one database secret in Vault.

Why:
- Helpful when database credentials do not match what the workload expects.

21. `./setup.sh rotate <db> <pass>`
Use this to rotate a database password.

Why:
- Vault is the source of truth.
- Password changes should be made there instead of manually editing Kubernetes secrets.

## Local Access Commands

22. `./setup.sh pg`
Use this to port-forward PostgreSQL to local port `5432`.

23. `./setup.sh mongo`
Use this to port-forward MongoDB to local port `27017`.

24. `./setup.sh redis`
Use this to port-forward Redis to local port `6379`.

25. `./setup.sh mysql`
Use this to port-forward MySQL to local port `3306`.

26. `./setup.sh cassandra`
Use this to port-forward Cassandra to local port `9042`.

27. `./setup.sh vault_ui`
Use this to port-forward Vault UI to local port `8200`.

28. `./setup.sh longhorn_ui`
Use this to port-forward Longhorn UI to local port `8080`.

29. `./setup.sh cloudflare_secret`
Use this to create or update the Cloudflare API token secret.

Why:
- The Cloudflare DNS automation job reads the token from a Kubernetes secret.
- This avoids storing the token directly in `values.yaml`.

Why for all port-forward commands:
- They give local access without exposing services publicly.
- They are useful for debugging, admin work, and local client testing.

## TLS

The chart now supports explicit database TLS wiring for all database charts in this repo.

- PostgreSQL: CNPG operator-managed TLS by default, with optional external secret wiring if you explicitly switch modes
- MySQL: cert-manager-generated `ssl` and `ssl-internal` secrets
- MongoDB: cert-manager-generated `ssl` and `sslInternal` secrets for the Percona MongoDB operator
- Redis: cert-manager-generated TLS secret referenced by the Redis operator `TLS` block
- Cassandra: K8ssandra encryption-store secret references for client and internode encryption
- Put your public DNS name in `publicHostnames` so it is added to the server certificate SANs for PostgreSQL, MySQL, MongoDB, and Redis
- PostgreSQL, MySQL, MongoDB, Redis, and Cassandra can stay `ClusterIP` and be exposed through Traefik `IngressRouteTCP`
- Web ingress is intended to be `Traefik + cert-manager`
- Database traffic is intended to be `Service + TLS on the database`, optionally routed through Traefik TCP, not normal HTTP Ingress
- In the ClusterIP-only setup, external clients connect to the existing public IP or DNS name that already reaches Traefik on the database port, and Traefik forwards that traffic internally with TCP passthrough

Default Traefik TCP ports:
- PostgreSQL: `5432`
- MySQL: `3306`
- MongoDB: `27017`
- Redis: `6379`
- Cassandra: `9042`

Important Cassandra note:
- Cassandra TLS is store-based, not PEM-based
- You must provide keystore/truststore secrets or enable inline secret creation with valid base64-encoded store content

## Cloudflare DNS

For Cloudflare-backed public hostnames:

- Use `DNS only` records unless you intentionally want Cloudflare HTTP proxying for a web UI.
- Point the hostname to the existing external IP that already reaches your ingress controller.
- Put database hostnames in the relevant `*.externalAccess.publicHostnames` value only if you are intentionally exposing that database outside the cluster.

Example:
- `vault.example.com` -> external IP of your ingress path
- `longhorn.example.com` -> external IP of your ingress path
- client connects to `postgres-db.example.com:5432`
- PostgreSQL external exposure is not handled by standard HTTP Ingress
- PostgreSQL terminates TLS using a cert that includes `postgres-db.example.com` when you expose it on its native port

## Cloudflare Automation

The chart can create/update Cloudflare DNS records automatically.

- Set `cloudflare.enabled: true`
- Set `cloudflare.zoneName`
- Set `cloudflare.externalIP`
- Put DB hostnames in the relevant `*.externalAccess.publicHostnames`
- Store the Cloudflare API token in a Kubernetes secret and set `cloudflare.apiTokenExistingSecret`

Example secret:
```bash
kubectl create secret generic cloudflare-api-token \
  --from-literal=token=YOUR_CLOUDFLARE_API_TOKEN \
  -n databases
```

Or with the repo helper:
```bash
export CLOUDFLARE_API_TOKEN=YOUR_CLOUDFLARE_API_TOKEN
./setup.sh cloudflare_secret
```

Then on install/upgrade the chart runs a job that upserts DNS-only `A` records for those hostnames.

## Destructive Command

30. `./setup.sh teardown`
Use this when you want to remove the entire platform.

Why:
- It removes Helm releases, CRDs, PVC/PV finalizers, namespaces, and local init artifacts.
- It is intended for reset and cleanup scenarios.

Warning:
- This is destructive.
- It can permanently delete your data.

## Recommended Order

1. Edit `db-cluster/values.yaml` or use `db-cluster/values.small-cluster.yaml`.
2. Put passwords in `.env`.
3. Run `./setup.sh preflight`.
4. Run `./setup.sh` or `./setup.sh small_setup`.
5. Run `./setup.sh status`.
6. Run `./setup.sh clusters`.

## Recommended For This Cluster

For your current cluster, the safe choices are:

1. `./setup.sh`
Use this if your edited `db-cluster/values.yaml` only enables workloads your cluster can handle.

2. `./setup.sh small_setup`
Use this if you want the known-safe reduced profile.
