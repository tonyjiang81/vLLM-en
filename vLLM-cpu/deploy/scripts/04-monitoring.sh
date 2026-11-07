#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.env"
CTX="${KUBE_CONTEXT}"
NS="${NAMESPACE}"

echo "== Start Prometheus + Grafana (monitoring ns) and scrape vllm-cpu =="

# Minimal kube-prometheus-stack pieces for the lab
kubectl --context "${CTX}" -n monitoring scale deploy/monitoring-kube-prometheus-operator --replicas=1
kubectl --context "${CTX}" -n monitoring scale deploy/monitoring-grafana --replicas=1
kubectl --context "${CTX}" -n monitoring patch prometheus monitoring-kube-prometheus-prometheus \
  --type merge -p '{"spec":{"replicas":1}}'

echo "Waiting for operator / prometheus / grafana..."
kubectl --context "${CTX}" -n monitoring rollout status deploy/monitoring-kube-prometheus-operator --timeout=300s
kubectl --context "${CTX}" -n monitoring rollout status deploy/monitoring-grafana --timeout=300s
# Prometheus is a StatefulSet owned by the operator
for i in $(seq 1 60); do
  READY=$(kubectl --context "${CTX}" -n monitoring get prometheus monitoring-kube-prometheus-prometheus -o jsonpath='{.status.ready}' 2>/dev/null || echo 0)
  echo "[$(date +%H:%M:%S)] prometheus readyReplicas=${READY}"
  if [[ "${READY}" == "1" ]]; then break; fi
  sleep 5
done

# Ensure Service labels match ServiceMonitor selectors (Stage1 + Stage2 + Stage3).
# stage label is also required so Grafana can filter by lab stage.
kubectl --context "${CTX}" -n "${NS}" label svc vllm-single app=vllm-single stage=1 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-a app=vllm-a stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-b app=vllm-b stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc lmcache app=lmcache stage=2 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-prefill app=vllm-prefill stage=3 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-decode app=vllm-decode stage=3 --overwrite 2>/dev/null || true
kubectl --context "${CTX}" -n "${NS}" label svc vllm-pd app=pd-proxy stage=3 --overwrite 2>/dev/null || true

# Scale Stage1/2 engines if present so Prometheus has scrape endpoints (Stage3 can stay up).
for d in vllm-single vllm-a vllm-b; do
  if kubectl --context "${CTX}" -n "${NS}" get deploy "${d}" >/dev/null 2>&1; then
    kubectl --context "${CTX}" -n "${NS}" scale "deploy/${d}" --replicas=1
  fi
done

kubectl --context "${CTX}" apply -f "${ROOT}/manifests/monitoring/servicemonitors.yaml"
kubectl --context "${CTX}" apply -f "${ROOT}/manifests/monitoring/grafana-dashboard.yaml"

# Point Grafana Prometheus DS at Prometheus itself (thanos-query is often scaled to 0 in this lab).
# Do NOT add a second isDefault datasource ConfigMap — Grafana will CrashLoop.
kubectl --context "${CTX}" -n monitoring create cm monitoring-kube-prometheus-grafana-datasource \
  --from-literal=datasource.yaml="$(cat <<'EOF'
apiVersion: 1
datasources:
- name: Prometheus
  type: prometheus
  uid: prometheus
  url: http://monitoring-kube-prometheus-prometheus.monitoring:9090
  access: proxy
  isDefault: true
  jsonData:
    httpMethod: POST
    timeInterval: 15s
- name: Alertmanager
  type: alertmanager
  uid: alertmanager
  url: http://monitoring-kube-prometheus-alertmanager.monitoring:9093/
  access: proxy
  jsonData:
    handleGrafanaManagedAlerts: false
    implementation: prometheus
EOF
)" -o yaml --dry-run=client | kubectl --context "${CTX}" -n monitoring apply -f -
kubectl --context "${CTX}" -n monitoring label cm monitoring-kube-prometheus-grafana-datasource \
  grafana_datasource=1 release=monitoring app=kube-prometheus-stack-grafana --overwrite || true
kubectl --context "${CTX}" -n monitoring delete cm grafana-datasource-prometheus-direct --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "${CTX}" -n monitoring rollout restart deploy/monitoring-grafana
kubectl --context "${CTX}" -n monitoring rollout status deploy/monitoring-grafana --timeout=180s

USER=$(kubectl --context "${CTX}" -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-user}' | base64 --decode)
PASS=$(kubectl --context "${CTX}" -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 --decode)
NODE_IP=$(kubectl --context "${CTX}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo
echo "Monitoring ready (lab)."
echo "  Grafana:    http://${NODE_IP}:30300  (user=${USER})"
echo "  Password:   ${PASS}"
echo "  Dashboard:  search 'vLLM CPU Lab' (uid=vllm-cpu-lab)"
echo "  Prometheus: kubectl --context ${CTX} -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo
echo "Generate a little traffic (any stage that is Ready):"
echo "  ${ROOT}/scripts/smoke-test.sh stage1"
echo "  ${ROOT}/scripts/smoke-test.sh stage2"
echo "  ${ROOT}/scripts/smoke-test.sh stage3"
