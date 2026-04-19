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

retry_cmd() {
  local attempts="$1"
  local delay="$2"
  shift 2

  local try rc
  for try in $(seq 1 "$attempts"); do
    if "$@"; then
      return 0
    fi
    rc=$?
    if [ "$try" -lt "$attempts" ]; then
      echo "    attempt $try/$attempts failed; retrying in ${delay}s..."
      sleep "$delay"
    fi
  done

  return "$rc"
}

helm_upgrade_install_with_retry() {
  local release="$1"
  local namespace="$2"
  shift 2

  local attempts="${HELM_INSTALL_RETRIES:-4}"
  local delay="${HELM_INSTALL_RETRY_DELAY:-15}"
  local try

  for try in $(seq 1 "$attempts"); do
    if helm upgrade --install "$release" "$@" --namespace "$namespace"; then
      return 0
    fi

    if [ "$try" -lt "$attempts" ]; then
      cleanup_pending_release "$release" "$namespace"
      echo "    Helm install for $release failed on attempt $try/$attempts; retrying in ${delay}s..."
      sleep "$delay"
    fi
  done

  return 1
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

requested_databases() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi

  if [ -n "${OPERATORS:-}" ]; then
    for db in ${OPERATORS//,/ }; do
      [ -n "$db" ] && printf '%s\n' "$db"
    done
    return 0
  fi

  printf '%s\n' postgresql mongodb mysql redis cassandra
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

release_status() {
  local release="$1"
  local namespace="$2"

  helm status "$release" -n "$namespace" 2>/dev/null | awk '/^STATUS:/ {print $2}'
}

skip_if_deployed() {
  local release="$1"
  local namespace="$2"
  local label="$3"
  local status

  status="$(release_status "$release" "$namespace")"
  if [ "$status" = "deployed" ]; then
    ok "$label already installed in namespace $namespace; skipping"
    return 0
  fi

  return 1
}

repos() {
  log "Adding Helm repositories"
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  helm repo add percona https://percona.github.io/percona-helm-charts/ >/dev/null 2>&1 || true
  helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ >/dev/null 2>&1 || true
  helm repo add k8ssandra https://helm.k8ssandra.io/stable >/dev/null 2>&1 || true
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  retry_cmd "${HELM_REPO_UPDATE_RETRIES:-4}" "${HELM_REPO_UPDATE_RETRY_DELAY:-10}" helm repo update >/dev/null \
    || die "Failed to update Helm repositories"
  ok "Helm repos ready"
}

install_cnpg() {
  skip_if_deployed cnpg "$CNPG_NAMESPACE" "CloudNativePG operator" && return 0
  log "Installing CloudNativePG operator"
  helm_upgrade_install_with_retry cnpg "$CNPG_NAMESPACE" cnpg/cloudnative-pg \
    --create-namespace \
    --version "$CNPG_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install CloudNativePG operator"
  ok "CloudNativePG installed in namespace $CNPG_NAMESPACE"
}

install_psmdb() {
  skip_if_deployed psmdb-operator "$PSMDB_NAMESPACE" "Percona PSMDB operator" && return 0
  log "Installing Percona PSMDB operator"
  helm_upgrade_install_with_retry psmdb-operator "$PSMDB_NAMESPACE" percona/psmdb-operator \
    --create-namespace \
    --version "$PSMDB_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install Percona PSMDB operator"
  ok "Percona PSMDB installed in namespace $PSMDB_NAMESPACE"
}

install_pxc() {
  skip_if_deployed pxc-operator "$PXC_NAMESPACE" "Percona PXC operator" && return 0
  log "Installing Percona PXC operator"
  helm_upgrade_install_with_retry pxc-operator "$PXC_NAMESPACE" percona/pxc-operator \
    --create-namespace \
    --version "$PXC_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install Percona PXC operator"
  ok "Percona PXC installed in namespace $PXC_NAMESPACE"
}

install_redis_operator() {
  if skip_if_deployed redis-operator "$REDIS_NAMESPACE" "Redis operator"; then
    return 0
  fi
  cleanup_pending_release redis-operator "$REDIS_NAMESPACE"
  log "Installing OpsTree Redis operator"
  helm_upgrade_install_with_retry redis-operator "$REDIS_NAMESPACE" ot-helm/redis-operator \
    --create-namespace \
    --version "$REDIS_OPERATOR_VERSION" \
    --set "featureGates.GenerateConfigInInitContainer=true" \
    --set "resources.requests.cpu=$REDIS_OPERATOR_REQUEST_CPU" \
    --set "resources.requests.memory=$REDIS_OPERATOR_REQUEST_MEMORY" \
    --set "resources.limits.cpu=$REDIS_OPERATOR_LIMIT_CPU" \
    --set "resources.limits.memory=$REDIS_OPERATOR_LIMIT_MEMORY" \
    --wait --timeout "$REDIS_OPERATOR_TIMEOUT" \
    || die "Failed to install Redis operator"
  ok "Redis operator installed in namespace $REDIS_NAMESPACE"
}

ensure_cert_manager() {
  if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    ok "cert-manager already present"
    return 0
  fi

  log "Installing cert-manager (required by K8ssandra)"
  helm_upgrade_install_with_retry cert-manager "$CERT_MANAGER_NAMESPACE" jetstack/cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 10m \
    || die "Failed to install cert-manager"
  ok "cert-manager installed in namespace $CERT_MANAGER_NAMESPACE"
}

install_k8ssandra() {
  ensure_cert_manager
  skip_if_deployed k8ssandra-operator "$K8SSANDRA_NAMESPACE" "K8ssandra operator" && return 0
  log "Installing K8ssandra operator"
  helm_upgrade_install_with_retry k8ssandra-operator "$K8SSANDRA_NAMESPACE" k8ssandra/k8ssandra-operator \
    --create-namespace \
    --version "$K8SSANDRA_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install K8ssandra operator"
  ok "K8ssandra operator installed in namespace $K8SSANDRA_NAMESPACE"
}

usage() {
  cat <<'EOF'
Usage:
  ./install-operators.sh repos
  ./install-operators.sh all
  ./install-operators.sh all postgresql mongodb
  ./install-operators.sh cnpg
  ./install-operators.sh psmdb
  ./install-operators.sh pxc
  ./install-operators.sh redis
  ./install-operators.sh k8ssandra

Examples:
  ./install-operators.sh all
  OPERATORS=postgresql,mongodb,redis ./install-operators.sh all
  ./install-operators.sh all mysql cassandra
  ./install-operators.sh cnpg
  NAMESPACE=databases ./install-operators.sh psmdb
EOF
}

main() {
  require_bin helm
  require_bin kubectl

  local cmd="${1:-all}"
  shift || true

  case "$cmd" in
    repos)
      repos
      ;;
    all)
      local enabled
      repos
      enabled="$(requested_databases "$@")"
      info_file="${VALUES_FILE}"
      if [ "$#" -gt 0 ]; then
        log "Installing requested operators: $*"
      elif [ -n "${OPERATORS:-}" ]; then
        log "Installing requested operators from OPERATORS: ${OPERATORS}"
      else
        log "Installing all database operators from $info_file"
      fi
      for db in $enabled; do
        case "$db" in
          postgresql) install_cnpg ;;
          mongodb) install_psmdb ;;
          mysql) install_pxc ;;
          redis) install_redis_operator ;;
          cassandra) install_k8ssandra ;;
          *) die "Unknown database operator requested: $db" ;;
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
