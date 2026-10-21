#!/usr/bin/env bash
# Remove the optional gpu-unlock component installed by
# scripts/install-gpu-unlock.sh:
#   - gpu_unlock.targets= from the boot mechanism in use
#   - the module override, firmware, licenses and initramfs drop-in
#   - the boot image is rebuilt without them
#
#   sudo bash scripts/revert-gpu-unlock.sh
#
# The build tree under /opt/modded-p2p is left in place (reinstall from it).
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BASE="${BARLINK_BASE:-/opt/modded-p2p}"
KVER="$(uname -r)"
FW="/usr/lib/firmware/gpu-unlock"

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; RC=1; }
RC=0

step "kernel command line"
if [ -x "$ROOT/scripts/gpu-unlock-cmdline.sh" ]; then
  bash "$ROOT/scripts/gpu-unlock-cmdline.sh" remove || warn "command-line cleanup reported a problem"
else
  warn "$ROOT/scripts/gpu-unlock-cmdline.sh missing; remove gpu_unlock.targets= by hand"
fi

step "removing module, firmware and licenses"
rm -rf /lib/modules/*/updates/gpu-unlock
depmod -a "$KVER"
rm -rf "$FW" \
       /usr/share/licenses/gpu-unlock \
       /usr/share/licenses/gpu-unlock-firmware \
       /usr/share/doc/gpu-unlock
rm -f /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf \
      /usr/share/initramfs-tools/modules.d/gpu-unlock.conf \
      /usr/lib/dracut/dracut.conf.d/gpu-unlock.conf
# our own config backups
rm -f /etc/default/grub.gpu-unlock.bak \
      /etc/default/limine.gpu-unlock.bak \
      /etc/kernel/cmdline.gpu-unlock.bak
for f in /boot/loader/entries/*.conf /boot/efi/loader/entries/*.conf /efi/loader/entries/*.conf \
         /boot/refind_linux.conf /boot/efi/refind_linux.conf /efi/refind_linux.conf \
         /etc/cmdline.d/*.conf; do
  rm -f "$f.gpu-unlock.bak"
done

step "rebuilding the boot image (this can take a minute)"
if compgen -G "/etc/mkinitcpio.d/*.preset" >/dev/null; then
  mkinitcpio -P
elif command -v dracut >/dev/null 2>&1 && [ -d /usr/lib/dracut ]; then
  dracut --force
elif command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k all
else
  warn "no initramfs generator found; rebuild the image yourself"
fi
if [ -f /etc/default/grub ]; then
  if command -v grub-mkconfig >/dev/null 2>&1; then
    CFG=""
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do [ -e "$c" ] && { CFG="$c"; break; }; done
    [ -n "$CFG" ] || CFG=/boot/grub/grub.cfg
    grub-mkconfig -o "$CFG" || warn "grub-mkconfig failed"
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub || warn "update-grub failed"
  fi
fi
if [ -f /etc/default/limine ] && command -v limine-update >/dev/null 2>&1; then
  limine-update || warn "limine-update failed"
fi

step "verification"
RESOLVED="$(modinfo -n gpu_unlock 2>/dev/null || true)"
if [ -z "$RESOLVED" ]; then
  ok "gpu_unlock no longer resolves"
else
  warn "gpu_unlock still resolves to $RESOLVED (another installation? remove it with your package manager)"
fi
if [ -e "$FW" ]; then fail "firmware directory still present: $FW"; else ok "firmware removed"; fi
for p in /etc/cmdline.d/*.conf /etc/kernel/cmdline /etc/default/grub /etc/default/limine \
         /boot/loader/entries/*.conf /boot/efi/loader/entries/*.conf /efi/loader/entries/*.conf; do
  [ -f "$p" ] || continue
  if grep -qs 'gpu_unlock\.targets=' "$p"; then fail "option still present in $p"; fi
done
[ "$RC" = 0 ] && ok "no gpu_unlock.targets= remains in the checked boot configuration"

step "done"
if [ "$RC" != 0 ]; then
  echo "FAIL -- see the lines above." >&2
  exit "$RC"
fi
cat <<EOF
gpu-unlock removed. If the current power cycle already ran the unlock, the
selector values stay until the card loses power; power off for a clean state.
The build tree at $BASE was left in place.
EOF
