#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage2 MOCK: dual vLLM + lmcache-mock + SeaweedFS =="
echo "NOTE: real LMCache/CUDA stack is skipped on this CPU lab."

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"
kubectl --context "${CTX}" apply -f "${ROOT}/manifests/stage2-shared-kv/seaweed-netpol.yaml"

# Copy Seaweed S3 credentials into this namespace
kubectl --context "${CTX}" -n "${SEAWEED_NS}" get secret "${SEAWEED_SECRET}" -o json \
  | python3 -c "
import json,sys
s=json.load(sys.stdin)
out={
  'apiVersion':'v1','kind':'Secret',
  'metadata':{'name':'seaweed-s3','namespace':'${NS}','labels':{'stage':'2'}},
  'type':'Opaque',
  'data':{'accesskey':s['data']['accesskey'],'secretkey':s['data']['secretkey']}
}
json.dump(out,sys.stdout)
" | kubectl --context "${CTX}" apply -f -

kubectl --context "${CTX}" -n "${NS}" delete job seaweed-create-kv-cache-bucket --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/bucket-job.yaml"
echo "Waiting for Seaweed bucket job..."
kubectl --context "${CTX}" -n "${NS}" wait --for=condition=complete job/seaweed-create-kv-cache-bucket --timeout=180s \
  || { echo "Bucket job failed"; kubectl --context "${CTX}" -n "${NS}" logs job/seaweed-create-kv-cache-bucket || true; exit 1; }

# Remove any leftover real-lmcache attempt artifacts that conflict
kubectl --context "${CTX}" -n "${NS}" delete configmap lmcache-l2-adapter kv-transfer-config --ignore-not-found >/dev/null 2>&1 || true

kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/lmcache-mock.yaml"
echo "Waiting for lmcache-mock..."
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/lmcache --timeout=180s

if kubectl --context "${CTX}" -n "${NS}" get deploy vllm-single >/dev/null 2>&1; then
  echo "Scaling Stage1 vllm-single -> 0 to free resources"
  kubectl --context "${CTX}" -n "${NS}" scale deploy/vllm-single --replicas=0
fi

kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/vllm-shared.yaml"
echo "Waiting for vllm-a / vllm-b..."
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-a --timeout=600s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-b --timeout=600s

echo
echo "Stage2 MOCK ready."
echo "  Components: lmcache-mock (L1+Seaweed L2) + vllm-a + vllm-b"
echo "  Smoke: ${ROOT}/scripts/smoke-test.sh stage2"
