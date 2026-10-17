#!/usr/bin/env bash
# Undo modded-p2p completely: remove the persistent override and return to the
# stock driver. Safe to run from a TTY if a boot went wrong.
#
#   sudo bash scripts/revert.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

BASE="${BARLINK_BASE:-/opt/modded-p2p}"
KVER="$(uname -r)"
OVR="/lib/modules/$KVER/updates/barlink-p2p"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

step "stopping GPU users"
stopped=""
for s in gdm sddm lightdm greetd ly ly@tty1 display-manager nvidia-persistenced; do
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$s" 2>/dev/null; then
    systemctl stop "$s" && stopped="$stopped systemd:$s" && continue
  fi
  if command -v dinitctl >/dev/null 2>&1 && dinitctl status "$s" 2>/dev/null | grep -q started; then
    dinitctl stop "$s" >/dev/null && stopped="$stopped dinit:$s"
  fi
done
pkill -TERM -f 'Hyprland|sway|kwin_wayland|gnome-shell|Xorg|startplasma|plasmashell' 2>/dev/null || true
pkill -TERM -f nvidia-persistenced 2>/dev/null || true
sleep 2

step "unloading modules"
for m in dmabuf_holder nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
  rmmod "$m" 2>/dev/null && echo "rmmod $m ok"
done
if lsmod | grep -qE '^nvidia'; then
  warn "modules still loaded (a process holds /dev/nvidia*)."
  warn "Persistent override will be removed anyway; reboot to finish."
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

step "removing the persistent override"
rm -rf "$OVR"
rm -f /etc/modprobe.d/barlink-p2p.conf /etc/modules-load.d/barlink-p2p.conf \
      /etc/barlink-p2p.hold-bdf /etc/profile.d/barlink-p2p.sh \
      /etc/barlink-p2p.env
depmod -a "$KVER"

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
  esac
done

step "done"
echo "modded-p2p removed. Reboot for a completely clean state."
echo "The build tree at $BASE was left in place; delete it manually if you want:"
echo "  rm -rf $BASE"
