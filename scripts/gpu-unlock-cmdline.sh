#!/usr/bin/env bash
# gpu_unlock does nothing unless the kernel command line carries
#   gpu_unlock.targets=all              or a comma-separated BDF list
# (gpu_unlock.targets=0000:01:00.0,0000:05:00.0).
#
# This helper adds, removes or shows that token on the boot mechanism the
# machine actually uses. It edits configuration only; the caller rebuilds the
# initramfs/UKI and the boot menu.
#
#   sudo bash scripts/gpu-unlock-cmdline.sh add --targets=all
#   sudo bash scripts/gpu-unlock-cmdline.sh add --targets=0000:01:00.0,0000:05:00.0
#   sudo bash scripts/gpu-unlock-cmdline.sh remove
#   sudo bash scripts/gpu-unlock-cmdline.sh show
#
# Mechanisms:
#   systemd-boot  loader entries with an options line, or linux entries
#   uki           auto-discovered UKI: the cmdline is embedded at image build
#                 time, so the token goes into the image's cmdline source
#                 (preset *_cmdline, /etc/kernel/cmdline, /etc/cmdline.d) and
#                 the image is rebuilt afterwards
#   grub          /etc/default/grub (GRUB_CMDLINE_LINUX_DEFAULT)
#   limine        /etc/default/limine (KERNEL_CMDLINE[default]+=)
#   refind        refind_linux.conf
#
# Options:
#   --targets=all|BDF[,BDF...]   value to add (default: all)
#   --mechanism=auto|systemd-boot|uki|grub|limine|refind
#   --root=DIR                   operate on another root (chroot/rescue/test)
#   --dry-run                    show the edits, change nothing
set -euo pipefail

ROOT="${GPU_UNLOCK_CMDLINE_ROOT:-/}"
MODE=""
TARGETS="all"
MECH="auto"
DRY=0

usage() { sed -n '2,29p' "$0"; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    add|remove|show)      MODE="$1" ;;
    --targets=*)          TARGETS="${1#*=}" ;;
    --mechanism=*)        MECH="${1#*=}" ;;
    --root=*)             ROOT="${1#*=}" ;;
    --dry-run)            DRY=1 ;;
    -h|--help)            usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
  shift
done

[ -n "$MODE" ] || { echo "usage: $0 {add|remove|show} [options]" >&2; exit 2; }
if [ "$ROOT" = / ] && [ "$(id -u)" != 0 ] && [ "$DRY" != 1 ] && [ "$MODE" != show ]; then
  echo "run as root (or pass --root=DIR / --dry-run): sudo bash $0 $MODE" >&2
  exit 1
fi
case "$TARGETS" in
  all|'') ;;
  *) printf '%s' "$TARGETS" | grep -qE '^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7](,[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])*$' \
       || { echo "invalid --targets (use all or 0000:01:00.0[,0000:05:00.0]): $TARGETS" >&2; exit 2; } ;;
esac
[ "$TARGETS" = all ] || [ -n "$TARGETS" ] || TARGETS=all

