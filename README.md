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

## Frameworks

**vLLM and sglang** can run their tensor-parallel collectives over the BAR1
path instead of NCCL — barlink-pcie ships a real `torch.distributed` backend,
and `integrations/python/` makes the frameworks choose it. Verified on this rig:
two ranks, CUDA `all_reduce` byte-correct, transport `achieved: bar1` on both.
Native C++ engines (llama.cpp, Strata) have no such seam and are not covered.

Launch lines, limits and requirements:
[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## Docs

- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — vLLM / sglang setup and limits
- [docs/DETAILS.md](docs/DETAILS.md) — how the patch works, troubleshooting, FAQ
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measurements, conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
