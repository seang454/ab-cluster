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

6. `./setup.sh deps`
Use this when you want to update local chart dependencies.

Why:
- The umbrella chart depends on packaged child charts.
- This refreshes those before deploy.

7. `./setup.sh vault_transit`
Use this when you only want to install transit Vault.

Why:
- Transit Vault is used to auto-unseal the main Vault cluster.
- It must exist before the main Vault unseal flow can work.

8. `./setup.sh vault_install`
Use this when you want to install the main Vault cluster only.

Why:
- Sometimes you want to validate Vault health before deploying databases.

9. `./setup.sh vault_init`
Use this after Vault installation.

Why:
- Vault is not usable until it is initialized and unsealed.
- Later steps depend on the root token secret created from this step.

10. `./setup.sh install_operators`
Use this when you only want the Kubernetes operators.

Why:
- Operators are the controllers that manage PostgreSQL, MongoDB, MySQL, Redis, and Cassandra custom resources.
- Without them, the database resources will not reconcile.

11. `./setup.sh deploy`
Use this after storage, Vault, and operators are ready.

Why:
- This creates the main application resources and database custom resources.

12. `./setup.sh operator_plugins`
Use this when you want to rerun the standalone operator installer script.

Why:
- It gives you a separate way to install or repair operators without rerunning the full setup.

## Status And Operations

13. `./setup.sh status`
Use this for a quick platform health check.

Why:
- It shows pods and PVCs across the main namespaces.

14. `./setup.sh clusters`
Use this to inspect database custom resources.

Why:
- Operators manage custom resources like `cluster`, `psmdb`, `pxc`, `rediscluster`, and `k8ssandracluster`.
- This gives a database-level view instead of just pod-level output.

15. `./setup.sh vault_status`
Use this when secret sync or authentication looks broken.

Why:
- If Vault is sealed or unhealthy, the rest of the platform will often fail indirectly.

16. `./setup.sh upgrade`
Use this after changing values or secrets.

Why:
- It reapplies the Helm release without requiring full teardown and reinstall.

17. `./setup.sh sync`
Use this when External Secrets need to refresh.

Why:
- It forces Kubernetes secrets to sync again from Vault.

18. `./setup.sh vault_list`
Use this to list secret paths in Vault.

Why:
- Useful for confirming database secrets exist where expected.

19. `./setup.sh vault_get <db>`
Use this to inspect one database secret in Vault.

Why:
- Helpful when database credentials do not match what the workload expects.

20. `./setup.sh rotate <db> <pass>`
Use this to rotate a database password.

Why:
- Vault is the source of truth.
- Password changes should be made there instead of manually editing Kubernetes secrets.

## Local Access Commands

21. `./setup.sh pg`
Use this to port-forward PostgreSQL to local port `5432`.

22. `./setup.sh mongo`
Use this to port-forward MongoDB to local port `27017`.

23. `./setup.sh redis`
Use this to port-forward Redis to local port `6379`.

24. `./setup.sh mysql`
Use this to port-forward MySQL to local port `3306`.

25. `./setup.sh cassandra`
Use this to port-forward Cassandra to local port `9042`.

26. `./setup.sh vault_ui`
Use this to port-forward Vault UI to local port `8200`.

27. `./setup.sh longhorn_ui`
Use this to port-forward Longhorn UI to local port `8080`.

Why for all port-forward commands:
- They give local access without exposing services publicly.
- They are useful for debugging, admin work, and local client testing.

## Destructive Command

28. `./setup.sh teardown`
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
