#!/usr/bin/env bash
# Install NVIDIA GPU Operator + Network Operator (Helm).
# Stage1/2 need GPU Operator. Stage3 cross-node PD needs Network Operator + RDMA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"
CTX="${KUBE_CONTEXT}"

GPU_OP_NS="${GPU_OPERATOR_NS:-gpu-operator}"
NET_OP_NS="${NETWORK_OPERATOR_NS:-nvidia-network-operator}"
GPU_CHART_VER="${GPU_OPERATOR_CHART_VERSION:-}"
NET_CHART_VER="${NETWORK_OPERATOR_CHART_VERSION:-}"
SKIP_NETWORK="${SKIP_NETWORK_OPERATOR:-0}"
APPLY_NIC_POLICY="${APPLY_NIC_CLUSTER_POLICY:-1}"
FORCE_REAL_GPU="${FORCE_REAL_GPU_OPERATOR:-0}"
DRY_RUN="${DRY_RUN:-0}"
WAIT_GPU_SECS="${WAIT_GPU_SECS:-120}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FAIL] missing command: $1"
    exit 1
  }
}

need kubectl
need helm
need python3

echo "== Install NVIDIA operators (context=${CTX}) =="
echo "  GPU Operator ns=${GPU_OP_NS}"
echo "  Network Operator ns=${NET_OP_NS} (SKIP_NETWORK_OPERATOR=${SKIP_NETWORK})"
echo "  DRY_RUN=${DRY_RUN} FORCE_REAL_GPU_OPERATOR=${FORCE_REAL_GPU}"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia >/dev/null

# --- GPU Operator ---
EXISTING_GPU_CHART="$(helm_release_chart "${CTX}" "${GPU_OP_NS}" gpu-operator || true)"
echo "  existing gpu-operator chart: ${EXISTING_GPU_CHART:-<none>}"

install_gpu=1
if [[ -n "${EXISTING_GPU_CHART}" ]]; then
  case "${EXISTING_GPU_CHART}" in
    fake-gpu-operator*|gpu-operator-fake*)
      if [[ "${FORCE_REAL_GPU}" != "1" ]]; then
        echo "[SKIP] release gpu-operator is ${EXISTING_GPU_CHART} (lab fake)."
        echo "       Refusing to overwrite with nvidia/gpu-operator."
        echo "       Set FORCE_REAL_GPU_OPERATOR=1 only on clusters with real NVIDIA GPUs."
        install_gpu=0
      fi
      ;;
    gpu-operator*|nvidia-gpu-operator*)
      echo "[INFO] nvidia GPU Operator release already present; will helm upgrade"
      ;;
    *)
      echo "[WARN] unknown chart ${EXISTING_GPU_CHART}; will try helm upgrade --install"
      ;;
  esac
fi

if [[ "${install_gpu}" == "1" ]]; then
  echo "-- GPU Operator --"
  GPU_CMD=(helm upgrade --install gpu-operator nvidia/gpu-operator
    --kube-context "${CTX}"
    --namespace "${GPU_OP_NS}"
    --create-namespace
    --timeout 20m
    -f "${ROOT}/manifests/operators/gpu-operator-values.yaml")
  if [[ -n "${GPU_CHART_VER}" ]]; then
    GPU_CMD+=(--version "${GPU_CHART_VER}")
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    GPU_CMD+=(--dry-run)
    echo "[DRY_RUN] ${GPU_CMD[*]}"
    "${GPU_CMD[@]}" >/tmp/vllm-gpu-operator-dryrun.yaml
    echo "[PASS] GPU Operator helm dry-run wrote /tmp/vllm-gpu-operator-dryrun.yaml"
  else
    # Do not --wait forever on GPU-less labs; wait separately for allocatable GPUs.
    "${GPU_CMD[@]}"
    echo "Waiting up to ${WAIT_GPU_SECS}s for nvidia.com/gpu allocatable..."
    end=$((SECONDS + WAIT_GPU_SECS))
    got=0
    while (( SECONDS < end )); do
      got="$(gpu_alloc_total "${CTX}")"
      echo "  allocatable nvidia.com/gpu=${got}"
      if [[ "${got}" =~ ^[1-9] ]]; then
        break
      fi
      sleep 5
    done
    if ! [[ "${got}" =~ ^[1-9] ]]; then
      echo "[WARN] GPU Operator installed/upgraded but nvidia.com/gpu still 0"
      echo "       (no NVIDIA device, driver not ready, or still using fake operator)"
    else
      echo "[PASS] nvidia.com/gpu allocatable=${got}"
    fi
  fi
fi

# --- Network Operator ---
if [[ "${SKIP_NETWORK}" == "1" ]]; then
  echo "[SKIP] Network Operator (Stage1/2-only or same-node PD drill)"
else
  echo "-- Network Operator --"
  NET_CMD=(helm upgrade --install network-operator nvidia/network-operator
    --kube-context "${CTX}"
    --namespace "${NET_OP_NS}"
    --create-namespace
    --timeout 20m
    -f "${ROOT}/manifests/operators/network-operator-values.yaml")
  if [[ -n "${NET_CHART_VER}" ]]; then
    NET_CMD+=(--version "${NET_CHART_VER}")
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    NET_CMD+=(--dry-run)
    echo "[DRY_RUN] ${NET_CMD[*]}"
    "${NET_CMD[@]}" >/tmp/vllm-network-operator-dryrun.yaml
    echo "[PASS] Network Operator helm dry-run wrote /tmp/vllm-network-operator-dryrun.yaml"
  else
    # Avoid indefinite hang if CRDs/nodes are odd; --wait can block 20m.
    "${NET_CMD[@]}" || {
      echo "[WARN] network-operator helm returned non-zero; checking release status"
      helm --kube-context "${CTX}" status network-operator -n "${NET_OP_NS}" || true
    }
  fi

  if [[ "${APPLY_NIC_POLICY}" == "1" && "${DRY_RUN}" != "1" ]]; then
    echo "-- NicClusterPolicy (edit vendors/deviceIDs for your NICs) --"
    if kubectl --context "${CTX}" get crd nicclusterpolicies.mellanox.com >/dev/null 2>&1; then
      kubectl --context "${CTX}" apply -f "${ROOT}/manifests/operators/nic-cluster-policy.yaml" || \
        echo "[WARN] NicClusterPolicy apply failed"
    else
      echo "[WARN] NicClusterPolicy CRD missing; skip apply (Network Operator may still be starting)"
    fi
  fi
fi

echo
echo "Operators step finished."
echo "  Next: ${ROOT}/scripts/00-validate.sh"
echo "  Dry-run only: DRY_RUN=1 $0"
echo "  Skip Network Operator: SKIP_NETWORK_OPERATOR=1 $0"
echo "  Replace lab fake GPU operator: FORCE_REAL_GPU_OPERATOR=1 $0"
exit 0
