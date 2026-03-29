#!/usr/bin/env bash
# =============================================================================
# db-cluster v4 — Setup Script
# =============================================================================
# USAGE:
#   ./setup.sh             → full setup
#   ./setup.sh teardown    → delete everything
#   ./setup.sh status      → show pods
#   ./setup.sh <step>      → run one step
#
# STEPS (in order): preflight, repos, longhorn, deps, vault_transit,
#                   vault_install, vault_init, install_operators, deploy
#
# Create .env file with passwords before running:
#   PG_PASS=secret  MONGO_PASS=secret  MYSQL_PASS=secret
#   REDIS_PASS=secret  CASS_PASS=secret
# =============================================================================

RELEASE="my-db"
NAMESPACE="databases"
VAULT_NS="vault"
TRANSIT_NS="vault-transit"
CHART_DIR="./db-cluster"
LONGHORN_REPLICA_COUNT="${LONGHORN_REPLICA_COUNT:-1}"
OPERATOR_INSTALLER="${OPERATOR_INSTALLER:-./install-operators.sh}"
VALUES_FILE="${VALUES_FILE:-}"

[ -f .env ] && { set -a; source .env; set +a; }

log()  { echo ""; echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
info() { echo "    $*"; }
die()  { echo ""; echo "ERROR: $*"; exit 1; }

KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-15s}"

# Wait until a command succeeds, with retries
retry() {
    local MAX="$1"; local WAIT="$2"; shift 2
    for i in $(seq 1 "$MAX"); do
        "$@" 2>/dev/null && return 0
        info "Attempt $i/$MAX failed, waiting ${WAIT}s..."
        sleep "$WAIT"
    done
    return 1
}

values_args() {
    if [ -n "$VALUES_FILE" ]; then
        [ -f "$VALUES_FILE" ] || die "VALUES_FILE not found: $VALUES_FILE"
        printf -- '-f\n%s\n' "$VALUES_FILE"
    fi
}

schedulable_worker_report() {
    kubectl get nodes -o json > /tmp/setup_nodes.json 2>/dev/null || return 1
    kubectl get pods -A -o json > /tmp/setup_pods.json 2>/dev/null || return 1

    python3 - /tmp/setup_nodes.json /tmp/setup_pods.json <<'PY'
import json
import math
import sys

nodes = json.load(open(sys.argv[1], "r", encoding="utf-8"))
pods = json.load(open(sys.argv[2], "r", encoding="utf-8"))

def cpu_to_millis(value):
    if not value:
        return 0
    if isinstance(value, (int, float)):
        return int(float(value) * 1000)
    value = str(value)
    return int(value[:-1]) if value.endswith("m") else int(float(value) * 1000)

def mem_to_mib(value):
    if not value:
        return 0
    value = str(value)
    units = {
        "Ki": 1 / 1024,
        "Mi": 1,
        "Gi": 1024,
        "Ti": 1024 * 1024,
        "K": 1000 / (1024 * 1024),
        "M": 1000 * 1000 / (1024 * 1024),
        "G": 1000 * 1000 * 1000 / (1024 * 1024),
    }
    for suffix, factor in units.items():
        if value.endswith(suffix):
            return int(math.ceil(float(value[:-len(suffix)]) * factor))
    return int(math.ceil(float(value) / (1024 * 1024)))

eligible = {}
for item in nodes["items"]:
    name = item["metadata"]["name"]
    taints = item.get("spec", {}).get("taints", []) or []
    if taints:
        continue
    alloc = item["status"]["allocatable"]
    eligible[name] = {
        "alloc_cpu_m": cpu_to_millis(alloc.get("cpu")),
        "alloc_mem_mib": mem_to_mib(alloc.get("memory")),
        "req_cpu_m": 0,
        "req_mem_mib": 0,
    }

for pod in pods["items"]:
    node_name = pod.get("spec", {}).get("nodeName")
    if node_name not in eligible:
        continue
    phase = pod.get("status", {}).get("phase")
    if phase in {"Succeeded", "Failed"}:
        continue
    for container in pod.get("spec", {}).get("containers", []):
        req = container.get("resources", {}).get("requests", {})
        eligible[node_name]["req_cpu_m"] += cpu_to_millis(req.get("cpu"))
        eligible[node_name]["req_mem_mib"] += mem_to_mib(req.get("memory"))

total_alloc_cpu = total_alloc_mem = total_req_cpu = total_req_mem = 0
for name in sorted(eligible):
    item = eligible[name]
    avail_cpu = item["alloc_cpu_m"] - item["req_cpu_m"]
    avail_mem = item["alloc_mem_mib"] - item["req_mem_mib"]
    total_alloc_cpu += item["alloc_cpu_m"]
    total_alloc_mem += item["alloc_mem_mib"]
    total_req_cpu += item["req_cpu_m"]
    total_req_mem += item["req_mem_mib"]
    print(f"{name}\t{item['alloc_cpu_m']}\t{item['alloc_mem_mib']}\t{item['req_cpu_m']}\t{item['req_mem_mib']}\t{avail_cpu}\t{avail_mem}")

print(f"TOTAL\t{total_alloc_cpu}\t{total_alloc_mem}\t{total_req_cpu}\t{total_req_mem}\t{total_alloc_cpu-total_req_cpu}\t{total_alloc_mem-total_req_mem}")
PY
}

required_profile_resources() {
    local PROFILE_FILE
    PROFILE_FILE="${VALUES_FILE:-$CHART_DIR/values.yaml}"
    [ -f "$PROFILE_FILE" ] || die "Values file not found: $PROFILE_FILE"

    python3 - "$PROFILE_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path, "r", encoding="utf-8").read().splitlines()
dbs = ["postgresql", "mongodb", "mysql", "redis", "cassandra"]
data = {db: {"enabled": False, "instances": 0, "cpu_m": 0, "mem_mib": 0} for db in dbs}

section = None
in_cluster = False
in_resources = False
in_requests = False

def cpu_to_millis(value: str) -> int:
    value = value.strip().strip('"').strip("'")
    if not value:
        return 0
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)

def mem_to_mib(value: str) -> int:
    value = value.strip().strip('"').strip("'")
    if not value:
        return 0
    units = {
        "Ki": 1 / 1024,
        "Mi": 1,
        "Gi": 1024,
        "Ti": 1024 * 1024,
        "K": 1000 / (1024 * 1024),
        "M": 1000 * 1000 / (1024 * 1024),
        "G": 1000 * 1000 * 1000 / (1024 * 1024),
    }
    for suffix, factor in units.items():
        if value.endswith(suffix):
            return int(float(value[:-len(suffix)]) * factor)
    return int(float(value) / (1024 * 1024))

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue

    indent = len(raw) - len(raw.lstrip(" "))
    line = raw.strip()

    m = re.match(r"([A-Za-z0-9_]+):\s*(.*)$", line)
    if indent == 0 and m and m.group(1) in dbs:
        section = m.group(1)
        in_cluster = False
        in_resources = False
        in_requests = False
        continue

    if section is None:
        continue

    if indent <= 1:
        in_cluster = False
        in_resources = False
        in_requests = False

    if indent == 2 and line.startswith("enabled:"):
        data[section]["enabled"] = line.split(":", 1)[1].strip().lower() == "true"
        continue

    if indent == 2 and line.startswith("cluster:"):
        in_cluster = True
        in_resources = False
        in_requests = False
        continue

    if indent <= 2 and not line.startswith("cluster:"):
        in_cluster = False
        in_resources = False
        in_requests = False

    if not in_cluster:
        continue

    if indent == 4 and line.startswith("instances:"):
        data[section]["instances"] = int(line.split(":", 1)[1].strip().strip('"').strip("'"))
        continue

    if indent == 4 and line.startswith("resources:"):
        in_resources = True
        in_requests = False
        continue

    if indent <= 4 and not line.startswith("resources:"):
        in_resources = False
        in_requests = False

    if in_resources and indent == 6 and line.startswith("requests:"):
        in_requests = True
        continue

    if in_resources and indent <= 6 and not line.startswith("requests:"):
        in_requests = False

    if in_requests and indent == 8 and line.startswith("cpu:"):
        data[section]["cpu_m"] = cpu_to_millis(line.split(":", 1)[1])
    if in_requests and indent == 8 and line.startswith("memory:"):
        data[section]["mem_mib"] = mem_to_mib(line.split(":", 1)[1])

total_cpu = 0
total_mem = 0
for db in dbs:
    if data[db]["enabled"]:
        total_cpu += data[db]["instances"] * data[db]["cpu_m"]
        total_mem += data[db]["instances"] * data[db]["mem_mib"]

print(f"{total_cpu}\t{total_mem}")
PY
}

