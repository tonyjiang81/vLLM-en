#!/bin/bash
set -euo pipefail
CTX=108

echo "Restoring k3s workloads on context ${CTX}"
kubectl --context "$CTX" -n slinky scale deploy slurm-operator-webhook --replicas=1
kubectl --context "$CTX" -n slinky rollout status deploy/slurm-operator-webhook --timeout=180s
kubectl --context "$CTX" patch nodesets.slinky.slurm.net -n slurm slurm-worker-lab --type merge -p '{"spec":{"replicas":1}}'
kubectl --context "$CTX" patch loginsets.slinky.slurm.net -n slurm slurm-login-lab --type merge -p '{"spec":{"replicas":1}}'
kubectl --context "$CTX" patch restapis.slinky.slurm.net -n slurm slurm --type merge -p '{"spec":{"replicas":1}}'

kubectl --context "$CTX" -n agent-lab scale deploy agent-api --replicas=1
kubectl --context "$CTX" -n agent-lab scale deploy agent-redis --replicas=1
kubectl --context "$CTX" -n agent-lab scale deploy agent-worker --replicas=1
kubectl --context "$CTX" -n ai-infra scale deploy ollama --replicas=1
kubectl --context "$CTX" -n cert-manager scale deploy cert-manager --replicas=1
kubectl --context "$CTX" -n cert-manager scale deploy cert-manager-cainjector --replicas=1
kubectl --context "$CTX" -n cert-manager scale deploy cert-manager-webhook --replicas=1
kubectl --context "$CTX" -n gateway scale deploy lab-gateway-index --replicas=1
kubectl --context "$CTX" -n gateway scale deploy lab-gateway-istio --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy gpu-operator --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy kwok-gpu-device-plugin --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy nvidia-dcgm-exporter --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy nvidia-dcgm-exporter-kwok --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy status-updater --replicas=1
kubectl --context "$CTX" -n gpu-operator scale deploy topology-server --replicas=1
kubectl --context "$CTX" -n istio-system scale deploy istio-egressgateway --replicas=1
kubectl --context "$CTX" -n istio-system scale deploy istio-ingressgateway --replicas=1
kubectl --context "$CTX" -n istio-system scale deploy istiod --replicas=1
kubectl --context "$CTX" -n istio-system scale deploy kiali --replicas=1
kubectl --context "$CTX" -n keda scale deploy keda-admission-webhooks --replicas=1
kubectl --context "$CTX" -n keda scale deploy keda-operator --replicas=1
kubectl --context "$CTX" -n keda scale deploy keda-operator-metrics-apiserver --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy cache-deployer-deployment --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy cache-server --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy metadata-envoy-deployment --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy metadata-grpc-deployment --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy metadata-writer --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline-persistenceagent --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline-scheduledworkflow --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline-ui --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline-viewer-crd --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy ml-pipeline-visualizationserver --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy mysql --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy seaweedfs --replicas=1
kubectl --context "$CTX" -n kubeflow scale deploy workflow-controller --replicas=1
kubectl --context "$CTX" -n kuberay-system scale deploy kuberay-operator --replicas=1
kubectl --context "$CTX" -n langfuse scale deploy langfuse-s3 --replicas=1
kubectl --context "$CTX" -n langfuse scale deploy langfuse-web --replicas=1
kubectl --context "$CTX" -n langfuse scale deploy langfuse-worker --replicas=1
kubectl --context "$CTX" -n metallb-system scale deploy controller --replicas=1
kubectl --context "$CTX" -n mlops scale deploy minio --replicas=1
kubectl --context "$CTX" -n mlops scale deploy mlflow --replicas=1
kubectl --context "$CTX" -n mlops scale deploy postgres --replicas=1
kubectl --context "$CTX" -n monitoring scale deploy monitoring-grafana --replicas=1
kubectl --context "$CTX" -n monitoring scale deploy monitoring-kube-prometheus-operator --replicas=1
kubectl --context "$CTX" -n monitoring scale deploy monitoring-kube-state-metrics --replicas=1
kubectl --context "$CTX" -n monitoring scale deploy thanos-query --replicas=1
kubectl --context "$CTX" -n nvidia-network-operator scale deploy network-operator --replicas=1
kubectl --context "$CTX" -n nvidia-network-operator scale deploy network-operator-node-feature-discovery-gc --replicas=1
kubectl --context "$CTX" -n nvidia-network-operator scale deploy network-operator-node-feature-discovery-master --replicas=1
kubectl --context "$CTX" -n observability scale deploy jaeger --replicas=1
kubectl --context "$CTX" -n observability scale deploy opentelemetry-collector --replicas=1
kubectl --context "$CTX" -n observability scale deploy otel-collector --replicas=1
kubectl --context "$CTX" -n observability scale deploy tempo --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy adservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy cartservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy checkoutservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy currencyservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy emailservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy frontend --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy loadgenerator --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy paymentservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy productcatalogservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy recommendationservice --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy redis-cart --replicas=1
kubectl --context "$CTX" -n online-boutique scale deploy shippingservice --replicas=1
kubectl --context "$CTX" -n slinky scale deploy slurm-operator --replicas=1
kubectl --context "$CTX" -n slinky scale deploy slurm-operator-webhook --replicas=1
kubectl --context "$CTX" -n slurm scale deploy slurm-login-lab --replicas=1
kubectl --context "$CTX" -n slurm scale deploy slurm-restapi --replicas=1
kubectl --context "$CTX" -n langfuse scale sts langfuse-clickhouse-shard0 --replicas=1
kubectl --context "$CTX" -n langfuse scale sts langfuse-postgresql --replicas=1
kubectl --context "$CTX" -n langfuse scale sts langfuse-redis-primary --replicas=1
kubectl --context "$CTX" -n langfuse scale sts langfuse-zookeeper --replicas=1
kubectl --context "$CTX" -n monitoring scale sts alertmanager-monitoring-kube-prometheus-alertmanager --replicas=1
kubectl --context "$CTX" -n monitoring scale sts prometheus-p8s --replicas=1
kubectl --context "$CTX" -n monitoring scale sts prometheus-p8s-shard-1 --replicas=1
kubectl --context "$CTX" -n slurm scale sts slurm-controller --replicas=1

echo "Removing vllm-paused from DaemonSets"
kubectl --context "$CTX" get ds -A -o json | python3 -c '
import json, subprocess, sys
data = json.load(sys.stdin)
for item in data["items"]:
    ns = item["metadata"]["namespace"]
    if ns == "kube-system":
        continue
    name = item["metadata"]["name"]
    selector = (item["spec"]["template"]["spec"].get("nodeSelector") or {})
    if "vllm-paused" not in selector:
        continue
    if len(selector) == 1:
        patch = [{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]
    else:
        patch = [{"op": "remove", "path": "/spec/template/spec/nodeSelector/vllm-paused"}]
    subprocess.check_call(["kubectl", "--context", "108", "-n", ns, "patch", "ds", name, "--type", "json", "-p", json.dumps(patch)])
'
