#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-databases}"
VALUES_FILE="${VALUES_FILE:-./db-cluster/values.yaml}"
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
REDIS_NAMESPACE="${REDIS_NAMESPACE:-$NAMESPACE}"
PXC_NAMESPACE="${PXC_NAMESPACE:-$NAMESPACE}"
PSMDB_NAMESPACE="${PSMDB_NAMESPACE:-$NAMESPACE}"
K8SSANDRA_NAMESPACE="${K8SSANDRA_NAMESPACE:-$NAMESPACE}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"

CNPG_VERSION="${CNPG_VERSION:-0.21.0}"
PSMDB_VERSION="${PSMDB_VERSION:-1.15.0}"
PXC_VERSION="${PXC_VERSION:-1.14.0}"
REDIS_OPERATOR_VERSION="${REDIS_OPERATOR_VERSION:-0.24.0}"
K8SSANDRA_VERSION="${K8SSANDRA_VERSION:-1.14.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
REDIS_OPERATOR_REQUEST_CPU="${REDIS_OPERATOR_REQUEST_CPU:-100m}"
REDIS_OPERATOR_REQUEST_MEMORY="${REDIS_OPERATOR_REQUEST_MEMORY:-128Mi}"
REDIS_OPERATOR_LIMIT_CPU="${REDIS_OPERATOR_LIMIT_CPU:-250m}"
REDIS_OPERATOR_LIMIT_MEMORY="${REDIS_OPERATOR_LIMIT_MEMORY:-256Mi}"
REDIS_OPERATOR_TIMEOUT="${REDIS_OPERATOR_TIMEOUT:-10m}"

log() {
  echo
  echo "==> $*"
}

ok() {
  echo "    ✓ $*"
}

die() {
  echo
  echo "ERROR: $*"
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

enabled_databases() {
  [ -f "$VALUES_FILE" ] || die "Values file not found: $VALUES_FILE"

  python3 - "$VALUES_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path, "r", encoding="utf-8").read().splitlines()
dbs = ["postgresql", "mongodb", "mysql", "redis", "cassandra"]
section = None
enabled = []

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    indent = len(raw) - len(raw.lstrip(" "))
    line = raw.strip()
    m = re.match(r"([A-Za-z0-9_]+):\s*(.*)$", line)
    if indent == 0 and m and m.group(1) in dbs:
        section = m.group(1)
        continue
    if section and indent == 2 and line.startswith("enabled:"):
        if line.split(":", 1)[1].strip().lower() == "true":
            enabled.append(section)
        section = None

print(" ".join(enabled))
PY
}

cleanup_pending_release() {
  local release="$1"
  local namespace="$2"
  local status

  if ! status="$(helm status "$release" -n "$namespace" 2>/dev/null | awk '/^STATUS:/ {print $2}')"; then
    status=""
  fi

  case "$status" in
    pending-install|pending-upgrade|pending-rollback)
      log "Cleaning up stuck Helm release $release ($status)"
      helm uninstall "$release" -n "$namespace" >/dev/null 2>&1 || true
      ok "Removed stuck release state for $release"
      ;;
  esac
}

repos() {
  log "Adding Helm repositories"
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  helm repo add percona https://percona.github.io/percona-helm-charts/ >/dev/null 2>&1 || true
  helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ >/dev/null 2>&1 || true
  helm repo add k8ssandra https://helm.k8ssandra.io/stable >/dev/null 2>&1 || true
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  ok "Helm repos ready"
}

install_cnpg() {
  log "Installing CloudNativePG operator"
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace "$CNPG_NAMESPACE" \
    --create-namespace \
    --version "$CNPG_VERSION" \
    --wait --timeout 5m
  ok "CloudNativePG installed in namespace $CNPG_NAMESPACE"
}