profile_schedulability_report() {
    local PROFILE_FILE
    PROFILE_FILE="${VALUES_FILE:-$CHART_DIR/values.yaml}"
    [ -f "$PROFILE_FILE" ] || die "Values file not found: $PROFILE_FILE"

    kubectl get nodes -o json > /tmp/setup_nodes_sched.json 2>/dev/null || return 1
    kubectl get pods -A -o json > /tmp/setup_pods_sched.json 2>/dev/null || return 1

    python3 - "$PROFILE_FILE" /tmp/setup_nodes_sched.json /tmp/setup_pods_sched.json <<'PY'
import json
import math
import re
import sys

profile_path, nodes_path, pods_path = sys.argv[1:4]
lines = open(profile_path, "r", encoding="utf-8").read().splitlines()
nodes = json.load(open(nodes_path, "r", encoding="utf-8"))
pods = json.load(open(pods_path, "r", encoding="utf-8"))

dbs = ["postgresql", "mongodb", "mysql", "redis", "cassandra"]
data = {
    db: {
        "enabled": False,
        "instances": 0,
        "cpu_m": 0,
        "mem_mib": 0,
        "config_builder_cpu_m": 0,
        "config_builder_mem_mib": 0,
        "system_logger_cpu_m": 0,
        "system_logger_mem_mib": 0,
    }
    for db in dbs
}

section = None
path = []

def cpu_to_millis(value):
    if value is None:
        return 0
    value = str(value).strip().strip('"').strip("'")
    if not value:
        return 0
    return int(value[:-1]) if value.endswith("m") else int(float(value) * 1000)

def mem_to_mib(value):
    if value is None:
        return 0
    value = str(value).strip().strip('"').strip("'")
    if not value:
        return 0
    units = {
        "Ki": 1 / 1024,
        "Mi": 1,
        "Gi": 1024,
        "Ti": 1024 * 1024,
        "K": 1000 / (1024 * 1024),
        "M": 1000 * 1000 / (1024 * 1024),
        "G": 1000 * 1000 * 1000 / (1024 * 1024),
    }
    for suffix, factor in units.items():
        if value.endswith(suffix):
            return int(math.ceil(float(value[:-len(suffix)]) * factor))
    return int(math.ceil(float(value) / (1024 * 1024)))

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    indent = len(raw) - len(raw.lstrip(" "))
    level = indent // 2
    line = raw.strip()
    m = re.match(r"([A-Za-z0-9_]+):\s*(.*)$", line)
    if not m:
        continue
    key, value = m.group(1), m.group(2)
    path = path[:level]
    path.append(key)

    if level == 0 and key in dbs:
        section = key
    if section != path[0]:
        continue

    joined = ".".join(path)
    if joined == f"{section}.enabled":
        data[section]["enabled"] = value.strip().lower() == "true"
    elif joined == f"{section}.cluster.instances":
        data[section]["instances"] = int(value.strip().strip('"').strip("'"))
    elif joined == f"{section}.cluster.resources.requests.cpu":
        data[section]["cpu_m"] = cpu_to_millis(value)
    elif joined == f"{section}.cluster.resources.requests.memory":
        data[section]["mem_mib"] = mem_to_mib(value)
    elif joined == f"{section}.cluster.configBuilderResources.requests.cpu":
        data[section]["config_builder_cpu_m"] = cpu_to_millis(value)
    elif joined == f"{section}.cluster.configBuilderResources.requests.memory":
        data[section]["config_builder_mem_mib"] = mem_to_mib(value)
    elif joined == f"{section}.cluster.systemLoggerResources.requests.cpu":
        data[section]["system_logger_cpu_m"] = cpu_to_millis(value)
    elif joined == f"{section}.cluster.systemLoggerResources.requests.memory":
        data[section]["system_logger_mem_mib"] = mem_to_mib(value)

eligible = {}
for item in nodes["items"]:
    name = item["metadata"]["name"]
    taints = item.get("spec", {}).get("taints", []) or []
    if taints:
        continue
    alloc = item["status"]["allocatable"]
    eligible[name] = {
        "avail_cpu_m": cpu_to_millis(alloc.get("cpu")),
        "avail_mem_mib": mem_to_mib(alloc.get("memory")),
    }

for pod in pods["items"]:
    node_name = pod.get("spec", {}).get("nodeName")
    if node_name not in eligible:
        continue
    phase = pod.get("status", {}).get("phase")
    if phase in {"Succeeded", "Failed"}:
        continue
    for container in pod.get("spec", {}).get("containers", []):
        req = container.get("resources", {}).get("requests", {})
        eligible[node_name]["avail_cpu_m"] -= cpu_to_millis(req.get("cpu"))
        eligible[node_name]["avail_mem_mib"] -= mem_to_mib(req.get("memory"))

issues = []
node_availability = [
    (name, item["avail_cpu_m"], item["avail_mem_mib"])
    for name, item in sorted(eligible.items())
]

for db, cfg in data.items():
    if not cfg["enabled"] or cfg["instances"] <= 0:
        continue

    if db == "cassandra":
        if cfg["config_builder_cpu_m"] == 0:
            cfg["config_builder_cpu_m"] = 1000
        if cfg["config_builder_mem_mib"] == 0:
            cfg["config_builder_mem_mib"] = 256
        if cfg["system_logger_cpu_m"] == 0:
            cfg["system_logger_cpu_m"] = 100
        if cfg["system_logger_mem_mib"] == 0:
            cfg["system_logger_mem_mib"] = 64
        steady_cpu = cfg["cpu_m"] + cfg["system_logger_cpu_m"]
        steady_mem = cfg["mem_mib"] + cfg["system_logger_mem_mib"]
        init_cpu = cfg["config_builder_cpu_m"]
        init_mem = cfg["config_builder_mem_mib"]
        pod_cpu = max(steady_cpu, init_cpu)
        pod_mem = max(steady_mem, init_mem)
        needed = cfg["instances"]
        fitting_nodes = [
            name for name, avail_cpu, avail_mem in node_availability
            if avail_cpu >= pod_cpu and avail_mem >= pod_mem
        ]
        if len(fitting_nodes) < needed:
            issues.append(
                f"cassandra\tneed {needed} nodes with >= {pod_cpu}m CPU and >= {pod_mem}Mi memory free per pod, only {len(fitting_nodes)} fit: {','.join(fitting_nodes) or '-'}"
            )

if issues:
    print("\n".join(issues))
PY
}

