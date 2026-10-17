#!/bin/bash
# Run vLLM over the barlink direct path for a LOCAL model directory.
# The script changes into the model directory, so relative paths inside the
# checkpoint behave as they would there.
#
#   sudo -E bash run_vllm_local.sh /path/to/model [extra vllm args...]
#
# Environment overrides: TP (default 2), PORT (8000), GPU_UTIL (0.85),
# PY (interpreter that has vllm installed).
set -u
MODEL="${1:-${MODEL:-}}"
[ -n "${MODEL:-}" ] && [ "$#" -gt 0 ] && shift
[ -n "${MODEL:-}" ] && [ -d "$MODEL" ] || { echo "usage: $0 <model-dir> [vllm args...]" >&2; exit 2; }
MODEL="$(cd "$MODEL" && pwd)" || exit 2
cd "$MODEL" || exit 2

. /etc/profile.d/barlink-p2p.sh 2>/dev/null || true
export CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-$HOME/.cache/torch_extensions}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT="${BARLINK_TRANSPORT:-bar1}"
PY="${PY:-python3}"

EXTRA=()
[ -n "${HOST:-}" ] && EXTRA+=(--host "$HOST")
[ -n "${API_KEY:-}" ] && EXTRA+=(--api-key "$API_KEY")

exec "$PY" -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size "${TP:-2}" \
  --disable-custom-all-reduce \
  --gpu-memory-utilization "${GPU_UTIL:-0.85}" \
  --port "${PORT:-8000}" \
  "${EXTRA[@]}" \
  "$@"
