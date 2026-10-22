# GPU unlock (GA102/GA104)

The optional [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) module
runs from the initramfs **before** `nvidia` binds a card, replays the V67/PLM
pre-driver sequence, writes the two SM speed-selector registers and issues an
FLR. The stock driver then binds the card normally.

This is independent of the BAR1 P2P work: the unlock touches neither BAR1 nor
the driver patch. Both components can be installed on the same machine.

## Scope

| | |
|---|---|
| Chips | GA102 and GA104 **GeForce and CMP** parts |
| Rejected | professional RTX A-series, data-centre parts (they already run at full rate), everything else |
| This machine | 2 × RTX 3080 20 GB: `10de:2206`, subsystem `10de:146d`, `0000:01:00.0` and `0000:05:00.0` — both accepted |
| Verified upstream | one RTX 3090 (`0000:21:00.0`) on a CachyOS 7.2.8 kernel with driver 615.71.09 |
| Driver | NVIDIA **open** kernel modules; the module only runs from the initramfs and only on a cold card |

`install-gpu-unlock.sh` reads the accepted PCI IDs from the pinned upstream
source, so the list cannot drift from the module that is built.

## RTX 3080 20 GB versus the tested RTX 3090

There is no upstream report for a 3080 board. What the code says:

- The eligibility gate is the **chip/PCI ID** list; `10de:2206` is in it.
- The firmware and V67 image are **GA102**, not board-specific. Nothing in the
  path reads the memory size, the board straps or the vBIOS geometry.
- A 20 GB 3080 is the same GA102 silicon as a 3090 with a different memory and
  board configuration. The VRAM size does not enter the unlock.

So the 20 GB card is expected to behave like the tested GA102 parts, but the
first cold boot is the actual test. Recovery is trivial (remove the cmdline
option or run `revert-gpu-unlock.sh`, then power-cycle).

## What the selectors actually do

`SS0` and `SS1` are **not** a BF16 switch. They are the two override registers
for the nine `OPT_SM_SPEED_SELECT` fuses — instruction **issue-rate dividers**,
one per arithmetic family:

| Register | Address | Fields |
|---|---|---|
| `FEATURE_OVERRIDE_SM_SPEED_SELECT` (SS0) | `0x0082381c` | eight 4-bit fields: `IMLA0`–`IMLA3`, `FMLA16`, `FMLA32`, `FFMA`, `DP` |
| `FEATURE_OVERRIDE_SM_SPEED_SELECT_1` (SS1) | `0x00823820` | the ninth field: `IMLA4` |

Each nibble reads as `[enable | 3-bit speed]`; `0x8` is "override enabled,
speed 0 = full rate". Writing `0x88888888` to SS0 and `0x8` to SS1 therefore
sets **all nine** units to full rate:

| Field | Governs |
|---|---|
| `DP` | FP64 |
| `FFMA` | FP32 fused multiply-add |
| `FMLA16` | FP16 MLA |
| `FMLA32` | FP32 MLA (the consumer halving of FP16-with-FP32-accumulate tensor throughput) |
| `IMLA0`–`IMLA4` | integer MLA; `IMLA0` also DP4A |

Consumer Ampere parts are only partially fused: `FMLA32` and `IMLA4` sit at the
`0x1` tier, the rest at full rate; the CMP parts have most fields at the maximum
divisor. The override outranks the fuses; the fuse shadows are not modified, so
nothing is permanent and the vBIOS is never written.

Upstream's description says "full BF16 rate" because BF16 tensor throughput was
the largest observed gain on a GA102 GeForce card. The register width is
broader; that is the label, not the scope.

Measured elsewhere (not on this machine), for scale:

| Source | Before → after |
|---|---|
| RTX 3090 Ti fork, 8192³ GEMM | FP16 87.5 → 118.4 TFLOPS; BF16 87.5 → 157.4; TF32 42.6 → 82.6 |
| User report, RTX 30-series | float32 22.5, float16 90.8 (60 → 90), bfloat16 97.8 TFLOPS |

