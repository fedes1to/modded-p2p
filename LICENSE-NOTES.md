# Licenses and redistribution notes

This repository contains **diffs and scripts only**. No NVIDIA code, no
binaries, no proprietary userspace is redistributed here.

| Piece | Upstream | License | What we ship |
|---|---|---|---|
| `patches/BARLINK_PCIE-615.78.08.patch` | [efschu/barlink-pcie](https://github.com/efschu/barlink-pcie) `patches/BARLINK_PCIE.patch`, a diff against [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) tag 595.58.03, ported to tag 615.78.08 | The patch carries the license of the files it touches: NVIDIA's dual **MIT/GPLv2** (see `kernel-open/COPYING` in the upstream tree) | A unified diff. NVIDIA's source is downloaded by `install.sh`, never bundled |
| `patches/barlink-platform-fixes.patch` | diffs against efschu/barlink-pcie (probes + `src/barlink/bar1.py`) | **Apache-2.0** (barlink-pcie's own license) | A unified diff |
| `patches/barlink-baton-marker-state.patch` | diffs against efschu/barlink-pcie (`src/barlink/device.py`, `src/barlink/_compat/jit_kernel/{cache,baton}_health.py`) | **Apache-2.0** (barlink-pcie's own license) | A unified diff |
| `scripts/*.sh`, `docs/*`, `README.md` | this repository | **GPL-3.0** (see [LICENSE](LICENSE)) | — |
| `dmabuf_holder` | efschu/barlink-pcie | **GPL-2.0** (kernel module) | Not shipped; cloned and built by `install.sh` |

The ported driver patch keeps every added line identifiable (the
`BARLINK_PCIE:` comment tag upstream uses), so it remains obvious which lines
are not NVIDIA's.
