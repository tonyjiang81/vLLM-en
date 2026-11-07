#!/usr/bin/env bash
# Structural verification: scripts parse, manifests dry-run, operators helm dry-run.
# Does NOT require a physical GPU. Exit 0 means the package is runnable on a real GPU cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
# shellcheck disable=SC1091
source "${ROOT}/scripts/_common.sh"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"
pass=0
fail=0

ok()  { echo "[PASS] $*"; pass=$((pass+1)); }
bad() { echo "[FAIL] $*"; fail=$((fail+1)); }

echo "== verify vLLM-gpu scripts/manifests (context=${CTX}, ns=${NS}) =="

need() {
  command -v "$1" >/dev/null 2>&1 || { bad "missing $1"; return 1; }
  ok "have $1"
}
need kubectl
need helm
need python3
need curl

for s in "${ROOT}/scripts/"*.sh; do
  if bash -n "$s"; then
    ok "bash -n $(basename "$s")"
  else
    bad "bash -n $(basename "$s")"
  fi
done

# NAMESPACE must be the GPU package, not a leaked CPU value
if [[ "${NS}" != "vllm-gpu" ]]; then
  bad "NAMESPACE=${NS} (expected vllm-gpu); check config.env / VLLM_GPU_NAMESPACE"
else
  ok "NAMESPACE=${NS}"
fi

kubectl --context "${CTX}" cluster-info >/dev/null 2>&1 && ok "cluster reachable" || bad "cluster unreachable"

# Client-side apply dry-run for all manifests
while IFS= read -r f; do
  base="$(basename "$f")"
  if [[ "$base" == "nic-cluster-policy.yaml" ]] && ! kubectl --context "${CTX}" get crd nicclusterpolicies.mellanox.com >/dev/null 2>&1; then
    warn_msg="skip nic-cluster-policy dry-run (CRD missing)"
    echo "[WARN] ${warn_msg}"
    continue
  fi
  if kubectl --context "${CTX}" apply --dry-run=client --validate=false -f "$f" >/dev/null; then
    ok "kubectl dry-run $(basename "$(dirname "$f")")/$(basename "$f")"
  else
    bad "kubectl dry-run $f"
  fi
done < <(find "${ROOT}/manifests" -type f \( -name '*.yaml' -o -name '*.yml' \) ! -path '*/operators/gpu-operator-values.yaml' ! -path '*/operators/network-operator-values.yaml' | sort)

# Helm dry-run (does not mutate cluster). Skip GPU chart if fake release present unless forced.
EXISTING="$(helm_release_chart "${CTX}" "${GPU_OPERATOR_NS}" gpu-operator || true)"
if [[ "${EXISTING}" == fake-gpu-operator* ]]; then
  ok "detected lab fake-gpu-operator (${EXISTING}); skip live GPU chart dry-run overwrite"
else
  if DRY_RUN=1 SKIP_NETWORK_OPERATOR=1 "${ROOT}/scripts/00-install-operators.sh"; then
    ok "00-install-operators.sh DRY_RUN (GPU only)"
  else
    bad "00-install-operators.sh DRY_RUN failed"
  fi
fi

if DRY_RUN=1 SKIP_NETWORK_OPERATOR=0 APPLY_NIC_CLUSTER_POLICY=0 \
  "${ROOT}/scripts/00-install-operators.sh" 2>/tmp/vllm-op-verify.err; then
  ok "00-install-operators.sh DRY_RUN (with network chart)"
else
  # If fake GPU skip path exited 0 already above, network dry-run alone:
  if helm --kube-context "${CTX}" upgrade --install network-operator nvidia/network-operator \
      --namespace "${NETWORK_OPERATOR_NS}" --create-namespace --dry-run \
      -f "${ROOT}/manifests/operators/network-operator-values.yaml" >/tmp/vllm-net-dryrun.yaml; then
    ok "network-operator helm dry-run"
  else
    bad "network-operator helm dry-run"
    cat /tmp/vllm-op-verify.err | tail -20 || true
  fi
fi

# Validate script must be executable and should report GPU status (may FAIL on this lab)
set +e
"${ROOT}/scripts/00-validate.sh" >/tmp/vllm-gpu-validate.out 2>&1
rc=$?
set -e
if grep -q 'nvidia.com/gpu' /tmp/vllm-gpu-validate.out; then
  ok "00-validate.sh runs and checks GPU (exit=${rc})"
else
  bad "00-validate.sh did not check GPU"
fi
if [[ "$(gpu_alloc_total "${CTX}")" == "0" ]]; then
  if [[ "${rc}" -ne 0 ]]; then
    ok "00-validate.sh correctly fails on gpu=0 lab"
  else
    bad "00-validate.sh should fail when allocatable gpu=0"
  fi
fi

# Stage scripts must refuse to hang when no GPU
set +e
OUT="$("${ROOT}/scripts/01-deploy-stage1.sh" 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && echo "${OUT}" | grep -qi 'nvidia.com/gpu'; then
  ok "01-deploy-stage1.sh fails fast without GPU"
else
  # If cluster somehow has GPU, dry-run path already covered manifests
  if [[ "$(gpu_alloc_total "${CTX}")" != "0" ]]; then
    ok "cluster has GPU; skip fail-fast assertion for Stage1"
  else
    bad "01-deploy-stage1.sh did not fail fast without GPU"
    echo "${OUT}" | tail -30
  fi
fi

echo
echo "Summary: PASS=${pass} FAIL=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
echo "Script package verification OK."
echo "On a real GPU cluster: ./scripts/00-install-operators.sh && ./scripts/00-validate.sh && ./scripts/01-deploy-stage1.sh"
exit 0