enabled_databases() {
    local PROFILE_FILE
    PROFILE_FILE="${VALUES_FILE:-$CHART_DIR/values.yaml}"
    [ -f "$PROFILE_FILE" ] || die "Values file not found: $PROFILE_FILE"

    python3 - "$PROFILE_FILE" <<'PY'
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

prune_disabled_database_operators() {
    local ENABLED
    ENABLED=" $(enabled_databases) "

    prune_operator() {
        local DB="$1"
        local RELEASE_NAME="$2"
        local RELEASE_NS="$3"
        if [[ "$ENABLED" == *" $DB "* ]]; then
            return 0
        fi
        if helm status "$RELEASE_NAME" -n "$RELEASE_NS" >/dev/null 2>&1; then
            info "Removing disabled $DB operator release: $RELEASE_NAME"
            helm uninstall "$RELEASE_NAME" -n "$RELEASE_NS" >/dev/null \
                || die "Failed to uninstall operator release $RELEASE_NAME from namespace $RELEASE_NS"
            ok "$DB operator removed"
        fi
    }

    prune_operator postgresql cnpg cnpg-system
    prune_operator mongodb psmdb-operator "$NAMESPACE"
    prune_operator mysql pxc-operator "$NAMESPACE"
    prune_operator redis redis-operator "$NAMESPACE"
    prune_operator cassandra k8ssandra-operator "$NAMESPACE"
}

preflight() {
    log "[0/9] Running preflight checks..."
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
    command -v helm >/dev/null 2>&1 || die "helm not found"
    kubectl version --client >/dev/null 2>&1 || die "kubectl is not working"
    kubectl get nodes >/dev/null 2>&1 || die "Cannot reach the Kubernetes API"

    local PROFILE_LABEL REQUIRED_CPU REQUIRED_MEM
    local TOTAL_ALLOC_CPU TOTAL_ALLOC_MEM TOTAL_REQ_CPU TOTAL_REQ_MEM TOTAL_AVAIL_CPU TOTAL_AVAIL_MEM
    local RESOURCES_LINE SCHED_ISSUES
    PROFILE_LABEL="${VALUES_FILE:-$CHART_DIR/values.yaml}"
    IFS=$'\t' read -r REQUIRED_CPU REQUIRED_MEM <<<"$(required_profile_resources)"
    RESOURCES_LINE="$(schedulable_worker_report)" || die "Failed to inspect schedulable node resources"

    info "Selected values profile: $PROFILE_LABEL"
    echo "    Schedulable untainted nodes:"
    while IFS=$'\t' read -r NODE ALLOC_CPU ALLOC_MEM REQ_CPU REQ_MEM AVAIL_CPU AVAIL_MEM; do
        [ -n "$NODE" ] || continue
        if [ "$NODE" = "TOTAL" ]; then
            TOTAL_ALLOC_CPU="$ALLOC_CPU"
            TOTAL_ALLOC_MEM="$ALLOC_MEM"
            TOTAL_REQ_CPU="$REQ_CPU"
            TOTAL_REQ_MEM="$REQ_MEM"
            TOTAL_AVAIL_CPU="$AVAIL_CPU"
            TOTAL_AVAIL_MEM="$AVAIL_MEM"
            continue
        fi
        echo "    - $NODE: alloc=${ALLOC_CPU}m/${ALLOC_MEM}Mi, current-used=${REQ_CPU}m/${REQ_MEM}Mi, available=${AVAIL_CPU}m/${AVAIL_MEM}Mi"
    done <<< "$RESOURCES_LINE"

    info "Schedulable node totals: alloc=${TOTAL_ALLOC_CPU}m/${TOTAL_ALLOC_MEM}Mi, current-used=${TOTAL_REQ_CPU}m/${TOTAL_REQ_MEM}Mi, available=${TOTAL_AVAIL_CPU}m/${TOTAL_AVAIL_MEM}Mi"
    info "Project requested resources from values file: cpu=${REQUIRED_CPU}m memory=${REQUIRED_MEM}Mi"

    if [ "${TOTAL_AVAIL_CPU:-0}" -lt "$REQUIRED_CPU" ] || [ "${TOTAL_AVAIL_MEM:-0}" -lt "$REQUIRED_MEM" ]; then
        die "Cluster does not have enough available resources on schedulable untainted nodes for this profile."
    fi

    SCHED_ISSUES="$(profile_schedulability_report)" || die "Failed to evaluate per-node schedulability"
    if [ -n "$SCHED_ISSUES" ]; then
        while IFS= read -r issue; do
            [ -n "$issue" ] || continue
            info "Scheduling check: $issue"
        done <<< "$SCHED_ISSUES"
        die "Profile passes total-capacity checks but would not schedule cleanly on current nodes."
    fi

    ok "Preflight checks passed"
}

wait_for_pods_ready() {
    local NS="$1"; local SELECTOR="$2"; local MAX="$3"; local WAIT="$4"; local LABEL="$5"
    local TOTAL READY
    for i in $(seq 1 "$MAX"); do
        TOTAL=$(kubectl get pods -n "$NS" -l "$SELECTOR" --no-headers 2>/dev/null \
            | awk '$3 != "Completed" && $3 != "Succeeded" {c++} END {print c+0}')
        READY=$(kubectl get pods -n "$NS" -l "$SELECTOR" --no-headers 2>/dev/null \
            | awk '$3 != "Completed" && $3 != "Succeeded" {split($2,a,"/"); if (a[1] == a[2]) c++} END {print c+0}')
        info "[$i/$MAX] ${LABEL}: ${READY:-0}/${TOTAL:-0} ready"
        if [ "${TOTAL:-0}" -gt 0 ] && [ "${READY:-0}" -eq "${TOTAL:-0}" ]; then
            return 0
        fi
        sleep "$WAIT"
    done
    kubectl get pods -n "$NS" -l "$SELECTOR" 2>/dev/null || true
    return 1
}

select_vault_pod() {
    kubectl get pods -n "$VAULT_NS" --no-headers 2>/dev/null \
        | awk '$1 ~ /^vault-[0-2]$/ && $3 == "Running" {print $1; exit}'
}

# =============================================================================
# STEP 1 — REPOS
# =============================================================================
repos() {
    log "[1/8] Adding Helm repositories..."
    helm repo add hashicorp   https://helm.releases.hashicorp.com        2>/dev/null || true
    helm repo add cnpg        https://cloudnative-pg.github.io/charts    2>/dev/null || true
    helm repo add percona     https://percona.github.io/percona-helm-charts/ 2>/dev/null || true
    helm repo add ot-helm     https://ot-container-kit.github.io/helm-charts/ 2>/dev/null || true
    helm repo add k8ssandra   https://helm.k8ssandra.io/stable           2>/dev/null || true
    helm repo add ext-secrets https://charts.external-secrets.io         2>/dev/null || true
    helm repo add longhorn    https://charts.longhorn.io                 2>/dev/null || true
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update
    ok "Repos ready"
}

ingress_nginx() {
    log "[optional] Installing ingress-nginx controller..."
    if helm status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then
        info "ingress-nginx already installed — reconciling desired config"
    elif kubectl get ingressclass nginx >/dev/null 2>&1; then
        ok "IngressClass nginx already exists — skipping"
        return 0
    fi

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.kind=DaemonSet \
        --set controller.hostNetwork=true \
        --set controller.dnsPolicy=ClusterFirstWithHostNet \
        --set controller.service.type=ClusterIP \
        --set controller.ingressClassResource.name=nginx \
        --set controller.ingressClassResource.controllerValue=k8s.io/ingress-nginx \
        --set controller.ingressClass=nginx \
        --set controller.ingressClassResource.default=false \
        --wait --timeout 10m \
        || die "ingress-nginx install failed"

    ok "ingress-nginx ready"
}

# =============================================================================
# STEP 2 — LONGHORN
# =============================================================================
longhorn() {
    log "[2/8] Installing Longhorn..."

    # Already fully running? (manager + csi-attacher both present)
    MGR=$(kubectl get pods -n longhorn-system 2>/dev/null         | grep longhorn-manager | grep Running | wc -l || true)
    CSI=$(kubectl get pods -n longhorn-system 2>/dev/null         | grep csi-attacher | grep Running | wc -l || true)
    if [ "${MGR:-0}" -ge "1" ] && [ "${CSI:-0}" -ge "1" ]; then
        ok "Longhorn already running — skipping"
        kubectl get pods -n longhorn-system | grep -v Completed | head -6
        return 0
    fi

    # Clean up any broken previous install that blocks reinstall.
    # Helm release metadata can remain even when the namespace is already gone.
    LONGHORN_HELM_STATE="$(helm status longhorn -n longhorn-system 2>/dev/null | awk '/^STATUS:/ {print $2}' || true)"
    if [ -n "$LONGHORN_HELM_STATE" ]; then
        info "Found existing Helm release state for longhorn: $LONGHORN_HELM_STATE"
        helm uninstall longhorn -n longhorn-system --no-hooks 2>/dev/null || true
        for secret in $(kubectl get secret -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null \
            | awk '$2 ~ /^sh\\.helm\\.release\\.v1\\.longhorn\\./ {print $1"/"$2}'); do
            ns="${secret%%/*}"; name="${secret##*/}"
            kubectl delete secret "$name" -n "$ns" --ignore-not-found 2>/dev/null || true
        done
    fi

    # Clean up any broken previous install that blocks reinstall.
    if kubectl get namespace longhorn-system &>/dev/null; then
        info "Cleaning up previous Longhorn install..."
        helm uninstall longhorn -n longhorn-system 2>/dev/null || true
        # Remove finalizers from Longhorn CRs so they delete cleanly
        kubectl get volumes.longhorn.io -n longhorn-system -o name 2>/dev/null             | xargs -I{} kubectl patch {} -n longhorn-system             -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null || true
        kubectl get nodes.longhorn.io -n longhorn-system -o name 2>/dev/null             | xargs -I{} kubectl patch {} -n longhorn-system             -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null || true
        kubectl delete pods --all -n longhorn-system --force --grace-period=0 2>/dev/null || true
        for crd in $(kubectl get crd 2>/dev/null | grep longhorn | awk '"'"'{print $1}'"'"'); do
            kubectl patch crd "$crd"                 -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null || true
        done
        kubectl delete secret -n longhorn-system -l owner=helm 2>/dev/null || true
        kubectl delete namespace longhorn-system --timeout=60s 2>/dev/null || true
        # Force finalize if stuck terminating
        if kubectl get namespace longhorn-system 2>/dev/null | grep -q Terminating; then
            kubectl get namespace longhorn-system -o json                 | python3 -c "import sys,json; d=json.load(sys.stdin); d['"'"'spec'"'"']['"'"'finalizers'"'"']=[]; print(json.dumps(d))"                 | kubectl replace --raw /api/v1/namespaces/longhorn-system/finalize -f - 2>/dev/null || true
        fi
        info "Waiting for longhorn-system namespace to be gone..."
        for i in $(seq 1 20); do
            kubectl get namespace longhorn-system &>/dev/null || break
            sleep 3
        done
    fi

    # Install open-iscsi on all nodes via a privileged DaemonSet init container
    # Uses ubuntu:22.04 for apt, then exits — main container is not needed
    info "Installing open-iscsi on all nodes (Longhorn prerequisite)..."

    # Clean up any previous attempt first
    kubectl delete daemonset longhorn-iscsi-installation -n kube-system 2>/dev/null || true
    sleep 3

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: longhorn-iscsi-installation
  namespace: kube-system
  labels:
    app: longhorn-iscsi-installation
spec:
  selector:
    matchLabels:
      app: longhorn-iscsi-installation
  template:
    metadata:
      labels:
        app: longhorn-iscsi-installation
    spec:
      hostNetwork: true
      hostPID: true
      initContainers:
      - name: install-iscsi
        image: ubuntu:22.04
        command:
        - nsenter
        - --mount=/proc/1/ns/mnt
        - --
        - bash
        - -c
        - |
          apt-get update -qq
          apt-get install -y open-iscsi
          systemctl enable --now iscsid || true
          systemctl disable --now multipathd multipathd.socket || true
          multipath -F || true
          pkill -9 multipathd || true
        securityContext:
          privileged: true
      containers:
      - name: done
        image: ubuntu:22.04
        command: ["sh", "-c", "sleep infinity"]
      tolerations:
      - operator: Exists
EOF

    info "Waiting for iscsi init containers to complete on all nodes (up to 5 min)..."
    for i in $(seq 1 30); do
        # Count nodes where init container has completed (pod Running = init done)
        TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' 
' || echo "0")
        TOTAL="${TOTAL:-0}"
        # Init container Completed means iscsi installed; pod Running means init done
        DONE=$(kubectl get pods -n kube-system -l app=longhorn-iscsi-installation             --no-headers 2>/dev/null | grep -E "Running|Completed" | wc -l | tr -d ' 
' || echo "0")
        DONE="${DONE:-0}"
        info "[$i/30] nodes with iscsi installed: $DONE/$TOTAL"
        if [ "$TOTAL" -gt "0" ] && [ "$DONE" -ge "$TOTAL" ]; then break; fi
        sleep 10
    done

    # Clean up the daemonset — it did its job
    kubectl delete daemonset longhorn-iscsi-installation -n kube-system 2>/dev/null || true
    ok "open-iscsi installed on all nodes"

    # Install Longhorn
    info "Installing Longhorn v1.11.1..."
    helm upgrade --install longhorn longhorn/longhorn         --namespace longhorn-system         --create-namespace         --version 1.11.1 \
        --set "persistence.defaultClassReplicaCount=${LONGHORN_REPLICA_COUNT}" \
        || die "Longhorn Helm install failed"

    info "Waiting for Longhorn to be fully ready (up to 10 min)..."
    local READY=false
    for i in $(seq 1 60); do
        MGR=$(kubectl get pods -n longhorn-system 2>/dev/null             | grep longhorn-manager | grep Running | wc -l || true)
        CSI=$(kubectl get pods -n longhorn-system 2>/dev/null             | grep csi-attacher | grep Running | wc -l || true)
        info "[$i/60] manager=${MGR:-0} csi-attacher=${CSI:-0}"
        if [ "${MGR:-0}" -ge "1" ] && [ "${CSI:-0}" -ge "1" ]; then
            READY=true
            break
        fi
        sleep 10
    done

    [ "$READY" = "true" ] || die "Longhorn did not become ready — check: kubectl get pods -n longhorn-system"
    kubectl get storageclass longhorn 2>/dev/null | grep -q longhorn         || die "Longhorn storageclass not registered yet"
    kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null | grep -qx "$LONGHORN_REPLICA_COUNT" \
        || die "Longhorn storageclass replica count is not $LONGHORN_REPLICA_COUNT"

    ok "Longhorn ready"
    kubectl get pods -n longhorn-system | grep -v Completed
}

# =============================================================================
# STEP 3 — CHART DEPS
# =============================================================================
deps() {
    log "[3/8] Downloading chart dependencies..."
    helm dependency build "$CHART_DIR" || helm dependency update "$CHART_DIR"
    ok "Dependencies ready"
}

# =============================================================================
# STEP 4 — VAULT TRANSIT (auto-unseal authority)
# =============================================================================
vault_transit() {
    log "[4/8] Setting up Transit Vault..."

    kubectl create namespace "$VAULT_NS"    2>/dev/null || true
    kubectl create namespace "$TRANSIT_NS"  2>/dev/null || true

    # Already healthy? Require both the bootstrap token and the running transit pod/service.
    HAVE_TRANSIT_TOKEN=false
    HAVE_TRANSIT_POD=false
    HAVE_TRANSIT_SERVICE=false
    kubectl get secret vault-transit-token -n "$VAULT_NS" >/dev/null 2>&1 && HAVE_TRANSIT_TOKEN=true
    kubectl get pod vault-transit-0 -n "$TRANSIT_NS" >/dev/null 2>&1 && HAVE_TRANSIT_POD=true
    kubectl get svc vault-transit -n "$TRANSIT_NS" >/dev/null 2>&1 && HAVE_TRANSIT_SERVICE=true

    if [ "$HAVE_TRANSIT_TOKEN" = "true" ] && [ "$HAVE_TRANSIT_POD" = "true" ] && [ "$HAVE_TRANSIT_SERVICE" = "true" ]; then
        READY_STATUS=$(kubectl get pod vault-transit-0 -n "$TRANSIT_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$READY_STATUS" = "Running" ]; then
            ok "vault-transit already installed — skipping"
            return 0
        fi
    fi

    # Broken partial state from a previous run needs cleanup before reinstall.
    if helm status vault-transit -n "$TRANSIT_NS" >/dev/null 2>&1 || kubectl get pod vault-transit-0 -n "$TRANSIT_NS" >/dev/null 2>&1; then
        info "Cleaning up broken vault-transit install..."
        helm uninstall vault-transit -n "$TRANSIT_NS" 2>/dev/null || true
        kubectl delete pvc -n "$TRANSIT_NS" --all --force --grace-period=0 --wait=false 2>/dev/null || true
        kubectl delete all -n "$TRANSIT_NS" --all --force --grace-period=0 --wait=false 2>/dev/null || true
        sleep 5
    fi

    info "Installing vault-transit (standalone, Longhorn storage)..."
    helm upgrade --install vault-transit hashicorp/vault \
        --namespace "$TRANSIT_NS" \
        --set "server.standalone.enabled=true" \
        --set "server.ha.enabled=false" \
        --set "server.dataStorage.storageClass=longhorn" \
        --set "server.dataStorage.size=2Gi" \
        --set "injector.enabled=false"

    info "Waiting for vault-transit PVC to bind..."
    for i in $(seq 1 24); do
        BOUND=$(kubectl get pvc -n "$TRANSIT_NS" 2>/dev/null | grep -c "Bound" || true)
        [ "${BOUND:-0}" -ge "1" ] && break
        info "[$i/24] PVC not bound yet, waiting 10s..."
        sleep 10
    done
    kubectl get pvc -n "$TRANSIT_NS" | grep -q "Bound" || die "vault-transit PVC never bound"
    ok "PVC bound"

    info "Waiting for vault-transit-0 to be Running..."
    for i in $(seq 1 24); do
        RUNNING=$(kubectl get pod vault-transit-0 -n "$TRANSIT_NS" 2>/dev/null \
            | grep -c "Running" || true)
        [ "${RUNNING:-0}" -ge "1" ] && break
        info "[$i/24] waiting 10s..."
        sleep 10
    done
    kubectl get pod vault-transit-0 -n "$TRANSIT_NS" 2>/dev/null | grep -q "Running" \
        || die "vault-transit-0 never became Running"
    ok "vault-transit-0 is Running"

    info "Waiting for vault-transit API..."
    for i in $(seq 1 24); do
        STATUS=$(kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
            -- vault status 2>/dev/null || echo "")
        echo "$STATUS" | grep -q "Initialized" && break
        info "[$i/24] waiting 5s..."
        sleep 5
    done

    # Initialize
    INITIALIZED=$(kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
        -- vault status 2>/dev/null | grep "^Initialized" | awk '{print $2}' || echo "false")

    if [ "$INITIALIZED" = "false" ]; then
        info "Initializing vault-transit..."
        kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
            -- vault operator init \
                -key-shares=1 -key-threshold=1 \
                -format=json > vault-transit-init.json \
            || die "vault-transit init failed"

        UNSEAL_KEY=$(python3 -c \
            "import json; print(json.load(open('vault-transit-init.json'))['unseal_keys_b64'][0])")
        ROOT_TOKEN=$(python3 -c \
            "import json; print(json.load(open('vault-transit-init.json'))['root_token'])")

        kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
            -- vault operator unseal "$UNSEAL_KEY" || die "unseal failed"
        ok "vault-transit initialized and unsealed"
    else
        info "Already initialized, reading tokens..."
        [ -f vault-transit-init.json ] || die "vault-transit-init.json missing — cannot continue"
        UNSEAL_KEY=$(python3 -c \
            "import json; print(json.load(open('vault-transit-init.json'))['unseal_keys_b64'][0])")
        ROOT_TOKEN=$(python3 -c \
            "import json; print(json.load(open('vault-transit-init.json'))['root_token'])")
        kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
            -- vault operator unseal "$UNSEAL_KEY" 2>/dev/null || true
    fi

    # Verify unsealed
    kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
        -- vault status 2>/dev/null | grep "^Sealed" | grep -q "false" \
        || die "vault-transit is still sealed"

    # Configure transit
    kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
        -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault secrets enable transit" 2>/dev/null || true
    kubectl exec -n "$TRANSIT_NS" vault-transit-0 \
        -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write -f transit/keys/unseal-key" 2>/dev/null || true

    # Create policy
    kubectl exec -n "$TRANSIT_NS" vault-transit-0 -- sh -c \
        "VAULT_TOKEN=$ROOT_TOKEN vault policy write vault-unseal-policy - << 'POLICY'
path \"transit/encrypt/unseal-key\" { capabilities = [\"update\"] }
path \"transit/decrypt/unseal-key\" { capabilities = [\"update\"] }
POLICY"

    # Create token — use -ttl=0 for a truly non-expiring token
    # NOTE: -period=0 does NOT mean non-expiring; it falls back to system default TTL
    # and the token will expire (causing 403 "invalid token" on Vault restart).
    # -ttl=0 with -explicit-max-ttl=0 means no expiry ever.
    TRANSIT_TOKEN=$(kubectl exec -n "$TRANSIT_NS" vault-transit-0 -- sh -c \
        "VAULT_TOKEN=$ROOT_TOKEN vault token create \
            -policy=vault-unseal-policy \
            -ttl=0 \
            -explicit-max-ttl=0 \
            -orphan \
            -format=json" \
        | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

    [ -z "$TRANSIT_TOKEN" ] && die "Failed to create transit token"

    # Store token secret where both the standalone Vault install and the chart hooks expect it.
    for ns in "$VAULT_NS" "$NAMESPACE"; do
        kubectl create namespace "$ns" 2>/dev/null || true
        kubectl create secret generic vault-transit-token \
            --namespace="$ns" \
            --from-literal=token="$TRANSIT_TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
    done

    kubectl get secret vault-transit-token -n "$VAULT_NS" >/dev/null 2>&1 \
        || die "vault-transit-token secret not created"

    ok "vault-transit-token secret created in $VAULT_NS"
    info "Back up vault-transit-init.json outside this machine!"
}

# =============================================================================
# STEP 5 — VAULT HA INSTALL
# =============================================================================
vault_install() {
    log "[5/8] Installing Main Vault HA..."

    [ -f vault-values.yaml ] || die "vault-values.yaml not found"

    kubectl get secret vault-transit-token -n "$VAULT_NS" >/dev/null 2>&1 \
        || die "vault-transit-token not found — run: ./setup.sh vault_transit"

    STATUS=$(helm status vault -n "$VAULT_NS" 2>/dev/null \
        | grep "^STATUS" | awk '{print $2}' || echo "none")

    if [ "$STATUS" = "deployed" ]; then
        RUNNING=$(kubectl get pods -n "$VAULT_NS" 2>/dev/null \
            | grep "vault-[012]" | grep -c "Running" || true)
        if [ "${RUNNING:-0}" -ge "1" ]; then
            ok "Vault already installed — skipping helm install"
            return 0
        fi
        info "Vault release is deployed but pods are not healthy enough to use; reinstalling..."
        helm uninstall vault -n "$VAULT_NS" 2>/dev/null || true
        kubectl delete pvc -n "$VAULT_NS" --all --force --grace-period=0 --wait=false 2>/dev/null || true
        sleep 5
    fi

    [ "$STATUS" != "none" ] && {
        info "Removing broken release ($STATUS)..."
        helm uninstall vault -n "$VAULT_NS" 2>/dev/null || true
        sleep 5
    }

    helm upgrade --install vault hashicorp/vault \
        --namespace "$VAULT_NS" \
        --create-namespace \
        --values vault-values.yaml

    info "Waiting for Vault PVCs to bind..."
    for i in $(seq 1 30); do
        BOUND=$(kubectl get pvc -n "$VAULT_NS" 2>/dev/null | grep -c "Bound" || true)
        TOTAL=$(kubectl get pvc -n "$VAULT_NS" 2>/dev/null | grep -c "data-vault" || true)
        info "[$i/30] bound=$BOUND total=$TOTAL (need 3)"
        [ "${TOTAL:-0}" -ge "3" ] && [ "${BOUND:-0}" -eq "${TOTAL:-0}" ] && break
        sleep 10
    done

    BOUND=$(kubectl get pvc -n "$VAULT_NS" 2>/dev/null | grep -c "Bound" || true)
    [ "${BOUND:-0}" -ge "3" ] || die "Vault PVCs did not bind — is Longhorn running?"

    info "Waiting for Vault pods to start (up to 5 min)..."
    for i in $(seq 1 30); do
        # With transit seal, pods are Running but 0/1 Ready (sealed) until initialized.
        # We only need them Running so we can exec in and call vault operator init.
        RUNNING=$(kubectl get pods -n "$VAULT_NS" 2>/dev/null \
            | grep "vault-[012]" | grep -c "Running" || true)
        info "[$i/30] vault pods running: ${RUNNING:-0}/3"
        [ "${RUNNING:-0}" -ge "1" ] && break   # at least vault-0 running is enough to init
        sleep 10
    done

    kubectl get pods -n "$VAULT_NS"
    ok "Vault pods running"
}

# =============================================================================
# STEP 6 — VAULT INIT
# =============================================================================
vault_init() {
    log "[6/8] Initializing Main Vault..."

    VAULT_INIT_POD=""
    info "Waiting for a Vault pod API..."
    for i in $(seq 1 40); do
        VAULT_INIT_POD="$(select_vault_pod)"
        STATUS=$(kubectl exec -n "$VAULT_NS" "$VAULT_INIT_POD" \
            -- vault status 2>/dev/null || echo "")
        echo "$STATUS" | grep -q "Initialized" && { ok "API ready on $VAULT_INIT_POD"; break; }
        info "[$i/40] not ready, waiting 5s..."
        sleep 5
        [ "$i" = "40" ] && {
            [ -n "$VAULT_INIT_POD" ] && kubectl logs "$VAULT_INIT_POD" -n "$VAULT_NS" --tail=20 2>/dev/null || true
            die "Vault API never became ready"
        }
    done

    [ -n "$VAULT_INIT_POD" ] || die "No running Vault pod found for initialization"

    INITIALIZED=$(kubectl exec -n "$VAULT_NS" "$VAULT_INIT_POD" \
        -- vault status 2>/dev/null | grep "^Initialized" | awk '{print $2}' || echo "false")

    if [ "$INITIALIZED" = "true" ]; then
        ok "Vault already initialized"
        SEALED=$(kubectl exec -n "$VAULT_NS" "$VAULT_INIT_POD" \
            -- vault status 2>/dev/null | grep "^Sealed" | awk '{print $2}' || echo "true")
        [ "$SEALED" = "false" ] && { ok "Already unsealed"; return 0; }
        info "Sealed — transit should auto-unseal within 30s..."
        sleep 30
        return 0
    fi

    info "Initializing with transit seal (recovery keys)..."
    # NOTE: With transit auto-unseal, use -recovery-shares / -recovery-threshold
    # NOT -key-shares / -key-threshold (those are for Shamir seal only and cause a 400 error)
    kubectl exec -n "$VAULT_NS" "$VAULT_INIT_POD" \
        -- vault operator init \
            -recovery-shares=5 \
            -recovery-threshold=3 \
            -format=json > vault-main-init.json \
        || die "vault init failed"

    ok "vault-main-init.json saved — BACK THIS UP!"
    info "These are RECOVERY keys (only needed if transit vault is lost)"

    ROOT_TOKEN=$(python3 -c \
        "import json; print(json.load(open('vault-main-init.json'))['root_token'])")

    info "Waiting for auto-unseal via Transit (up to 2 min)..."
    for i in $(seq 1 12); do
        ALL_OK=true
        for pod in vault-0 vault-1 vault-2; do
            SEALED=$(kubectl exec -n "$VAULT_NS" "$pod" \
                -- vault status 2>/dev/null \
                | grep "^Sealed" | awk '{print $2}' || echo "true")
            info "$pod: sealed=$SEALED"
            [ "$SEALED" != "false" ] && ALL_OK=false
        done
        [ "$ALL_OK" = "true" ] && { ok "All pods auto-unsealed"; break; }
        info "[$i/12] waiting 10s..."
        sleep 10
    done

    kubectl create namespace "$NAMESPACE" 2>/dev/null || true
    kubectl create secret generic vault-root-token \
        --from-literal=token="$ROOT_TOKEN" \
        --namespace "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic "${RELEASE}-vault-root-token" \
        --from-literal=token="$ROOT_TOKEN" \
        --namespace "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    wait_for_pods_ready "$VAULT_NS" "app.kubernetes.io/name=vault,component=server" 30 10 "Vault pods" \
        || die "Vault pods did not become Ready"

    ok "Vault initialized and auto-unsealed via Transit"
}

# =============================================================================
# STEP 7 — OPERATORS
# =============================================================================
install_operators() {
    log "[7/8] Installing operators..."

    info "External Secrets Operator..."
    helm upgrade --install external-secrets ext-secrets/external-secrets \
        --namespace external-secrets --create-namespace \
        --set installCRDs=true --wait --timeout 5m

    for crd in externalsecrets.external-secrets.io \
               secretstores.external-secrets.io \
               clustersecretstores.external-secrets.io; do
        kubectl wait --for=condition=Established "crd/$crd" --timeout=120s >/dev/null 2>&1 \
            || die "CRD $crd was not established"
    done
    ok "ESO ready"

    info "CloudNativePG (PostgreSQL operator)..."
    helm upgrade --install cnpg cnpg/cloudnative-pg \
        --namespace cnpg-system --create-namespace \
        --wait --timeout 5m
    ok "CloudNativePG ready"

    info "Percona MongoDB operator..."
    helm upgrade --install psmdb-operator percona/psmdb-operator \
        --namespace "$NAMESPACE" --create-namespace \
        --wait --timeout 5m
    ok "MongoDB operator ready"

    ok "All operators installed"
}

# =============================================================================
# STEP 8 — DEPLOY
# =============================================================================
deploy() {
    log "[8/8] Deploying db-cluster chart..."

    : "${PG_PASS:?Add PG_PASS to .env}"
    : "${MONGO_PASS:?Add MONGO_PASS to .env}"
    : "${MYSQL_PASS:?Add MYSQL_PASS to .env}"
    : "${REDIS_PASS:?Add REDIS_PASS to .env}"
    : "${CASS_PASS:?Add CASS_PASS to .env}"
    ensure_cloudflare_secret_if_present

    # Clean up any ad-hoc RBAC from previous recovery attempts so Helm can own it.
    kubectl delete role my-db-vault-auth-secret-reader -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    kubectl delete rolebinding my-db-vault-auth-secret-reader -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    local HELM_VALUES_ARGS=()
    if [ -n "$VALUES_FILE" ]; then
        mapfile -t HELM_VALUES_ARGS < <(values_args)
    fi

    helm upgrade --install "$RELEASE" "$CHART_DIR" \
        --namespace "$NAMESPACE" --create-namespace \
        "${HELM_VALUES_ARGS[@]}" \
        --set "externalSecrets.enabled=false" \
        --set "postgresql.operator.enabled=false" \
        --set "mongodb.operator.enabled=false" \
        --set "mysql.operator.enabled=false" \
        --set "redis.operator.enabled=false" \
        --set "cassandra.operator.enabled=false" \
        --set "vaultTransit.enabled=false" \
        --set "vault.postgresql.superuserPassword=$PG_PASS" \
        --set "vault.postgresql.appPassword=$PG_PASS" \
        --set "vault.mongodb.clusterAdminPassword=$MONGO_PASS" \
        --set "vault.mongodb.userAdminPassword=$MONGO_PASS" \
        --set "vault.mongodb.replicationKey=$MONGO_PASS" \
        --set "vault.mysql.rootPassword=$MYSQL_PASS" \
        --set "vault.mysql.appPassword=$MYSQL_PASS" \
        --set "vault.mysql.replicationPassword=$MYSQL_PASS" \
        --set "vault.mysql.monitorPassword=$MYSQL_PASS" \
        --set "vault.mysql.clusterCheckPassword=$MYSQL_PASS" \
        --set "vault.redis.password=$REDIS_PASS" \
        --set "vault.cassandra.password=$CASS_PASS" \
        --timeout 10m \
        || die "db-cluster chart deploy failed"

    kubectl wait --for=condition=Ready clustersecretstore/vault-backend --timeout=180s >/dev/null 2>&1 \
        || die "Vault ClusterSecretStore did not become Ready"
    local ENABLED_DBS
    ENABLED_DBS="$(enabled_databases)"
    for db in $ENABLED_DBS; do
        case "$db" in
            postgresql)
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-postgresql-credentials -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "PostgreSQL superuser ExternalSecret did not become Ready"
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-postgresql-app -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "PostgreSQL app ExternalSecret did not become Ready"
                retry 18 10 kubectl get secret "$RELEASE-postgresql-credentials" -n "$NAMESPACE" >/dev/null \
                    || die "PostgreSQL superuser secret was not created"
                retry 18 10 kubectl get secret "$RELEASE-postgresql-app" -n "$NAMESPACE" >/dev/null \
                    || die "PostgreSQL app secret was not created"
                wait_for_pods_ready "$NAMESPACE" "cnpg.io/cluster=${RELEASE}-postgresql" 60 10 "PostgreSQL pods" \
                    || die "PostgreSQL did not become Ready"
                ;;
            mongodb)
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-mongodb-credentials -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "MongoDB ExternalSecret did not become Ready"
                retry 18 10 kubectl get secret "$RELEASE-mongodb-credentials" -n "$NAMESPACE" >/dev/null \
                    || die "MongoDB credentials secret was not created"
                wait_for_pods_ready "$NAMESPACE" "app.kubernetes.io/instance=${RELEASE}-mongodb,app.kubernetes.io/component=mongod" 60 10 "MongoDB pods" \
                    || die "MongoDB did not become Ready"
                ;;
            mysql)
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-mysql-credentials -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "MySQL ExternalSecret did not become Ready"
                retry 18 10 kubectl get secret "$RELEASE-mysql-credentials" -n "$NAMESPACE" >/dev/null \
                    || die "MySQL credentials secret was not created"
                ;;
            redis)
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-redis-credentials -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "Redis ExternalSecret did not become Ready"
                retry 18 10 kubectl get secret "$RELEASE-redis-credentials" -n "$NAMESPACE" >/dev/null \
                    || die "Redis credentials secret was not created"
                ;;
            cassandra)
                kubectl wait --for=condition=Ready externalsecret/"$RELEASE"-cassandra-credentials -n "$NAMESPACE" --timeout=180s >/dev/null 2>&1 \
                    || die "Cassandra ExternalSecret did not become Ready"
                retry 18 10 kubectl get secret "$RELEASE-cassandra-credentials" -n "$NAMESPACE" >/dev/null \
                    || die "Cassandra credentials secret was not created"
                ;;
        esac
    done

    ok "Chart deployed"
    kubectl get pods -n "$NAMESPACE"
}

