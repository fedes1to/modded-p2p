"""vLLM entry point.

vLLM loads general plugins registered under the ``vllm.general_plugins``
entry-point group at import time. Install this package (``pip install -e
integrations/python``) and set ``MODDED_P2P_VLLM=1``; then vLLM's tensor
parallel process group is created with barlink's backend instead of NCCL.

Scope: tensor parallelism (all_reduce / broadcast). vLLM's own CUDA-IPC custom
all-reduce auto-disables itself on rigs without peer access; keep it disabled
(``--disable-custom-all-reduce``) so the barlink path is the one used.
"""

from __future__ import annotations

import os


def register() -> None:
    """Called by vLLM for every entry point in ``vllm.general_plugins``."""
    if os.environ.get("MODDED_P2P_VLLM", "0").strip().lower() not in ("1", "true", "yes", "on"):
        return
    from modded_p2p import activate

    activate(map_backends=True)
    _force_torch_allreduce()
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
