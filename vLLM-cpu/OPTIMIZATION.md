# vLLM Optimization Checklist (CPU Operations Exercise / k3s-108)

Target: GPU-free, CPU-only AMD 5800H with 64GB of memory, the toy model `facebook/opt-125m`, and k3s context `108`.

Goal: Run the optimization capabilities commonly found in an enterprise-grade inference gateway and observe them quantitatively. Generation quality is not a goal.

Priority: P0 is required and aligned with `INSTALL.md`; P1 is strongly recommended; P2 is advanced or should be deferred until a GPU is available.

---

## 0. Where KV Resides in Real Deployments

Align expectations before the exercise.

This directory is a **mock exercise** that deliberately implements LMCache, SeaweedFS, and cross-Pod hits. In public production materials, however, **cluster-wide shared KV is not the default starting point**.

| Tier | How Common It Is | Purpose | References |
|---|---|---|---|
| Basic multi-replica deployment | **Default and most common** | Each Pod manages its local KV cache. Replicas do not share it. When the V1 GPU path is full, it uses preemption with RECOMPUTE rather than in-engine eviction. | [IBM: each replica owns its KV by default](https://research.ibm.com/publications/a-shared-kv-cache-for-vllm-reuse-failover-and-elastic-scaling), [V1 Guide](https://docs.vllm.ai/en/latest/usage/v1_guide/) |
| Session affinity or KV-aware routing | **A very common compromise** | Storage remains unshared. Affinity, prefix hashing, or KV-aware routing sends a request to a replica that already has the relevant local APC data. | [TrueFoundry](https://www.truefoundry.com/blog/kv-cache-routing-why-standard-load-balancers-break-prefix-caching-and-how-to-fix-it), [production-stack KV-aware routing](https://github.com/vllm-project/production-stack/blob/main/tutorials/17-kv-aware-routing.md) |
| Mooncake or LMCache shared pool | **Advanced for large-scale, Agent, or PD deployments** | Shares memory or disk across Pods. This CPU directory uses LMCache plus SeaweedFS to **simulate** this tier. | [vLLM and Mooncake](https://vllm-project.github.io/2026/05/06/mooncake-store.html), [production-stack Sharing KV Cache](https://docs.vllm.ai/projects/production-stack/en/latest/use_cases/sharing-kv-cache.html) |

Rule of thumb: first understand that each replica computes and caches independently by default. Cross-Pod sharing in this repository's CPU exercise is an **advanced capability simulation**, not the default production form for everyone. See section 0.1 of `../vLLM-gpu/OPTIMIZATION.md` for the GPU comparison.

Note: If a table below still says that `--swap-space` demonstrates eviction, it refers only to the CPU mock or the behavior of an older path. It is not the same mechanism as the default RECOMPUTE behavior in the current GPU V1 path.

---

## 1. Scheduling and Throughput on the Serving Side

| ID | Optimization | Meaning | Action | Observation | Priority |
|---|---|---|---|---|---|
| S1 | Continuous Batching | **Scheduling method:** multiple users can run concurrently and compute side by side at each token step. It does not combine several HTTP requests into one long sequence. It is generally enabled by default rather than activated by a dedicated flag. | Keep the default continuous batching behavior; do not switch to serial, one-request-at-a-time execution. | tokens/s and queue length at the same concurrency | P0 |
| S2 | Chunked Prefill | Splits a long prompt into small prefill chunks and time-shares compute with decode, reducing the chance that a long request blocks short token generation. | Use `--enable-chunked-prefill true`; it is often already the default in V1. | Whether tail latency for short decode requests is more stable while a long request is active | P0 |
| S3 | Concurrency and context limits | **Capacity limits:** `--max-num-seqs` is the maximum number of sequences active at once in continuous batching. It is the concurrency-capacity control, not Continuous Batching itself. `--max-model-len` is the maximum context length of one request. Think of them as the number of tables and the maximum length of each table. Lower values control memory and make it easier to fill the KV cache deliberately. | Reduce `--max-num-seqs` and `--max-model-len`. | Whether memory is controlled and whether filling KV becomes easier | P0 |
| S4 | Batched-token budget | **Work per step:** `--max-num-batched-tokens` is the maximum total tokens processed for all users in one scheduler step; both prefill and decode consume the budget. A smaller budget favors ITL because decode is blocked less, while a larger budget favors TTFT and throughput. Unlike S3, which controls how many users and how long each request can be, S4 controls the maximum work in each step. | Tune `--max-num-batched-tokens` as needed. | The throughput versus single-request latency tradeoff | P1 |

---

## 2. KV Cache and Memory Watermarks

| ID | Optimization | Meaning | Action | Observation | Priority |
|---|---|---|---|---|---|
| K1 | PagedAttention watermark | `--gpu-memory-utilization` proportionally determines the size of the model, activation, and KV page-table pool. A higher watermark provides a larger KV pool and supports more concurrency or longer contexts, but also increases OOM risk. The CPU mock has no physical GPU but still uses this parameter to control the virtual GPU memory pool. `gpu_cache_usage_*` reports how much of the pool is used. | Start at `0.60` for a single process. | `gpu_cache_usage_perc` or `gpu_cache_usage_factor` | P0 |
| K2 | CPU Swap eviction | `--swap-space`, in GiB, reserves another region in host memory. On the older path, inactive KV can be **swapped out** to this region when the KV pool is full. This CPU directory retains that behavior to provide experience with eviction after saturation. The current **GPU V1 path does not use in-engine SWAP by default**; a full cache generally causes preemption and RECOMPUTE. Use LMCache or Mooncake for true tiered KV retention. | Use moderate `--swap-space`; enough to demonstrate eviction, without reserving 16GB as if the model were 7B. | Whether swap-out events and increased latency appear after KV is full | P0 |
| K3 | Block size | PagedAttention divides KV into fixed pages, commonly 16 tokens per page. Smaller pages increase management overhead but provide finer prefix-hit granularity. Larger pages waste more space at the end through fragmentation and make short prefixes harder to align. Keep the default initially. | Test `--block-size` when needed; 16 is common. | Fragmentation and prefix-hit granularity | P2 |
| K4 | Leave memory for multiple Pods | When several vLLM instances plus LMCache and SeaweedFS share one host, large watermarks and swap allocations for every instance can exhaust host memory. Reduce K1 and K2 per instance to leave memory for the shared cache tier. Observe the entire host, not just one container. | Reduce the watermark and swap allocation for multiple instances. | Host `free -h` output and whether OOM events disappear | P0 |

In short: K1 controls pool size; K2 controls where data is evicted in this exercise; K3 controls page size; and K4 prevents multiple instances from exhausting the host. S3 controls how many users can run and how long each request can be. S4 controls the total tokens processed per step. S1 is the parallel scheduling method itself.

---

## 3. Prefix Caching

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| P1a | Single-process prefix cache | Enable `--enable-prefix-caching` and send the same system prompt or prefix twice. | Lower TTFT and a higher prefix-hit count on the second request | P0 |
| P1b | Disable the in-process cache for distributed caching | Disable `--enable-prefix-caching` after connecting LMCache. | Avoid conflicting semantics between two cache layers. | P0 |
| P2a | Network-distributed prefix cache | Run an in-cluster `lmcache server`, at least 2 vLLM Pods, and `LMCacheMPConnector`. | Pod A writes and Pod B hits. | P0 |
| P2b | Consistent hashing | Standardize the prefix-hash algorithm and conventions such as `PYTHONHASHSEED` across instances. | Whether a cross-Pod request produces a real hit | P0 |
| P3 | Shared-prefix workload design | Use a fixed long prefix with a varying suffix in load tests. | Whether the hit rate increases with the degree of sharing | P1 |

---

## 4. Tiered KV and Remote Cache with LMCache and SeaweedFS

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| L1 | Hot tier in memory | Use a small quota, such as 1GB to 2GB, for the LMCache local or process-side CPU buffer. | Hot-hit latency and buffer usage | P0 |
| L2 | Cold tier on network storage | Point the LMCache remote backend to `seaweedfs.kubeflow.svc`, preferably S3 on `8333` or alternatively Filer on `8888`, using a path such as `kv-cache`. | Cross-Pod cold hits, disk or object growth, and network latency | P0 |
| L3 | Distinguish it from `--swap-space` | Swap evicts only within process memory. SeaweedFS provides shared persistent storage. | Whether metrics and directory or bucket contents match the intended behavior | P0 |
| L4 | Eviction policy | Confirm LRU, or another selected policy, and the remote quota. | Whether old chunks are evicted after the quota is full | P1 |
| L5 | Observe direct disk writes | For a local-disk comparison, enable `use_odirect`. For a network S3 path, observe object-storage latency. | Whether page caching creates misleading IO results | P2 |

---

## 5. CPU Backend and Model Loading

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| C1 | CPU platform | Run `export VLLM_PLATFORM=CPU`. | CUDA and ROCm are not probed, and serving remains stable. | P0 |
| C2 | Toy model | Use `--model facebook/opt-125m`, approximately 250MB, by default. | Startup time, memory use, and readable short English completions | P0 |
| C3 | Fast dummy startup | Use `--load-format dummy` when needed. | Faster startup; text may become meaningless, while metrics remain valid. | P1 |
| C4 | Thread and core affinity | Control OpenMP and thread counts so that 2 Pods do not both saturate all 8 cores. | Latency jitter and CPU utilization | P1 |
| C5 | Precision | Prefer a viable float32 or bf16 combination on CPU, subject to support in the current vLLM CPU backend. | Speed versus memory | P2 |

---

## 6. API, Gateway, and Observability

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| O1 | OpenAI-compatible endpoint | Bind local port or Service port `8000` and expose `/v1/completions` or `/v1/chat/completions`. | Both streaming and non-streaming requests work. | P0 |
| O2 | Prometheus metrics | Enable `/metrics` and collect `gpu_cache_usage_*`, request-latency, and throughput metrics. | Curve changes before and after load testing | P0 |
| O3 | Load-test scripts | Create a fixed-prefix hit case and a case that fills KV to trigger swap or the cold tier. | Reproducible experiments | P0 |
| O4 | Multi-instance entry point | Optionally use a Service or simple load balancer to send requests to different Pods. | Whether cross-Pod hits depend on routing | P1 |
| O5 | Structured logs | Record cache hits, TTFT, and swap events. | Troubleshooting time | P2 |

---

## 7. k8s and Platform Configuration

These settings should complement the inference parameters.

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| N1 | Resource requests and limits | Set reasonable requests and limits for vLLM, LMCache, and SeaweedFS. | Avoid driving the node close to OOM. | P0 |
| N2 | Persistent SeaweedFS availability | Keep `kubeflow/seaweedfs` available and store only KV data there. | Filer and S3 health, and bucket or directory existence | P0 |
| N3 | Make room by scaling unrelated workloads down | Before the exercise, scale down unrelated workloads. Use `restore-k3s-108.sh` to restore them. | Available memory in `free -h` | P0 |
| N4 | Probes and rolling updates | Use readiness so traffic arrives only after the API is ready. | Whether rolling updates produce 5xx responses | P1 |

---

## 8. PD Disaggregation Topology Exercise

This can run on CPU but is not a performance optimization.

| ID | Optimization | Action | Observation | Priority |
|---|---|---|---|---|
| PD1 | Separate Prefill and Decode | Run at least 1 Prefill Pod and 1 Decode Pod with the `opt-125m` model. | Whether each role performs only its assigned work | P1 |
| PD2 | Unified entry point | Use a proxy or router that sends a request to Prefill and then Decode. | The client still uses one OpenAI endpoint. | P1 |
| PD3 | Real handoff, optional | Use `NixlConnector` with `kv_buffer_device: "cpu"`, P set to `kv_producer`, and D set to `kv_consumer`. | Successful KV handoff and observable failures | P1 |
| PD4 | Lighter fake PD | Prefill writes to LMCache or SeaweedFS, and Decode retrieves by key. | Cross-role hits and routing without installing NIXL | P1 |
| PD5 | Acceptance criteria | Do not require higher tokens/s; it is often slower on 8 cores. | Topology, handoff, retries, and `/metrics` | P0 |

Note: This is Prefill-Decode disaggregation, not Data Parallel. See `../vLLM-gpu/OPTIMIZATION.md` for GPU acceleration benefits.

---

## 9. Defer Until a GPU Is Available

These items are not required for the local CPU exercise.

| ID | Optimization | Description | Priority |
|---|---|---|---|
| G1 | CUDA Graph or compilation | Reduce decode launch overhead. | P2 |
| G2 | FP8, INT8, AWQ, or GPTQ | Quantize weights to save GPU memory and improve throughput. | P2 |
| G3 | Tensor Parallel or Pipeline Parallel | Partition a model across multiple GPUs. | P2 |
| G4 | Speculative Decoding | Use a draft model to accelerate decoding. | P2 |

---

## Suggested Rollout Order for One Complete Exercise

1. Single-process CPU: `opt-125m`, OpenAI API, and `/metrics`.
2. Enable prefix caching and chunked prefill, then send the same prefix twice.
3. Tune the watermark and swap, then fill KV and observe eviction.
4. Run LMCache and 2 vLLM Pods, then verify a cross-Pod hit.
5. Connect the cold tier to SeaweedFS to create a network-shared KV cache.
6. Build the PD topology with Prefill, Decode, and a proxy. Start with fake PD, then optionally add NIXL CPU handoff.
7. Standardize two `curl` or load-test cases: streaming generation, and cache plus swap or PD handoff metrics.

---

## Relationship to `INSTALL.md`

- `INSTALL.md` defines which capabilities to simulate and which components to use.
- `OPTIMIZATION.md` defines which controls to tune for those capabilities, which items to implement first, and which metrics to observe.

Use both documents together: first build the foundation by following `INSTALL.md`, then use this checklist to enable and validate each optimization.
