# vLLM-cpu deploy package (k3s context `108`)

Staged rollout of capabilities from `INSTALL.md` / `OPTIMIZATION.md` into namespace `vllm-cpu`.

This directory is the **CPU simulation path** (official CPU image + toy model `facebook/opt-125m`). Accept on API, `/metrics`, cache hits, and topology — not generation quality.

**GPU / CUDA production path:** `../../vLLM-gpu/deploy` (aligned Stages: single engine → LMCache shared KV → Prefill/Decode + monitoring).

---

## Preflight conclusions (2026-11-07)

| Check | Result | Notes |
|---|---|---|
| Node reachable | Pass | `matthew` / `192.168.10.108`, containerd k3s |
| Headroom | Pass | ~62Gi memory / 16 CPU allocatable; lab workloads mostly scaled down |
| SeaweedFS | Pass | `kubeflow/seaweedfs` Running; S3 `8333`, Filer `8888`; Secret `mlpipeline-minio-artifact` |
| Model pull | Pass | Pod can reach `huggingface.co` → HTTP 200 |
| Official CPU image | Pass | `vllm/vllm-openai-cpu:v0.33.0-x86_64` (also `latest-x86_64`) |
| LMCache image | Conditional | `lmcache/standalone:v0.5.7-amd64`; CPU workers need `--supported-transfer-mode engine_driven` (or `auto`) |
| Engine `--swap-space` | Do not treat as production truth | V1 removed GPU↔CPU KV SWAP; pressure defaults to preemption + RECOMPUTE. Stage1 may keep a small swap knob for lab feel; watch preemption / cache usage |
| Cross-Pod shared KV | Advanced / risky on CPU | Official LMCache+vLLM images lean CUDA; CPU path may `pip install lmcache` for drills — not a production recipe |
| PD / NIXL | Deferred in this lab | Stage3 is **fake PD**: Prefill warms shared cache, Decode serves; no NIXL |
| Local Docker / SSH to node | Unavailable | No Docker daemon on Mac; no SSH build on 108 → no custom image registry dependency |

**Summary:**

1. **Plan is sound**: single process (API + prefix cache + watermark) → shared KV (LMCache + SeaweedFS) → fake PD; matches the install/optimization order and the “default is not shared; sharing is advanced” mental model.
2. **Stage1 likely succeeds**: official image + small model + free node + HF reachable.
3. **Stage2 uses MOCK**: real LMCache wants CUDA / large images; this lab uses `lmcache-mock` (memory L1 + SeaweedFS L2) + dual vLLM to practice cross-Pod topology and metrics — not an in-engine KV connector.
4. **Do not enable everything at once**: on ~8 cores, 2×vLLM + LMCache contend for CPU; validate topology and metrics only.

---

## Layout

```
deploy/
  config.env
  README.md                 # this file
  scripts/
    00-validate.sh          # preflight (required)
    01-deploy-stage1.sh     # single opt-125m
    02-deploy-stage2.sh     # LMCache + dual vLLM + SeaweedFS cold tier
    03-deploy-stage3.sh     # fake PD (Prefill/Decode + entry)
    smoke-test.sh           # API /metrics / shared-prefix twice
    undeploy.sh             # delete this namespace
  manifests/
    namespace.yaml
    stage1-single/
    stage2-shared-kv/
    stage3-pd-fake/
```

---

## Recommended order

```bash
cd /Users/jiangtao/code/vLLM-en/vLLM-cpu/deploy
set -a && source ./config.env && set +a

./scripts/00-validate.sh          # do not continue on FAIL
./scripts/01-deploy-stage1.sh
./scripts/smoke-test.sh stage1

# after Stage1 is stable:
./scripts/02-deploy-stage2.sh
./scripts/smoke-test.sh stage2

# optional:
./scripts/03-deploy-stage3.sh
./scripts/smoke-test.sh stage3
```

Cleanup:

```bash
./scripts/undeploy.sh
```

---

## Sizing knobs (intentionally small)

| Item | Stage1 | Stage2 (per vLLM) |
|---|---|---|
| Model | `facebook/opt-125m` | same |
| `VLLM_CPU_KVCACHE_SPACE` | 2 GiB | 1 GiB |
| `--max-model-len` | 512 | 256 |
| `--max-num-seqs` | 4 | 2 |
| `--swap-space` | 1 (mostly no-op on V1) | 0 |
| In-process prefix caching | on | off (LMCache owns reuse) |
| LMCache L1 | — | 2 GiB |
| Seaweed bucket | — | `kv-cache` |

---

## Mapping to docs

- `INSTALL.md` capability list → staged here  
- `OPTIMIZATION.md` S/K/P/L/O/PD → Stage1 covers S/K/P1a/O; Stage2 covers P2/L; Stage3 covers fake PD
