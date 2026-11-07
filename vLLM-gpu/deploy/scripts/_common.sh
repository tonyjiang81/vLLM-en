#!/usr/bin/env bash
# Shared helpers for vLLM-gpu deploy scripts. Sourced, not executed.

gpu_alloc_total() {
  local ctx="${1:?}"
  kubectl --context "${ctx}" get nodes -o json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(int(n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0")) for n in d.get("items",[])))' \
    2>/dev/null || echo 0
}

rdma_resource_keys() {
  local ctx="${1:?}"
  kubectl --context "${ctx}" get nodes -o json 2>/dev/null \
    | python3 -c '
import sys,json
d=json.load(sys.stdin)
keys=set()
for n in d.get("items",[]):
  for k in (n.get("status",{}).get("allocatable") or {}):
    if k.startswith("rdma/") or "rdma" in k.lower():
      keys.add(k)
print(",".join(sorted(keys)))
' 2>/dev/null || true
}

require_gpu_capacity() {
  local ctx="${1:?}"
  local need="${2:-1}"
  local got
  got="$(gpu_alloc_total "${ctx}")"
  if ! [[ "${got}" =~ ^[0-9]+$ ]] || [[ "${got}" -lt "${need}" ]]; then
    echo "[FAIL] need nvidia.com/gpu>=${need}, allocatable=${got}"
    echo "       Install/fix GPU Operator on nodes with real NVIDIA GPUs, then re-run."
    echo "       This lab node may only have fake-gpu-operator (gpu=0)."
    return 1
  fi
  echo "[PASS] nvidia.com/gpu allocatable=${got} (need>=${need})"
}

helm_release_chart() {
  local ctx="${1:?}" ns="${2:?}" name="${3:?}"
  helm --kube-context "${ctx}" list -n "${ns}" -o json 2>/dev/null \
    | python3 -c '
import sys,json
name=sys.argv[1]
try:
  rows=json.load(sys.stdin)
except Exception:
  rows=[]
for r in rows:
  if r.get("name")==name:
    print(r.get("chart",""))
    break
' "${name}" 2>/dev/null || true
}
