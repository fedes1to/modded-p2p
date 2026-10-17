# modded-p2p

GPU↔GPU direct transfers (P2P) on consumer NVIDIA cards **without ReBAR, without
flashing firmware, and without proprietary driver blobs**.

This repository is packaging: it turns the excellent
[**barlink-pcie**](https://github.com/efschu/barlink-pcie) project by **efschu**
into a reproducible install for one class of machine — Ampere/Ada cards whose
BAR1 is smaller than their VRAM (e.g. RTX 3080, 256 MiB BAR1 against 20 GiB of
memory). It contains **only patches and scripts**. It never ships NVIDIA code,
never ships a binary driver, and never touches your card's firmware.
It works on **systemd, OpenRC and dinit** hosts.

## Credit where it is due

- **barlink-pcie** (https://github.com/efschu/barlink-pcie, Apache-2.0) — the
  dma-buf BAR1 transport, the kernel patch design, the `dmabuf_holder` module,
  the measurement discipline and the collectives library. Everything that makes
  this work exists there first.
- This repo adds: a port of their driver patch from NVIDIA tag `595.58.03` to
  **`615.78.08`**, two platform fixes found on our test rig, and
  install/load/verify scripts written for people who have never patched a
  kernel module.
- The driver patch itself is a diff against NVIDIA's
  [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
  (MIT/GPLv2). You download the source yourself; the patch is all we ship.

## What actually happens (the beginner version)

Your two cards cannot talk to each other directly because the driver refuses
peer access (`cudaDeviceCanAccessPeer` returns 0) and your BAR1 aperture is far
smaller than the framebuffer. barlink's trick:

1. A buffer on the **target** card is exported as a **dma-buf**.
2. A small **holder** module attaches to that dma-buf — this is the step that
   makes the driver program the buffer's pages into the target card's BAR1.
3. The **source** card maps that BAR1 slice and writes into it with ordinary
   GPU DMA. The bytes never pass through system RAM.
4. The two driver-side patches: one relaxes the guard that forbids userspace
   from registering another GPU's BAR1 (`BarlinkPeerBar1=1`), the other wires
   the BAR1-P2P HAL functions that the driver ships as stubs on Ampere.

Net effect, measured on our test rig (2× RTX 3080 20GB, second card on a
Gen3×4 PCH slot): `all_reduce` at 1 MiB is **1.07×** and at 16 MiB **1.15×**
faster than NCCL, with **zero bad bytes** in both directions. Details:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Requirements

| What | Why |
|---|---|
| Linux with NVIDIA **open** kernel modules installed (the `nvidia-open` style package) | we rebuild and load that module |
| Kernel headers (`/lib/modules/$(uname -r)/build`) | to build modules |
| `gcc` at least as new as the compiler your kernel was built with | kernel module ABI |
| `git`, `patch`, `make`, `python3` | build |
| ~2 GB disk (+ ~3 GB if you want the optional Python checks) | source + build |
| Two NVIDIA GPUs of the same generation | P2P needs a pair |
| systemd, OpenRC or dinit | the scripts detect your init: service control for the display/persistenced, and a boot hook that loads the holder module |
| Root | loading a kernel module |

Tested: Arch Linux, kernel 7.2.9-zen, driver 615.78.08, 2× GA102 (RTX 3080).
The driver patch is written against tag **615.78.08** — other versions may
apply if the context is unchanged; `install.sh` tells you immediately.

## Quickstart

```bash
# one command: builds, installs persistently, activates now
sudo bash scripts/install.sh          # add --with-torch for the optional Python checks

# prove it (byte-level check, both directions)
sudo bash scripts/verify.sh

# undo everything
sudo bash scripts/revert.sh
```

`install.sh` builds into `/opt/modded-p2p/`, installs the patched modules into
`/lib/modules/<kernel>/updates/barlink-p2p/` (which `depmod` prefers over the
packaged module), writes the load keys, and swaps the running driver.
**It is persistent:** every boot from now on loads the patched module. After a
kernel upgrade it boots the stock driver until you re-run the installer.

## What each script does

| Script | Run as | Effect |
|---|---|---|
| `scripts/install.sh` | root | clones NVIDIA's module source at the pinned tag, applies `patches/BARLINK_PCIE-615.78.08.patch`, builds it; clones barlink-pcie, applies `patches/barlink-platform-fixes.patch`, builds `dmabuf_holder`; installs the modules as a persistent override, writes the keys, activates now. Idempotent — re-run after a kernel upgrade |
| `scripts/verify.sh` | root | compiles and runs the byte-proof probe (both directions, `bad_bytes` must be 0); checks the loaded module, keys, holder, and optionally runs barlink's own `preflight` |
| `scripts/revert.sh` | root | removes the override and all config, returns to the stock driver |

## Is it safe?

- **Nothing is flashed.** The card's firmware/vBIOS is never written.
- **Nothing proprietary is included.** No NVIDIA binaries, no `.run` files, no
  userspace replacement. Your installed driver stays untouched on disk; we
  load a module from `~/barlink-build` with `insmod`, so a **reboot always
  returns you to the stock driver**.
- The failure mode of the patched module itself is an unclean kernel — that is
  true of any out-of-tree module. Keep a second machine or a recovery boot
  handy; the stock driver is one reboot away.

## Troubleshooting (the ones we actually hit)

| Symptom | Cause | Fix |
|---|---|---|
| `rmmod: nvidia_modeset is in use` | `nvidia-persistenced` keeps `/dev/nvidia*` open | `install.sh` stops it; if you do it by hand: `systemctl stop nvidia-persistenced` (or `dinitctl stop`) |
| `dmabuf_holder` attach fails with `ENOTSUPP` and dmesg says `NVRM: attaching GPU is not supported` | 615-class drivers refuse FRAMEBUFFER dma-bufs attached as a **GPU** | attach as a non-GPU busmaster — the installer auto-detects a NIC or NVMe controller and exports `BARLINK_BAR1_HOLD_BDF`; override it if you want a specific device |
| Export fails with `NV_ERR_INVALID_LOCK_STATE` | static BAR1 forced on a small-BAR card | do **not** pass `RMStaticBar1LocalForce` — `install.sh` doesn't |
| `mmap(resource1_wc): EINVAL` | kernel with `CONFIG_IO_STRICT_DEVMEM=y`: a driver-claimed BAR cannot be mmap'd from sysfs. BAR1 of the peer is unclaimed, so it works; seeing this on `resource0` is expected | none needed; do not mmap BAR0 |
| Marker count ≠ 37 after build | wrong tag or a partially applied patch | `git -C /opt/modded-p2p/build/driver-* diff --stat` → should be 21 files, +1805/−57 |
| Screen stays black after install | the display manager was stopped and not restarted | `sudo bash scripts/revert.sh` from a TTY (Ctrl-Alt-F3), then reboot; or start it: `systemctl start <your-dm>` / `dinitctl start ly` |

## FAQ

**Does this resize BAR1 to 16 GiB?** No. On RTX 3080-class cards the vBIOS
offers at most 256 MiB, and no operating-system setting can invent more. This
project makes P2P work *inside* that limit.

**Will it help on a machine with PCIe 4.0 ×16 per card?** The transport scales
with the link; on our ×4-Gen3 test slot everything is link-bound. Expect the
direct path to reach barlink's reference numbers (~80 % of link for writes,
~1.3× full-duplex) on a wider, CPU-attached pair.

**Which cards?** Turing/Ampere/Ada with a small BAR. Blackwell/Hopper need
nothing from this patch. Datacenter parts already have the HAL wired.

**Does it survive reboots?** Yes — `install.sh` installs a module override
that `depmod` prefers over the packaged driver, plus the load keys, so every
boot loads the patched module. `revert.sh` removes all of it in one command.
**After a kernel upgrade** the override belongs to the old kernel: the machine
boots the stock driver (safe) until you re-run `install.sh`.

**Where do the numbers come from?** Our rig, honestly labelled:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md). barlink's own
[docs/RESULTS.md](https://github.com/efschu/barlink-pcie/blob/main/docs/RESULTS.md)
has theirs.

## Layout

```
patches/
  BARLINK_PCIE-615.78.08.patch     driver patch (barlink-pcie's, ported to 615.78.08)
  barlink-platform-fixes.patch     two probe-flag fixes + BARLINK_BAR1_HOLD_BDF support
scripts/ install.sh verify.sh revert.sh
docs/    DETAILS.md PERFORMANCE.md
```

Licenses and what may be redistributed: [LICENSE-NOTES.md](LICENSE-NOTES.md).
