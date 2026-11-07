# vLLM serving lab (English)

Two parallel deploy packages for the same Stage narrative:

| Path | Role |
|---|---|
| [`vLLM-gpu/`](./vLLM-gpu/) | CUDA / NVIDIA production path (`deploy/`) |
| [`vLLM-cpu/`](./vLLM-cpu/) | CPU simulation path for clusters without GPU (`deploy/`) |

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
./scripts/00-validate.sh
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
