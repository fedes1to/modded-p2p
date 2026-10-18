"""vLLM entry point.

vLLM loads general plugins registered under the ``vllm.general_plugins``
entry-point group at import time. Install this package (``pip install -e
integrations/python``) and set ``MODDED_P2P_VLLM=1``; then vLLM's tensor
parallel process group is created with barlink's backend instead of NCCL.

Scope: tensor parallelism (all_reduce / broadcast) and pipeline parallelism
(the stage hand-off is a send/recv pair, staged through pinned host memory by
``patches/barlink-p2p-staging.patch``). vLLM's own CUDA-IPC custom all-reduce
auto-disables itself on rigs without peer access; keep it disabled
(``--disable-custom-all-reduce``) so the barlink path is the one used.
"""

from __future__ import annotations

import os
import sys


def register() -> None:
    """Called by vLLM for every entry point in ``vllm.general_plugins``."""
    if os.environ.get("MODDED_P2P_VLLM", "0").strip().lower() not in ("1", "true", "yes", "on"):
        return
    from modded_p2p import activate

    activate(map_backends=True)
    _force_torch_allreduce()
    _pause_abort_polling_during_capture()
    print("modded_p2p: vLLM plugin active -- nccl groups mapped to barlink", flush=True)


def _force_torch_allreduce() -> None:
    """Route vLLM's TP all-reduce through ``torch.distributed``.

    vLLM 0.31 dispatches all-reduce through its own backends (PYNCCL,
    flashinfer, quick-reduce, custom, symmetric memory) and only falls back to
    ``torch.distributed.all_reduce`` when none applies. Those backends bypass
    the process group, and with it barlink. Replacing the communicator's
    ``all_reduce`` with the documented in-tree fallback (clone + distributed
    all_reduce, same out-of-place semantics vLLM expects) is what makes the
    barlink backend the transport.
    """
    try:
        from vllm.distributed.device_communicators.cuda_communicator import CudaCommunicator
    except Exception:  # vLLM not importable / other version: nothing to patch
        return
    if getattr(CudaCommunicator, "_modded_p2p_patched", False):
        return

    import torch.distributed as dist

    def all_reduce(self, input_):
        out = input_.clone()
        dist.all_reduce(out, group=self.device_group)
        return out

    CudaCommunicator.all_reduce = all_reduce
    CudaCommunicator._modded_p2p_patched = True


def _pause_abort_polling_during_capture() -> None:
    """Keep BAR1's abort watchdog out of torch CUDA-graph capture.

    barlink's watchdog reads a status word on a private stream and synchronizes
    that stream. CUDA forbids synchronizing *any* stream while a capture is in
    progress, so a poll that happens to land inside ``torch.cuda.graph``
    invalidates the capture with ``cudaErrorStreamCaptureUnsupported``. vLLM
    captures several graphs during startup, which made the failure look like an
    engine-init error with no obvious cause.

    ``barlink.abort_gate.pause_polling()`` is the transport's own reentrant
    exclusion for exactly this; the plugin enters it around the one context
    manager that wraps every capture in the process.
    """
    try:
        from barlink import abort_gate
        from torch.cuda.graphs import graph as graph_capture
    except Exception:  # barlink or torch version without the hook: leave as-is
        return
    if getattr(graph_capture, "_modded_p2p_abort_pause", False):
        return

    original_enter = graph_capture.__enter__
    original_exit = graph_capture.__exit__

    def enter(self):
        pause = abort_gate.pause_polling()
        pause.__enter__()
        self._modded_p2p_pause = pause
        try:
            return original_enter(self)
        except BaseException:
            self._modded_p2p_pause = None
            pause.__exit__(*sys.exc_info())
            raise

    def exit(self, *exc):
        try:
            return original_exit(self, *exc)
        finally:
            pause = getattr(self, "_modded_p2p_pause", None)
            self._modded_p2p_pause = None
            if pause is not None:
                pause.__exit__(*exc)

    graph_capture.__enter__ = enter
    graph_capture.__exit__ = exit
    graph_capture._modded_p2p_abort_pause = True
