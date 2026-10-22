#!/usr/bin/env bash
# Optional GA102/GA104 pre-driver unlock (Zagitta/gpu-unlock).
#
#   sudo bash scripts/install-gpu-unlock.sh                    # detect the cards
#   sudo bash scripts/install-gpu-unlock.sh --targets=all
#   sudo bash scripts/install-gpu-unlock.sh --targets=0000:01:00.0,0000:05:00.0
#   sudo bash scripts/install-gpu-unlock.sh --no-cmdline       # install, print the cmdline
#
# What it does:
#   1. clones Zagitta/gpu-unlock at a pinned commit into the build tree
#   2. generates the pinned 610.43.03 firmware (checked SHA-256 downloads)
#   3. builds gpu_unlock.ko against the running kernel
#   4. installs the module, firmware, licenses and the initramfs drop-in
#   5. adds gpu_unlock.targets= to the boot mechanism in use (systemd-boot
#      entries, UKI, GRUB, limine, rEFInd) and rebuilds the boot image
#   6. verifies the module, the firmware and the embedded cmdline
#
# The module runs from the initramfs before nvidia binds. It applies to
# GA102/GA104 GeForce/CMP cards only. Upstream verified an RTX 3090; the
# RTX 3080 20 GB board is the same GA102 silicon and is accepted by ID, but
# has no upstream report. The unlock takes effect on the next cold power-on.
#
# Arguments:
#   --targets=all|BDF[,BDF...]   default: the GA102/GA104 cards found
#   --no-cmdline                 do not edit boot configuration
#   --mechanism=auto|systemd-boot|uki|grub|limine|refind
#   --commit=SHA                 override the pinned upstream commit
#   --src=DIR                    use an existing checkout (not managed)
#   --dry-run                    build and show the plan, change nothing
#   --check                      only report whether a GA102/GA104 card is
#                                present (exit 0 = yes, 3 = no); install.sh uses
#                                this to enable the unlock automatically
#
# Environment: GPU_UNLOCK_POWER_FIX=auto|0|1 overrides the kernel < 6.16
# power-state patch (auto = apply below 6.16).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BASE="${BARLINK_BASE:-/opt/nvidia-gpu-patches}"
BUILD="$BASE/build"
SRC="$BUILD/gpu-unlock"
CACHE="$BASE/gpu-unlock-cache"
INPUTS="$CACHE/inputs"
ASSETS="$CACHE/assets"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
OVR="/lib/modules/$KVER/updates/gpu-unlock"
FW="/usr/lib/firmware/gpu-unlock/610.43.03"
REPO="${GPU_UNLOCK_REPO:-https://github.com/Zagitta/gpu-unlock}"
PIN="${GPU_UNLOCK_COMMIT:-1799023e1d16dd1e58a7fc85823579fe93281e1a}"
POWER_FIX="${GPU_UNLOCK_POWER_FIX:-auto}"

TARGETS=""
NO_CMDLINE=0
MECH=auto
DRY=0
CHECK=0
SRC_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --targets=*)   TARGETS="${arg#*=}" ;;
    --no-cmdline)  NO_CMDLINE=1 ;;
    --mechanism=*) MECH="${arg#*=}" ;;
    --commit=*)    PIN="${arg#*=}" ;;
    --src=*)       SRC_OVERRIDE="${arg#*=}" ;;
    --dry-run)     DRY=1 ;;
    --check)       CHECK=1 ;;
    -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" != 0 ] && [ "$DRY" != 1 ] && [ "$CHECK" != 1 ]; then
  echo "run as root: sudo bash $0 (--check and --dry-run work unprivileged)" >&2
  exit 1
fi

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; RC=1; }
RC=0

step "prerequisites"
for c in git make gcc python3 depmod modprobe; do
  command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
