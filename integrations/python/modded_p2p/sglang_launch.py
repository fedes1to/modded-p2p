"""Launcher that applies the modded-p2p backend mapping before sglang starts.

    MODDED_P2P_SGLANG=1 BARLINK_TRANSPORT=bar1 \
      python -m modded_p2p.sglang_launch --model-path <model> --tp 2 ...

The shim is env-gated: without MODDED_P2P_SGLANG=1 this is exactly
``python -m sglang.launch_server``.
"""

from __future__ import annotations

import runpy
import sys

import modded_p2p.sglang_shim  # noqa: F401  (applies the mapping when enabled)

sys.argv[0] = "sglang.launch_server"
runpy.run_module("sglang.launch_server", run_name="__main__", alter_sys=True)
