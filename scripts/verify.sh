#!/usr/bin/env bash
# modded-p2p verification:
#   1. is the patched module the one that is loaded?
#   2. host requirements (barlink preflight, if the venv was installed)
#   3. byte-level proof: GPU->GPU write into the peer's BAR1, read back through
#      the target's own pointer -- both directions, bad_bytes must be 0.
#
#   sudo bash scripts/verify.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

BASE="${BARLINK_BASE:-/opt/modded-p2p}"
# shellcheck disable=SC1091
. "$BASE/env" 2>/dev/null || { echo "not installed: $BASE/env missing -- run scripts/install.sh" >&2; exit 1; }
CUDA_HOME="${CUDA_HOME:-/opt/cuda}"
HOLD_BDF="${BARLINK_HOLD_BDF:-$(cat /etc/barlink-p2p.hold-bdf 2>/dev/null || true)}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }
RC=0

step "loaded module vs built module"
modprobe dmabuf_holder 2>/dev/null || true
LOADED="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
BUILT="$(modinfo "$DRIVER_DIR/kernel-open/nvidia.ko" | awk '/^srcversion:/{print $2}')"
if [ -n "$LOADED" ] && [ "$LOADED" = "$BUILT" ]; then ok "srcversion $LOADED"; else fail "srcversion mismatch (loaded='${LOADED:-none}' built='$BUILT')"; fi
MARKERS="$(strings "$DRIVER_DIR/kernel-open/nvidia.ko" | grep -c BARLINK_PCIE || true)"
[ "$MARKERS" = "37" ] && ok "full patch (37 markers)" || fail "marker count $MARKERS != 37"
grep -qi 'BarlinkPeerBar1=1' /proc/driver/nvidia/params 2>/dev/null && ok "BarlinkPeerBar1=1 present" || fail "BarlinkPeerBar1=1 not in RegistryDwords"
grep -q '^dmabuf_holder' /proc/modules 2>/dev/null && ok "dmabuf_holder loaded" || fail "dmabuf_holder not loaded"
[ -e /dev/dmabuf_holder ] && ok "/dev/dmabuf_holder present" || fail "/dev/dmabuf_holder missing"
if [ -n "$HOLD_BDF" ] && [ -d "/sys/bus/pci/devices/$HOLD_BDF" ]; then ok "attach device $HOLD_BDF"; else fail "attach device missing (BARLINK_BAR1_HOLD_BDF='$HOLD_BDF')"; fi

step "barlink preflight (optional)"
if [ -x "$BARLINK_DIR/.venv/bin/python" ]; then
  BARLINK_NVIDIA_KO="$DRIVER_DIR/kernel-open/nvidia.ko" \
    "$BARLINK_DIR/.venv/bin/python" -m barlink.preflight && ok "preflight passed" || fail "preflight failed (see above)"
else
  echo "skipped: no venv (re-run install.sh --with-torch to enable)"
fi

step "byte-level proof (both directions)"
command -v g++ >/dev/null || { fail "g++ missing"; exit "$RC"; }
PROBE=/tmp/modded-p2p-probe
g++ -O2 -std=c++14 \
  -I"$BARLINK_DIR" \
  -I"$DRIVER_DIR/kernel-open/common/inc" \
  -I"$DRIVER_DIR/src/common/sdk/nvidia/inc" \
  -I"$DRIVER_DIR/src/nvidia/arch/nvalloc/unix/include" \
  -I"$CUDA_HOME/include" \
  -o "$PROBE" "$BARLINK_DIR/probes/dmabuf_pcie_probe.cpp" \
  -L"$CUDA_HOME/lib64" -lcudart -lcuda || { fail "probe build failed"; exit "$RC"; }

for pair in "0 1" "1 0"; do
  set -- $pair
  echo "-- target GPU$1, source GPU$2"
  OUT="$("$PROBE" "$1" "$2" --importer=module --hold-bdf="$HOLD_BDF" 2>&1 || true)"
  echo "$OUT" | grep -E 'HOLD OK|BAR1 OFFSET|bad_bytes|ALL bytes match' || true
  if echo "$OUT" | grep -q 'bad_bytes = 0'; then ok "bad_bytes = 0 (GPU$1 <- GPU$2)"; else fail "byte check failed (GPU$1 <- GPU$2)"; fi
done

step "result"
if [ "$RC" = 0 ]; then echo "PASS -- P2P direct path is working."; else echo "FAIL -- see lines above."; fi
exit "$RC"
