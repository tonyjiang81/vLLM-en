# vLLM serving lab (English)

## Purpose

This repository is a **staged playbook for deploying and operating a vLLM OpenAI-compatible inference gateway on Kubernetes**.

It turns the ideas in `INSTALL.md` / `OPTIMIZATION.md` into runnable `deploy/` packages:

1. **Stage 1** — single engine (API, prefix caching, KV watermark / memory pressure)
2. **Stage 2** — cross-Pod shared KV (LMCache + object-store cold tier)
3. **Stage 3** — Prefill / Decode disaggregation entry (+ monitoring)

The goal is not a one-off demo script. It is a **repeatable ops path**: validate the cluster, install platform pieces when needed, deploy by stage, smoke-test, and scrape Prometheus / Grafana.

## Why two versions (`vLLM-cpu` and `vLLM-gpu`)?

Both trees follow the **same Stage story** so you can learn and operate the topology without mixing “lab mock” and “CUDA production” into one confusing package.

| | [`vLLM-gpu/`](./vLLM-gpu/) | [`vLLM-cpu/`](./vLLM-cpu/) |
|---|---|---|
| **Role** | CUDA / NVIDIA **production path** | **CPU simulation path** for clusters without a real GPU |
| **When to use** | Nodes with `nvidia.com/gpu`, GPU Operator (+ Network Operator / RDMA for cross-node PD) | Laptop labs / CPU-only k3s where you still want API, metrics, cache topology, and PD entry drills |
| **Model default** | `Qwen/Qwen2.5-7B-Instruct` (real quality / throughput target) | `facebook/opt-125m` (ops drill; not generation quality) |
| **Shared KV** | Real LMCache connector path | `lmcache-mock` + SeaweedFS topology drill |
| **PD** | Prefill/Decode + `NixlConnector` + RDMA-oriented Stage 3 | Fake PD proxy topology (no NIXL requirement) |
| **Watch** | DCGM GPU util / FB + vLLM metrics | Container CPU / KV usage (no meaningful GPU util) |

**Short version:** use **GPU** when you have NVIDIA hardware and want the real CUDA stack; use **CPU** when you do not, but still need to practice the same staged architecture, scripts, and observability workflow.

Docs live next to each package (`INSTALL.md`, `OPTIMIZATION.md`). Ops scripts and manifests are under each `deploy/`.

> Sibling Chinese tree: `../vLLM/` (same layout, Chinese docs).

## Quick start

CPU lab (no GPU):

```bash
cd vLLM-cpu/deploy
set -a && source ./config.env && set +a
./scripts/00-validate.sh
./scripts/01-deploy-stage1.sh
./scripts/smoke-test.sh stage1
```

GPU / CUDA:

```bash
cd vLLM-gpu/deploy
set -a && source ./config.env && set +a
./scripts/00-install-operators.sh   # GPU Operator + Network Operator
./scripts/00-validate.sh            # or: ./scripts/00-verify-scripts.sh (structural check, no GPU required)
./scripts/01-deploy-stage1.sh
./scripts/smoke-test.sh stage1
```

## Layout

```
vLLM-en/
  README.md
  restore-k3s-108.sh          # optional lab cluster helper
  vLLM-cpu/
    INSTALL.md
    OPTIMIZATION.md
    deploy/
  vLLM-gpu/
    INSTALL.md
    OPTIMIZATION.md
    deploy/
```
