# Performance — measured, with conditions

## Test configuration

Two same-generation consumer GPUs (20 GiB each), one on a CPU-attached PCIe 4.0
×16 slot and one on a PCH-attached PCIe 3.0 ×4 slot — a deliberately uneven
pair, so the measurements show the floor rather than the ceiling. IOMMU in
pass-through mode. Peer access is disabled by the driver
(`cudaDeviceCanAccessPeer = 0`), so host-staged copies run at ~2.6 GiB/s.

Driver: the patched open kernel modules from this repository, loaded with
`BarlinkPeerBar1=1;RMPcieP2PType=1` and static BAR1 disabled. Tooling from
barlink-pcie (`bench_host_transport.py`, `barlink_vs_nccl.py`), bfloat16, full
operation duration, p50, 8–10 rounds.

## bar1 direct path vs NCCL (all_reduce)

| size | barlink:bar1 | NCCL | bar1 vs NCCL |
|---|---|---|---|
| 20 KiB | 57.35 µs | **50.51 µs** | 0.88× |
| 80 KiB | **82.95 µs** | 84.71 µs | **1.02×** |
| 1 MiB | **521.87 µs** | 560.21 µs | **1.07×** |
| 4 MiB | **1938.86 µs** | 2099.73 µs | **1.08×** |
| 16 MiB | **7169.01 µs** | 8208.90 µs | **1.15×** |

The GPU1 ×4-Gen3 link caps both backends (bar1 ≈ 2340 MB/s effective at
16 MiB, NCCL ≈ 2044 MB/s). On a ×16 Gen4 CPU-attached pair both numbers scale
with the link; barlink-pcie's published measurements report ~80 % of link for writes
and ~1.3× full-duplex.

## Non-direct transports (same run, `barlink_vs_nccl.py`)

| op | size | NCCL | barlink:device | barlink:shm |
|---|---|---|---|---|
| all_reduce | 20 KiB | **50.6 µs** | 67.7 µs | 71.6 µs |
| all_reduce | 1 MiB | **568.5 µs** | 701.5 µs | 697.1 µs |
| broadcast | 20 KiB | **44.4 µs** | 69.9 µs | 126.1 µs |
| broadcast | 1 MiB | **353.5 µs** | 699.2 µs | 921.3 µs |

As barlink-pcie's own README states for homogeneous NVIDIA rigs: the base
transports do not beat a working NCCL. **The direct path is the reason to run
any of this.**

## Correctness (the number that matters most)

`dmabuf_pcie_probe`, both directions, 65536 bytes written from the source GPU
into the target's BAR1 slice and read back through the target's **own VMM
pointer**: `bad_bytes = 0` in both directions; `barlink.preflight` 6/6 OK.
The sg table reports the offset (32 × 64 KiB contiguous), so no pattern scan
is needed.

## What was not measured

- A ×16/×16 CPU-attached pair.
- Multi-hour sustained load (barlink-pcie reports 1.1 M checked rounds in its
  own testing; the figures here cover minutes).
- Anything above 16 MiB payloads.
