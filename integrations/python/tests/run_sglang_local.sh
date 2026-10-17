#!/bin/bash
# Run sglang over the barlink direct path for a LOCAL model directory.
# The script changes into the model directory, so relative paths inside the
# checkpoint behave as they would there.
#
#   sudo -E bash run_sglang_local.sh /path/to/model [extra sglang args...]
#
# Environment overrides: TP (default 2), PORT (30000),
# PY (interpreter that has sglang installed).
set -u
MODEL="${1:-${MODEL:-}}"
[ -n "${MODEL:-}" ] && [ "$#" -gt 0 ] && shift
[ -n "${MODEL:-}" ] && [ -d "$MODEL" ] || { echo "usage: $0 <model-dir> [sglang args...]" >&2; exit 2; }
MODEL="$(cd "$MODEL" && pwd)" || exit 2
cd "$MODEL" || exit 2

. /etc/profile.d/barlink-p2p.sh 2>/dev/null || true
export CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-$HOME/.cache/torch_extensions}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT="${BARLINK_TRANSPORT:-bar1}"
PY="${PY:-python3}"

exec "$PY" -m modded_p2p.sglang_launch \
  --model-path "$MODEL" \
  --tp "${TP:-2}" \
  --host "${HOST:-127.0.0.1}" \
  --port "${PORT:-30000}" \
  "$@"
