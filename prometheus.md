# 1. Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Generate values.yaml FIRST
helm show values prometheus-community/kube-prometheus-stack > values.yaml

# 3. Install
helm install prometheus-stack-release prometheus-community/kube-prometheus-stack \
  -f values-prometheus.yaml \
  -n default

# 4. Verify pods
kubectl get pods -n default -l "release=prometheus-stack-release"

# 5. Upgrade (only when you change values.yaml)
helm upgrade prometheus-stack-release prometheus-community/kube-prometheus-stack \
  -f values.yaml \
  -n default

# if you don forget password we can reset it
kubectl exec -it prometheus-stack-release-grafana-68cc4457b9-njwcp \
  -- grafana-cli admin reset-admin-password admin

kubectl get secret prometheus-stack-release-grafana -n default \
  -o jsonpath="{.data.admin-password}" | base64 -d && echo