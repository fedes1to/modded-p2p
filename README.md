# modded-p2p

GPU↔GPU direct transfers (P2P) on consumer NVIDIA cards — **no ReBAR, no
firmware flashing, no proprietary blobs**. Patches and scripts only.

Built on [**barlink-pcie**](https://github.com/efschu/barlink-pcie) by
**efschu** — all credit for the mechanism goes there. This repository adds a
port of their driver patch to a current NVIDIA open-kernel-modules tag, two
platform fixes, and a persistent installer.

The optional GA102/GA104 pre-driver unlock is
[**gpu-unlock**](https://github.com/Zagitta/gpu-unlock) by **Zagitta** — all
credit for the module and the V67/PLM sequence goes there. This repository adds
a pinned, repeatable installer for it.

## What it changes

Consumer cards normally cannot address each other's memory: peer access is
disabled and the BAR1 aperture is much smaller than the framebuffer, so
collectives go through system RAM. This project exposes a direct path through
the existing BAR1 aperture:

1. A buffer on the target card is exported as a **dma-buf**.
2. A small kernel module (the holder) attaches to it, which makes the driver
   map that buffer into the target card's **BAR1**.
3. The source card writes straight into that BAR1 slice over PCIe. No system
   RAM in the data path.
4. The driver patches make the driver permit this on consumer cards.

BAR1 is not resized and the firmware is not touched.

Measured at the collective level against NCCL: gains from roughly 80 KiB
message size upward, a small loss for the smallest messages (below the direct
path's minimum transfer size). Figures and the conditions they were taken
under: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Requirements

- Linux with NVIDIA **open** kernel modules
- Kernel headers, `gcc`, `git`, `patch`, `make`
- Two NVIDIA GPUs of the same generation
- systemd, OpenRC or dinit
- Root (to load kernel modules)
- ~2 GB disk
- For the optional GA102/GA104 unlock: `python3` ≥ 3.14 (firmware generator) and network access to the pinned inputs

The installer pins the NVIDIA source tag it was written against; see
[docs/DETAILS.md](docs/DETAILS.md).

## Install

```bash
git clone https://git.fedesito.me/fedes1to/modded-p2p
cd modded-p2p
sudo bash scripts/install.sh     # build + install + activate (screen blinks once)
sudo bash scripts/verify.sh      # must print: PASS
```

The install persists across reboots. After a kernel upgrade, re-run
`install.sh`.

Undo everything:

```bash
sudo bash scripts/revert.sh
```

A reboot also returns to the stock driver.

On GA102/GA104 machines the installer also sets up the optional
[compute unlock](docs/GPU-UNLOCK.md) described below. `--no-gpu-unlock` opts
out; `--with-gpu-unlock` forces it on a machine where auto-detection is not
wanted.

## vLLM and sglang

Both frameworks send tensor-parallel collectives through NCCL, which cannot use
the direct path here. `integrations/python/` lets them use the direct path
instead: the process group is created with barlink's transport, so the
framework's collectives travel over BAR1.

### vLLM

vLLM requires a specific PyTorch build, so give it its own environment:

```bash
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e /path/to/modded-p2p/integrations/python
```

Start it (root is required — the driver's P2P path asks for a permission only
root holds; the first start compiles a kernel once):

```bash
. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-vllm/bin/vllm serve <your-model> \
    --tensor-parallel-size 2 \
    --disable-custom-all-reduce
```

Each worker prints one line at startup when the direct path is active:

```
modded_p2p: process group created, resolved backend=barlink
```

Without that line the framework runs its normal path.

Some Python releases are not supported by parts of vLLM's own runtime; if the
first request hangs with `No available shared memory broadcast block`, that
issue exists independently of this project — use a Python version the
framework supports.

### sglang

sglang's binary packages are not published for every Python version; use one
its wheels exist for (see its installation docs).

```bash
python3 -m venv ~/venv-sglang
~/venv-sglang/bin/pip install sglang
~/venv-sglang/bin/pip install -e /path/to/barlink-pcie -e /path/to/modded-p2p/integrations/python

. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-sglang/bin/python -m modded_p2p.sglang_launch \
    --model-path <your-model> --tp 2
```

The launcher is sglang's own server with the transport selection applied
first; without the two variables it behaves like plain sglang.

### Verify the direct path without a framework

```bash
. /etc/profile.d/barlink-p2p.sh
export BARLINK_TRANSPORT=bar1
sudo -E python -m torch.distributed.run --nproc_per_node=2 \
    integrations/python/tests/test_backend_allreduce.py --backend barlink
```

Expected: `all_reduce ...: OK` per rank and a transport state line reading
`requested: bar1, achieved: bar1`.

### Operational notes

- Every GPU process must see the same `BARLINK_*` variables. Mismatched values
  between processes make the job hang rather than print an error.
- Transfers below the transport's minimum size (4 KiB by default) deliberately
  use the host-staged path; larger messages are where the direct path pays.
- Tensor parallelism is covered; pipeline parallelism is not — run PP profiles
  with the plugin off. See [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).
- Native C++ engines (llama.cpp, Strata) have no `torch.distributed` interface
  and are out of scope for these integrations.

Details and limits: [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## GPU unlock (GA102/GA104, optional)

[gpu-unlock](https://github.com/Zagitta/gpu-unlock) runs from the initramfs
before the driver binds and lifts the SM issue-rate dividers (`SS0`/`SS1`), the
consumer/CMP cap on tensor and arithmetic throughput. It does not touch clocks,
memory bandwidth, BAR1 or the P2P path, and it never writes the vBIOS.

```bash
sudo bash scripts/install-gpu-unlock.sh          # auto-detects the cards
sudo bash scripts/install.sh --with-gpu-unlock   # or as part of the main install
```

It is enabled automatically by `install.sh` when a GA102/GA104 card is present.
It runs from the next boot; upstream's supported path is a cold boot, though
kernels ≥ 6.16 also applied it after a warm reboot here. Verify with
`dmesg | grep gpu_unlock` (root) or `journalctl -k -b` with journald.

Scope, the 3080-20GB-versus-3090 caveat, what the selectors really govern, and
recovery: [docs/GPU-UNLOCK.md](docs/GPU-UNLOCK.md).

## Docs

- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — framework integration and limits
- [docs/GPU-UNLOCK.md](docs/GPU-UNLOCK.md) — GA102/GA104 compute unlock (scope, selectors, cold boot)
- [docs/DETAILS.md](docs/DETAILS.md) — how the patch works, troubleshooting, FAQ
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measurements, conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
