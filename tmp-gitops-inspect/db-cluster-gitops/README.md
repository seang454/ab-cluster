# db-cluster-gitops

GitOps repo for user database cluster deployments.
Helm chart lives in: https://github.com/seang454/ab-cluster (db-cluster/)

## Structure
```
apps/
  applicationset.yaml            ← ONE ApplicationSet for ALL users (apply once)

db-cluster/
  default/
    values.yaml                  ← cluster-wide defaults (reference only)
  users/
    john/
      values.yaml                ← John's config — Spring writes here
    jane/
      values.yaml                ← Jane's config — Spring writes here
    <username>/
      values.yaml                ← Spring creates this for every new user
```

## How it works (Option B — ApplicationSet)

ArgoCD watches `db-cluster/users/*` in this repo.
When Spring pushes a new `db-cluster/users/{username}/values.yaml`,
ArgoCD automatically creates an Application for that user and syncs the cluster.
**Spring never calls kubectl.**

## One-time cluster setup
```bash
kubectl apply -f apps/applicationset.yaml
```
That's it. Never touch this again.

## Adding a new user (Spring does this automatically)
Spring Boot only needs to:
1. Create `db-cluster/users/{username}/values.yaml`
2. Git commit + push

ArgoCD detects the new folder and provisions the namespace + databases within ~30s (webhook) or ~2min (polling).

## Removing a user
Delete `db-cluster/users/{username}/` and push.
ArgoCD prunes the Application and all resources in the namespace automatically
(because `prune: true` is set in the ApplicationSet).