operator_plugins() {
    [ -x "$OPERATOR_INSTALLER" ] || die "Operator installer not found or not executable: $OPERATOR_INSTALLER"
    log "[9/9] Running operator installer script..."
    VALUES_FILE="${VALUES_FILE:-$CHART_DIR/values.yaml}" "$OPERATOR_INSTALLER" all || die "Operator installer script failed"
    ok "Operator installer script completed"
}

# =============================================================================
# FULL SETUP
# =============================================================================
setup() {
    echo ""
    echo "============================================="
    echo " db-cluster setup starting..."
    echo "============================================="

    preflight       || die "Step preflight failed"
    repos           || die "Step repos failed"
    ingress_nginx   || die "Step ingress_nginx failed"
    longhorn        || die "Step longhorn failed"
    deps            || die "Step deps failed"
    vault_transit   || die "Step vault_transit failed"
    vault_install   || die "Step vault_install failed"
    vault_init      || die "Step vault_init failed"
    install_operators || die "Step install_operators failed"
    operator_plugins || die "Step operator_plugins failed"
    deploy          || die "Step deploy failed"

    echo ""
    echo "============================================="
    echo " ✓ Setup complete!"
    echo "   ./setup.sh status   — see all pods"
    echo "   ./setup.sh clusters — see DB health"
    echo "   ./setup.sh operator_plugins — rerun operator installer script"
    echo "============================================="
}

