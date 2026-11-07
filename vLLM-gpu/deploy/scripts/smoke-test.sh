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

LOCAL_PORT="${LOCAL_PORT:-18010}"
PF_PID=""
cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

pf() {
  cleanup
  kubectl --context "${CTX}" -n "${NS}" port-forward "$1" "${LOCAL_PORT}:$2" >/tmp/vllm-gpu-pf.log 2>&1 &
  PF_PID=$!
  sleep 2
}

echo "== smoke ${STAGE} via ${SVC} (ns=${NS}) =="
pf "svc/${SVC}" 8000
BASE="http://127.0.0.1:${LOCAL_PORT}"

echo "-- health --"
curl -fsS "${BASE}/health" && echo

PREFIX="You are a helpful ops assistant for vLLM GPU serving. Shared system context for cache test. "
PROMPT1="${PREFIX}Say hello in one short sentence."
PROMPT2="${PREFIX}Say goodbye in one short sentence."

echo "-- completion #1 --"
START=$(python3 -c 'import time; print(int(time.time()*1000))')
curl -fsS "${BASE}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT1}"),\"max_tokens\":32,\"temperature\":0}" \
  | python3 -m json.tool | head -40
END=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "wall_ms_approx=$((END-START))"

echo "-- completion #2 (same prefix) --"
START=$(python3 -c 'import time; print(int(time.time()*1000))')
curl -fsS "${BASE}/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT2}"),\"max_tokens\":32,\"temperature\":0}" \
  | python3 -m json.tool | head -40
END=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "wall_ms_approx=$((END-START))"

echo "-- metrics snippet --"
curl -fsS "${BASE}/metrics" | grep -Ei 'cache|prefix|preempt|kv_cache|gpu|vllm:' | head -50 || true

if [[ "${STAGE}" == "stage2" ]]; then
  echo "-- vllm-b completion --"
  pf "svc/vllm-b" 8000
  curl -fsS "${BASE}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${PROMPT1}"),\"max_tokens\":16,\"temperature\":0}" \
    | python3 -m json.tool | head -20
fi

echo "smoke ${STAGE} done."
