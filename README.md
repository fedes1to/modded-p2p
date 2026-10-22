# nvidia-gpu-patches

Patch collection for consumer NVIDIA cards: a GA102/GA104 compute unlock, a P2P
driver for modded cards, and the framework patches that put that P2P path under
vLLM and sglang. **No ReBAR resizing, no firmware flashing, no proprietary
blobs** — patches and scripts only.

## What's in here

| Component | Effect | Applies to |
|---|---|---|
| [**gpu-unlock**](docs/GPU-UNLOCK.md) | lifts the consumer SM issue-rate caps (`SS0`/`SS1`) from the initramfs, before the driver binds | GA102/GA104 |
| [**modded-p2p**](docs/DETAILS.md) | port of [barlink-pcie](https://github.com/efschu/barlink-pcie) to a current open-kernel-modules tag: GPU↔GPU transfers through the BAR1 aperture, no system-RAM staging in the data path | modded cards (2080 Ti 22 GB, 3080 20 GB, 4080 32 GB, 4090 48 GB) and uneven rigs |
| [**framework patches**](docs/INTEGRATIONS.md) | route vLLM/sglang tensor-parallel collectives over barlink, and re-enable vLLM's P2P custom all-reduce on more than two PCIe GPUs | the venvs on those rigs |

All credit for the mechanisms goes upstream: barlink-pcie by **efschu**,
gpu-unlock by **Zagitta**. This repository adds the ports, the platform fixes,
and the card-aware installer.

## Requirements

- Linux with NVIDIA **open** kernel modules (modded-p2p)
- Kernel headers, `gcc`, `git`, `patch`, `make`
- Two or more NVIDIA GPUs — `install.sh` selects what applies (below)
- systemd, OpenRC or dinit
- Root (to load kernel modules)
- ~2 GB disk
- gpu-unlock only: `python3` ≥ 3.14 (firmware generator) and network access to
  the pinned inputs

The installer pins the NVIDIA source tag it was written against; see
[docs/DETAILS.md](docs/DETAILS.md).

## Install

```bash
git clone https://git.fedesito.me/fedes1to/nvidia-gpu-patches
cd nvidia-gpu-patches
sudo bash scripts/install.sh     # detect the cards, install what applies
sudo bash scripts/verify.sh      # must print: PASS
```

`install.sh` picks the components from the cards it finds:

- **gpu-unlock** — installed on GA102/GA104 cards. `--no-gpu-unlock` opts out;
  `--with-gpu-unlock` forces it.
- **modded-p2p** — installed for modded cards and for uneven rigs (mixed models
  or memory) after a confirmation prompt. A uniform stock rig is left on the
  stock driver; force the install with `--with-modded-p2p`.
- **vLLM custom all-reduce** — with an even GPU count (2/4/6/8) the installer
  offers to apply the vLLM P2P patch to the vLLM venv.

Non-interactive runs take the default (no) for the prompts; `--yes` accepts
them. The install persists across reboots. After a kernel upgrade, re-run
`install.sh`.

Undo everything:

```bash
sudo bash scripts/revert.sh
```

A reboot also returns to the stock driver.

## gpu-unlock (GA102/GA104)

[gpu-unlock](https://github.com/Zagitta/gpu-unlock) runs from the initramfs
before the driver binds and lifts the SM issue-rate dividers (`SS0`/`SS1`), the
consumer/CMP cap on tensor and arithmetic throughput. It does not touch clocks,
memory bandwidth, BAR1 or the P2P path, and it never writes the vBIOS.

It is installed automatically by `install.sh` when a compatible card is present.
It runs from the next boot; upstream's supported path is a cold boot, though
kernels ≥ 6.16 also applied it after a warm reboot here. Verify with
`dmesg | grep gpu_unlock` (root) or `journalctl -k -b` with journald.

Standalone:

```bash
sudo bash scripts/install-gpu-unlock.sh          # auto-detects the cards
sudo bash scripts/install.sh --with-gpu-unlock   # or as part of the main install
```

Scope, the 3080-20GB-versus-3090 caveat, what the selectors really govern, and
recovery: [docs/GPU-UNLOCK.md](docs/GPU-UNLOCK.md).

## modded-p2p

Consumer cards normally cannot address each other's memory: peer access is
disabled and BAR1 is much smaller than the framebuffer, so collectives go
through system RAM. barlink-pcie exposes a direct path inside that existing
BAR1 aperture — a dma-buf on the target card, attached by a small holder
module, which the source card writes into over PCIe. BAR1 is not resized and
the firmware is not touched.

Measured at the collective level against NCCL: gains from roughly 80 KiB
message size upward, a small loss below the direct path's minimum transfer
size. Figures and conditions: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

Requirements, the pinned driver tag, the load keys and the recovery steps:
[docs/DETAILS.md](docs/DETAILS.md).

## Framework patches (vLLM, sglang)

Both frameworks send tensor-parallel collectives through NCCL, which cannot use
the direct path. `integrations/python/` makes the process group use barlink's
transport instead. vLLM additionally has its own P2P custom all-reduce, which
it disables on more than two PCIe-only GPUs; a patch in `patches/` re-enables
it on a P2P-capable driver.

### Apply the venv patches

One command patches both environments (auto-detects `~/venv-vllm` and
`~/venv-sglang`):

```bash
sudo bash scripts/patch-venvs.sh
sudo bash scripts/patch-venvs.sh ~/venv-vllm ~/venv-sglang   # explicit paths
```

It applies the four barlink patches to the barlink-pcie each venv imports, and
the vLLM custom all-reduce patch to the vLLM venv. `--check` reports without
writing.

### vLLM

vLLM requires a specific PyTorch build, so give it its own environment:

```bash
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e /path/to/nvidia-gpu-patches/integrations/python
sudo bash scripts/patch-venvs.sh ~/venv-vllm
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
~/venv-sglang/bin/pip install -e /path/to/barlink-pcie -e /path/to/nvidia-gpu-patches/integrations/python
sudo bash scripts/patch-venvs.sh ~/venv-sglang

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

## Docs

- [docs/GPU-UNLOCK.md](docs/GPU-UNLOCK.md) — GA102/GA104 compute unlock (scope, selectors, cold boot)
- [docs/DETAILS.md](docs/DETAILS.md) — modded-p2p mechanism, patch ports, troubleshooting, FAQ
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — vLLM/sglang integration and limits
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measurements, conditions
- [LICENSE-NOTES.md](LICENSE-NOTES.md) — licenses

## License

This repository's own files: **GPL-3.0** ([LICENSE](LICENSE)). The patches
keep their upstream licenses — see [LICENSE-NOTES.md](LICENSE-NOTES.md).
