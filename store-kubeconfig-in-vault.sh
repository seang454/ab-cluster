#!/usr/bin/env bash
set -euo pipefail

# Store Kubernetes kubeconfig/certificate files in Vault KV v2.
#
# Usage:
#   chmod +x store-kubeconfig-in-vault.sh
#   export VAULT_ADDR="https://vault.seang.shop"
#   export VAULT_TOKEN="your-vault-token"
#   ./store-kubeconfig-in-vault.sh
#
# If running Vault in Docker only:
#   docker exec -it vault-prod vault login
#   docker cp /path/to/config-cluster2 vault-prod:/tmp/config-cluster2
#   docker exec -it vault-prod vault kv put secret/a8s/kubeconfigs/cluster2 config-cluster2=@/tmp/config-cluster2

VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/a8s/kubeconfigs/cluster2}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/config-cluster2}"

if ! command -v vault >/dev/null 2>&1; then
  echo "vault CLI is not installed or not in PATH."
  echo "Install Vault CLI, or use docker exec commands shown in the comments."
  exit 1
fi

if [ -z "${VAULT_ADDR:-}" ]; then
  echo "VAULT_ADDR is required. Example:"
  echo "  export VAULT_ADDR=https://vault.seang.shop"
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "VAULT_TOKEN is required. Example:"
  echo "  export VAULT_TOKEN=your-vault-token"
  exit 1
fi

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Kubeconfig file not found: $KUBECONFIG_FILE"
  echo "Set it with:"
  echo "  export KUBECONFIG_FILE=/path/to/config-cluster2"
  exit 1
fi

vault kv put "$VAULT_SECRET_PATH" \
  config-cluster2=@"$KUBECONFIG_FILE"

echo "Stored kubeconfig in Vault:"
echo "  path: $VAULT_SECRET_PATH"
echo "  key:  config-cluster2"