# Paths are relative to ROOT; R is "" for a real root.
R="${ROOT%/}"
rp() { printf '%s%s' "$R" "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

token() { printf 'gpu_unlock.targets=%s' "$TARGETS"; }

# Remove every gpu_unlock.targets= token from a string and squeeze spaces.
strip_tokens() {
  sed -E 's/(^|[[:space:]])gpu_unlock\.targets=[^[:space:]]*/\1/g' \
    | tr -s ' ' | sed -E 's/^ +//; s/ +$//'
}

# Replace FILE with TMP when the content differs; back up once, honour --dry-run.
apply_file() { # $1 = relative path, $2 = new content
  local f; f="$(rp "$1")"
  if cmp -s "$f" "$2"; then
    echo "unchanged: $1"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    echo "would edit: $1"
    diff -u "$f" "$2" || true
    return 0
  fi
  [ -e "$f.gpu-unlock.bak" ] || cp -a "$f" "$f.gpu-unlock.bak"
  cat "$2" > "$f"
  echo "edited: $1"
}

apply_new() { # $1 = relative path, $2 = content
  local f; f="$(rp "$1")"
  if [ -e "$f" ]; then
    apply_file "$1" "$2"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    echo "would create: $1"
    sed 's/^/    /' "$2"
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  cp "$2" "$f"
  echo "created: $1"
}

# --------------------------------------------------------------------------
# detection
# --------------------------------------------------------------------------
first_existing() { # relative paths; prints the first that exists
  local p
  for p in "$@"; do
    [ -e "$(rp "$p")" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

entries_dir() { first_existing /boot/loader/entries /boot/efi/loader/entries /efi/loader/entries; }

# Entries whose cmdline we can edit safely: an options line (kernel or UKI
# entry), or a linux entry without one. A bare "efi /EFI/Linux/..." entry is a
# UKI whose cmdline lives in the image; it is not edited here.
editable_entries() {
  local d f
  d="$(entries_dir)" || return 0
  for f in "$(rp "$d")"/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*options[[:space:]]' "$f" ||
       grep -qE '^[[:space:]]*linux[[:space:]]' "$f"; then
      printf '%s/%s\n' "${d%/}" "$(basename "$f")"
    fi
  done
}

preset_names() { # $1 = preset file; mkinitcpio's PRESETS=(...)
  local names
  names="$(sed -nE 's/^[[:space:]]*PRESETS=\((.*)\)[[:space:]]*$/\1/p' "$1" | tr -d "'\"" | tr ' ' '\n' | grep -v '^$')"
  [ -n "$names" ] || printf 'default\n'
  [ -n "$names" ] && printf '%s\n' "$names"
}

uki_detected() {
  local preset name key
  for preset in "$(rp /etc/mkinitcpio.d)"/*.preset; do
    [ -f "$preset" ] || continue
    for name in $(preset_names "$preset"); do
      for key in "${name}_uki" "${name}_efi_image"; do
        sed -nE "s/^[[:space:]]*${key}=(.+)$/\1/p" "$preset" | grep -q . && return 0
      done
    done
  done
  first_existing /boot/efi/EFI/Linux /efi/EFI/Linux /boot/EFI/Linux >/dev/null && return 0
  return 1
}

grub_detected() {
  [ -f "$(rp /etc/default/grub)" ] || return 1
  first_existing /boot/grub/grub.cfg /boot/grub2/grub.cfg >/dev/null && return 0
  command -v grub-mkconfig >/dev/null 2>&1 || command -v update-grub >/dev/null 2>&1
}

limine_detected() { [ -f "$(rp /etc/default/limine)" ]; }

refind_conf() { first_existing /boot/refind_linux.conf /boot/efi/refind_linux.conf /efi/refind_linux.conf; }
refind_detected() { refind_conf >/dev/null; }

choose_mechanism() {
  if [ -n "$(editable_entries)" ]; then echo systemd-boot; return 0; fi
  if uki_detected;                then echo uki;           return 0; fi
  if grub_detected;               then echo grub;          return 0; fi
  if limine_detected;             then echo limine;        return 0; fi
  if refind_detected;             then echo refind;        return 0; fi
  return 1
}

# --------------------------------------------------------------------------
# editors
# --------------------------------------------------------------------------
edit_entry() { # $1 = relative entry, $2 = add|remove
  local f; f="$(rp "$1")" out="$TMP/entry"
  if grep -qE '^[[:space:]]*options[[:space:]]' "$f"; then
    awk -v t="$(token)" -v op="$2" '
      /^[[:space:]]*options[[:space:]]/ {
        v = $0
        sub(/^[[:space:]]*options[[:space:]]+/, "", v)
        gsub(/(^|[[:space:]])gpu_unlock\.targets=[^[:space:]]*/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (op == "add") { v = (v != "" ? v " " : "") t }
        print "options " v
        next
      }
      { print }
    ' "$f" > "$out"
  elif [ "$2" = add ]; then
    { cat "$f"; printf 'options %s\n' "$(token)"; } > "$out"
  else
    cp "$f" "$out"
  fi
  apply_file "$1" "$out"
}

edit_grub() { # $1 = add|remove
  local f; f="$(rp /etc/default/grub)" out="$TMP/grub"
  awk -v t="$(token)" -v op="$1" '
    /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ {
      v = $0
      sub(/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      gsub(/(^|[[:space:]])gpu_unlock\.targets=[^[:space:]]*/, "", v)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (op == "add") v = (v != "" ? v " " : "") t
      print "GRUB_CMDLINE_LINUX_DEFAULT=\"" v "\""
      next
    }
    { print }
  ' "$f" > "$out"
  if [ "$1" = add ] && ! grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$(token)" >> "$out"
  fi
  apply_file /etc/default/grub "$out"
}

edit_limine() { # $1 = add|remove
  local f; f="$(rp /etc/default/limine)" out="$TMP/limine"
  awk '
    /gpu_unlock\.targets=/ {
      gsub(/[[:space:]]*gpu_unlock\.targets=[^"[:space:]]+/, "")
      if ($0 ~ /KERNEL_CMDLINE\[default\]\+="[[:space:]]*"$/) next
    }
    { print }
  ' "$f" > "$out"
  if [ "$1" = add ]; then
    printf 'KERNEL_CMDLINE[default]+=" %s"\n' "$(token)" >> "$out"
  fi
  apply_file /etc/default/limine "$out"
}

edit_refind() { # $1 = relative conf, $2 = add|remove
  local f; f="$(rp "$1")" out="$TMP/refind"
  awk -v t="$(token)" -v op="$2" '
    /^[[:space:]]*#/ || $0 !~ /^[[:space:]]*"/ { print; next }
    {
      line = $0
      gsub(/[[:space:]]*gpu_unlock\.targets=[^"[:space:]]*/, "", line)
      if (op == "add") {
        pos = 0
        for (i = length(line); i > 0; i--)
          if (substr(line, i, 1) == "\"") { pos = i; break }
        if (pos > 0) line = substr(line, 1, pos - 1) " " t substr(line, pos)
      }
      print line
    }
  ' "$f" > "$out"
  apply_file "$1" "$out"
}

# Where the embedded UKI cmdline comes from, following mkinitcpio's order:
# preset *_cmdline / ALL_cmdline, then /etc/kernel/cmdline, then /etc/cmdline.d.
uki_source() {
  local preset name key val
  for preset in "$(rp /etc/mkinitcpio.d)"/*.preset; do
    [ -f "$preset" ] || continue
    for name in $(preset_names "$preset"); do
      for key in "${name}_cmdline" ALL_cmdline; do
        val="$(sed -nE "s/^[[:space:]]*${key}=(.*)$/\1/p" "$preset" | head -n1)"
        [ -n "$val" ] || continue
        case "$val" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        [ -n "$val" ] || continue
        if [ -d "$(rp "$val")" ]; then printf 'dir %s\n' "$val"; else printf 'file %s\n' "$val"; fi
        return 0
      done
    done
  done
  if [ -f "$(rp /etc/kernel/cmdline)" ]; then
    printf 'file /etc/kernel/cmdline\n'; return 0
  fi
  if [ -d "$(rp /etc/cmdline.d)" ] && compgen -G "$(rp /etc/cmdline.d)/*.conf" >/dev/null; then
    printf 'dir /etc/cmdline.d\n'; return 0
  fi
  printf 'file /etc/kernel/cmdline\n'
}

edit_uki_file() { # $1 = relative file, $2 = add|remove
  local f; f="$(rp "$1")" out="$TMP/cmdline" body comments
  if [ ! -e "$f" ]; then
    # No source yet: the image would embed /proc/cmdline at build time. Pin
    # that cmdline plus the token so the rebuild is deterministic.
    body="$(cat "$(rp /proc/cmdline)" 2>/dev/null | strip_tokens || true)"
    if [ "$2" = remove ]; then
      echo "not present: $1"
      return 0
    fi
    {
      printf '%s\n' '# modded-p2p: gpu_unlock cmdline option (created by install-gpu-unlock.sh)'
      printf '%s %s\n' "$body" "$(token)" | sed -E 's/^ +//'
    } > "$out"
    apply_new "$1" "$out"
    return 0
  fi
  comments="$(grep -E '^[[:space:]]*#' "$f" || true)"
  body="$(grep -vE '^[[:space:]]*(#|$)' "$f" | tr '\n' ' ' | strip_tokens || true)"
  {
    printf '%s\n' "$comments" | grep -v 'modded-p2p: gpu_unlock' || true
    if [ "$2" = add ]; then
      printf '%s\n' '# modded-p2p: gpu_unlock cmdline option'
      printf '%s %s\n' "$body" "$(token)" | sed -E 's/^ +//'
    elif [ -n "$body" ]; then
      printf '%s\n' "$body"
    fi
  } > "$out"
  if [ "$2" = remove ] && [ -z "$body" ]; then
    if [ "$DRY" = 1 ]; then echo "would remove: $1"; else rm -f "$f"; echo "removed: $1"; fi
    return 0
  fi
  apply_file "$1" "$out"
}

edit_uki() { # $1 = add|remove
  local src kind path rel
  src="$(uki_source)"
  kind="${src%% *}"
  path="${src#* }"
  if [ "$kind" = dir ]; then
    rel="${path%/}/zz-gpu-unlock.conf"
    if [ "$1" = add ]; then
      printf '%s\n' "$(token)" > "$TMP/dropin"
      apply_new "$rel" "$TMP/dropin"
    else
      if [ -e "$(rp "$rel")" ]; then
        if [ "$DRY" = 1 ]; then echo "would remove: $rel"; else rm -f "$(rp "$rel")"; echo "removed: $rel"; fi
      else
        echo "not present: $rel"
      fi
    fi
  else
    edit_uki_file "$path" "$1"
  fi
}

# --------------------------------------------------------------------------
# modes
# --------------------------------------------------------------------------
show() {
  local d="" f="" m="" candidates=()
  echo "detected mechanisms:"
  d="$(entries_dir || true)"; [ -n "$d" ] && echo "  systemd-boot entries: $d"
  uki_detected && echo "  uki: $(uki_source)"
  grub_detected && echo "  grub: /etc/default/grub"
  limine_detected && echo "  limine: /etc/default/limine"
  f="$(refind_conf || true)"; [ -n "$f" ] && echo "  refind: $f"
  m="$(choose_mechanism || true)"
  echo "chosen mechanism: ${m:-none}"
  echo
  echo "gpu_unlock.targets occurrences:"
  if [ -n "$d" ]; then
    for f in "$(rp "$d")"/*.conf; do [ -e "$f" ] && candidates+=("${f#"$R"}"); done
  fi
  candidates+=(/etc/kernel/cmdline /etc/default/grub /etc/default/limine)
  if compgen -G "$(rp /etc/cmdline.d)/*.conf" >/dev/null; then
    for f in "$(rp /etc/cmdline.d)"/*.conf; do candidates+=("${f#"$R"}"); done
  fi
  f="$(refind_conf || true)"; [ -n "$f" ] && candidates+=("$f")
  local found=0 c
  for c in "${candidates[@]}"; do
    [ -f "$(rp "$c")" ] || continue
    if grep -nH 'gpu_unlock\.targets=' "$(rp "$c")" 2>/dev/null; then found=1; fi
  done
  [ "$found" = 1 ] || echo "  none"
}

remove_all() {
  local d="" f=""
  d="$(entries_dir || true)"
  if [ -n "$d" ]; then
    for f in "$(rp "$d")"/*.conf; do
      [ -f "$f" ] || continue
      edit_entry "${d%/}/$(basename "$f")" remove
    done
  fi
  uki_detected && edit_uki remove
  [ -f "$(rp /etc/default/grub)" ] && edit_grub remove
  limine_detected && edit_limine remove
  f="$(refind_conf || true)"; [ -n "$f" ] && edit_refind "$f" remove
  return 0
}

case "$MODE" in
  show)
    show
    ;;
  add|remove)
    m="$MECH"
    if [ "$m" = auto ]; then
      m="$(choose_mechanism || true)"
      [ -n "$m" ] || {
        echo "no supported boot configuration found (systemd-boot entries, UKI, GRUB, limine, rEFInd)" >&2
        exit 2
      }
    fi
    if [ "$MODE" = remove ]; then
      remove_all
      echo "MECHANISMS=$(choose_mechanism || true)"
    else
      case "$m" in
        systemd-boot)
          for f in $(editable_entries); do edit_entry "$f" add; done
          ;;
        uki)    edit_uki add ;;
        grub)   grub_detected || { echo "grub not in use" >&2; exit 2; }; edit_grub add ;;
        limine) limine_detected || { echo "limine not in use" >&2; exit 2; }; edit_limine add ;;
        refind) f="$(refind_conf)" || { echo "rEFInd not in use" >&2; exit 2; }; edit_refind "$f" add ;;
        *) echo "unknown --mechanism: $m" >&2; exit 2 ;;
      esac
      echo "MECHANISM=$m"
      case "$m" in
        uki) echo "REBUILD=uki" ;;
        grub) echo "REBUILD=grub" ;;
        limine) echo "REBUILD=limine" ;;
        *) echo "REBUILD=none" ;;
      esac
    fi
    ;;
esac
