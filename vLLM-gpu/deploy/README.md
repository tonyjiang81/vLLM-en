# vLLM-gpu deploy package (CUDA / NVIDIA)

This directory is the **GPU / CUDA production path** staged package, matching `INSTALL.md` / `OPTIMIZATION.md`.

The sibling **CPU simulation path** is `../../vLLM-cpu/deploy` (same Stage narrative with the official CPU image).

Stages align for side-by-side comparison:

| Stage | GPU (this tree) | CPU simulation |
|---|---|---|
| 1 single engine | `vllm-single` + APC / chunked prefill / `gpu_memory_utilization` | same topology, CPU image + `VLLM_CPU_KVCACHE_SPACE` |
| 2 shared KV | `LMCacheConnectorV1` + dual engines + Seaweed cold tier | `lmcache-mock` + dual-engine topology drill |
| 3 PD | Prefill/Decode + `NixlConnector` + `pd-proxy` | fake PD entry topology |
| Monitoring | DCGM GPU util / FB + vLLM metrics, dashboard `vLLM GPU` | container CPU/KV, dashboard `vLLM CPU Lab` |

---

## Layout

```
deploy/
  config.env
  README.md
  scripts/
    00-validate.sh
    01-deploy-stage1.sh
    02-deploy-stage2.sh
    03-deploy-stage3.sh
    04-monitoring.sh
    smoke-test.sh
    undeploy.sh
  manifests/
    namespace.yaml
    stage1-single/
    stage2-shared-kv/
    stage3-pd/
    monitoring/
```

---

## Prerequisites

- Nodes schedule `nvidia.com/gpu` (Device Plugin / GPU Operator)
- Image matches driver/CUDA matrix (default `vllm/vllm-openai:v0.8.5`; override in `config.env`)
- Egress to pull `Qwen/Qwen2.5-7B-Instruct` (or change `MODEL`)
- Stage2 cold tier: in-cluster SeaweedFS S3 (same `kubeflow` asset as the CPU package)
- Stage3 PD: production cross-node KV transfer follows Dynamo RDMA/NIXL docs; same-node drills still use connector configs
- Monitoring: kube-prometheus + (recommended) DCGM Exporter

---

## Run order

```bash
cd /Users/jiangtao/code/vLLM-en/vLLM-gpu/deploy
set -a && source ./config.env && set +a

./scripts/00-validate.sh
./scripts/01-deploy-stage1.sh
./scripts/smoke-test.sh stage1

./scripts/02-deploy-stage2.sh
./scripts/smoke-test.sh stage2

./scripts/03-deploy-stage3.sh
./scripts/smoke-test.sh stage3

./scripts/04-monitoring.sh
```

Cleanup:

```bash
./scripts/undeploy.sh
```

---

## Defaults

| Item | Stage1 | Stage2 (per engine) | Stage3 |
|---|---|---|---|
| Model | `Qwen/Qwen2.5-7B-Instruct` | same | same |
| GPU / engine | 1 | 1 | Prefill 1 + Decode 1 |
| `gpu_memory_utilization` | 0.92 | 0.90 | 0.90 |
| `--max-model-len` | 8192 | 4096 | 8192 |
| KV sharing | in-process APC | LMCache connector | NixlConnector P→D |
| Entry | `svc/vllm-single` | `vllm-a` / `vllm-b` | `svc/vllm-pd` |

If VRAM is tight: use a quantized model, lower `max_model_len` / `max_num_seqs`, or raise `TENSOR_PARALLEL_SIZE`.

---

## Mapping to docs

- `INSTALL.md` GPU capability list → staged here  
- `OPTIMIZATION.md` S/K/P/L/O/PD → Stage1 covers S/K/P1/O; Stage2 covers cross-replica L; Stage3 covers PD + NIXL roles  
- CPU simulation counterpart → `vLLM-cpu/deploy` (same Stage story, runnable without GPUs)
