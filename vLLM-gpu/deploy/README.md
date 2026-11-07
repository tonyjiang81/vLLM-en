# vLLM-gpu deploy package (CUDA / NVIDIA)

This directory is the **GPU / CUDA production path** staged package, matching `INSTALL.md` / `OPTIMIZATION.md`.

The sibling **CPU simulation path** is `../../vLLM-cpu/deploy` (same Stage narrative with the official CPU image).

Stages align for side-by-side comparison:

| Stage | GPU (this tree) | CPU simulation |
|---|---|---|
| 0 operators | NVIDIA GPU Operator + Network Operator | n/a |
| 1 single engine | `vllm-single` + APC / chunked prefill / `gpu_memory_utilization` | same topology, CPU image + `VLLM_CPU_KVCACHE_SPACE` |
| 2 shared KV | `LMCacheConnectorV1` + dual engines + Seaweed cold tier | `lmcache-mock` + dual-engine topology drill |
| 3 PD | Prefill/Decode + `NixlConnector` + `pd-proxy` + RDMA | fake PD entry topology |
| Monitoring | DCGM GPU util / FB + vLLM metrics, dashboard `vLLM GPU` | container CPU/KV, dashboard `vLLM CPU Lab` |

---

## Layout

```
deploy/
  config.env
  README.md
  scripts/
    00-install-operators.sh   # GPU Operator + Network Operator (Helm)
    00-validate.sh
    01-deploy-stage1.sh
    02-deploy-stage2.sh
    03-deploy-stage3.sh
    04-monitoring.sh
    smoke-test.sh
    undeploy.sh
  manifests/
    operators/                # Helm values + NicClusterPolicy sample
    namespace.yaml
    stage1-single/
    stage2-shared-kv/
    stage3-pd/
    monitoring/
```

---

## Prerequisites

| Component | Needed for | Notes |
|---|---|---|
| **NVIDIA GPU Operator** | Stage1+ | Driver/toolkit/device-plugin/DCGM; exposes `nvidia.com/gpu` |
| **NVIDIA Network Operator** | Stage3 cross-node PD | RDMA Shared Device Plugin; exposes `rdma/*` for NIXL |
| Image / CUDA matrix | all | default `vllm/vllm-openai:v0.8.5` |
| Model egress | all | `Qwen/Qwen2.5-7B-Instruct` (or change `MODEL`) |
| SeaweedFS S3 | Stage2 | same `kubeflow` asset as CPU package |
| kube-prometheus + DCGM | monitoring | DCGM usually comes with GPU Operator |

Same-node Stage3 drills can set `SKIP_NETWORK_OPERATOR=1` and remove `rdma/*` from Stage3 manifests. Production cross-node PD should keep both operators.

---

## Run order

```bash
cd /Users/jiangtao/code/vLLM-en/vLLM-gpu/deploy
set -a && source ./config.env && set +a

# Platform layer (once per cluster)
./scripts/00-install-operators.sh
# Stage1/2 only: SKIP_NETWORK_OPERATOR=1 ./scripts/00-install-operators.sh

./scripts/00-validate.sh
./scripts/01-deploy-stage1.sh
./scripts/smoke-test.sh stage1

./scripts/02-deploy-stage2.sh
./scripts/smoke-test.sh stage2

# Before Stage3 RDMA PD:
#   1) edit manifests/operators/nic-cluster-policy.yaml for your NIC vendors
#   2) REQUIRE_NETWORK_OPERATOR=1 ./scripts/00-validate.sh
./scripts/03-deploy-stage3.sh
./scripts/smoke-test.sh stage3

./scripts/04-monitoring.sh
```

Cleanup (vLLM namespace only; does **not** uninstall operators):

```bash
./scripts/undeploy.sh
```

Uninstall operators (cluster-wide; careful):

```bash
helm --kube-context "${KUBE_CONTEXT}" uninstall network-operator -n nvidia-network-operator || true
helm --kube-context "${KUBE_CONTEXT}" uninstall gpu-operator -n gpu-operator || true
```

---

## Defaults

| Item | Stage1 | Stage2 (per engine) | Stage3 |
|---|---|---|---|
| Model | `Qwen/Qwen2.5-7B-Instruct` | same | same |
| GPU / engine | 1 | 1 | Prefill 1 + Decode 1 |
| RDMA / engine | — | — | `rdma/rdma_shared_device_a: 1` |
| `gpu_memory_utilization` | 0.92 | 0.90 | 0.90 |
| `--max-model-len` | 8192 | 4096 | 8192 |
| KV sharing | in-process APC | LMCache connector | NixlConnector P→D |
| Entry | `svc/vllm-single` | `vllm-a` / `vllm-b` | `svc/vllm-pd` |

If VRAM is tight: use a quantized model, lower `max_model_len` / `max_num_seqs`, or raise `TENSOR_PARALLEL_SIZE`.

---

## Mapping to docs

- `INSTALL.md` GPU capability list → staged here (operators first)  
- `OPTIMIZATION.md` S/K/P/L/O/PD → Stage1 covers S/K/P1/O; Stage2 covers cross-replica L; Stage3 covers PD + NIXL/RDMA  
- CPU simulation counterpart → `vLLM-cpu/deploy`