install_psmdb() {
  log "Installing Percona PSMDB operator"
  helm upgrade --install psmdb-operator percona/psmdb-operator \
    --namespace "$PSMDB_NAMESPACE" \
    --create-namespace \
    --version "$PSMDB_VERSION" \
    --wait --timeout 5m
  ok "Percona PSMDB installed in namespace $PSMDB_NAMESPACE"
}

install_pxc() {
  log "Installing Percona PXC operator"
  helm upgrade --install pxc-operator percona/pxc-operator \
    --namespace "$PXC_NAMESPACE" \
    --create-namespace \
    --version "$PXC_VERSION" \
    --wait --timeout 5m
  ok "Percona PXC installed in namespace $PXC_NAMESPACE"
}

install_redis_operator() {
  cleanup_pending_release redis-operator "$REDIS_NAMESPACE"
  log "Installing OpsTree Redis operator"
  helm upgrade --install redis-operator ot-helm/redis-operator \
    --namespace "$REDIS_NAMESPACE" \
    --create-namespace \
    --version "$REDIS_OPERATOR_VERSION" \
    --set "featureGates.GenerateConfigInInitContainer=true" \
    --set "resources.requests.cpu=$REDIS_OPERATOR_REQUEST_CPU" \
    --set "resources.requests.memory=$REDIS_OPERATOR_REQUEST_MEMORY" \
    --set "resources.limits.cpu=$REDIS_OPERATOR_LIMIT_CPU" \
    --set "resources.limits.memory=$REDIS_OPERATOR_LIMIT_MEMORY" \
    --wait --timeout "$REDIS_OPERATOR_TIMEOUT"
  ok "Redis operator installed in namespace $REDIS_NAMESPACE"
}

ensure_cert_manager() {
  if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    ok "cert-manager already present"
    return 0
  fi

  log "Installing cert-manager (required by K8ssandra)"
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERT_MANAGER_NAMESPACE" \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 10m
  ok "cert-manager installed in namespace $CERT_MANAGER_NAMESPACE"
}

install_k8ssandra() {
  ensure_cert_manager
  log "Installing K8ssandra operator"
  helm upgrade --install k8ssandra-operator k8ssandra/k8ssandra-operator \
    --namespace "$K8SSANDRA_NAMESPACE" \
    --create-namespace \
    --version "$K8SSANDRA_VERSION" \
    --wait --timeout 5m
  ok "K8ssandra operator installed in namespace $K8SSANDRA_NAMESPACE"
}

usage() {
  cat <<'EOF'
Usage:
  ./install-operators.sh repos
  ./install-operators.sh all
  ./install-operators.sh cnpg
  ./install-operators.sh psmdb
  ./install-operators.sh pxc
  ./install-operators.sh redis
  ./install-operators.sh k8ssandra

Examples:
  ./install-operators.sh all
  ./install-operators.sh cnpg
  NAMESPACE=databases ./install-operators.sh psmdb
  VALUES_FILE=./db-cluster/values.small-cluster.yaml ./install-operators.sh all
EOF
}

main() {
  require_bin helm
  require_bin kubectl

  local cmd="${1:-all}"

  case "$cmd" in
    repos)
      repos
      ;;
    all)
      local enabled
      repos
      enabled="$(enabled_databases)"
      info_file="${VALUES_FILE}"
      log "Installing operators for enabled databases from $info_file"
      [ -n "$enabled" ] || die "No databases are enabled in $VALUES_FILE"
      for db in $enabled; do
        case "$db" in
          postgresql) install_cnpg ;;
          mongodb) install_psmdb ;;
          mysql) install_pxc ;;
          redis) install_redis_operator ;;
          cassandra) install_k8ssandra ;;
        esac
      done
      ;;
    cnpg)
      repos
      install_cnpg
      ;;
    psmdb)
      repos
      install_psmdb
      ;;
    pxc)
      repos
      install_pxc
      ;;
    redis)
      repos
      install_redis_operator
      ;;
    k8ssandra)
      repos
      install_k8ssandra
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
