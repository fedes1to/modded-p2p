"""modded-p2p framework integrations.

Shared seam: barlink-pcie ships a real ``torch.distributed`` backend
(``barlink.register_backend()`` -> ``init_process_group(backend="barlink")``,
CUDA tensors over the transport ladder, CPU tensors on gloo). Every Python
inference framework here builds its collectives on ``torch.distributed``, so
the integration is: register the backend, then make the framework pass the
barlink backend name instead of ``nccl`` for its tensor-parallel group.

    import modded_p2p
    modded_p2p.activate()          # generic: register + map nccl -> barlink

or let a framework plugin do it (vLLM entry point, sglang import hook).

Requirements for the BAR1 plane (inherited from barlink-pcie):
  * the persistent driver from modded-p2p's install.sh (BarlinkPeerBar1=1),
  * ``BARLINK_BAR1_NV_SOURCE`` / ``BARLINK_BAR1_HOLD_BDF`` / ``CUDA_HOME``
    (installed into /etc/profile.d by the installer),
  * CAP_SYS_ADMIN in the worker processes (driver checks osIsAdministrator()),
    or the ``PeerMappingOverride=1`` registry alternative,
  * identical BARLINK_* environment on every rank.
"""

from __future__ import annotations

import os

__version__ = "0.1.0"
__all__ = ["activate", "vllm_plugin"]

_PATCHED = False


def _env_on(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes", "on")


def activate(map_backends: bool = True) -> None:
    """Register barlink as a torch.distributed backend and (optionally) make
    framework collectives use it instead of NCCL.

    Idempotent. Safe to call from every rank.
    """
    global _PATCHED
    import barlink  # noqa: F401  (import error is the right failure)

    barlink.register_backend()
    if not map_backends or _PATCHED:
        return

    import torch.distributed as dist

    def _mapped(backend):
        if isinstance(backend, str) and backend.lower() == "nccl":
            return "barlink"
        return backend

    if not getattr(dist, "_modded_p2p_original_init", None):
        dist._modded_p2p_original_init = dist.init_process_group
        dist._modded_p2p_original_new_group = dist.new_group

        def init_process_group(backend=None, *args, **kwargs):
            result = dist._modded_p2p_original_init(_mapped(backend), *args, **kwargs)
            try:
                print(f"modded_p2p: process group created, resolved backend={dist.get_backend()}",
                      flush=True)
            except Exception:
                pass
            return result

        def new_group(ranks=None, **kwargs):
            if "backend" in kwargs:
                kwargs["backend"] = _mapped(kwargs["backend"])
            return dist._modded_p2p_original_new_group(ranks, **kwargs)

        dist.init_process_group = init_process_group
        dist.new_group = new_group

    _PATCHED = True
