# modded-p2p

GPU↔GPU direct transfers (P2P) on consumer NVIDIA cards — **no ReBAR, no
firmware flashing, no proprietary blobs**. Patches and scripts only.

Built on [**barlink-pcie**](https://github.com/efschu/barlink-pcie) by
**efschu** — all credit for the mechanism goes there. This repo adds a port of
their driver patch to NVIDIA's 615.78.08 modules, two platform fixes, and a
persistent one-command installer.

## What you get

Measured on 2× RTX 3080 20GB (the second card even on a slow ×4 slot),
`all_reduce`, bfloat16:

| size | modded-p2p | NCCL | gain |
|---|---|---|---|
| 20 KiB | 57.4 µs | **50.5 µs** | –12 % |
| 1 MiB | **521.9 µs** | 560.2 µs | **+7 %** |
| 4 MiB | **1938.9 µs** | 2099.7 µs | **+8 %** |
| 16 MiB | **7169.0 µs** | 8208.9 µs | **+15 %** |

Zero bad bytes in both directions. On a normal ×16 PCIe 4.0 pair everything is
link-bound and scales up. Numbers and conditions:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## How it works (short version)

1. A buffer on the target card is exported as a **dma-buf**.
2. A tiny kernel module (holder) attaches to it — that makes the driver map
   the buffer into the target card's **BAR1**.
3. The source card writes straight into that BAR1 slice over PCIe. No system
   RAM in the path.
4. Two driver patches make the driver allow this on consumer cards.

That's it. No BAR resize, no VBIOS.

## Requirements

- Linux with NVIDIA **open** kernel modules (615.78.08 tested)
- Kernel headers, `gcc`, `git`, `patch`, `make`
- Two NVIDIA GPUs of the same generation
- systemd, OpenRC or dinit
- Root (to load modules)
- ~2 GB disk

## Install

```bash
git clone https://git.fedesito.me/fedes1to/modded-p2p
cd modded-p2p
sudo bash scripts/install.sh     # build + install + activate (screen blinks once)
sudo bash scripts/verify.sh      # must print: PASS
```

**Persists across reboots.** After a kernel upgrade, re-run `install.sh`.

Undo everything:

```bash
sudo bash scripts/revert.sh
```

A reboot also returns you to the stock driver.

## Running vLLM or sglang over P2P (beginner version)

**The short story.** vLLM and sglang talk between your GPUs through a library
called NCCL. NCCL cannot use the direct path on these cards, so it bounces
every message through your RAM. This project adds a small translation layer
that lets the framework send those messages over the direct P2P path instead.
You install the layer once and start the framework with two extra environment
variables. That's the whole change.

### vLLM (step by step)

vLLM wants a specific PyTorch version, so give it its own environment:

```bash
# 1. one-time setup (replace the two /path/to with where your checkouts are)
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e /path/to/modded-p2p/integrations/python
```

```bash
# 2. start it (root is needed: the P2P path asks the driver for a permission
#    only root has). The first start compiles a small kernel: one-time, slower.
. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-vllm/bin/vllm serve <your-model> \
    --tensor-parallel-size 2 \
    --disable-custom-all-reduce
```

**How to know it worked.** Each worker prints one line at startup:

```
modded_p2p: process group created, resolved backend=barlink
```

If you see that, the GPUs are talking over the direct path. If you do not,
nothing is broken — vLLM simply fell back to its normal behaviour.

**One warning that is not our fault.** On Python 3.14 (what current Arch
ships), vLLM has a shared-memory bug of its own: the first request can hang
with `No available shared memory broadcast block`. It happens with or without
this project. Use Python 3.13 for vLLM if you hit it.

### sglang (step by step)

**Use Python 3.12 or 3.13.** On 3.14 some of sglang's binary packages cannot be
installed at all (an upstream packaging problem, unrelated to this project).

```bash
# 1. one-time setup
python3.13 -m venv ~/venv-sglang
~/venv-sglang/bin/pip install sglang
~/venv-sglang/bin/pip install -e /path/to/barlink-pcie -e /path/to/modded-p2p/integrations/python
```

```bash
# 2. start it (root, same reason as above)
. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-sglang/bin/python -m modded_p2p.sglang_launch \
    --model-path <your-model> --tp 2
```

The launcher is just sglang's own server with the translation layer switched
on first. Without the two variables it behaves exactly like plain sglang.

### Is it really using the direct path?

The honest check (no framework needed):

```bash
. /etc/profile.d/barlink-p2p.sh
export BARLINK_TRANSPORT=bar1
sudo -E python -m torch.distributed.run --nproc_per_node=2 \
    integrations/python/tests/test_backend_allreduce.py --backend barlink
```

It prints `all_reduce ...: OK` and a transport state line showing
`requested: bar1, achieved: bar1`.

### Things to know before you try

- Every GPU process must see the same `BARLINK_*` variables. Mismatched values
  between processes make the job hang instead of printing an error.
- Messages smaller than 4 KiB deliberately use the old path (the direct path is
  not faster for them). Larger messages are where the speedup lives.
- Pipeline-parallel `send`/`recv` is not covered — tensor parallelism is.
- Native C++ engines (llama.cpp, Strata) do not have this interface at all;
  they are out of scope here.

Details, limits and the measured numbers:
[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) and
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Docs

- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — vLLM / sglang setup and limits
- [docs/DETAILS.md](docs/DETAILS.md) — how the patch works, troubleshooting, FAQ
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measurements, conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
