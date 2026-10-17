"""sglang adapter.

barlink carries a tested sglang adapter (``barlink.integrations.sglang``) whose
API matches the sglang fork it grew in. Stock sglang does not construct it, so
this shim wires the same seam as the vLLM plugin: the process group must be
created with barlink's backend.

Install this package and set ``MODDED_P2P_SGLANG=1``; import it before sglang
initialises its distributed state (``import modded_p2p.sglang_shim``), or call
``modded_p2p.activate()`` yourself in the launcher.

Scope: tensor-parallel collectives (all_reduce, all_gather, broadcast,
reduce_scatter, barrier -- the ops barlink's backend implements).
"""

from __future__ import annotations

import os


def register() -> None:
    if os.environ.get("MODDED_P2P_SGLANG", "0").strip().lower() not in ("1", "true", "yes", "on"):
        return
    from modded_p2p import activate

    activate(map_backends=True)


try:  # import side effect, guarded by the env switch
    register()
except Exception:  # pragma: no cover - the shim must never break a plain import
    pass