done
[ -e "$KDIR" ] || die "kernel headers missing at $KDIR (install your distro's linux-headers package)"
python3 -c 'import compression.zstd' 2>/dev/null ||
  die "python3 with zstd tar support (3.14+) is required for the 610.43.03 firmware generator"
echo "kernel $KVER | compiler $(gcc -dumpversion) | python $(python3 -c 'import platform;print(platform.python_version())')"

mkdir -p "$BASE" "$BUILD" "$CACHE"

step "upstream source @ $PIN"
if [ -n "$SRC_OVERRIDE" ]; then
  SRC="$SRC_OVERRIDE"
  [ -f "$SRC/kernel/gpu_unlock/main.c" ] || die "$SRC is not a gpu-unlock checkout"
  echo "using $SRC"
else
  if [ ! -d "$SRC/.git" ]; then
    [ -e "$SRC" ] && die "$SRC exists and is not a git checkout; move it away"
    git clone -q "$REPO" "$SRC"
  fi
  git -C "$SRC" remote get-url origin >/dev/null 2>&1 || die "$SRC has no origin"
  git -C "$SRC" fetch -q origin || warn "fetch failed; using the local objects"
  git -C "$SRC" reset --hard -q "$PIN" 2>/dev/null ||
    git -C "$SRC" checkout -q --detach "$PIN"
  HEAD_SHA="$(git -C "$SRC" rev-parse HEAD)"
  [ "$HEAD_SHA" = "$PIN" ] || die "checkout is $HEAD_SHA, expected $PIN"
  echo "checkout $SRC at $HEAD_SHA"
fi

step "supported cards"
mapfile -t IDS < <(awk '/supported_ids\[\] = \{/,/\};/' "$SRC/kernel/gpu_unlock/main.c" |
  grep -oE '0x[0-9a-fA-F]{4}' | tr 'A-F' 'a-f' | sort -u)
[ "${#IDS[@]}" -gt 0 ] || die "could not read supported_ids[] from $SRC/kernel/gpu_unlock/main.c"
CARDS=()
OTHER=0
for d in /sys/bus/pci/devices/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
  cls="$(cat "$d/class" 2>/dev/null)" || continue
  case "$cls" in 0x03*) ;; *) continue ;; esac
  dev="$(cat "$d/device" 2>/dev/null | tr 'A-F' 'a-f')"
  if printf '%s\n' "${IDS[@]}" | grep -qx "$dev"; then
    CARDS+=("$(basename "$d")")
    sub="$(cat "$d/subsystem_device" 2>/dev/null || true)"
    echo "  $(basename "$d")  ${dev/0x/10de:}  subsystem ${sub:-?}"
  else
    OTHER=$((OTHER + 1))
  fi
done
if [ "${#CARDS[@]}" -eq 0 ]; then
  if [ "$CHECK" = 1 ]; then
    echo "unsupported: no GA102/GA104 card"
    exit 3
  fi
  die "no GA102/GA104 card found. gpu-unlock targets GA102/GA104 GeForce/CMP only; professional and data-centre parts are excluded by device ID."
fi
[ "$OTHER" -gt 0 ] && warn "$OTHER other NVIDIA GPU function(s) are not GA102/GA104 and will be ignored"
if [ -z "$TARGETS" ]; then
  TARGETS="$(printf '%s\n' "${CARDS[@]}" | paste -sd, -)"
fi
[ "$TARGETS" = all ] || printf '%s' "$TARGETS" | grep -qE '^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7](,[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])*$' ||
  die "invalid targets: $TARGETS"
echo "targets: $TARGETS"
if [ "$CHECK" = 1 ]; then
  echo "supported: ${CARDS[*]}"
  exit 0
fi
echo "note: upstream verified an RTX 3090; a 20 GB RTX 3080 is GA102 with a different"
echo "      memory/board configuration and is accepted by device ID, but untested upstream."

