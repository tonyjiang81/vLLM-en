#!/usr/bin/env bash
# Preflight for CUDA / NVIDIA GPU path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"

CTX="${KUBE_CONTEXT}"
pass=0
warn=0
fail=0
REQUIRE_NETWORK="${REQUIRE_NETWORK_OPERATOR:-0}"

ok()   { echo "[PASS] $*"; pass=$((pass+1)); }
warn() { echo "[WARN] $*"; warn=$((warn+1)); }
bad()  { echo "[FAIL] $*"; fail=$((fail+1)); }

echo "== vLLM-gpu preflight (context=${CTX}, ns=${NAMESPACE}) =="
echo "  REQUIRE_NETWORK_OPERATOR=${REQUIRE_NETWORK} (set 1 before Stage3 RDMA PD)"

if ! kubectl --context "${CTX}" cluster-info >/dev/null 2>&1; then
  bad "cannot reach API for context ${CTX}"
  exit 1
fi
ok "kubectl context ${CTX} reachable"

# --- GPU Operator / device plugin ---
if kubectl --context "${CTX}" get ns gpu-operator >/dev/null 2>&1 \
  || kubectl --context "${CTX}" get deploy -A 2>/dev/null | grep -qi 'gpu-operator'; then
  ok "GPU Operator namespace/deploy detected"
else
  warn "GPU Operator not detected (standalone device-plugin may still work)"
fi

GPU_ALLOC="$(gpu_alloc_total "${CTX}")"
echo "     allocatable nvidia.com/gpu total=${GPU_ALLOC}"
EXISTING_GPU_CHART="$(helm_release_chart "${CTX}" "${GPU_OPERATOR_NS}" gpu-operator || true)"
if [[ -n "${EXISTING_GPU_CHART}" ]]; then
  echo "     helm release gpu-operator chart=${EXISTING_GPU_CHART}"
fi
if [[ "${GPU_ALLOC}" =~ ^[1-9] ]]; then
  ok "cluster advertises nvidia.com/gpu=${GPU_ALLOC}"
else
  bad "no nvidia.com/gpu in node allocatable (need real NVIDIA GPU + GPU Operator; fake-gpu-operator alone is not enough)"
fi

if kubectl --context "${CTX}" get pods -A -l app.kubernetes.io/name=dcgm-exporter -o name 2>/dev/null | head -1 | grep -q .; then
  ok "dcgm-exporter pods present"
elif kubectl --context "${CTX}" get pods -A 2>/dev/null | grep -qi dcgm; then
  ok "DCGM-related pods present"
else
  warn "DCGM exporter not found (GPU util panels need it; enable via GPU Operator)"
fi

# --- Network Operator / RDMA ---
RDMA_KEYS="$(rdma_resource_keys "${CTX}")"

if kubectl --context "${CTX}" get ns nvidia-network-operator >/dev/null 2>&1 \
  || kubectl --context "${CTX}" get deploy -A 2>/dev/null | grep -qi 'network-operator'; then
  ok "Network Operator namespace/deploy detected"
else
  if [[ "${REQUIRE_NETWORK}" == "1" ]]; then
    bad "Network Operator missing (required for Stage3 cross-node RDMA PD)"
  else
    warn "Network Operator not detected (OK for Stage1/2; needed for Stage3 RDMA)"
  fi
fi

if [[ -n "${RDMA_KEYS}" ]]; then
  ok "RDMA allocatable resources: ${RDMA_KEYS}"
else
  if [[ "${REQUIRE_NETWORK}" == "1" ]]; then
    bad "no rdma/* allocatable (apply NicClusterPolicy / check OFED + Network Operator)"
  else
    warn "no rdma/* allocatable yet (edit manifests/operators/nic-cluster-policy.yaml for your NICs)"
  fi
fi

if kubectl --context "${CTX}" get nicclusterpolicies.mellanox.com >/dev/null 2>&1; then
  COUNT="$(kubectl --context "${CTX}" get nicclusterpolicies.mellanox.com -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${COUNT}" != "0" ]]; then
    ok "NicClusterPolicy count=${COUNT}"
  else
    warn "NicClusterPolicy CRD present but no instances"
  fi
else
  warn "NicClusterPolicy CRD not found yet"
fi

if kubectl --context "${CTX}" -n "${SEAWEED_NS}" get deploy seaweedfs >/dev/null 2>&1; then
  READY="$(kubectl --context "${CTX}" -n "${SEAWEED_NS}" get deploy seaweedfs -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${READY}" == "1" ]]; then
    ok "SeaweedFS ready in ${SEAWEED_NS}"
  else
    warn "SeaweedFS not ready (Stage2 cold tier)"
  fi
else
  warn "SeaweedFS missing (Stage2 cold tier optional if you change remote_url)"
fi

if kubectl --context "${CTX}" -n "${SEAWEED_NS}" get secret "${SEAWEED_SECRET}" >/dev/null 2>&1; then
  ok "S3 secret ${SEAWEED_NS}/${SEAWEED_SECRET} exists"
else
  warn "missing ${SEAWEED_NS}/${SEAWEED_SECRET} (needed for Stage2 bucket job)"
fi

CHECK_NS="${SEAWEED_NS}"
POD="vllm-gpu-preflight-$$"
cleanup() { kubectl --context "${CTX}" -n "${CHECK_NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl --context "${CTX}" -n "${CHECK_NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "${CTX}" -n "${CHECK_NS}" run "${POD}" \
  --image=curlimages/curl:8.5.0 --restart=Never --labels="app=vllm-gpu-preflight" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl:8.5.0","command":["sleep","90"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":1000,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}' \
  >/dev/null
kubectl --context "${CTX}" -n "${CHECK_NS}" wait --for=condition=Ready "pod/${POD}" --timeout=90s >/dev/null

if kubectl --context "${CTX}" -n "${CHECK_NS}" exec "${POD}" -- curl -fsI -m 20 https://huggingface.co >/dev/null 2>&1; then
  ok "Pod can reach huggingface.co"
else
  bad "Pod cannot reach huggingface.co (model pull will fail)"
fi

echo
echo "---- path map ----"
echo "  GPU CUDA package : ${ROOT}"
echo "  CPU simulation  : $(cd "${ROOT}/../.." && pwd)/vLLM-cpu/deploy"
echo "  Operators        : ./scripts/00-install-operators.sh"
echo "  Stage1 single GPU + APC/chunked prefill"
echo "  Stage2 LMCacheConnectorV1 + dual engine + Seaweed cold tier"
echo "  Stage3 Prefill/Decode + NixlConnector + pd-proxy (needs RDMA for cross-node)"
echo

echo "Summary: PASS=${pass} WARN=${warn} FAIL=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  echo "Fix FAIL items (often: ./scripts/00-install-operators.sh), then re-run."
  exit 1
fi
echo "Preflight OK. Next: ./scripts/01-deploy-stage1.sh"
echo "Before Stage3 RDMA PD: REQUIRE_NETWORK_OPERATOR=1 ./scripts/00-validate.sh"
exit 0
