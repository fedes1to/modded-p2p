#!/usr/bin/env bash
# modded-p2p installer -- one command, persists across reboots.
#
#   sudo bash scripts/install.sh                 # build + install + activate now
#   sudo bash scripts/install.sh --with-torch    # ... plus the optional Python checks
#   sudo bash scripts/install.sh --no-activate   # install for the next boot only
#
# What it does:
#   1. builds NVIDIA's open kernel modules at the pinned tag with the barlink
#      patch, plus barlink-pcie (with the platform fixes) and dmabuf_holder
#   2. installs the patched modules into
#      /lib/modules/<kernel>/updates/barlink-p2p/  (depmod prefers it over the
#      packaged module, so every boot from now on loads the patched one)
#   3. writes the load keys and runtime environment
#   4. swaps the running driver now (screen freezes for a few seconds)
#
# Undo everything with:  sudo bash scripts/revert.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DRIVER_TAG="${BARLINK_DRIVER_TAG:-615.78.08}"
BASE="${BARLINK_BASE:-/opt/modded-p2p}"
BUILD="$BASE/build"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
OVR="/lib/modules/$KVER/updates/barlink-p2p"
WITH_TORCH=0
ACTIVATE=1
UPSTREAM_DRIVER="https://github.com/NVIDIA/open-gpu-kernel-modules"
UPSTREAM_BARLINK="https://github.com/efschu/barlink-pcie"

for arg in "$@"; do
  case "$arg" in
    --with-torch)    WITH_TORCH=1 ;;
    --no-activate)   ACTIVATE=0 ;;
    --driver-tag=*)  DRIVER_TAG="${arg#*=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

step "prerequisites"
for c in git patch make gcc python3 depmod insmod modprobe; do
  command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
done
[ -e "$KDIR" ] || die "kernel headers missing at $KDIR (install your distro's linux-headers package)"
echo "kernel $(uname -r) | compiler $(gcc -dumpversion)"

mkdir -p "$BASE" "$BUILD"
DRIVER_DIR="$BUILD/driver-$DRIVER_TAG"
BARLINK_DIR="$BUILD/barlink-pcie"

step "driver source @ $DRIVER_TAG"
if [ ! -d "$DRIVER_DIR" ]; then
  git clone --depth 1 --branch "$DRIVER_TAG" "$UPSTREAM_DRIVER" "$DRIVER_DIR"
else
  echo "present: $DRIVER_DIR"
fi

step "driver patch"
cd "$DRIVER_DIR"
if git diff --quiet && git diff --cached --quiet; then
  patch -p1 --fuzz=0 --batch -i "$ROOT/patches/BARLINK_PCIE-$DRIVER_TAG.patch" \
    || die "patch did not apply -- this driver tag is not supported by the shipped patch"
else
  echo "tree already patched -- skipping"
fi

step "building kernel modules (about a minute)"
make modules -j"$(nproc)"

M=$(strings kernel-open/nvidia.ko | grep -c BARLINK_PCIE || true)
echo "BARLINK_PCIE markers: $M (expected 37)"
[ "$M" = "37" ] || warn "unexpected marker count -- barlink preflight will not report 'full patch'"

step "barlink-pcie library + platform fixes"
if [ ! -d "$BARLINK_DIR" ]; then
  git clone --depth 1 "$UPSTREAM_BARLINK" "$BARLINK_DIR"
else
  echo "present: $BARLINK_DIR"
fi
cd "$BARLINK_DIR"
if git diff --quiet; then
  git apply "$ROOT/patches/barlink-platform-fixes.patch" \
    || die "platform-fixes patch did not apply -- upstream changed; report the diff"
else
  echo "library already patched -- skipping"
fi

step "dmabuf_holder module"
make -C "$KDIR" M="$BARLINK_DIR/dmabuf_holder" modules

step "installing the patched modules for every boot"
mkdir -p "$OVR"
for m in nvidia nvidia-uvm nvidia-drm nvidia-modeset nvidia-peermem; do
  f="$DRIVER_DIR/kernel-open/$m.ko"
  [ -f "$f" ] && install -m 644 "$f" "$OVR/$m.ko"
done
install -m 644 "$BARLINK_DIR/dmabuf_holder/dmabuf_holder.ko" "$OVR/dmabuf_holder.ko"
depmod -a "$KVER"
RESOLVED="$(modinfo -n nvidia 2>/dev/null || true)"
[ "$RESOLVED" = "$OVR/nvidia.ko" ] || warn "modinfo resolves nvidia to '$RESOLVED' (expected $OVR/nvidia.ko)"

step "load keys + runtime environment"
cat > /etc/modprobe.d/barlink-p2p.conf <<'EOF'
# modded-p2p: keys consumed by the patched module. Unknown keys are ignored by
# the stock module, so a kernel update cannot make the machine unbootable.
options nvidia NVreg_RegistryDwords="BarlinkPeerBar1=1;RMPcieP2PType=1"
EOF
echo dmabuf_holder > /etc/modules-load.d/barlink-p2p.conf