Measured on this machine after the unlock (2 × RTX 3080 20 GB, 68 SM each,
driver 615.78.08, torch 2.13.0+cu130; 16384³ GEMM, median of 5 × 10 iterations;
the cards are capped at 200 W and sustain ~1.0–1.25 GHz):

| Card | BF16 | FP16 | INT8 | TF32 | FP32 |
|---|---:|---:|---:|---:|---:|
| `0000:01:00.0` | 85.2 TFLOPS | 79.2 | 31.8 TOPS | 38.3 | 16.9 |
| `0000:05:00.0` | 81.3 TFLOPS | 74.8 | 30.3 TOPS | 36.9 | 16.1 |

Sanity check: 68 SM × 1.215 GHz × 1024 FLOP ≈ 84.6 TFLOPS, which matches the
BF16 figure; the consumer-halved rate would be about 42. TF32 matches the
512 FLOP/SM/clk rate. INT8 stays near one IMMA per clock (≈ 32 TOPS), i.e. it
does **not** follow the override — same finding as the CMP measurements.

Caveats: the nibble encoding is inferred, not documented by NVIDIA; the CMP
measurements showed INT8/IMMA still gated despite the override; the gain is
per-card and workload-dependent. It does not change clocks, SM count, memory
bandwidth or the PCIe link — the latter two are why it does nothing for P2P.

## Install

```bash
sudo bash scripts/install-gpu-unlock.sh            # uses the GA102/GA104 cards found
sudo bash scripts/install-gpu-unlock.sh --targets=all
sudo bash scripts/install-gpu-unlock.sh --no-cmdline   # install, print the cmdline line
```

`scripts/install.sh` also does it:

```bash
sudo bash scripts/install.sh                    # auto: on when a GA102/GA104 card is present
sudo bash scripts/install.sh --with-gpu-unlock  # force on
sudo bash scripts/install.sh --no-gpu-unlock    # never
```

The installer clones the upstream repository at a pinned commit, downloads the
pinned NVIDIA 610.43.03 inputs over HTTPS, verifies every SHA-256, generates the
firmware, builds `gpu_unlock.ko` against the running kernel and installs:

| Path | Purpose |
|---|---|
| `/lib/modules/<kernel>/updates/gpu-unlock/gpu_unlock.ko` | module, loaded from the initramfs |
| `/usr/lib/firmware/gpu-unlock/610.43.03/*.bin` | booter, GSP and V67 images |
| `/etc/mkinitcpio.conf.d/zz-gpu-unlock.conf` (or the dracut / initramfs-tools drop-in) | puts the module and its firmware in the image, before `nvidia` |
| `/opt/nvidia-gpu-patches/build/gpu-unlock`, `/opt/nvidia-gpu-patches/gpu-unlock-cache` | source tree, pinned inputs and generated assets |

Kernels before 6.16 leave a card the firmware never POSTed at `PCI_UNKNOWN`, so
upstream's D0 gate rejects it; the installer applies
[`patches/gpu-unlock-kernel-power-state.patch`](../patches/gpu-unlock-kernel-power-state.patch)
below 6.16 (`GPU_UNLOCK_POWER_FIX=0|1` overrides the detection). 7.2 already
syncs the state itself.

## Kernel command line

The module does nothing without the opt-in:

```
gpu_unlock.targets=all                          # every unbound GA102/GA104 card
gpu_unlock.targets=0000:01:00.0,0000:05:00.0    # explicit list
```

`scripts/gpu-unlock-cmdline.sh` edits the mechanism actually in use:

