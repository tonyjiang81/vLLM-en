#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== undeploy namespace ${NS} (context ${CTX}) =="
if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "Delete all resources in namespace ${NS}? [y/N] " ans
  if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
    echo "aborted"
    exit 0
  fi
fi

kubectl --context "${CTX}" delete ns "${NS}" --wait=true --timeout=180s || \
  kubectl --context "${CTX}" -n "${NS}" delete all --all --timeout=120s || true
echo "done."