# a non-GPU PCI device the dma-bufs are attached as (615-class drivers refuse
# a GPU as the attaching device)
HOLD_BDF=""
for d in /sys/bus/pci/devices/*; do
  cls="$(cat "$d/class" 2>/dev/null)" || continue
  ven="$(cat "$d/vendor" 2>/dev/null)" || continue
  [ "$ven" = "0x10de" ] && continue
  case "$cls" in 0x03*) continue ;; esac
  case "$cls" in 0x020000|0x010802) HOLD_BDF="$(basename "$d")"; break ;; esac
done
if [ -z "$HOLD_BDF" ]; then
  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    [ "$ven" = "0x10de" ] && continue
    case "$cls" in 0x03*) continue ;; esac
    HOLD_BDF="$(basename "$d")"; break
  done
fi
echo "$HOLD_BDF" > /etc/barlink-p2p.hold-bdf
echo "attach device: ${HOLD_BDF:-<none found>}"

cat > /etc/profile.d/barlink-p2p.sh <<EOF
# modded-p2p runtime environment (barlink-pcie direct path)
export BARLINK_BUILD_DIR="$BUILD"
export BARLINK_BAR1_NV_SOURCE="$BUILD/driver-$DRIVER_TAG"
export BARLINK_NVIDIA_KO="$BUILD/driver-$DRIVER_TAG/kernel-open/nvidia.ko"
[ -r /etc/barlink-p2p.hold-bdf ] && export BARLINK_BAR1_HOLD_BDF="\$(cat /etc/barlink-p2p.hold-bdf)"
[ -z "\${CUDA_HOME:-}" ] && [ -d /opt/cuda ] && export CUDA_HOME=/opt/cuda
true
EOF
chmod 644 /etc/profile.d/barlink-p2p.sh

cat > "$BASE/env" <<EOF
BASE=$BASE
BUILD=$BUILD
DRIVER_TAG=$DRIVER_TAG
DRIVER_DIR=$DRIVER_DIR
BARLINK_DIR=$BARLINK_DIR
OVERRIDE_DIR=$OVR
HOLD_BDF=$HOLD_BDF
EOF

if [ "$WITH_TORCH" = 1 ]; then
  step "Python environment for the optional checks (torch)"
  [ -x "$BARLINK_DIR/.venv/bin/python" ] || python3 -m venv "$BARLINK_DIR/.venv"
  "$BARLINK_DIR/.venv/bin/pip" install -q -e "$BARLINK_DIR"
  "$BARLINK_DIR/.venv/bin/pip" install -q nvidia-ml-py numpy
fi

# ---------------------------------------------------------------------------
# live activation
# ---------------------------------------------------------------------------
if [ "$ACTIVATE" = 1 ]; then
  step "activating now (display freezes for a few seconds)"
  stopped=""
  stop_service() {
    local s="$1"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$s" 2>/dev/null; then
      systemctl stop "$s" && stopped="$stopped systemd:$s" && return
    fi
    if command -v dinitctl >/dev/null 2>&1 && dinitctl status "$s" 2>/dev/null | grep -q started; then
      dinitctl stop "$s" >/dev/null && stopped="$stopped dinit:$s"
    fi
  }
  for s in gdm sddm lightdm greetd ly ly@tty1 display-manager; do stop_service "$s"; done
  pkill -TERM -f 'Hyprland|sway|kwin_wayland|gnome-shell|Xorg|startplasma|plasmashell' 2>/dev/null || true
  sleep 2
  pkill -TERM -f nvidia-persistenced 2>/dev/null || true
  if command -v dinitctl >/dev/null 2>&1 && dinitctl status nvidia-persistenced 2>/dev/null | grep -q started; then
    dinitctl stop nvidia-persistenced >/dev/null 2>&1 || true
  fi
  sleep 1

  for m in dmabuf_holder nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    rmmod "$m" 2>/dev/null && echo "rmmod $m ok"
  done
  sleep 1
  if lsmod | grep -qE '^nvidia'; then
    lsmod | grep nvidia
    die "modules still loaded -- a process holds /dev/nvidia*; close it and re-run, or reboot"
  fi

  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    case "$cls:$ven" in
      0x030000:0x10de|0x030200:0x10de) echo 1 > "$d/reset" 2>/dev/null || true ;;
    esac
  done
  sleep 2

  modprobe nvidia || { dmesg | tail -15; die "nvidia load failed"; }
  modprobe nvidia-uvm 2>/dev/null || warn "nvidia-uvm failed"
  modprobe dmabuf_holder 2>/dev/null || warn "dmabuf_holder failed"
  sleep 2

  loaded="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
  built="$(modinfo "$DRIVER_DIR/kernel-open/nvidia.ko" | awk '/^srcversion:/{print $2}')"
  echo "srcversion loaded=$loaded built=$built"
  [ "$loaded" = "$built" ] && echo "patched module is loaded" || warn "srcversion mismatch"
  grep -i '^RegistryDwords' /proc/driver/nvidia/params 2>/dev/null || warn "RegistryDwords empty"
  dmesg | grep BARLINK_PCIE | tail -4 || true

  # restart what was stopped
  for s in $stopped; do
    case "$s" in
      systemd:*) systemctl start "${s#systemd:}" 2>/dev/null || true ;;
      dinit:*)   dinitctl start "${s#dinit:}" 2>/dev/null || true ;;
    esac
  done
  if command -v dinitctl >/dev/null 2>&1; then dinitctl start nvidia-persistenced >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1; then systemctl start nvidia-persistenced 2>/dev/null || true; fi
fi

step "installed"
cat <<EOF
Persistent: every boot now loads the patched module from
  $OVR
  (stock module stays at /lib/modules/$KVER/kernel/..., untouched)
Verify now:     sudo bash $ROOT/scripts/verify.sh
Revert to stock: sudo bash $ROOT/scripts/revert.sh   (a reboot also does it)
After a kernel  upgrade: re-run this installer for the new kernel; until then
the machine boots the stock driver (safe).
EOF
