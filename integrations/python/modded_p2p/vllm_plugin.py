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
