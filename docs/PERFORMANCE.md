# Performance — measured, with conditions

Machine: 2× RTX 3080 20GB (GA102, 20 GiB each), Intel 12th gen,
GPU0 on a CPU-attached Gen4 ×16 slot, **GPU1 on a PCH-attached Gen3 ×4 slot**,
`intel_iommu=on iommu=pt`. P2P is locked out by the driver
(`cudaDeviceCanAccessPeer = 0`), so every host-staged copy runs at ~2.6 GiB/s.

Driver: open kernel modules 615.78.08 + `patches/BARLINK_PCIE-615.78.08.patch`,
loaded with `BarlinkPeerBar1=1;RMPcieP2PType=1`, static BAR1 off.
Tooling: `benchmarks/bench_host_transport.py` and `barlink_vs_nccl.py` from
barlink-pcie; bfloat16; full operation duration; p50; 8–10 rounds;
torch 2.14.1+cu130, NCCL 2.30.7.

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
with the link; barlink's own reference rig measures ~80 % of link for writes
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

## What we did not measure

- A ×16/×16 CPU-attached pair (the intended production topology).
- Multi-hour sustained load (`barlink-pcie` has 1.1 M checked rounds on their
  rig; this one has minutes).
- Anything above 16 MiB payloads.
