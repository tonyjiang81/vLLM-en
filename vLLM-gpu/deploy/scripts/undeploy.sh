#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== undeploy namespace ${NS} (context ${CTX}) =="
if [[ "${1:-}" != "-y" ]]; then
  read -r -p "Delete all resources in namespace ${NS}? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || exit 0
fi

kubectl --context "${CTX}" delete ns "${NS}" --wait=true --timeout=300s || \
  kubectl --context "${CTX}" -n "${NS}" delete all --all --timeout=180s || true
kubectl --context "${CTX}" -n monitoring delete cm grafana-dashboard-vllm-gpu --ignore-not-found >/dev/null 2>&1 || true
echo "done."
