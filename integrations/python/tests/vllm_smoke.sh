#!/bin/bash
# vLLM TP=2 smoke over the barlink backend. Root required (CAP_SYS_ADMIN).
# Usage: sudo -E bash integrations/python/tests/vllm_smoke.sh [model] [port]
#
# Env knobs used here:
#   MODDED_P2P_VLLM=1                     apply the plugin (backend mapping + all-reduce patch)
#   BARLINK_TRANSPORT=bar1                force the direct plane
#   VLLM_ENABLE_V1_MULTIPROCESSING=0      run the engine in-process: avoids vLLM's
#                                         shm-broadcast bridge, which hangs on
#                                         Python 3.14 independently of barlink
#                                         (verified with plain NCCL too)
set -u
MODEL="${1:-hf-internal-testing/tiny-random-LlamaForCausalLM}"
PORT="${2:-8012}"

. /etc/profile.d/barlink-p2p.sh 2>/dev/null || true
export CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-$HOME/.cache/torch_extensions}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export MODDED_P2P_VLLM=1
export BARLINK_TRANSPORT="${BARLINK_TRANSPORT:-bar1}"
export VLLM_ENABLE_V1_MULTIPROCESSING="${VLLM_ENABLE_V1_MULTIPROCESSING:-0}"
PY="${PY:-python3}"   # override with the interpreter that has vllm installed

SRVLOG=/tmp/vllm-smoke-server.log
cd /tmp
"$PY" -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size 2 --disable-custom-all-reduce --enforce-eager \
  --gpu-memory-utilization 0.80 --max-model-len 512 --max-num-seqs 4 \
  --port "$PORT" > "$SRVLOG" 2>&1 &
SRV=$!
ok=0
for i in $(seq 1 120); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }
  kill -0 "$SRV" 2>/dev/null || break
  sleep 2
done
echo "health_ok=$ok"
rc=1
if [ "$ok" = 1 ]; then
  code=$(curl -s -m 120 -o /tmp/vllm-smoke-comp.json -w '%{http_code}' \
    "http://127.0.0.1:$PORT/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Hello\",\"max_tokens\":8}")
  echo "completion_http=$code"
  head -c 500 /tmp/vllm-smoke-comp.json; echo
  [ "$code" = "200" ] && rc=0
fi
kill "$SRV" 2>/dev/null; sleep 3; kill -9 "$SRV" 2>/dev/null
echo "== proof lines (backend / transport):"
grep -nE 'modded_p2p|barlink\[' "$SRVLOG" | head -8
echo "== errors:"
grep -nE 'ERROR|Traceback' "$SRVLOG" | head -5
exit "$rc"
