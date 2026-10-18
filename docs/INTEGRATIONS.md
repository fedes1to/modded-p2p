# Framework integrations (vLLM, sglang)

The driver from this repository does nothing for a Python framework by itself:
the framework talks to `torch.distributed`, and NCCL does not know about
dma-bufs. barlink-pcie closes that gap — it provides a `torch.distributed`
backend (`barlink.register_backend()` → `init_process_group(backend="barlink")`;
CUDA tensors use the transport ladder including the BAR1 plane, CPU tensors
stay on gloo). `integrations/python/` is the thin layer that makes frameworks
choose that backend.

## Scope

| Piece | State |
|---|---|
| torch backend seam (2 ranks, CUDA all_reduce, byte-correct) | verified with `integrations/python/tests/test_backend_allreduce.py`; transport state reports `requested: bar1, achieved: bar1, direct: True` on both ranks |
| vLLM plugin (entry point `vllm.general_plugins`) | implemented and exercised; instructions below |
| sglang shim + launcher | implemented; instructions below |
| llama.cpp / Strata (native C++ engines) | not covered: they have no `torch.distributed` interface and would need engine-level C++ changes |

Frameworks pin specific PyTorch builds, so give each framework its own virtual
environment and install the shim plus barlink into that environment.

## vLLM

```bash
python3 -m venv ~/venv-vllm
~/venv-vllm/bin/pip install vllm
~/venv-vllm/bin/pip install -e /path/to/barlink-pcie -e integrations/python

. /etc/profile.d/barlink-p2p.sh   # BARLINK_* and CUDA_HOME, written by install.sh
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT=bar1     # force the direct plane; "device" is the ladder default
sudo -E ~/venv-vllm/bin/vllm serve <model> --tensor-parallel-size 2 \
     --disable-custom-all-reduce
```

Notes:

- Run as root, or grant CAP_SYS_ADMIN: the driver's peer-mapping path checks
  `osIsAdministrator()`. The registry alternative is `PeerMappingOverride=1`.
- Every rank must see identical `BARLINK_*` values — a mismatch hangs rather
  than erroring.
- vLLM also dispatches all-reduce through its own backends (custom all-reduce,
  NCCL wrappers), which bypass the process group. The plugin replaces the
  communicator's `all_reduce` with vLLM's own documented fallback
  (`clone` + `torch.distributed.all_reduce`), so the collective lands on the
  barlink backend.
- Each worker prints `modded_p2p: process group created, resolved backend=barlink`
  when the direct path is active.
- The plugin also carries a barlink fix for `torch.inference_mode()` (the
  execution context vLLM uses): inference tensors may only be mutated inside
  InferenceMode, so the abort-gate watchdog re-enters it. `patches/barlink-inference-mode.patch`
  is applied separately from the platform fixes, so an installation that
  predates this hunk picks it up on the next `scripts/install.sh`.
- The plugin enters `barlink.abort_gate.pause_polling()` around
  `torch.cuda.graph` capture. The watchdog reads its status word on a private
  stream and synchronizes it; CUDA forbids synchronizing any stream while a
  capture is running, and the resulting `cudaErrorStreamCaptureUnsupported`
  invalidates the graph. vLLM reports that as "Engine core initialization
  failed", with the real cause buried in the worker log. The abort watchdog
  stays enabled.
- `patches/barlink-capture-gate.patch` closes the remaining race: the
  exclusion now waits for a poll already on a device, and a poll that starts
  after the pause re-checks it under the same gate. Without that gate one
  in-flight poll can still invalidate a long startup sequence of captures.
- `patches/barlink-baton-marker-state.patch` stops a **queued** rank from
  vetoing the reclaim of a dead builder's `lock`. The
  `.barlink_jit_building` marker is written before torch's `FileBaton` is
  even attempted, so it said "compiling" about a process that was only
  waiting; with two TP ranks behind one abandoned lock, each kept the
  other's veto alive and both sat out the full 30-minute limit next to a
  finished `.so`. The marker now carries `waiting` or `building` and only
  `building` vetoes; it is flipped when `try_acquire`/`wait` wins the lock,
  which is the only moment the claim is true.
- Scope: tensor-parallel collectives (`all_reduce`, `all_gather`, `broadcast`,
  `reduce_scatter`, `barrier`). Pipeline-parallel `send`/`recv` is not part of
  the backend's op set.
- The first start JIT-builds the transport extension once; set `CUDA_HOME` if
  your toolkit is not auto-detected.
- Small test models: cap `--max-num-seqs` (for example 4) — attention backends
  size their buffers per sequence and can exhaust a small card on defaults.

### Framework issues that are not the transport

Some Python releases are not fully supported by vLLM's runtime yet. The
symptom observed is the first generation hanging with
`No available shared memory broadcast block found in 60 seconds`; it
reproduces with plain NCCL and the plugin disabled, so it is independent of
this project. Use a Python version the framework supports. None of
`VLLM_ENABLE_V1_MULTIPROCESSING=0`, `--enforce-eager` or
`--disable-custom-all-reduce` changes it.

## sglang

sglang's compiled kernel package is published only for specific Python and
CUDA combinations. Use a combination its installation docs support; if the
wheels for your interpreter do not exist, pip will try to build them and fail
— that is upstream packaging, not this project.

```bash
python3 -m venv ~/venv-sglang
~/venv-sglang/bin/pip install sglang
~/venv-sglang/bin/pip install -e /path/to/barlink-pcie -e integrations/python

. /etc/profile.d/barlink-p2p.sh
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT=bar1
sudo -E ~/venv-sglang/bin/python -m modded_p2p.sglang_launch \
     --model-path <model> --tp 2
```

`modded_p2p.sglang_launch` is sglang's own server with the backend mapping
applied first; without the two variables it behaves like plain sglang.
`modded_p2p.sglang_shim` applies the same mapping on import, guarded by the
environment switch. barlink also ships a dedicated sglang adapter
(`barlink.integrations.sglang`) for code that calls `BarlinkCommunicator`
directly instead of using a torch process group.

## Local model directories

Both helpers accept a local checkpoint directory, change into it, and start the
server with the direct path enabled:

```bash
sudo -E bash integrations/python/tests/run_vllm_local.sh  /path/to/model [vllm args...]
sudo -E bash integrations/python/tests/run_sglang_local.sh /path/to/model [sglang args...]
```

Overrides through the environment: `TP` (default 2), `PORT`, `GPU_UTIL`
(vLLM), `PY` (interpreter that has the framework installed). Extra arguments
are passed through, e.g. `--max-model-len 8192 --max-num-seqs 2`.

## Verifying the direct path without a framework

```bash
. /etc/profile.d/barlink-p2p.sh
export BARLINK_TRANSPORT=bar1
PYTHONPATH=integrations/python sudo -E torchrun --nproc_per_node=2 \
  integrations/python/tests/test_backend_allreduce.py --backend barlink
```

Expected: `all_reduce ...: OK` per rank and a transport state line reading
`requested: bar1, achieved: bar1`. The smoke scripts
`integrations/python/tests/vllm_smoke.sh` and `sglang_smoke.sh` do the same for
the frameworks.

## Performance expectation

Framework collectives in the sub-megabyte range are where the direct path
pays; the smallest messages stay on the host-staged path by design. End-to-end
throughput gains are a fraction of the collective-level gains, because
attention and GEMMs dominate a decode step. Figures and their conditions:
[PERFORMANCE.md](PERFORMANCE.md).
