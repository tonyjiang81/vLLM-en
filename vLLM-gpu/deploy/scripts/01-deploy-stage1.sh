#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage1 single GPU engine (${NS}) =="
require_gpu_capacity "${CTX}" 1

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage1-single/deployment.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage1-single/service.yaml"

kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-single --timeout=900s
echo "Stage1 ready."
echo "  Port-forward: kubectl --context ${CTX} -n ${NS} port-forward svc/vllm-single 8000:8000"
echo "  Smoke: ${ROOT}/scripts/smoke-test.sh stage1"