step "firmware inputs (pinned 610.43.03, SHA-256 checked)"
make -C "$SRC" INPUTS="$INPUTS" ASSETS="$ASSETS" inputs
step "firmware generation"
make -C "$SRC" INPUTS="$INPUTS" ASSETS="$ASSETS" firmware
for f in booter_load_ga102.bin gsp_ga10x.bin gsp_boot_ga102.bin gsp_boot_desc_ga102.bin v67-ga102-610.43.03.bin; do
  [ -s "$ASSETS/$f" ] || die "missing generated asset: $ASSETS/$f"
done

step "kernel power-state compatibility"
major="$(uname -r | cut -d. -f1)"; minor="$(uname -r | cut -d. -f2)"
need_fix=0
[ "$POWER_FIX" = 1 ] && need_fix=1
if [ "$POWER_FIX" = auto ] && { [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 16 ]; }; }; then
  need_fix=1
fi
if [ "$need_fix" = 1 ]; then
  P="$ROOT/patches/gpu-unlock-kernel-power-state.patch"
  if git -C "$SRC" apply --reverse --check "$P" >/dev/null 2>&1; then
    echo "power-state fix already applied"
  elif git -C "$SRC" apply --check "$P" >/dev/null 2>&1; then
    git -C "$SRC" apply "$P"
    echo "applied kernel < 6.16 power-state fix ($(basename "$P"))"
  else
    warn "power-state patch does not apply; building upstream code"
  fi
else
  echo "not needed on $KVER (kernels >= 6.16 sync the PCI power state themselves)"
fi

step "kernel module"
make -C "$SRC/kernel/gpu_unlock" KDIR="$KDIR" -s
KO="$SRC/kernel/gpu_unlock/gpu_unlock.ko"
[ -s "$KO" ] || die "module build produced no gpu_unlock.ko"
echo "built $KO ($(stat -c %s "$KO") bytes)"

step "install plan"
CMDLINE_PLAN="gpu_unlock.targets=$TARGETS via ${MECH}"
[ "$NO_CMDLINE" = 1 ] && CMDLINE_PLAN="not edited (--no-cmdline)"
cat <<EOF
  module    $KO -> $OVR/gpu_unlock.ko
  firmware  $ASSETS -> /usr/lib/firmware/gpu-unlock/610.43.03/
  licenses  /usr/share/licenses/gpu-unlock{,-firmware}/
  initramfs drop-in for the detected generator
  cmdline   $CMDLINE_PLAN
EOF

if [ "$DRY" = 1 ]; then
  step "dry run: stopping before system changes"
  if [ "$NO_CMDLINE" = 0 ]; then
    bash "$ROOT/scripts/gpu-unlock-cmdline.sh" add --targets="$TARGETS" --mechanism="$MECH" --dry-run || true
  fi
  exit 0
fi

step "installing module + firmware"
install -Dm644 "$KO" "$OVR/gpu_unlock.ko"
depmod -a "$KVER"
RESOLVED="$(modinfo -n gpu_unlock 2>/dev/null || true)"
[ "$RESOLVED" = "$OVR/gpu_unlock.ko" ] || warn "modinfo resolves gpu_unlock to '$RESOLVED' (expected $OVR/gpu_unlock.ko)"
make -C "$SRC" ASSETS="$ASSETS" DESTDIR= install-firmware
make -C "$SRC" DESTDIR= PKG=gpu-unlock install-licenses

step "initramfs integration"
if compgen -G "/etc/mkinitcpio.d/*.preset" >/dev/null; then
  GEN=mkinitcpio
  make -C "$SRC" DESTDIR= install-mkinitcpio
  [ -f /etc/mkinitcpio.conf.d/zz-gpu-unlock.conf ] || die "mkinitcpio drop-in missing"
elif command -v dracut >/dev/null 2>&1 && [ -d /usr/lib/dracut ]; then
  GEN=dracut
  make -C "$SRC" DESTDIR= install-dracut
elif command -v update-initramfs >/dev/null 2>&1; then
  GEN=initramfs-tools
  make -C "$SRC" DESTDIR= install-initramfs-tools
