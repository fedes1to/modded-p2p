#!/usr/bin/env bash
# Undo nvidia-gpu-patches completely: remove the persistent override and all config,
# return to the stock driver. Works with systemd, OpenRC and dinit.
# Safe to run from a TTY if a boot went wrong.
#
#   sudo bash scripts/revert.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BASE="${BARLINK_BASE:-/opt/nvidia-gpu-patches}"
KVER="$(uname -r)"
OVR="/lib/modules/$KVER/updates/barlink-p2p"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

stopped=""
svc_active() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$1" 2>/dev/null; then echo systemd; return; fi
  if command -v dinitctl  >/dev/null 2>&1 && dinitctl status "$1" 2>/dev/null | grep -q started; then echo dinit; return; fi
  if command -v rc-service >/dev/null 2>&1 && rc-service "$1" status >/dev/null 2>&1; then echo openrc; return; fi
}
svc_stop() {
  local who; who="$(svc_active "$1")"; [ -n "$who" ] || return 1
  case "$who" in
    systemd) systemctl stop "$1" ;;
    dinit)   dinitctl stop "$1" >/dev/null ;;
    openrc)  rc-service "$1" stop ;;
  esac
  stopped="$stopped $who:$1"
}

step "stopping GPU users"
for s in gdm sddm lightdm greetd ly ly@tty1 display-manager nvidia-persistenced; do svc_stop "$s" || true; done
pkill -TERM -f 'Hyprland|sway|kwin_wayland|gnome-shell|Xorg|startplasma|plasmashell' 2>/dev/null || true
pkill -TERM -f nvidia-persistenced 2>/dev/null || true
sleep 2

step "unloading modules"
for m in dmabuf_holder nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
  rmmod "$m" 2>/dev/null && echo "rmmod $m ok"
done
if lsmod | grep -qE '^nvidia'; then
  warn "modules still loaded (a process holds /dev/nvidia*)."
  warn "The persistent override is removed anyway; reboot to finish."
else
  for d in /sys/bus/pci/devices/*; do
    cls="$(cat "$d/class" 2>/dev/null)" || continue
    ven="$(cat "$d/vendor" 2>/dev/null)" || continue
    case "$cls:$ven" in
      0x030000:0x10de|0x030200:0x10de) echo 1 > "$d/reset" 2>/dev/null || true ;;
    esac
  done
  sleep 2
fi

step "removing the persistent override and config"
rm -rf "$OVR"
rm -f /etc/modprobe.d/barlink-p2p.conf \
      /etc/modules-load.d/barlink-p2p.conf \
      /etc/dinit.d/barlink-holder \
      /etc/dinit.d/boot.d/barlink-holder \
      /etc/barlink-p2p.hold-bdf \
      /etc/barlink-p2p.env \
      /etc/profile.d/barlink-p2p.sh
[ -f /etc/conf.d/modules ] && sed -i '/dmabuf_holder/d' /etc/conf.d/modules 2>/dev/null || true
[ -f /etc/modules ] && sed -i '/^dmabuf_holder$/d' /etc/modules 2>/dev/null || true
depmod -a "$KVER"

if [ -x "$ROOT/scripts/revert-gpu-unlock.sh" ] &&
   { [ -e /usr/lib/firmware/gpu-unlock ] || compgen -G "/lib/modules/*/updates/gpu-unlock" >/dev/null; }; then
  step "removing the optional gpu-unlock component"
  "$ROOT/scripts/revert-gpu-unlock.sh" || warn "gpu-unlock cleanup reported a problem"
fi

step "restoring the stock driver"
RESOLVED="$(modinfo -n nvidia 2>/dev/null || true)"
echo "nvidia resolves to: $RESOLVED"
case "$RESOLVED" in
  *updates/barlink-p2p*) warn "still resolving to the override -- reboot to finish cleanup" ;;
esac
if ! lsmod | grep -qE '^nvidia'; then
  modprobe nvidia 2>/dev/null || warn "modprobe nvidia failed"
  modprobe nvidia-uvm 2>/dev/null || true
  modprobe nvidia-modeset 2>/dev/null || true
  modprobe nvidia-drm 2>/dev/null || true
fi

step "restarting services"
for s in $stopped; do
  case "$s" in
    systemd:*) systemctl start "${s#systemd:}" 2>/dev/null || true ;;
    dinit:*)   dinitctl start "${s#dinit:}" 2>/dev/null || true ;;
    openrc:*)  rc-service "${s#openrc:}" start 2>/dev/null || true ;;
  esac
done

step "done"
echo "nvidia-gpu-patches removed. Reboot for a completely clean state."
echo "The build tree at $BASE was left in place; delete it manually if you want:"
echo "  rm -rf $BASE"