| Mechanism | What is edited |
|---|---|
| systemd-boot entries | `options` line of kernel entries (and of UKI entries that already carry one) |
| UKI (auto-discovered) | the image's cmdline source: preset `*_cmdline`, `/etc/kernel/cmdline`, or an additive `/etc/cmdline.d/zz-gpu-unlock.conf`; the image is rebuilt |
| GRUB | `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`; `grub-mkconfig` runs |
| limine | `KERNEL_CMDLINE[default]+=` in `/etc/default/limine`; `limine-update` runs |
| rEFInd | `refind_linux.conf` |

Every edit is idempotent, keeps a `*.gpu-unlock.bak` next to the file, and the
installation rebuilds the boot image and menu. A UKI embeds its command line at
build time, which is why the installer rebuilds it instead of only touching a
config file. `--mechanism=` forces one path when the machine has several.

## Applying it: cold boot

Upstream's supported path is a **cold card**: power the machine off and on. A
card that a driver already used this power cycle is refused before any firmware
runs (`card already initialised since power on`).

Observed on this machine: a warm reboot on kernel 7.2.11 also ran the unlock on
both cards (`gpu_unlock: unlocked` in `dmesg`). Kernels >= 6.16 sync the PCI D0
state in `pci_pm_init()`, which is the state upstream's pre-6.16 fix addresses.
Treat a warm reboot as best-effort: if the log says the card was refused, power
off.

Check the result (any init; `dmesg` needs root or `CAP_SYSLOG`):

```bash
dmesg | grep gpu_unlock
# with systemd/journald instead:
journalctl -k -b | grep gpu_unlock
lspci -nnk -s 0000:01:00.0
```

A successful run logs `gpu_unlock: unlocked` per card. If it logs `unlock failed`
or `no GA102/GA104 card`, the card was not cold, was bound, or the address does
not match.

## Remove

```bash
sudo bash scripts/revert-gpu-unlock.sh
```

`scripts/revert.sh` calls it too when the component is installed. The revert
strips the cmdline option, removes the module, firmware, licenses and initramfs
drop-in, rebuilds the image and the boot menu, and leaves the build tree in
place. If the unlock already ran this power cycle, the selector values stay
until the card loses power — power off for a clean state.

## Kernel upgrades

The module is installed for the running kernel, like the barlink override:
re-run `install-gpu-unlock.sh` after a kernel upgrade. Upstream also ships DKMS
packages if you prefer automatic rebuilds; do not mix both.

## Driver versions

The module runs **before** `nvidia` binds and patches no driver code. It loads
the pinned 610.43.03 booter/GSP images, writes the selectors, FLRs the card,
and the driver then binds the same clean, halted GSP it would after a cold
boot. A newer driver therefore does not change the unlock path, and a driver
update does not remove it (it rewrites `nvidia.ko`, not `gpu_unlock.ko`).

The one verified combination upstream is 615.71.09; the machine this
repository was set up on runs 615.78.08 (one patch release newer), which is
expected to behave identically but is not upstream-verified. Re-run the
installer after a **kernel** upgrade, not after a driver update.

## Risks and provenance

- An out-of-tree module that resets the GPU before the driver binds can crash
  the machine. Keep a TTY reachable; recovery is removing the cmdline option,
  `revert-gpu-unlock.sh`, or a power-cycle.
- The firmware is generated at install time from NVIDIA 610.43.03 inputs whose
  SHA-256 is pinned, and is never redistributed by this repository. The CMP V67
  constants come from WildFlash1st/cmp90hx-unlock (GPL-2.0). See
  [NOTICE.md](https://github.com/Zagitta/gpu-unlock/blob/main/firmware/NOTICE.md)
  and [LICENSE-NOTES.md](../LICENSE-NOTES.md).

## FAQ

**Does it increase VRAM or fix the 20 GB configuration?** No. It changes
selector overrides only.

**Does it help P2P or BAR1?** No. Memory bandwidth, L2 and the PCIe link are
untouched.

**Does it overclock?** No. It removes an issue-rate divider; clocks are a
separate control.

**Is it BF16-only?** No — see the selector table above.
