#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Stage2 shared KV (LMCache + dual GPU) =="
require_gpu_capacity "${CTX}" 2

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/namespace.yaml"

# Scale down Stage1 to free GPU if needed
if kubectl --context "${CTX}" -n "${NS}" get deploy vllm-single >/dev/null 2>&1; then
  kubectl --context "${CTX}" -n "${NS}" scale deploy/vllm-single --replicas=0 || true
fi

# Copy Seaweed S3 credentials into this namespace
SECRET_JSON="$(kubectl --context "${CTX}" -n "${SEAWEED_NS}" get secret "${SEAWEED_SECRET}" -o json)"
ACCESS="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["data"].get("accesskey") or d["data"].get("AWS_ACCESS_KEY_ID") or d["data"].get("accessKey") or "")' "${SECRET_JSON}")"
SECRET="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["data"].get("secretkey") or d["data"].get("AWS_SECRET_ACCESS_KEY") or d["data"].get("secretKey") or "")' "${SECRET_JSON}")"
if [[ -z "${ACCESS}" || -z "${SECRET}" ]]; then
  echo "[FAIL] cannot find accesskey/secretkey in ${SEAWEED_NS}/${SEAWEED_SECRET}"
  exit 1
fi
kubectl --context "${CTX}" -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: seaweed-s3
  namespace: ${NS}
  labels:
    stage: "2"
type: Opaque
data:
  accesskey: ${ACCESS}
  secretkey: ${SECRET}
EOF

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