small_setup() {
    VALUES_FILE="./db-cluster/values.small-cluster.yaml" setup
}

# =============================================================================
# STATUS
# =============================================================================
status() {
    echo "━━━ Longhorn ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl get pods -n longhorn-system 2>/dev/null | grep -v Completed || echo "  not deployed"
    echo ""
    echo "━━━ Transit Vault ($TRANSIT_NS) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl get pods -n "$TRANSIT_NS" 2>/dev/null || echo "  not deployed"
    echo ""
    echo "━━━ Main Vault ($VAULT_NS) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl get pods -n "$VAULT_NS" 2>/dev/null || echo "  not deployed"
    echo ""
    echo "━━━ Databases ($NAMESPACE) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  not deployed"
    echo ""
    echo "━━━ PVCs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl get pvc --all-namespaces 2>/dev/null | grep -v "^NAMESPACE" || echo "  none"
}

clusters() {
    for db in "cluster:PostgreSQL" "psmdb:MongoDB" "pxc:MySQL" \
              "rediscluster:Redis" "k8ssandracluster:Cassandra"; do
        KIND="${db%%:*}"; NAME="${db##*:}"
        echo "━━━ $NAME ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        kubectl get "$KIND" -n "$NAMESPACE" 2>/dev/null || echo "  not enabled"
        echo ""
    done
}

