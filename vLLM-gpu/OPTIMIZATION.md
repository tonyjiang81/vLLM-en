# vLLM Optimization Checklist (Real GPU / CUDA Production)

This checklist is compiled only from public vLLM, NVIDIA Dynamo, and related documentation. Versions change, so reopen and verify the source links before deployment. This directory does not cover CPU mocks.

Primary documentation:
- [Optimization and Tuning](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [Welcome to vLLM (feature overview)](https://docs.vllm.ai/en/stable/)
- [vLLM V1 User Guide](https://docs.vllm.ai/en/latest/usage/v1_guide/)
- [Automatic Prefix Caching](https://docs.vllm.ai/en/stable/features/automatic_prefix_caching/)
- [Parallelism and Scaling](https://docs.vllm.ai/en/stable/serving/parallelism_scaling/)
- [Speculative Decoding](https://docs.vllm.ai/en/stable/features/speculative_decoding/)
- [Quantization](https://docs.vllm.ai/en/latest/features/quantization/index.html)
- [CUDA Graphs](https://docs.vllm.ai/en/latest/design/cuda_graphs/)
- PD: [Dynamo Disagg Communication](https://docs.nvidia.com/dynamo/v1.4.1/knowledge-base/kubernetes/kubernetes-operator/disagg-communication), [Topology-Aware KV Transfer](https://docs.nvidia.com/dynamo/v1.4.2/knowledge-base/kubernetes/multinode/topology-aware-kv-transfer)

Priority: P0 required before launch -> P1 strongly recommended -> P2 enable as scale and workload require.

---

## 0. Corrections About V1 and Default Behavior

| Claim | Official Current Behavior | Source |
|---|---|---|
| Use `--swap-space` for GPU-to-CPU KV offloading | **V1 removed** `GPU <> CPU KV Cache Swapping`. When KV capacity is insufficient, the default is **preempt + RECOMPUTE** | [V1 Guide](https://docs.vllm.ai/en/latest/usage/v1_guide/), [Optimization: Preemption](https://docs.vllm.ai/en/stable/configuration/optimization/) |
| Chunked prefill and prefix caching must be enabled manually | Both are usually **enabled by default** on V1 | [cache config](https://docs.vllm.ai/en/stable/api/vllm/config/cache/), [Optimization: Chunked Prefill](https://docs.vllm.ai/en/stable/configuration/optimization/) |
| `gpu_memory_utilization` defaults to about 0.9 | The current documented default is **0.92** | [LLM / CacheConfig](https://docs.vllm.ai/en/stable/api/vllm/entrypoints/llm/) |

Mooncake and LMCache provide **external KV tiering and sharing**. They are not the same mechanism as RECOMPUTE inside the V1 engine.

---

## 0.1 Where KV Resides in Real Deployments (Default vs. Advanced)

| Layer | How Common It Is | What It Does | Reference |
|---|---|---|---|
| Bare multiple replicas | **Default and most common** | Each GPU replica manages its own local KV; when V1 fills up, it preempts and uses RECOMPUTE; replicas do not share KV | [IBM: each replica has its own KV by default](https://research.ibm.com/publications/a-shared-kv-cache-for-vllm-reuse-failover-and-elastic-scaling), [V1 removed SWAP](https://docs.vllm.ai/en/latest/usage/v1_guide/) |
| Sticky routing / KV-aware routing | **A very common compromise** | Storage is not shared; stickiness, prefix hashing, or KV-aware routing sends requests to a replica whose local APC already contains the cache | [TrueFoundry](https://www.truefoundry.com/blog/kv-cache-routing-why-standard-load-balancers-break-prefix-caching-and-how-to-fix-it), [production-stack KV-aware](https://github.com/vllm-project/production-stack/blob/main/tutorials/17-kv-aware-routing.md) |
| Mooncake / LMCache | **Advanced option for large-scale, multi-turn, agent, or PD workloads** | Shares KV through cluster DRAM, disk, or RDMA; can be combined with PD KV transfer | [vLLM x Mooncake](https://vllm-project.github.io/2026/05/06/mooncake-store.html), [production-stack Sharing KV](https://docs.vllm.ai/projects/production-stack/en/latest/use_cases/sharing-kv-cache.html), [Hao AI Lab](https://haoailab.com/blogs/distserve-retro/) |

Rule of thumb: an instance retains its own KV; **most production multi-replica deployments do not share KV by default**; real sharing requires explicit Mooncake/LMCache integration.

---

## 1. Core Acceleration Capabilities Listed on the Official Home Page

Source: [Welcome to vLLM](https://docs.vllm.ai/en/stable/)

| ID | Capability | Key Point in the Official Description | Priority |
|---|---|---|---|
| F1 | PagedAttention | Efficiently manages attention KV memory | P0 |
| F2 | Continuous batching | Listed alongside chunked prefill and prefix caching | P0 |
| F3 | Chunked prefill | See section 2 | P0 |
| F4 | Prefix caching | See section 3 | P0 |
| F5 | CUDA/HIP graphs | See section 5 | P1 |
| F6 | Quantization | FP8, INT8/INT4, GPTQ/AWQ, GGUF, ModelOpt, and others | P1 |
| F7 | Speculative decoding | n-gram, suffix, EAGLE, MTP, draft, and others | P2 |
| F8 | torch.compile | Related to optimization levels and startup caching | P1 |
| F9 | Disaggregated prefill/decode/encode | See section 6 | P1 |
| F10 | TP / PP / DP / EP / CP | See section 4 | Depends on model size |

---

## 2. Scheduling and Batching

Source: [Optimization and Tuning](https://docs.vllm.ai/en/stable/configuration/optimization/)

| ID | Optimization | Official Guidance | What to Observe | Priority |
|---|---|---|---|---|
| S1 | Chunked Prefill | V1 enables it by default whenever possible; scheduling **prioritizes decode**, then fills or splits prefill work within `max_num_batched_tokens` | ITL/TPOT, TTFT, GPU utilization | P0 |
| S2 | Tune `max_num_batched_tokens` | Maximum total number of tokens processed across all sequences **per scheduling step**. Smaller -> better ITL; larger -> better TTFT; `>8192` is often recommended for throughput with a small model on a large GPU | TTFT vs. ITL | P0 |
| S3 | Disable chunked prefill | When it is disabled, `max_num_batched_tokens` must be `> max_model_len` | Startup failure | P0 |
| S4 | Preemption | Preempts when KV capacity is insufficient; V1 defaults to **RECOMPUTE**, not in-engine GPU-to-CPU SWAP; frequent preemption harms tail latency | Preemption metrics and logs | P0 |
| S5 | Mitigate preemption | Increase `gpu_memory_utilization` to allocate a larger KV pool; decrease `max_num_seqs`, the maximum number of sequences concurrently in the batch, or `max_num_batched_tokens`; increase TP/PP | Preemption count, OOM | P0 |
| S6 | `-O0` through `-O3` | `-O2` is the default and includes FULL_AND_PIECEWISE cudagraphs | Startup vs. steady state | P1 |
| S7 | Faster startup | Compile cache; `--kv-cache-memory`; `--enforce-eager` | Cold start | P1 |

Concept comparison (consistent with the CPU exercise documentation):
- Continuous Batching means scheduling multiple users side by side at each token step as a default capability; it does not concatenate multiple HTTP requests into one sequence.
- `max_num_seqs` is the maximum number of concurrent sequences, which is the capacity control; `max_num_batched_tokens` is the total number of tokens computed in each step, which is the pacing control.
- `gpu_memory_utilization` sets the KV/working-set threshold. When V1 fills up, it defaults to preemption plus RECOMPUTE. Use Mooncake/LMCache for actual tiered KV retention.

---

## 3. Automatic Prefix Caching

Sources: [APC](https://docs.vllm.ai/en/stable/features/automatic_prefix_caching/), [cache config](https://docs.vllm.ai/en/stable/api/vllm/config/cache/)

| ID | Optimization | Official Guidance | What to Observe | Priority |
|---|---|---|---|---|
| P1 | APC | Reuses KV for identical prefixes and skips prefilling the shared segment | TTFT and throughput; decode is not accelerated | P0 |
| P2 | When it does not help | The answer is long, or there is no shared prefix | Hit rate | P0 |
| P3 | Default | `enable_prefix_caching=True`; the default hash is `sha256` | Single-engine hits | P0 |

Use Mooncake/LMCache separately for cross-replica sharing; that is not part of APC's single-engine semantics.

---

## 4. Parallelism

Sources: [Parallelism and Scaling](https://docs.vllm.ai/en/stable/serving/parallelism_scaling/), [Optimization: Parallelism](https://docs.vllm.ai/en/stable/configuration/optimization/)

| ID | Strategy | Official Use Case | Priority |
|---|---|---|---|
| R1 | Single GPU | The model fits on one GPU | P0 |
| R2 | Tensor Parallel | One GPU is insufficient, but multiple GPUs in one host are sufficient | P0 |
| R3 | TP + PP | One host is insufficient: `TP=GPUs per node`, `PP=number of nodes` | P1 |
| R4 | Expert Parallel | MoE only | P2 |
| R5 | Data Parallel | Replicate the complete model to increase throughput | P1 |
| R6 | NUMA bind | Multiple sockets: `--numa-bind` | P1 |
| R7 | Host CPU cores | V1 multiprocess deployments need at least approximately `2+N` physical cores; insufficient CPU manifests as low GPU utilization | P0 |

---

## 5. CUDA Graphs, Quantization, and Speculative Decoding

| ID | Optimization | Official Key Point | Source | Priority |
|---|---|---|---|---|
| E1 | CUDA Graphs | `FULL_AND_PIECEWISE` and other modes; PD decode can use `FULL_DECODE_ONLY` | [CUDA Graphs](https://docs.vllm.ai/en/latest/design/cuda_graphs/) | P1 |
| E2 | Quantization | AWQ/GPTQ/FP8/INT8/INT4/GGUF/ModelOpt and others | [Quantization](https://docs.vllm.ai/en/latest/features/quantization/index.html) | P1 |
| E3 | Speculative Decoding | Reduces ITL at low to medium QPS; EAGLE/MTP/draft/ngram/suffix and others | [Speculative Decoding](https://docs.vllm.ai/en/stable/features/speculative_decoding/) | P2 |
| E4 | Attention backend | Select automatically or manually | [Optimization](https://docs.vllm.ai/en/stable/configuration/optimization/) | P2 |
| E5 | fastokens | `VLLM_USE_FASTOKENS=1` | Same as above | P2 |

---

## 6. PD Disaggregation and RDMA

| ID | Optimization | Official Guidance | Source | Priority |
|---|---|---|---|---|
| PD1 | Role separation | Prefill is compute-intensive; Decode is bandwidth-intensive | Dynamo Disaggregated Serving | P1 |
| PD2 | Transport | Production uses RDMA + NIXL; cross-Pod traffic does not rely on NVLink | [Disagg Communication](https://docs.nvidia.com/dynamo/v1.4.1/knowledge-base/kubernetes/kubernetes-operator/disagg-communication) | P0 |
| PD3 | Resources | One `rdma/ib` allocation per GPU; `IPC_LOCK` + `SYS_RESOURCE` | Same as above | P0 |
| PD4 | Capacity balance within a domain | Each zone or rack must have sufficient Prefill and Decode capacity | [Topology-Aware KV Transfer](https://docs.nvidia.com/dynamo/v1.4.2/knowledge-base/kubernetes/multinode/topology-aware-kv-transfer) | P0 |
| PD5 | Same-domain routing | Set `kvTransferPolicy` to `required` or `preferred` | Same as above | P0 |

---

## 7. Observability and API

| ID | Item | Description | Priority |
|---|---|---|---|
| O1 | OpenAI API | Streaming chat/completions | P0 |
| O2 | Prometheus | `gpu_cache_usage_*`, latency, throughput, preemption | P0 |
| O3 | Load testing | APC with shared prefixes; chunked long prefill plus short decode; fill KV capacity to observe preemption | P0 |

---

## Recommended Rollout Order

1. Run the real model on one GPU; confirm V1 and the default APC plus chunked prefill behavior.
2. Tune `gpu_memory_utilization`, `max_num_seqs`, and `max_num_batched_tokens` to reduce preemption.
3. For multiple replicas, start with KV-aware routing; add Mooncake/LMCache only if needed.
4. If the model does not fit, add TP, then PP; add DP when more throughput is needed.
5. Enable CUDA Graphs or quantization according to memory and latency requirements.
6. For multi-node PD, deploy RDMA + NIXL, then topology placement and same-domain routing.
7. Evaluate speculative decoding for low to medium QPS.

---

## Relationship to `INSTALL.md`

- `INSTALL.md` describes the capabilities and components required for GPU production.
- This file describes controls and priorities organized around the official Optimization documentation.
