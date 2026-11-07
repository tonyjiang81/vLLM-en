#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage2 shared KV (LMCache + dual GPU) =="
kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"

# Scale down Stage1 to free GPU if needed
if kubectl --context "${CTX}" -n "${NS}" get deploy vllm-single >/dev/null 2>&1; then
  kubectl --context "${CTX}" -n "${NS}" scale deploy/vllm-single --replicas=0 || true
fi

# Copy Seaweed S3 credentials into this namespace
kubectl --context "${CTX}" -n "${SEAWEED_NS}" get secret "${SEAWEED_SECRET}" -o json \
  | python3 -c "
import json,sys,os
d=json.load(sys.stdin)
out={
  'apiVersion':'v1','kind':'Secret',
  'metadata':{'name':'seaweed-s3','namespace':'${NS}','labels':{'stage':'2'}},
  'type':'Opaque',
  'data':{
    'accesskey': d['data'].get('accesskey') or d['data'].get('AWS_ACCESS_KEY_ID') or d['data'].get('accessKey'),
    'secretkey': d['data'].get('secretkey') or d['data'].get('AWS_SECRET_ACCESS_KEY') or d['data'].get('secretKey'),
  }
}
json.dump(out, sys.stdout)
" | kubectl --context "${CTX}" apply -f -

kubectl --context "${CTX}" -n "${NS}" delete job seaweed-create-kv-cache-bucket --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/bucket-job.yaml"
kubectl --context "${CTX}" -n "${NS}" wait --for=condition=complete job/seaweed-create-kv-cache-bucket --timeout=180s \
  || echo "[WARN] bucket job not complete yet; continuing"

kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/kv-transfer-config.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/lmcache-server.yaml"
kubectl --context "${CTX}" -n "${NS}" apply -f "${ROOT}/manifests/stage2-shared-kv/vllm-shared.yaml"

kubectl --context "${CTX}" -n "${NS}" rollout status deploy/lmcache --timeout=300s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-a --timeout=900s
kubectl --context "${CTX}" -n "${NS}" rollout status deploy/vllm-b --timeout=900s
echo "Stage2 ready."
echo "  Smoke: ${ROOT}/scripts/smoke-test.sh stage2"