vault_status() {
    echo "━━━ Transit Vault ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl exec -n "$TRANSIT_NS" vault-transit-0 -- vault status 2>/dev/null || echo "  not ready"
    echo ""
    for pod in vault-0 vault-1 vault-2; do
        echo "━━━ $pod ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        kubectl exec -n "$VAULT_NS" "$pod" -- vault status 2>/dev/null || echo "  not ready"
        echo ""
    done
}

# =============================================================================
# PORT FORWARDS
# =============================================================================
pg()         { kubectl port-forward svc/"$RELEASE"-postgresql-rw 5432:5432 -n "$NAMESPACE"; }
mongo()      { kubectl port-forward svc/"$RELEASE"-mongodb-rs0 27017:27017 -n "$NAMESPACE"; }
redis()      { kubectl port-forward svc/"$RELEASE"-redis-leader 6379:6379 -n "$NAMESPACE"; }
mysql()      { kubectl port-forward svc/"$RELEASE"-mysql-haproxy 3306:3306 -n "$NAMESPACE"; }
cassandra()  { kubectl port-forward svc/"$RELEASE"-dc1-service 9042:9042 -n "$NAMESPACE"; }
vault_ui()   { kubectl port-forward svc/vault 8200:8200 -n "$VAULT_NS"; }
longhorn_ui(){ kubectl port-forward svc/longhorn-frontend 8080:80 -n longhorn-system; }
cloudflare_secret() {
    : "${CLOUDFLARE_API_TOKEN:?Add CLOUDFLARE_API_TOKEN to your environment or .env}"
    kubectl create namespace "$NAMESPACE" 2>/dev/null || true
    kubectl create secret generic cloudflare-api-token \
        --from-literal=token="$CLOUDFLARE_API_TOKEN" \
        --namespace "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    ok "cloudflare-api-token secret created in $NAMESPACE"
}

