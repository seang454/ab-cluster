# Argo CD New Cluster Setup

This guide shows how to register a new Kubernetes cluster in Argo CD and use it in GitOps safely.

It covers:

- adding the cluster to Argo CD
- verifying the registration
- choosing `destination.server` vs `destination.name`
- wiring `root-app.yaml` and `applicationset.yaml`
- refreshing controllers when Argo keeps stale cluster state

## 1. Confirm the Kubernetes Context

Check the kubeconfig context you want Argo to use.

```bash
kubectl config get-contexts
kubectl config current-context
```

Example:

```text
k8s-cluster2
```

If needed, switch:

```bash
kubectl config use-context k8s-cluster2
```

## 2. Confirm Argo CD CLI Access

Make sure `argocd` CLI can talk to the correct Argo CD instance.

```bash
argocd version
argocd app list
```

If you use port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd login localhost:8080 --insecure
```

## 3. Add the Cluster to Argo CD

Register the cluster using the kubeconfig context name.

```bash
argocd cluster add k8s-cluster2 --name k8s-cluster2
```

This creates or updates:

- `argocd-manager` service account
- cluster role / role binding
- Argo CD cluster registration secret

Expected output:

```text
Cluster 'https://34.50.95.205:6443' added
```

## 4. Verify the Registration

Check Argo cluster secrets:

```bash
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
```

You should see a cluster secret such as:

```text
cluster-34.50.95.205-xxxxxxxx
```

Also check in the Argo UI under cluster settings.

You may see:

```text
Name: k8s-cluster2
URL:  https://34.50.95.205:6443
Status: Successful
```

This means:

- Argo cluster name = `k8s-cluster2`
- Kubernetes API server URL = `https://34.50.95.205:6443`

They refer to the same cluster.

## 5. Restart Argo Controllers After Registration

Sometimes Argo keeps stale cache or destination validation state after adding a cluster.

Restart both controllers:

```bash
kubectl rollout restart deployment argocd-applicationset-controller -n argocd
kubectl rollout restart statefulset argocd-application-controller -n argocd
```

Wait for them:

```bash
kubectl rollout status deployment argocd-applicationset-controller -n argocd
kubectl rollout status statefulset argocd-application-controller -n argocd
```

## 6. Choose `server` vs `name`

Argo supports two ways to target the destination cluster.

### Option A: `destination.server`

Example:

```yaml
destination:
  server: https://34.50.95.205:6443
  namespace: argocd
```

Use this when:

- you want to target the raw Kubernetes API URL
- Argo validation in your setup accepts the raw server cleanly

### Option B: `destination.name`

Example:

```yaml
destination:
  name: k8s-cluster2
  namespace: my-namespace
```

Use this when:

- you already registered the cluster under a known Argo name
- Argo UI and controller are more stable with cluster name than raw server URL

## 7. Recommended Split for This Platform

For this platform, the clean pattern is:

### Root app

Use the in-cluster destination for the root app because it only manages Argo resources in the same cluster.

`apps/root-app.yaml`

```yaml
destination:
  server: https://kubernetes.default.svc
  namespace: argocd
```

### Child database-cluster apps

Use the external cluster destination for generated applications.

You can use either:

```yaml
destination:
  server: https://34.50.95.205:6443
  namespace: '{{path[3]}}'
```

or:

```yaml
destination:
  name: k8s-cluster2
  namespace: '{{path[3]}}'
```

If raw `server:` keeps failing validation in `ApplicationSet`, switch to:

```yaml
name: k8s-cluster2
```

That still targets the same cluster.

## 8. Example Root App

`apps/root-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-db-clusters
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/seang454/db-cluster-gitops.git
    targetRevision: master
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## 9. Example ApplicationSet with Raw Server

`apps/applicationset.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: user-db-clusters
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/seang454/db-cluster-gitops.git
        revision: master
        directories:
          - path: db-cluster/users/*/*/*
  syncPolicy:
    preserveResourcesOnDeletion: false
  template:
    metadata:
      name: '{{path[3]}}-{{path.basename}}-db-cluster'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      sources:
        - repoURL: https://github.com/seang454/db-cluster-gitops.git
          targetRevision: master
          ref: uservalues
        - repoURL: https://github.com/seang454/ab-cluster.git
          targetRevision: master
          path: db-cluster
          helm:
            releaseName: '{{path.basename}}'
            valueFiles:
              - $uservalues/{{path}}/values.yaml
      destination:
        server: https://34.50.95.205:6443
        namespace: '{{path[3]}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - PrunePropagationPolicy=foreground
          - PruneLast=true
```

## 10. Example ApplicationSet with Cluster Name

If `server:` keeps failing, use:

```yaml
destination:
  name: k8s-cluster2
  namespace: '{{path[3]}}'
```

This uses the registered Argo cluster name instead of the raw URL.

## 11. Apply the GitOps Manifests

Apply root app and appset:

```bash
kubectl apply -f apps/root-app.yaml
kubectl apply -f apps/applicationset.yaml
```

Or:

```bash
kubectl apply -f apps/root-app.yaml -f apps/applicationset.yaml
```

## 12. Check Health

```bash
kubectl get applications -n argocd
kubectl describe application root-db-clusters -n argocd
kubectl describe applicationset user-db-clusters -n argocd
```

Healthy examples:

```text
root-db-clusters   Synced   Healthy
user-db-clusters   Synced   Healthy
```

## 13. Force Refresh When Status Looks Stale

If sync/health looks stale:

```bash
kubectl annotate application root-db-clusters -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl annotate applicationset user-db-clusters -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

Refresh child apps too:

```bash
kubectl annotate application <child-app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

## 14. Common Errors

### Error: `cluster not found`

Example:

```text
unable to find destination server: there are no clusters with this name: https://34.50.95.205:6443
```

Fix:

1. Run `argocd cluster add ...`
2. Verify cluster secret exists in `argocd`
3. Restart Argo controllers
4. Re-apply the manifest
5. If it still fails for `server:`, use `name: k8s-cluster2`

### Error: root app degraded because child appset degraded

Root app health depends on child resources.

If `user-db-clusters` is degraded, `root-db-clusters` will also show degraded.

### UI shows server URL, YAML uses cluster name

This is normal.

Argo UI often displays:

```text
https://34.50.95.205:6443
```

while YAML can use:

```yaml
name: k8s-cluster2
```

Both can refer to the same cluster.

## 15. Recommended Rule

Use this rule to reduce confusion:

- `root-app.yaml`:
  use `server: https://kubernetes.default.svc`
- child database-cluster apps:
  prefer `name: k8s-cluster2`
- use raw `server: https://34.50.95.205:6443` only if you have verified your Argo controller accepts it cleanly in that specific manifest path

