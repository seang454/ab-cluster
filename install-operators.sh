#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-databases}"
VALUES_FILE="${VALUES_FILE:-./db-cluster/values.yaml}"
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
REDIS_NAMESPACE="${REDIS_NAMESPACE:-database-operators}"
PXC_NAMESPACE="${PXC_NAMESPACE:-database-operators}"
PSMDB_NAMESPACE="${PSMDB_NAMESPACE:-database-operators}"
K8SSANDRA_NAMESPACE="${K8SSANDRA_NAMESPACE:-database-operators}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"

CNPG_VERSION="${CNPG_VERSION:-0.21.0}"
PSMDB_VERSION="${PSMDB_VERSION:-1.22.0}"
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

deployment_ready() {
  local namespace="$1"
  local deployment="$2"
  local ready replicas

  ready="$(
    kubectl get deployment "$deployment" -n "$namespace" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
  )"
  replicas="$(
    kubectl get deployment "$deployment" -n "$namespace" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || true
  )"

  [ -n "$ready" ] && [ "$ready" != "0" ] && [ "$ready" = "${replicas:-}" ]
}

crd_present() {
  local crd="$1"
  kubectl get crd "$crd" >/dev/null 2>&1
}

operator_release_healthy() {
  local release="$1"
  local namespace="$2"
  local label="$3"
  local deployment="$4"
  shift 4
  local crd

  if ! skip_if_deployed "$release" "$namespace" "$label" >/dev/null; then
    return 1
  fi

  if ! deployment_ready "$namespace" "$deployment"; then
    return 1
  fi

  for crd in "$@"; do
    [ -n "$crd" ] || continue
    if ! crd_present "$crd"; then
      return 1
    fi
  done

  ok "$label already installed and healthy in namespace $namespace; skipping"
  return 0
}

remove_release_if_exists() {
  local release="$1"
  local namespace="$2"

  if helm_release_exists "$release" "$namespace"; then
    log "Removing stale Helm release $release from namespace $namespace"
    helm uninstall "$release" -n "$namespace" >/dev/null 2>&1 || true
    ok "Removed stale release state for $release"
  fi
}

helm_release_exists() {
  local release="$1"
  local namespace="$2"

  helm status "$release" -n "$namespace" >/dev/null 2>&1
}

detect_redis_install_namespace() {
  local target_namespace="$1"
  local legacy_namespace="databases"
  local release="redis-operator"
  local current_owner_namespace

  if helm_release_exists "$release" "$target_namespace"; then
    printf '%s\n' "$target_namespace"
    return 0
  fi

  if [ "$target_namespace" != "$legacy_namespace" ] && helm_release_exists "$release" "$legacy_namespace"; then
    echo "    Found existing Redis operator Helm release in legacy namespace $legacy_namespace; reusing it" >&2
    printf '%s\n' "$legacy_namespace"
    return 0
  fi

  current_owner_namespace="$(
    kubectl get clusterrole "$release" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' \
      2>/dev/null || true
  )"

  if [ -n "$current_owner_namespace" ] && [ "$current_owner_namespace" != "$target_namespace" ]; then
    if helm_release_exists "$release" "$current_owner_namespace"; then
      echo "    Found existing Redis operator ClusterRole owned by Helm release namespace $current_owner_namespace; reusing it" >&2
      printf '%s\n' "$current_owner_namespace"
      return 0
    fi

    die "Redis operator ClusterRole is still owned by Helm namespace $current_owner_namespace, but no matching Helm release was found there. Remove the stale redis-operator resources or reinstall using REDIS_NAMESPACE=$current_owner_namespace."
  fi

  printf '%s\n' "$target_namespace"
}

detect_install_namespace_from_clusterrole() {
  local release="$1"
  local target_namespace="$2"
  local clusterrole_name="$3"
  local owner_var_name="$4"
  local display_name="$5"
  local legacy_namespace="databases"
  local current_owner_namespace

  if helm_release_exists "$release" "$target_namespace"; then
    printf '%s\n' "$target_namespace"
    return 0
  fi

  if [ "$target_namespace" != "$legacy_namespace" ] && helm_release_exists "$release" "$legacy_namespace"; then
    echo "    Found existing $display_name Helm release in legacy namespace $legacy_namespace; reusing it" >&2
    printf '%s\n' "$legacy_namespace"
    return 0
  fi

  current_owner_namespace="$(
    kubectl get clusterrole "$clusterrole_name" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' \
      2>/dev/null || true
  )"

  if [ -n "$current_owner_namespace" ] && [ "$current_owner_namespace" != "$target_namespace" ]; then
    if helm_release_exists "$release" "$current_owner_namespace"; then
      echo "    Found existing $display_name ClusterRole owned by Helm release namespace $current_owner_namespace; reusing it" >&2
      printf '%s\n' "$current_owner_namespace"
      return 0
    fi

    die "$display_name ClusterRole is still owned by Helm namespace $current_owner_namespace, but no matching Helm release was found there. Remove the stale $release resources or reinstall using $owner_var_name=$current_owner_namespace."
  fi

  printf '%s\n' "$target_namespace"
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
  if operator_release_healthy \
    cnpg "$CNPG_NAMESPACE" "CloudNativePG operator" "cnpg-cloudnative-pg" \
    clusters.postgresql.cnpg.io poolers.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io; then
    return 0
  fi
  remove_release_if_exists cnpg "$CNPG_NAMESPACE"
  log "Installing CloudNativePG operator"
  helm_upgrade_install_with_retry cnpg "$CNPG_NAMESPACE" cnpg/cloudnative-pg \
    --create-namespace \
    --version "$CNPG_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install CloudNativePG operator"
  ok "CloudNativePG installed in namespace $CNPG_NAMESPACE"
}