else
  die "no supported initramfs generator (mkinitcpio, dracut, initramfs-tools)"
fi
echo "generator: $GEN"

step "kernel command line"
CMDLINE_OUT=""
if [ "$NO_CMDLINE" = 0 ]; then
  CMDLINE_OUT="$(bash "$ROOT/scripts/gpu-unlock-cmdline.sh" add --targets="$TARGETS" --mechanism="$MECH")" ||
    die "could not add gpu_unlock.targets= to the boot configuration"
  printf '%s\n' "$CMDLINE_OUT"
  MECH_USED="$(printf '%s\n' "$CMDLINE_OUT" | sed -n 's/^MECHANISM=//p' | tail -1)"
else
  MECH_USED=""
  cat <<EOF
not edited (--no-cmdline). Add this where your bootloader keeps its command line:
  gpu_unlock.targets=$TARGETS
EOF
fi

step "rebuilding the boot image (this can take a minute)"
case "$GEN" in
  mkinitcpio)      mkinitcpio -P ;;
  dracut)          dracut --force ;;
  initramfs-tools) update-initramfs -u -k all ;;
esac
if grep -qs 'gpu_unlock\.targets=' /etc/default/grub; then
  if command -v grub-mkconfig >/dev/null 2>&1; then
    CFG=""
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do [ -e "$c" ] && { CFG="$c"; break; }; done
    [ -n "$CFG" ] || CFG=/boot/grub/grub.cfg
    grub-mkconfig -o "$CFG"
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub
  else
    warn "GRUB configured but neither grub-mkconfig nor update-grub is available"
  fi
fi
if [ -f /etc/default/limine ] && grep -qs 'gpu_unlock\.targets=' /etc/default/limine; then
  command -v limine-update >/dev/null 2>&1 && limine-update || warn "limine configured but limine-update is missing"
fi

step "verification"
for f in booter_load_ga102.bin gsp_ga10x.bin gsp_boot_ga102.bin gsp_boot_desc_ga102.bin v67-ga102-610.43.03.bin; do
  [ -s "$FW/$f" ] && ok "firmware $f" || fail "firmware missing: $FW/$f"
done
for f in $(modinfo -F firmware gpu_unlock 2>/dev/null); do
  [ -e "/usr/lib/firmware/$f" ] || fail "modinfo firmware missing: /usr/lib/firmware/$f"
done
[ "$(modinfo -n gpu_unlock 2>/dev/null || true)" = "$OVR/gpu_unlock.ko" ] &&
  ok "module resolves to the override" || fail "modinfo does not resolve gpu_unlock to $OVR/gpu_unlock.ko"

