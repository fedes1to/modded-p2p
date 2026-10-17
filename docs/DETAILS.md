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