install_psmdb() {
  if operator_release_healthy \
    psmdb-operator "$PSMDB_NAMESPACE" "Percona PSMDB operator" "psmdb-operator" \
    perconaservermongodbs.psmdb.percona.com; then
    return 0
  fi
  remove_release_if_exists psmdb-operator "$PSMDB_NAMESPACE"
  log "Installing Percona PSMDB operator"
  helm_upgrade_install_with_retry psmdb-operator "$PSMDB_NAMESPACE" percona/psmdb-operator \
    --create-namespace \
    --version "$PSMDB_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install Percona PSMDB operator"
  ok "Percona PSMDB installed in namespace $PSMDB_NAMESPACE"
}

install_pxc() {
  if operator_release_healthy \
    pxc-operator "$PXC_NAMESPACE" "Percona PXC operator" "pxc-operator" \
    perconaxtradbclusters.pxc.percona.com; then
    return 0
  fi
  remove_release_if_exists pxc-operator "$PXC_NAMESPACE"
  log "Installing Percona PXC operator"
  helm_upgrade_install_with_retry pxc-operator "$PXC_NAMESPACE" percona/pxc-operator \
    --create-namespace \
    --version "$PXC_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install Percona PXC operator"
  ok "Percona PXC installed in namespace $PXC_NAMESPACE"
}

install_redis_operator() {
  local install_namespace

  install_namespace="$(detect_redis_install_namespace "$REDIS_NAMESPACE")"

  if [ "$install_namespace" != "$REDIS_NAMESPACE" ]; then
    echo "    Requested Redis operator namespace $REDIS_NAMESPACE conflicts with existing ownership; using $install_namespace"
  fi

  if operator_release_healthy \
    redis-operator "$install_namespace" "Redis operator" "redis-operator" \
    redis.redis.redis.opstreelabs.in; then
    return 0
  fi
  remove_release_if_exists redis-operator "$install_namespace"
  cleanup_pending_release redis-operator "$install_namespace"
  log "Installing OpsTree Redis operator"
  helm_upgrade_install_with_retry redis-operator "$install_namespace" ot-helm/redis-operator \
    --create-namespace \
    --version "$REDIS_OPERATOR_VERSION" \
    --set "featureGates.GenerateConfigInInitContainer=true" \
    --set "resources.requests.cpu=$REDIS_OPERATOR_REQUEST_CPU" \
    --set "resources.requests.memory=$REDIS_OPERATOR_REQUEST_MEMORY" \
    --set "resources.limits.cpu=$REDIS_OPERATOR_LIMIT_CPU" \
    --set "resources.limits.memory=$REDIS_OPERATOR_LIMIT_MEMORY" \
    --wait --timeout "$REDIS_OPERATOR_TIMEOUT" \
    || die "Failed to install Redis operator"
  ok "Redis operator installed in namespace $install_namespace"
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
  local install_namespace

  ensure_cert_manager
  install_namespace="$(
    detect_install_namespace_from_clusterrole \
      "k8ssandra-operator" \
      "$K8SSANDRA_NAMESPACE" \
      "k8ssandra-operator-cass-operator-cr" \
      "K8SSANDRA_NAMESPACE" \
      "K8ssandra operator"
  )"

  if [ "$install_namespace" != "$K8SSANDRA_NAMESPACE" ]; then
    echo "    Requested K8ssandra operator namespace $K8SSANDRA_NAMESPACE conflicts with existing ownership; using $install_namespace"
  fi

  if operator_release_healthy \
    k8ssandra-operator "$install_namespace" "K8ssandra operator" "k8ssandra-operator" \
    k8ssandraclusters.k8ssandra.io; then
    return 0
  fi
  remove_release_if_exists k8ssandra-operator "$install_namespace"
  log "Installing K8ssandra operator"
  cleanup_pending_release k8ssandra-operator "$install_namespace"
  helm_upgrade_install_with_retry k8ssandra-operator "$install_namespace" k8ssandra/k8ssandra-operator \
    --create-namespace \
    --version "$K8SSANDRA_VERSION" \
    --wait --timeout 5m \
    || die "Failed to install K8ssandra operator"
  ok "K8ssandra operator installed in namespace $install_namespace"
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
