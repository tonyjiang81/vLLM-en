#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"
STAGE="${1:-stage1}"

case "${STAGE}" in
  stage1) SVC=vllm-single ;;
  stage2) SVC=vllm-a ;;
  stage3) SVC=vllm-pd ;;
  *) echo "usage: $0 stage1|stage2|stage3"; exit 2 ;;
esac

LOCAL_PORT="${LOCAL_PORT:-18000}"
PF_PID=""
cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

pf() {
  cleanup
  kubectl --context "${CTX}" -n "${NS}" port-forward "$1" "${LOCAL_PORT}:$2" >/tmp/vllm-cpu-pf.log 2>&1 &
  PF_PID=$!
  sleep 2
}

echo "== smoke ${STAGE} via ${SVC} =="
pf "svc/${SVC}" 8000
BASE="http://127.0.0.1:${LOCAL_PORT}"

echo "-- health --"
curl -fsS "${BASE}/health" && echo

PREFIX="You are a helpful ops assistant for vLLM CPU lab. Shared system context for cache test. "
PROMPT1="${PREFIX}Say hello in one short sentence."
PROMPT2="${PREFIX}Say goodbye in one short sentence."

echo "-- completion #1 --"
START=$(python3 -c 'import time; print(int(time.time()*1000))')
curl -fsS "${BASE}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT1}"),\"max_tokens\":16,\"temperature\":0}" \
  | python3 -m json.tool | head -40
END=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "wall_ms_approx=$((END-START))"

echo "-- completion #2 (same prefix) --"
START=$(python3 -c 'import time; print(int(time.time()*1000))')
curl -fsS "${BASE}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT2}"),\"max_tokens\":16,\"temperature\":0}" \
  | python3 -m json.tool | head -40
END=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "wall_ms_approx=$((END-START))"

echo "-- metrics snippet --"
curl -fsS "${BASE}/metrics" | grep -Ei 'cache|prefix|preempt|kv_cache|vllm:' | head -40 || true

if [[ "${STAGE}" == "stage2" ]]; then
  echo "-- vllm-b completion --"
  pf "svc/vllm-b" 8000
  curl -fsS "${BASE}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT1}"),\"max_tokens\":8,\"temperature\":0}" \
    | python3 -m json.tool | head -20

  echo "-- lmcache-mock cross-pod store/get --"
  KEY="demo-$(date +%s)"
  VAL="prefix-kv-chunk-from-pod-a"
  # write via curl from a one-shot pod (cluster DNS), then read stats
  kubectl --context "${CTX}" -n "${NS}" delete pod kv-mock-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CTX}" -n "${NS}" run kv-mock-smoke --restart=Never --image=curlimages/curl:8.5.0 \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl:8.5.0","command":["sleep","60"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}}]}}' \
    >/dev/null
  kubectl --context "${CTX}" -n "${NS}" wait --for=condition=Ready pod/kv-mock-smoke --timeout=60s >/dev/null
  kubectl --context "${CTX}" -n "${NS}" exec kv-mock-smoke -- \
    curl -fsS -X PUT --data-binary "${VAL}" "http://lmcache.vllm-cpu.svc:6555/kv/${KEY}"
  echo
  GOT=$(kubectl --context "${CTX}" -n "${NS}" exec kv-mock-smoke -- \
    curl -fsS "http://lmcache.vllm-cpu.svc:6555/kv/${KEY}")
  echo "got=${GOT}"
  kubectl --context "${CTX}" -n "${NS}" exec kv-mock-smoke -- \
    curl -fsS "http://lmcache.vllm-cpu.svc:6555/stats"
  echo
  kubectl --context "${CTX}" -n "${NS}" exec kv-mock-smoke -- \
    curl -fsS "http://lmcache.vllm-cpu.svc:6555/metrics" | head -20
  kubectl --context "${CTX}" -n "${NS}" delete pod kv-mock-smoke --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${GOT}" != "${VAL}" ]]; then
    echo "FAIL: mock cache roundtrip mismatch"
    exit 1
  fi
  echo "PASS: lmcache-mock L1 roundtrip ok (L2 to Seaweed may be best-effort)"
fi

echo "smoke ${STAGE} done."