ensure_cloudflare_secret_if_present() {
    if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
        cloudflare_secret
    fi
}

# =============================================================================
# VAULT OPS
# =============================================================================
vault_list() {
    TOKEN=$(kubectl get secret vault-root-token -n "$NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    [ -z "$TOKEN" ] && die "vault-root-token not found"
    VAULT_POD="$(select_vault_pod)"
    [ -n "$VAULT_POD" ] || die "No running Vault pod found"
    kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- env VAULT_TOKEN="$TOKEN" vault kv list databases/
}

vault_get() {
    DB="${1:?Usage: ./setup.sh vault_get <db>}"
    TOKEN=$(kubectl get secret vault-root-token -n "$NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    [ -z "$TOKEN" ] && die "vault-root-token not found"
    VAULT_POD="$(select_vault_pod)"
    [ -n "$VAULT_POD" ] || die "No running Vault pod found"
    kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- env VAULT_TOKEN="$TOKEN" vault kv get "databases/$DB"
}

rotate() {
    DB="${1:?Usage: ./setup.sh rotate <db> <pass>}"
    PASS="${2:?Usage: ./setup.sh rotate <db> <pass>}"
    TOKEN=$(kubectl get secret vault-root-token -n "$NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    [ -z "$TOKEN" ] && die "vault-root-token not found"
    VAULT_POD="$(select_vault_pod)"
    [ -n "$VAULT_POD" ] || die "No running Vault pod found"
    kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- env VAULT_TOKEN="$TOKEN" \
        vault kv patch "databases/$DB" \
        superuser-password="$PASS" app-password="$PASS"
    kubectl annotate externalsecret "$DB-secret" \
        force-sync="$(date +%s)" --overwrite -n "$NAMESPACE" 2>/dev/null || true
    ok "Password rotated"
}

sync() {
    for es in postgresql mongodb mysql redis cassandra; do
        kubectl annotate externalsecret "${es}-secret" \
            force-sync="$(date +%s)" --overwrite -n "$NAMESPACE" 2>/dev/null \
        && echo "✓ $es-secret" || echo "- $es-secret (not deployed)"
    done
}

upgrade() {
    : "${PG_PASS:?}" ; : "${MONGO_PASS:?}" ; : "${MYSQL_PASS:?}"
    : "${REDIS_PASS:?}" ; : "${CASS_PASS:?}"
    ensure_cloudflare_secret_if_present
    local HELM_VALUES_ARGS=()
    if [ -n "$VALUES_FILE" ]; then
        mapfile -t HELM_VALUES_ARGS < <(values_args)
    fi
    helm upgrade "$RELEASE" "$CHART_DIR" \
        --namespace "$NAMESPACE" \
        "${HELM_VALUES_ARGS[@]}" \
        --set "externalSecrets.enabled=false" \
        --set "postgresql.operator.enabled=false" \
        --set "mongodb.operator.enabled=false" \
        --set "mysql.operator.enabled=false" \
        --set "redis.operator.enabled=false" \
        --set "cassandra.operator.enabled=false" \
        --set "vaultTransit.enabled=false" \
        --set "vault.postgresql.superuserPassword=$PG_PASS" \
        --set "vault.postgresql.appPassword=$PG_PASS" \
        --set "vault.mongodb.clusterAdminPassword=$MONGO_PASS" \
        --set "vault.mongodb.userAdminPassword=$MONGO_PASS" \
        --set "vault.mongodb.replicationKey=$MONGO_PASS" \
        --set "vault.mysql.rootPassword=$MYSQL_PASS" \
        --set "vault.mysql.appPassword=$MYSQL_PASS" \
        --set "vault.mysql.replicationPassword=$MYSQL_PASS" \
        --set "vault.mysql.monitorPassword=$MYSQL_PASS" \
        --set "vault.mysql.clusterCheckPassword=$MYSQL_PASS" \
        --set "vault.redis.password=$REDIS_PASS" \
        --set "vault.cassandra.password=$CASS_PASS" \
        --timeout 10m \
        || die "Upgrade failed"
    prune_disabled_database_operators
    ok "Upgrade complete"
}

# =============================================================================
# TEARDOWN
# =============================================================================
teardown() {
    echo ""
    echo "==> WARNING: This will permanently delete ALL data in 5 seconds"
    echo "    Ctrl+C to cancel..."
    sleep 5

    # ── 1. Remove Longhorn admission webhooks FIRST ───────────────────────
    # Without this, every PVC patch/delete fails with "webhook service not found"
    log "[1/8] Removing Longhorn admission webhooks..."
    kubectl delete validatingwebhookconfiguration longhorn-webhook-validator 2>/dev/null || true
    kubectl delete mutatingwebhookconfiguration   longhorn-webhook-mutator   2>/dev/null || true
    kubectl delete validatingwebhookconfiguration longhorn-webhook-validator-node 2>/dev/null || true
    # Also remove any other Longhorn webhooks
    for wh in $(kubectl get validatingwebhookconfiguration 2>/dev/null | grep longhorn | awk '{print $1}'); do
        kubectl delete validatingwebhookconfiguration "$wh" 2>/dev/null || true
    done
    for wh in $(kubectl get mutatingwebhookconfiguration 2>/dev/null | grep longhorn | awk '{print $1}'); do
        kubectl delete mutatingwebhookconfiguration "$wh" 2>/dev/null || true
    done
    ok "Webhooks removed"

    # ── 2. Remove ALL PVC/PV finalizers BEFORE uninstalling anything ──────
    log "[2/8] Removing PVC and PV finalizers..."
    ALL_NS="$NAMESPACE $VAULT_NS $TRANSIT_NS longhorn-system external-secrets cnpg-system ingress-nginx traefik"
    for ns in $ALL_NS; do
        for pvc in $(kubectl get pvc -n "$ns" -o name --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null); do
            kubectl patch "$pvc" -n "$ns"                 -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
            kubectl delete "$pvc" -n "$ns" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        done
    done
    # Remove all PV finalizers cluster-wide
    for pv in $(kubectl get pv --no-headers --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null | awk '{print $1}'); do
        kubectl patch pv "$pv"             -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        kubectl delete pv "$pv" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
    done
    ok "PVC/PV finalizers cleared"

    # ── 3. Remove Longhorn CR finalizers ─────────────────────────────────
    log "[3/8] Removing Longhorn custom resource finalizers..."
    for crd in $(kubectl get crd --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null | grep longhorn | awk '{print $1}'); do
        for res in $(kubectl get "$crd" -A --no-headers --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null | awk '{print $1"/"$2}'); do
            ns="${res%%/*}"; name="${res##*/}"
            kubectl patch "$crd" "$name" -n "$ns"                 -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
            kubectl delete "$crd" "$name" -n "$ns"                 --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        done
    done
    ok "Longhorn CR finalizers cleared"

    # ── 4. Uninstall all Helm releases ───────────────────────────────────
    log "[4/8] Uninstalling Helm releases..."
    helm uninstall "$RELEASE"       -n "$NAMESPACE"     2>/dev/null || true
    helm uninstall vault            -n "$VAULT_NS"      2>/dev/null || true
    helm uninstall vault-transit    -n "$TRANSIT_NS"    2>/dev/null || true
    helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    helm uninstall cnpg             -n cnpg-system      2>/dev/null || true
    helm uninstall psmdb-operator   -n "$NAMESPACE"     2>/dev/null || true
    helm uninstall pxc-operator     -n "$NAMESPACE"     2>/dev/null || true
    helm uninstall redis-operator   -n "$NAMESPACE"     2>/dev/null || true
    helm uninstall k8ssandra-operator -n "$NAMESPACE"   2>/dev/null || true
    helm uninstall ingress-nginx    -n ingress-nginx    2>/dev/null || true
    helm uninstall traefik          -n traefik          2>/dev/null || true
    helm uninstall longhorn         -n longhorn-system  2>/dev/null || true
    ok "Helm releases uninstalled"

    # ── 5. Delete Longhorn CRDs ───────────────────────────────────────────
    log "[5/8] Deleting Longhorn CRDs..."
    for crd in $(kubectl get crd --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null | grep longhorn | awk '{print $1}'); do
        kubectl patch crd "$crd"             -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        kubectl delete crd "$crd" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
    done
    # Delete any operator CRDs (CNPG, Percona)
    for crd in $(kubectl get crd --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null | grep -E "cnpg|percona|psmdb|pxc|external-secrets|externalsecrets|clustersecretstores|redis\\.opstreelabs|k8ssandra|cassandradatacenters|cassandratasks|clientconfigs" | awk '{print $1}'); do
        kubectl patch crd "$crd"             -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        kubectl delete crd "$crd" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
    done
    ok "CRDs deleted"

    # ── 6. Delete the iscsi daemonset from kube-system ────────────────────
    log "[6/8] Removing iscsi installation daemonset..."
    kubectl delete daemonset longhorn-iscsi-installation -n kube-system 2>/dev/null || true
    kubectl delete pods -n kube-system -l app=longhorn-iscsi-installation         --force --grace-period=0 2>/dev/null || true
    ok "iscsi daemonset removed"

    # ── 7. Delete all namespaces ──────────────────────────────────────────
    log "[7/8] Deleting namespaces..."
    for ns in "$NAMESPACE" "$VAULT_NS" "$TRANSIT_NS"               external-secrets cnpg-system longhorn-system ingress-nginx traefik; do
        # Final PVC sweep
        for pvc in $(kubectl get pvc -n "$ns" -o name --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null); do
            kubectl patch "$pvc" -n "$ns"                 -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
            kubectl delete "$pvc" -n "$ns" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        done
        # Delete all remaining resources in namespace
        kubectl delete all --all -n "$ns" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        # Delete namespace
        kubectl delete namespace "$ns" --force --grace-period=0 --wait=false --ignore-not-found --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || true
        # Force finalize if still stuck terminating
        NS_JSON=$(kubectl get namespace "$ns" -o json --request-timeout="$KUBECTL_TIMEOUT" 2>/dev/null || echo "")
        if [ -n "$NS_JSON" ]; then
            echo "$NS_JSON"                 | python3 -c                     "import sys,json; d=json.load(sys.stdin);                      d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null                 | kubectl replace --raw "/api/v1/namespaces/$ns/finalize"                     -f - 2>/dev/null || true
        fi
    done
    ok "Namespaces deleted"

    # ── 8. Cleanup local files and verify ────────────────────────────────
    log "[8/8] Final cleanup and verification..."
    rm -f vault-init.json vault-main-init.json vault-transit-init.json
    sleep 5

    echo ""
    echo "  Remaining PVCs:"
    PVCS=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null |         grep -E "vault|databases|longhorn" || true)
    [ -n "$PVCS" ] && echo "$PVCS" || echo "    none ✓"

    echo ""
    echo "  Remaining namespaces:"
    NS_LEFT=$(kubectl get namespace --no-headers 2>/dev/null |         grep -E "^vault|^databases|^longhorn|^external-secrets|^cnpg|^ingress-nginx|^traefik" || true)
    [ -n "$NS_LEFT" ] && echo "$NS_LEFT" || echo "    none ✓"

    echo ""
    echo "  Remaining CRDs (longhorn/cnpg/percona):"
    CRDS=$(kubectl get crd 2>/dev/null |         grep -E "longhorn|cnpg|percona|psmdb|external-secrets|redis\\.opstreelabs|k8ssandra|cassandradatacenters|cassandratasks|clientconfigs" || true)
    [ -n "$CRDS" ] && echo "$CRDS" || echo "    none ✓"

    echo ""
    echo "  Remaining Longhorn webhooks:"
    WH=$(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration 2>/dev/null |         grep longhorn || true)
    [ -n "$WH" ] && echo "$WH" || echo "    none ✓"

    echo ""
    ok "Teardown complete — run './setup.sh' to start fresh"
}


# =============================================================================
# ENTRYPOINT
# =============================================================================
usage() {
    echo "Usage: ./setup.sh [command]"
    echo "Env:    VALUES_FILE=./db-cluster/values.small-cluster.yaml ./setup.sh"
    echo ""
    echo "1. setup"
    echo "   Run the normal full install using db-cluster/values.yaml."
    echo "   Why install it: this platform depends on ordered layers."
    echo "   Storage must exist before PVC workloads, Vault must exist before secret sync,"
    echo "   and operators must exist before database custom resources can reconcile."
    echo ""
    echo "2. small_setup"
    echo "   Run the smaller safe profile using db-cluster/values.small-cluster.yaml."
    echo "   Why install it: your cluster may not have enough worker CPU for the"
    echo "   full profile. This reduced profile avoids pods staying Pending."
    echo ""
    echo "3. preflight"
    echo "   Check whether cluster worker CPU is enough for the selected values file."
    echo "   Why run it: it catches sizing problems before a long install fails."
    echo ""
    echo "4. repos"
    echo "   Add or refresh Helm repositories."
    echo "   Why install it: Helm charts are downloaded from these repos."
    echo ""
    echo "5. longhorn"
    echo "   Install or repair Longhorn storage."
    echo "   Why install it: the databases in this stack are stateful and need"
    echo "   persistent volumes. Without storage, PVCs will not bind."
    echo ""
    echo "6. ingress_nginx"
    echo "   Install the ingress-nginx controller."
    echo "   Why install it: this repo now renders standard Kubernetes Ingress"
    echo "   resources with ingressClassName=nginx for the web UIs."
    echo ""
    echo "7. deps"
    echo "   Refresh local chart dependencies."
    echo "   Why install it: the umbrella chart uses packaged child charts that"
    echo "   must be present locally before Helm can deploy them."
    echo ""
    echo "8. vault_transit"
    echo "   Install transit Vault for auto-unseal."
    echo "   Why install it: it acts as the unseal authority for the main Vault"
    echo "   cluster so restarts do not require manual unseal every time."
    echo ""
    echo "9. vault_install"
    echo "   Install the main Vault cluster."
    echo "   Why install it: Vault is the source of truth for database passwords"
    echo "   and secrets used by the rest of the platform."
    echo ""
    echo "10. vault_init"
    echo "   Initialize Vault and create the token secret used later."
    echo "   Why install it: an uninitialized Vault cannot serve secrets."
    echo ""
    echo "11. install_operators"
    echo "    Install database operators."
    echo "    Why install them: operators are the controllers that create and"
    echo "    manage PostgreSQL, MongoDB, MySQL, Redis, and Cassandra clusters."
    echo ""
    echo "12. deploy"
    echo "    Deploy the db-cluster chart and database resources."
    echo "    Why install it: this is the step that creates the actual database"
    echo "    custom resources, secrets wiring, ingress, and supporting objects."
    echo ""
    echo "13. operator_plugins"
    echo "    Rerun the standalone operator installer script."
    echo "    Why install it: useful when operators need repair or reinstall"
    echo "    without rerunning the entire stack."
    echo ""
    echo "14. status"
    echo "    Show pods and PVCs across the main namespaces."
    echo "    Why use it: quick health check after install or during debugging."
    echo ""
    echo "15. clusters"
    echo "    Show database custom resources."
    echo "    Why use it: operators report database state through CRs, not only pods."
    echo ""
    echo "16. vault_status"
    echo "    Check seal and health status of Vault."
    echo "    Why use it: if Vault is sealed or unhealthy, secret sync and auth"
    echo "    problems will appear across the platform."
    echo ""
    echo "17. upgrade"
    echo "    Reapply the Helm release after values or password changes."
    echo "    Why use it: update the running release without tearing it down."
    echo ""
    echo "18. sync"
    echo "    Force External Secrets sync from Vault."
    echo "    Why use it: push updated Vault values back into Kubernetes secrets."
    echo ""
    echo "19. vault_list"
    echo "    List database secret paths in Vault."
    echo "    Why use it: confirm secret paths were created as expected."
    echo ""
    echo "20. vault_get <db>"
    echo "    Read one database secret from Vault."
    echo "    Why use it: debug credential mismatches for a specific database."
    echo ""
    echo "21. rotate <db> <pass>"
    echo "    Rotate one database password in Vault."
    echo "    Why use it: Vault is the source of truth, so rotation should start there."
    echo ""
    echo "22. pg | mongo | redis | mysql | cassandra"
    echo "    Port-forward one database locally."
    echo "    Why use it: local access for admin work without exposing databases publicly."
    echo ""
    echo "23. vault_ui | longhorn_ui"
    echo "    Port-forward Vault UI or Longhorn UI locally."
    echo "    Why use it: inspect secret state or storage state safely from your machine."
    echo ""
    echo "24. cloudflare_secret"
    echo "    Create or update the Cloudflare API token secret."
    echo "    Why use it: the Cloudflare DNS automation job reads the token from"
    echo "    a Kubernetes secret instead of plain Helm values."
    echo ""
    echo "25. teardown"
    echo "    Delete the entire platform. Destructive."
    echo "    Why use it: reset the cluster when you want a clean reinstall."
    echo ""
    echo "Ingress note:"
    echo "   This project uses standard Kubernetes Ingress for web UIs."
    echo "   setup installs ingress-nginx automatically unless your cluster"
    echo "   already provides an nginx IngressClass."
    echo ""
    echo "More detail: see HELP.md"
}

CMD="${1:-setup}"; shift 2>/dev/null || true
case "$CMD" in
    setup|small_setup|teardown|status|clusters|vault_status|upgrade|sync|usage|\
    preflight|repos|ingress_nginx|longhorn|deps|vault_transit|vault_install|vault_init|\
    install_operators|deploy|operator_plugins|vault_list|vault_get|rotate|cloudflare_secret|\
    pg|mongo|redis|mysql|cassandra|vault_ui|longhorn_ui)
        "$CMD" "$@" ;;
    *) echo "Unknown: $CMD"; usage; exit 1 ;;
esac
