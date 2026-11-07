#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage3 MOCK: fake PD (Prefill + Decode + proxy) =="
echo "Topology drill only; not NIXL / real KV handoff. Expect no tokens/s gain on this CPU node."

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"

# Free CPU/RAM: scale Stage1/Stage2 vLLM down; keep lmcache-mock if present
for d in vllm-a vllm-b vllm-single; do
  if kubectl --context "${CTX}" -n "${NS}" get deploy "${d}" >/dev/null 2>&1; then
    echo "Scaling ${d} -> 0"
    kubectl --context "${CTX}" -n "${NS}" scale "deploy/${d}" --replicas=0 || true
  fi
done

kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage3-pd-fake/pd.yaml"
echo "Waiting for Prefill / Decode / proxy..."
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-prefill --timeout=600s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-decode --timeout=600s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/pd-proxy --timeout=180s

echo
echo "Stage3 MOCK ready."
echo "  Entry: svc/vllm-pd (proxy -> prefill warm -> decode)"
echo "  Smoke: ${ROOT}/scripts/smoke-test.sh stage3"