find_images() {
  local p name k v printed=0
  for p in /etc/mkinitcpio.d/*.preset; do
    [ -f "$p" ] || continue
    for name in $(sed -nE 's/^[[:space:]]*PRESETS=\((.*)\)[[:space:]]*$/\1/p' "$p" | tr -d "'\"" | tr ' ' '\n' | grep -v '^$'); do
      for k in "${name}_uki" "${name}_efi_image" "${name}_image"; do
        v="$(sed -nE "s/^[[:space:]]*${k}=(.*)$/\1/p" "$p" | head -n1 | tr -d '"')"
        [ -n "$v" ] && { printf '%s\n' "$v"; printed=1; }
      done
    done
  done
  # No mkinitcpio presets (dracut / initramfs-tools): use the conventional names.
  [ "$printed" = 1 ] || printf '%s\n' "/boot/initramfs-$KVER.img" "/boot/initramfs-linux.img" "/boot/initramfs-linux-zen.img"
}
IMAGES=()
while read -r img; do
  [ -n "$img" ] && [ -e "$img" ] && IMAGES+=("$img")
done < <(find_images | awk '!seen[$0]++')

if [ "${#IMAGES[@]}" -eq 0 ]; then
  warn "no boot image found to inspect"
else
  LIST=""
  if command -v lsinitcpio >/dev/null 2>&1; then LIST="lsinitcpio"
  elif command -v lsinitrd >/dev/null 2>&1; then LIST="lsinitrd"
  elif command -v lsinitramfs >/dev/null 2>&1; then LIST="lsinitramfs"
  fi
  [ -n "$LIST" ] || warn "no initramfs listing tool; the image was not inspected"
  for img in "${IMAGES[@]}"; do
    [ -n "$LIST" ] || break
    if ! LISTING="$($LIST "$img" 2>/dev/null)"; then
      warn "cannot list $img"
      continue
    fi
    if printf '%s\n' "$LISTING" | grep -q 'gpu_unlock\.ko'; then
      ok "gpu_unlock.ko in $img"
    else
      fail "gpu_unlock.ko not in $img"
    fi
    if printf '%s\n' "$LISTING" | grep -q 'gpu-unlock/610\.43\.03/'; then
      ok "firmware in $img"
    else
      fail "gpu-unlock firmware not in $img"
    fi
  done
fi

# The token must be visible to the mechanism that was edited.
has_token() { # files
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -qs "gpu_unlock.targets=$TARGETS" "$f" && return 0
  done
  return 1
}
has_token_in_entries() {
  local d
  for d in /boot/loader/entries /boot/efi/loader/entries /efi/loader/entries; do
    [ -d "$d" ] || continue
    grep -qs "gpu_unlock.targets=$TARGETS" "$d"/*.conf && return 0
  done
  return 1
}

case "${MECH_USED:-}" in
  uki)
    CTMP="$(mktemp)"
    for img in "${IMAGES[@]}"; do
      case "$img" in *.efi) ;; *) continue ;; esac
      if command -v objcopy >/dev/null 2>&1; then
        objcopy -O binary --only-section=.cmdline "$img" "$CTMP" 2>/dev/null || true
        if tr -d '\0' < "$CTMP" | grep -q "gpu_unlock.targets=$TARGETS"; then
          ok "embedded cmdline in $(basename "$img")"
        else
          fail "gpu_unlock.targets= is not embedded in $(basename "$img")"
        fi
      else
        warn "objcopy missing; cannot inspect the embedded cmdline"
      fi
    done
    rm -f "$CTMP"
    ;;
  systemd-boot)
    has_token_in_entries && ok "loader entry carries gpu_unlock.targets=" ||
      fail "loader entries do not carry the option"
    ;;
  grub)
    has_token /boot/grub/grub.cfg /boot/grub2/grub.cfg && ok "grub.cfg carries gpu_unlock.targets=" ||
      fail "grub.cfg does not carry the option"
    ;;
  limine)
    has_token /boot/limine.conf /etc/default/limine && ok "limine configuration carries gpu_unlock.targets=" ||
      fail "limine configuration does not carry the option"
    ;;
  refind)
    has_token /boot/refind_linux.conf /boot/efi/refind_linux.conf /efi/refind_linux.conf &&
      ok "refind_linux.conf carries gpu_unlock.targets=" || fail "refind_linux.conf does not carry the option"
    ;;
esac

step "result"
if [ "$RC" != 0 ]; then
  echo "FAIL -- see the lines above." >&2
  exit "$RC"
fi
cat <<EOF
PASS -- installed.

The unlock runs from the initramfs, before nvidia binds. Upstream's supported
path is a cold boot; kernels >= 6.16 also ran it after a warm reboot here (7.2.11).
After the boot:
  dmesg | grep gpu_unlock        (root; or journalctl -k -b with journald)
  lspci -nnk -d 10de:2206

Disable:  sudo bash scripts/gpu-unlock-cmdline.sh remove && mkinitcpio -P  (or your generator)
Remove:   sudo bash scripts/revert-gpu-unlock.sh
EOF
