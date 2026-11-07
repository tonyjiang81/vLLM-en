#!/usr/bin/env bash
# Preflight checks before any deploy. Exit non-zero on hard failures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"

CTX="${KUBE_CONTEXT}"
pass=0
warn=0
fail=0

ok()   { echo "[PASS] $*"; pass=$((pass+1)); }
warn() { echo "[WARN] $*"; warn=$((warn+1)); }
bad()  { echo "[FAIL] $*"; fail=$((fail+1)); }

echo "== vLLM-cpu preflight (context=${CTX}, ns=${NAMESPACE}) =="

if ! kubectl --context "${CTX}" cluster-info >/dev/null 2>&1; then
  bad "cannot reach API for context ${CTX}"
  echo "Fix kubeconfig / network to 192.168.10.108:6443 first."
  exit 1
fi
ok "kubectl context ${CTX} reachable"

NODE_MEM="$(kubectl --context "${CTX}" get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || true)"
NODE_CPU="$(kubectl --context "${CTX}" get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || true)"
echo "     allocatable cpu=${NODE_CPU} memory=${NODE_MEM}"
if kubectl --context "${CTX}" top nodes >/dev/null 2>&1; then
  kubectl --context "${CTX}" top nodes | sed 's/^/     /'
  ok "metrics-server / top nodes"
else
  warn "kubectl top nodes unavailable (non-fatal)"
fi

if kubectl --context "${CTX}" -n "${SEAWEED_NS}" get deploy seaweedfs >/dev/null 2>&1; then
  READY="$(kubectl --context "${CTX}" -n "${SEAWEED_NS}" get deploy seaweedfs -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${READY}" == "1" ]]; then
    ok "SeaweedFS deploy ready in ${SEAWEED_NS}"
  else
    bad "SeaweedFS not ready (readyReplicas=${READY})"
  fi
else
  bad "SeaweedFS deploy missing in ${SEAWEED_NS}"
fi

if kubectl --context "${CTX}" -n "${SEAWEED_NS}" get secret "${SEAWEED_SECRET}" >/dev/null 2>&1; then
  ok "Seaweed S3 secret ${SEAWEED_NS}/${SEAWEED_SECRET} exists"
else
  bad "missing secret ${SEAWEED_NS}/${SEAWEED_SECRET}"
fi

# Ephemeral net check pod in a low-PSS namespace
CHECK_NS="${SEAWEED_NS}"
POD="vllm-cpu-preflight-$$"
cleanup() { kubectl --context "${CTX}" -n "${CHECK_NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl --context "${CTX}" -n "${CHECK_NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "${CTX}" -n "${CHECK_NS}" run "${POD}" \
  --image=curlimages/curl:8.5.0 --restart=Never --labels="app=vllm-cpu-preflight" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl:8.5.0","command":["sleep","90"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":1000,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}' \
  >/dev/null
kubectl --context "${CTX}" -n "${CHECK_NS}" wait --for=condition=Ready "pod/${POD}" --timeout=90s >/dev/null

if kubectl --context "${CTX}" -n "${CHECK_NS}" exec "${POD}" -- curl -fsI -m 20 https://huggingface.co >/dev/null 2>&1; then
  ok "Pod can reach huggingface.co"
else
  bad "Pod cannot reach huggingface.co (model pull will fail)"
fi

if kubectl --context "${CTX}" -n "${CHECK_NS}" exec "${POD}" -- curl -sI -m 10 "http://${SEAWEED_SVC}:${SEAWEED_S3_PORT}/status" 2>/dev/null | head -1 | grep -Eq 'HTTP/1\.[01] (200|403)'; then
  ok "Seaweed S3 endpoint responds on ${SEAWEED_SVC}:${SEAWEED_S3_PORT}"
else
  warn "Seaweed S3 /status unexpected (still may work with signed requests)"
fi

# Soft image existence check via docker hub API from workstation
if curl -fsS "https://hub.docker.com/v2/repositories/vllm/vllm-openai-cpu/tags/v0.33.0-x86_64" >/dev/null 2>&1; then
  ok "Docker Hub has ${VLLM_IMAGE%%:*} tag v0.33.0-x86_64"
else
  warn "Could not verify ${VLLM_IMAGE} on Docker Hub from this machine"
fi

if curl -fsS "https://hub.docker.com/v2/repositories/lmcache/standalone/tags/v0.5.7-amd64" >/dev/null 2>&1; then
  ok "Docker Hub has lmcache/standalone:v0.5.7-amd64"
else
  warn "Could not verify LMCache standalone tag (Stage2 may fail to pull)"
fi

echo
echo "---- plan reasonableness ----"
echo "  Stage1 single CPU serve     : EXPECT SUCCESS (official image + opt-125m + free RAM)"
echo "  Engine --swap-space demo    : LIMITED (V1 removed GPU<->CPU SWAP; watch preemption/cache)"
echo "  Stage2 LMCache + SeaweedFS  : TRY WITH CAUTION (CPU pip-install lmcache; engine_driven)"
echo "  Stage3 fake PD              : OPTIONAL after Stage2; topology only, not faster on 8c/16t"
echo

echo "Summary: PASS=${pass} WARN=${warn} FAIL=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  echo "Refusing to claim ready-to-deploy. Fix FAIL items, then re-run."
  exit 1
fi
echo "Preflight OK. Next: ./scripts/01-deploy-stage1.sh"
exit 0
