#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage3 Prefill/Decode (NixlConnector + pd-proxy) =="
require_gpu_capacity "${CTX}" 2

if [[ "${REQUIRE_NETWORK_OPERATOR:-0}" == "1" ]]; then
  keys="$(rdma_resource_keys "${CTX}")"
  if [[ -z "${keys}" ]]; then
    echo "[FAIL] REQUIRE_NETWORK_OPERATOR=1 but no rdma/* allocatable"
    exit 1
  fi
  echo "[PASS] RDMA resources: ${keys}"
fi

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"

# Free GPUs from earlier stages
for d in vllm-single vllm-a vllm-b; do
  if kubectl --context "${CTX}" -n "${NS}" get deploy "${d}" >/dev/null 2>&1; then
    kubectl --context "${CTX}" -n "${NS}" scale "deploy/${d}" --replicas=0 || true
  fi
done

kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage3-pd/pd.yaml"
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-prefill --timeout=900s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-decode --timeout=900s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/pd-proxy --timeout=180s
echo "Stage3 ready."
echo "  Port-forward: kubectl --context ${CTX} -n ${NS} port-forward svc/vllm-pd 8000:8000"
echo "  Smoke: ${ROOT}/scripts/smoke-test.sh stage3"
