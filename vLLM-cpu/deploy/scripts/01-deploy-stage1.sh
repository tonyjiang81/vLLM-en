#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage1: single vLLM CPU (${MODEL}) =="
"${ROOT}/scripts/00-validate.sh"

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage1-single/deployment.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage1-single/service.yaml"

echo "Waiting for vllm-single rollout..."
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-single --timeout=600s

echo
echo "Stage1 ready."
echo "  Port-forward: kubectl --context ${CTX} -n ${NS} port-forward svc/vllm-single 8000:8000"
echo "  Smoke:        ${ROOT}/scripts/smoke-test.sh stage1"
