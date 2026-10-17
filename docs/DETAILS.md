# Technical details

For readers who want to know what the patches change and why. The
authoritative design documents live upstream in
[efschu/barlink-pcie](https://github.com/efschu/barlink-pcie):
`design/bar-pcie-mechanism.md`, `docs/BUILDING_THE_DRIVER.md`,
`docs/OPERATIONS.md`, `docs/measurements/*`.

## The two halves of the driver patch

1. **Peer-BAR1 guard relaxation** (`osmemdesc.c`, `nvrm_registry.h`):
   `osCheckGpuBarsOverlapAddrRange()` normally rejects
   `cudaHostRegister(IOMEMORY)` on another GPU's BAR1. With
   `BarlinkPeerBar1=1` it allows a range fully contained in a *different*
   GPU's BAR1 aperture.
2. **BAR1-P2P HAL + static-BAR1 window** (`kern_bus_*`, generated tables,
   UVM plumbing): on Ampere/Ada the driver installs stub implementations of
   the BAR1-P2P functions (`return NV_FALSE`). The patch redirects them to the
   `_GH100` implementations (which touch no chip registers) and makes static
   BAR1 able to map a *window* instead of the whole framebuffer.

On the path used here (**dynamic dma-buf**) the second half is inert at
runtime: the holding module attaches the dma-buf, RM maps those pages into
BAR1 on demand, and the wildcard registration + `BarlinkPeerBar1=1` do the
rest. Static BAR1 must stay **off** (`RMStaticBar1LocalForce` unset) — forcing
it makes the dma-buf export fail with `NV_ERR_INVALID_LOCK_STATE`.

## Port to 615.78.08 — the five adaptations

The upstream patch is a diff against tag `595.58.03`. Between 595 and 615
NVIDIA changed five spots that the patch's context depends on. Full explanation
in `docs/` of the test campaign; in one line each:

1. `kern_bus_tu102.c` (Increase refcount): locals block realigned, extra
   `requestedKind`; pre-image corrected, `NvU32 gfid;` inserted there.
2. `g_kern_bus_nvoc.c`: a new `kbusShouldRefcountConstruct` dispatch section
   now follows the `kbusGetBar1P2PDmaInfo` one; trailing context moved.
3. `g_kern_bus_nvoc.h`: two new struct fields in 615
   (`staticBar1DefaultDmaFlags`, `staticBar1DefaultPageSize`); context re-spanned.
4. `kern_bus_tu102.c` (update-mapping): the 595 pre-image guard no longer
   exists; the window check now sits before the lock assert / `if (bRelease)`.
5. `p2p_caps.c`: 615 moved the per-GPU GSP caps query into
   `_gpuInitPcieP2PCapability` (`gpu.c`). The `capsSource=GSP_MAILBOX`
   diagnostic moved with it; marker count stays 37.

Result: all 82 hunks apply with `--fuzz=0`, +1805/−57 over 21 files, and the
built `nvidia.ko` contains exactly **37** `BARLINK_PCIE` strings — the
signature barlink's own `preflight` uses to say "full patch".

## Platform fixes for this class of machine

`patches/barlink-platform-fixes.patch` fixes two probe-level off-by-ones
(`--importer=` / `--hold-bdf=` are 11 characters; the code compared 12, so
both flags were unparseable as shipped) and adds `BARLINK_BAR1_HOLD_BDF` to
`src/barlink/bar1.py`. That env var exists because 615-class drivers refuse a
**GPU** as the attaching device for FRAMEBUFFER dma-bufs:

```
NVRM: attaching GPU is not supported
```

Attaching as a non-GPU busmaster (a NIC or NVMe controller on the same
machine) satisfies `dma_buf_attach`'s requirements; the writes still come from
the source GPU. `install.sh` detects a suitable device and writes it to
`/etc/barlink-p2p.env` (`BARLINK_BAR1_HOLD_BDF`).

## Load-time keys

| Key | Why |
|---|---|
| `BarlinkPeerBar1=1` | enables the peer-BAR1 registration guard relaxation |
| `RMPcieP2PType=1` | makes the BAR1 caps evaluation take the BAR1 branch |

Do **not** set `RMStaticBar1LocalForce` or `RMForceStaticBar1` on small-BAR
cards: the first is mutual-exclusive with the dma-buf path, the second stops
the GPU from initialising at all (GSP firmware rejects it before any patched
code runs).

## Recovery

| Situation | Action |
|---|---|
| anything wedges | reboot — the stock driver loads automatically |
| want stock now | `scripts/revert.sh` (or reboot) |
| display black after load | `scripts/revert.sh` or start your DM |
| verify a module is the patched one | `strings <ko> \| grep -c BARLINK_PCIE` → 37; `cat /sys/module/nvidia/srcversion` must equal `modinfo <ko> \| grep srcversion` |

## What each script does

| Script | Run as | Effect |
|---|---|---|
| `scripts/install.sh` | root | clones NVIDIA's module source at the pinned tag, applies `patches/BARLINK_PCIE-615.78.08.patch`, builds it; clones barlink-pcie, applies `patches/barlink-platform-fixes.patch`, builds `dmabuf_holder`; installs the modules as a persistent override, writes the keys, activates now. Idempotent — re-run after a kernel upgrade |
| `scripts/verify.sh` | root | compiles and runs the byte-proof probe (both directions, `bad_bytes` must be 0); checks the loaded module, keys, holder, and optionally runs barlink's own `preflight` |
| `scripts/revert.sh` | root | removes the override and all config, returns to the stock driver |

Files written by `install.sh`:

| Path | Purpose |
|---|---|
| `/lib/modules/<kernel>/updates/barlink-p2p/*.ko` | the patched modules (`depmod` prefers `updates/` over the packaged module) |
| `/etc/modprobe.d/barlink-p2p.conf` | `NVreg_RegistryDwords="BarlinkPeerBar1=1;RMPcieP2PType=1"` (unknown keys are ignored by stock modules, so a kernel update cannot break the boot) |
| `/etc/dinit.d/barlink-holder` + `boot.d` link — or `/etc/modules-load.d/barlink-p2p.conf` — or `/etc/conf.d/modules` | loads `dmabuf_holder` at boot, per init system |
| `/etc/profile.d/barlink-p2p.sh`, `/etc/barlink-p2p.hold-bdf` | runtime environment for the barlink library (`BARLINK_BAR1_NV_SOURCE`, `BARLINK_BAR1_HOLD_BDF`, `CUDA_HOME`) |
| `/opt/modded-p2p/build/` | the source trees and built modules |

The patched stack is not related to the **userspace** driver package: if an
NVIDIA `.run` installer ever overwrote system libraries (libglvnd/`nvidia-utils`
files replaced by regular files), reinstall those packages
(`pacman -S libglvnd lib32-libglvnd nvidia-utils lib32-nvidia-utils` on Arch)
to restore the packaged symlinks.

## Init support

| Init | Service stop/start | Holder at boot |
|---|---|---|
| systemd | `systemctl` | `/etc/modules-load.d/` |
| OpenRC | `rc-service` (+ `rc-update add modules boot`) | `/etc/conf.d/modules` |
| dinit | `dinitctl` | `/etc/dinit.d/barlink-holder` in `boot.d` |

The scripts detect which one is present; nothing is installed for an init the
machine does not run.

## Troubleshooting (the ones we actually hit)

| Symptom | Cause | Fix |
|---|---|---|
| `rmmod: nvidia_modeset is in use` | `nvidia-persistenced` keeps `/dev/nvidia*` open | `install.sh` stops it; by hand: stop the `nvidia-persistenced` service |
| holder attach fails with `ENOTSUPP`, dmesg `NVRM: attaching GPU is not supported` | 615-class drivers refuse FRAMEBUFFER dma-bufs attached as a **GPU** | attach as a non-GPU busmaster — the installer auto-detects a NIC or NVMe controller and exports `BARLINK_BAR1_HOLD_BDF` |
| Export fails with `NV_ERR_INVALID_LOCK_STATE` | static BAR1 forced on a small-BAR card | do **not** pass `RMStaticBar1LocalForce` — `install.sh` doesn't |
| `mmap(resource1_wc): EINVAL` | kernel with `CONFIG_IO_STRICT_DEVMEM=y`: a driver-claimed BAR cannot be sysfs-mmapped. The peer's BAR1 is unclaimed, so it works | none needed; do not mmap BAR0 |
| marker count ≠ 37 after build | wrong tag or a partially applied patch | `git -C /opt/modded-p2p/build/driver-* diff --stat` → should be 21 files, +1805/−57 |
| screen stays black | display manager was stopped and not restarted | start your DM; or TTY (Ctrl-Alt-F3) → `scripts/revert.sh` → reboot |

## Safety

- Nothing is flashed; the vBIOS is never written.
- No proprietary binaries are shipped or installed. The stock userspace driver
  and the packaged module stay untouched; the patched module is an override
  that `revert.sh` (or a reboot) removes.
- The only real risk of an out-of-tree kernel module is a kernel crash while
  it is loaded. Keep a TTY reachable; recovery is `revert.sh` or reboot.

## FAQ

**Does this resize BAR1 to 16 GiB?** No. On RTX 3080-class cards the vBIOS
offers at most 256 MiB. This project makes P2P work *inside* that limit.

**Will it help on a machine with PCIe 4.0 ×16 per card?** The transport
scales with the link; on a wide CPU-attached pair both backends get faster and
the direct path reaches barlink's reference numbers (~80 % of link for writes,
~1.3× full-duplex). See [PERFORMANCE.md](PERFORMANCE.md).

**The screen went black during install.** It should come back by itself; if
not, open a TTY (Ctrl-Alt-F3) and run `scripts/revert.sh`, then reboot.

**Which cards?** Turing/Ampere/Ada with a small BAR. Blackwell/Hopper need
nothing from this patch. Datacenter parts already have the HAL wired.

**Does it survive reboots?** Yes. After a kernel upgrade the override belongs
to the old kernel, so the machine boots the stock driver (safe) until you
re-run `install.sh`.

**Where do the numbers come from?** [PERFORMANCE.md](PERFORMANCE.md), and
barlink's own
[RESULTS.md](https://github.com/efschu/barlink-pcie/blob/main/docs/RESULTS.md).

## Layout

```
patches/
  BARLINK_PCIE-615.78.08.patch     driver patch (barlink-pcie's, ported to 615.78.08)
  barlink-platform-fixes.patch     two probe-flag fixes + BARLINK_BAR1_HOLD_BDF support
scripts/ install.sh verify.sh revert.sh
docs/    DETAILS.md PERFORMANCE.md
```
