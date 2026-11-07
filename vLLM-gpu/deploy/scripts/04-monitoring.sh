#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Monitoring for vLLM-gpu =="

kubectl --context "${CTX}" -n monitoring scale deploy/monitoring-kube-prometheus-operator --replicas=1 2>/dev/null || true
kubectl --context "${CTX}" -n monitoring scale deploy/monitoring-grafana --replicas=1 2>/dev/null || true
kubectl --context "${CTX}" -n monitoring patch prometheus monitoring-kube-prometheus-prometheus \
  --type merge -p '{"spec":{"replicas":1}}' 2>/dev/null || true

kubectl --context "${CTX}" -n "${NS}" label svc vllm-single app=vllm-single stage=1 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-a app=vllm-a stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-b app=vllm-b stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc lmcache app=lmcache stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-prefill app=vllm-prefill stage=3 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-decode app=vllm-decode stage=3 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-pd app=pd-proxy stage=3 --overwrite 2>/dev/null || true

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/monitoring/servicemonitors.yaml"
kubectl --context "${CTX}" apply -f "${ROOT}/manifests/monitoring/grafana-dashboard.yaml"

kubectl --context "${CTX}" -n monitoring rollout restart deploy/monitoring-grafana 2>/dev/null || true
kubectl --context "${CTX}" -n monitoring rollout status deploy/monitoring-grafana --timeout=180s 2>/dev/null || true

USER=$(kubectl --context "${CTX}" -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 --decode || echo admin)
PASS=$(kubectl --context "${CTX}" -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode || echo "")
NODE_IP=$(kubectl --context "${CTX}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "NODE_IP")

echo
echo "Monitoring applied."
echo "  Grafana:   http://${NODE_IP}:30300  (user=${USER})"
echo "  Password:  ${PASS}"
echo "  Dashboard: search 'vLLM GPU' (uid=vllm-gpu)"
echo "  Also keep CPU simulation board: 'vLLM CPU Lab' (uid=vllm-cpu-lab)"
