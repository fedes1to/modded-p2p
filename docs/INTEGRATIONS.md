# Framework integrations (vLLM, sglang)

The driver from this repo changes nothing for a Python framework on its own: the
framework talks to `torch.distributed`, and NCCL knows nothing about dma-bufs.
barlink-pcie closes that gap — it ships a real **`torch.distributed` backend**
(`barlink.register_backend()` → `init_process_group(backend="barlink")`; CUDA
tensors use the transport ladder including the BAR1 plane, CPU tensors stay on
gloo). `integrations/python/` is the thin layer that makes the frameworks
*choose* that backend.

## What is proven, what is not

| Piece | State |
|---|---|
| torch backend seam, 2 ranks, CUDA all_reduce, `bad` count = 0 | **tested on this rig** (`integrations/python/tests/test_backend_allreduce.py`): `TEST_RC=0`, transport state `requested: bar1, achieved: bar1, direct: True` on both ranks; the 2048-byte cell falls back to host-staged by design (below bar1's 4096-byte minimum) |
| vLLM plugin (entry point `vllm.general_plugins`) | implemented; independent vLLM venv (torch 2.13) prepared; launch instructions below |
| sglang shim | implemented; sglang 0.5.22 pins torch==2.14.1, which matches this repo's working stack |
| llama.cpp / Strata (native C++ engines) | **not covered**: no `torch.distributed` seam. llama.cpp has an internal allreduce (`ggml/src/ggml-cuda/allreduce.cuh`, `try_allreduce_{nccl,internal,butterfly}`) and Strata hands stages off through mapped pinned host memory; both would need C++ engine patches, which is a different project from this one. |

## Install

```bash
# the Python shim (entry points + adapters); into the SAME environment as the framework
pip install -e integrations/python
```

The framework's environment must import the same `barlink` package the shim
uses (barlink-pcie from the checkout your `install.sh` made, or a pip install of
it).

## vLLM

vLLM 0.31 pins `torch==2.13.0`; give it its own venv and install the shim plus
barlink into it:

```bash
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e integrations/python

. /etc/profile.d/barlink-p2p.sh          # BARLINK_* + CUDA_HOME (written by install.sh)
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT=bar1            # force the direct plane; "device" is the ladder default
sudo -E ~/venv-vllm/bin/vllm serve <model> --tensor-parallel-size 2 \
     --disable-custom-all-reduce
```

Notes:
- Run as root (or grant CAP_SYS_ADMIN): the driver's peer-mapping path checks
  `osIsAdministrator()`; the registry alternative is `PeerMappingOverride=1`.
- Every rank needs identical `BARLINK_*` values — a rank mismatch hangs, it does
  not error.
- **vLLM 0.31 has its own all-reduce dispatch** (PYNCCL, flashinfer,
  quick-reduce, custom, symmetric memory) that bypasses the process group;
  `--disable-custom-all-reduce` alone does not reach barlink. The plugin
  replaces `CudaCommunicator.all_reduce` with vLLM's own documented fallback
  (`clone` + `torch.distributed.all_reduce`), which lands on the barlink
  backend.
- **Proof line:** each worker prints
  `modded_p2p: process group created, resolved backend=barlink`.
- The plugin also fixes barlink's abort-gate under `torch.inference_mode()`
  (vLLM's execution context): inference tensors may only be mutated inside
  InferenceMode, so the watchdog re-enters it. Carried by
  `patches/barlink-platform-fixes.patch`.
- Scope: tensor-parallel collectives (`all_reduce`, `all_gather`, `broadcast`,
  `reduce_scatter`, `barrier`). Pipeline-parallel `send`/`recv` is not part of
  the backend's op set.
- First start JIT-builds the extension once (needs `CUDA_HOME`).
- Tiny test models: cap `--max-num-seqs` (e.g. 4) — vLLM's flex-attention
  backend sizes buffers per sequence and can OOM on defaults.

### Known environment blocker (not the transport)

On this box (Python 3.14), vLLM 0.31 brings the TP group up and carries its
collectives over barlink — log proof: `resolved backend=barlink` per worker,
and barlink's own dispatcher lines for vLLM's all-reduce (e.g. the 64-byte
calibration call falling back to host-staged, by design). The **first
generation request then hangs** with
`No available shared memory broadcast block found in 60 seconds`, and this
**reproduces identically with plain NCCL and the plugin disabled** — it is a
vLLM/Python-3.14 shared-memory issue on this machine, not the barlink path.
The environment flags tried (none resolved it):
`VLLM_ENABLE_V1_MULTIPROCESSING=0`, elevated timeouts, `--enforce-eager`,
`--disable-custom-all-reduce`. A vLLM environment on Python 3.13 (its tested
range) is the next step for full-generation validation.

## sglang

sglang 0.5.22 pins `torch==2.14.1` — the same version this rig already runs, so
it can share an environment with barlink:

```bash
pip install sglang
pip install -e /path/to/barlink-pcie -e integrations/python

. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT=bar1
```

`modded_p2p.sglang_shim` applies the same backend mapping on import, guarded by
the env switch. barlink also carries a dedicated sglang adapter
(`barlink.integrations.sglang`, tested against the fork it grew in) for code
that calls `BarlinkCommunicator` directly instead of a torch process group.

### Python 3.14 note

sglang 0.5.22 pins `outlines==0.1.11` (schema-constrained decoding). That
package's `outlines-core` predates Python 3.14 (its pyo3 cannot build for it),
so a plain `pip install sglang` fails at the wheel-build step. It is only
needed for guided/JSON-schema decoding; the workaround is
`pip install --no-deps sglang` plus the dependency list without
`outlines`/`outlines-core`, then run unconstrained generation — or use a
Python 3.13 environment.

### Status on this rig (Python 3.14, CUDA 13) — blocked upstream

Attempted end to end; the binary packages cannot be aligned on this
interpreter, independently of barlink:

- `sglang==0.5.22` has no installable distribution for this Python (pip offers
  only ≤0.4.2/0.5.10); the newest installable is `0.5.10.post1`.
- `sglang 0.5.10.post1` requires `sglang-kernel==0.4.1`. The PyPI wheel ships
  only `sm100` `common_ops` (needs spurious `libnvrtc.so.12`/`libcublas.so.12`
  CUDA-12 libs); the vendor cu130-index wheel for 0.4.1 resolves the ABI but
  still exposes only the `sm100` variant and fails on sm_86 with an undefined
  `c10::cuda` symbol against torch 2.14.
- `sglang-kernel==0.4.9` (cu130 index) imports cleanly, but renames
  `fp8_blockwise_scaled_mm` → `sglang 0.5.10` imports the old name and fails.

Conclusion: run sglang on Python 3.12/3.13 (its supported matrix) — the shim,
launcher and smoke test here need no changes there.

## Verifying the seam without a framework

```bash
. /etc/profile.d/barlink-p2p.sh
export CUDA_HOME=/opt/cuda BARLINK_TRANSPORT=bar1
PYTHONPATH=integrations/python sudo -E torchrun --nproc_per_node=2 \
  integrations/python/tests/test_backend_allreduce.py --backend barlink
```

Expected: `all_reduce ...: OK` from rank 0, transport state showing
`requested: bar1` / `achieved: bar1`, exit code 0.

## Performance expectation

Collectives in the 8 KiB–1 MiB range: bar1 wins from ~80 KiB upward on the test
rig (+2–15 % vs NCCL); it loses the smallest sizes (20 KiB: −12 %). End-to-end
tokens/s gains are a fraction of the collective gains — attention/GEMM dominate
a decode step. Numbers: [PERFORMANCE.md](PERFORMANCE.md).
