#!/usr/bin/env bash
# Install NVIDIA GPU Operator + Network Operator (Helm).
# Stage1/2 need GPU Operator. Stage3 cross-node PD needs Network Operator + RDMA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"

GPU_OP_NS="${GPU_OPERATOR_NS:-gpu-operator}"
NET_OP_NS="${NETWORK_OPERATOR_NS:-nvidia-network-operator}"
GPU_CHART_VER="${GPU_OPERATOR_CHART_VERSION:-}"
NET_CHART_VER="${NETWORK_OPERATOR_CHART_VERSION:-}"
SKIP_NETWORK="${SKIP_NETWORK_OPERATOR:-0}"
APPLY_NIC_POLICY="${APPLY_NIC_CLUSTER_POLICY:-1}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FAIL] missing command: $1"
    exit 1
  }
}

need kubectl
need helm

echo "== Install NVIDIA operators (context=${CTX}) =="
echo "  GPU Operator ns=${GPU_OP_NS}"
echo "  Network Operator ns=${NET_OP_NS} (SKIP_NETWORK_OPERATOR=${SKIP_NETWORK})"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia

GPU_VER_ARGS=()
if [[ -n "${GPU_CHART_VER}" ]]; then
  GPU_VER_ARGS=(--version "${GPU_CHART_VER}")
fi

echo "-- GPU Operator --"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --kube-context "${CTX}" \
  --namespace "${GPU_OP_NS}" \
  --create-namespace \
  --wait \
  --timeout 20m \
  "${GPU_VER_ARGS[@]}" \
  -f "${ROOT}/manifests/operators/gpu-operator-values.yaml"

echo "Waiting for nvidia.com/gpu allocatable..."
for i in $(seq 1 60); do
  GPU_ALLOC="$(kubectl --context "${CTX}" get nodes -o json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(int(n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0")) for n in d.get("items",[])))' 2>/dev/null || echo 0)"
  echo "  [${i}] allocatable nvidia.com/gpu=${GPU_ALLOC}"
  if [[ "${GPU_ALLOC}" =~ ^[1-9] ]]; then
    break
  fi
  sleep 10
done

if [[ "${SKIP_NETWORK}" == "1" ]]; then
  echo "[SKIP] Network Operator (Stage1/2-only or same-node PD drill)"
else
  NET_VER_ARGS=()
  if [[ -n "${NET_CHART_VER}" ]]; then
    NET_VER_ARGS=(--version "${NET_CHART_VER}")
  fi
  echo "-- Network Operator --"
  helm upgrade --install network-operator nvidia/network-operator \
    --kube-context "${CTX}" \
    --namespace "${NET_OP_NS}" \
    --create-namespace \
    --wait \
    --timeout 20m \
    "${NET_VER_ARGS[@]}" \
    -f "${ROOT}/manifests/operators/network-operator-values.yaml"

  if [[ "${APPLY_NIC_POLICY}" == "1" ]]; then
    echo "-- NicClusterPolicy (edit vendors/deviceIDs for your NICs) --"
    kubectl --context "${CTX}" apply -f "${ROOT}/manifests/operators/nic-cluster-policy.yaml" || \
      echo "[WARN] NicClusterPolicy apply failed (CRD may still be installing; re-apply later)"
  fi
fi

echo
echo "Operators install attempted."
echo "  Next: ${ROOT}/scripts/00-validate.sh"
echo "  Stage mapping:"
echo "    Stage1/2  -> GPU Operator required"
echo "    Stage3 PD -> GPU Operator + Network Operator (RDMA) for cross-node NIXL"
echo "  Skip Network Operator: SKIP_NETWORK_OPERATOR=1 $0"
