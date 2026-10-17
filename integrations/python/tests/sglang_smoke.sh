#!/bin/bash
# sglang TP=2 smoke over the barlink backend. Root required (CAP_SYS_ADMIN).
# Usage: sudo -E bash integrations/python/tests/sglang_smoke.sh [model] [port]
#
# The launcher module applies the backend mapping (env-gated by
# MODDED_P2P_SGLANG=1) before sglang initialises its distributed state.
set -u
MODEL="${1:-hf-internal-testing/tiny-random-LlamaForCausalLM}"
PORT="${2:-8021}"

. /etc/profile.d/barlink-p2p.sh 2>/dev/null || true
export CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-$HOME/.cache/torch_extensions}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export MODDED_P2P_SGLANG=1
export BARLINK_TRANSPORT="${BARLINK_TRANSPORT:-bar1}"
PY="${PY:-python3}"   # override with the interpreter that has sglang installed

SRVLOG=/tmp/sglang-smoke-server.log
cd /tmp
"$PY" -m modded_p2p.sglang_launch \
  --model-path "$MODEL" --tp 2 --port "$PORT" --host 127.0.0.1 \
  --mem-fraction-static "${MEM_FRAC:-0.70}" > "$SRVLOG" 2>&1 &
SRV=$!
ok=0
for i in $(seq 1 150); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }
  kill -0 "$SRV" 2>/dev/null || break
  sleep 2
done
echo "health_ok=$ok"
rc=1
if [ "$ok" = 1 ]; then
  code=$(curl -s -m 120 -o /tmp/sglang-smoke-comp.json -w '%{http_code}' \
    "http://127.0.0.1:$PORT/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Hello\",\"max_tokens\":8}")
  echo "completion_http=$code"
  head -c 500 /tmp/sglang-smoke-comp.json; echo
  [ "$code" = "200" ] && rc=0
fi
kill "$SRV" 2>/dev/null; sleep 3; kill -9 "$SRV" 2>/dev/null
echo "== proof lines:"
grep -nE 'modded_p2p|barlink|resolved backend' "$SRVLOG" | head -8
echo "== errors:"
grep -nE 'ERROR|Traceback' "$SRVLOG" | head -5
exit "$rc"
