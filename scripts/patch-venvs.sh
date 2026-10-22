#!/usr/bin/env bash
# Apply the framework-side patches to the vLLM and sglang venvs.
#
#   bash scripts/patch-venvs.sh                     # auto-detect both venvs
#   bash scripts/patch-venvs.sh ~/venv-vllm ~/venv-sglang
#   bash scripts/patch-venvs.sh --vllm-only [VENV]
#   bash scripts/patch-venvs.sh --sglang-only [VENV]
#   bash scripts/patch-venvs.sh --check             # report, change nothing
#
# What it patches:
#   every venv: the barlink-pcie tree it imports gets the four barlink patches
#               (platform fixes, inference-mode, capture gate, baton-marker
#               state; see docs/DETAILS.md). Editable installs are patched in
#               place; a non-editable barlink is reported, not patched.
#   vLLM venv:  vllm/distributed/device_communicators/custom_all_reduce.py gets
#               patches/vllm-custom-allreduce-p2p-<version>.patch, which
#               re-enables vLLM's P2P custom all-reduce on >2 PCIe-only GPUs.
#
# No root needed: the files live in the user's home. When run with sudo the
# script re-runs itself as $SUDO_USER so the patched files stay user-owned.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$SUDO_USER" -- "$0" "$@"
  fi
  echo "warning: runuser missing; patching as root -- venv files will be root-owned" >&2
fi

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
ok()   { printf 'ok:      %s\n' "$*"; }

VLLM_ONLY=0
SGLANG_ONLY=0
CHECK=0
POS=()
for arg in "$@"; do
  case "$arg" in
    --vllm-only)   VLLM_ONLY=1 ;;
    --sglang-only) SGLANG_ONLY=1 ;;
    --check)       CHECK=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *)  POS+=("$arg") ;;
  esac
done
[ "$VLLM_ONLY" = 1 ] && [ "$SGLANG_ONLY" = 1 ] && die "--vllm-only and --sglang-only are exclusive"

# ---------------------------------------------------------------------------
# apply one patch to a tree root, idempotently (git or plain patch)
# ---------------------------------------------------------------------------
apply_patch_root() {  # $1 = root, $2 = patch file, $3 = label
  local root="$1" pf="$2" label="$3" name
  name="$(basename "$pf")"
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$root" apply --check "$pf" >/dev/null 2>&1; then
      [ "$CHECK" = 1 ] && { ok "$label: would apply $name"; return 0; }
      git -C "$root" apply "$pf" || die "$label: $name failed to apply"
      ok "$label: applied $name"
    elif git -C "$root" apply --reverse --check "$pf" >/dev/null 2>&1; then
      ok "$label: already applied $name"
    else
      die "$label: $name does not apply in $root (upstream changed?)"
    fi
  else
    if patch --dry-run -p1 --fuzz=0 -d "$root" -i "$pf" >/dev/null 2>&1; then
      [ "$CHECK" = 1 ] && { ok "$label: would apply $name"; return 0; }
      patch -p1 --fuzz=0 -d "$root" -i "$pf" >/dev/null || die "$label: $name failed to apply"
      ok "$label: applied $name"
    elif patch --dry-run -p1 -R -d "$root" -i "$pf" >/dev/null 2>&1; then
      ok "$label: already applied $name"
    else
      die "$label: $name does not apply in $root (upstream changed?)"
    fi
  fi
}

barlink_root() {  # $1 = venv -> echoes the barlink-pcie tree root
  local venv="$1" pkg d
  # find_spec, not import: barlink's __init__ pulls in torch/CUDA.
  pkg="$("$venv/bin/python" -c 'import importlib.util, os; s = importlib.util.find_spec("barlink"); print(os.path.realpath(s.origin))' 2>/dev/null)" || return 1
  d="$(dirname "$pkg")"
  while [ "$d" != "/" ]; do
    if [ -d "$d/src/barlink" ]; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

patch_barlink() {  # $1 = venv, $2 = label
  local venv="$1" label="$2" root
  if ! root="$(barlink_root "$venv")"; then
    warn "$label: barlink is not importable as an editable install -- pip install -e <barlink-pcie> first"
    return 0
  fi
  step "$label: barlink-pcie at $root"
  apply_patch_root "$root" "$ROOT/patches/barlink-platform-fixes.patch"     "$label"
  apply_patch_root "$root" "$ROOT/patches/barlink-inference-mode.patch"     "$label"
  apply_patch_root "$root" "$ROOT/patches/barlink-capture-gate.patch"       "$label"
  apply_patch_root "$root" "$ROOT/patches/barlink-baton-marker-state.patch" "$label"
}

patch_vllm_allreduce() {  # $1 = venv
  local venv="$1" ver site target pf=""
  ver="$("$venv/bin/python" -c 'import importlib.metadata as m; print(m.version("vllm"))' 2>/dev/null)" || {
    warn "vllm: distribution not found in $venv -- skipping the custom all-reduce patch"; return 0; }
  site="$("$venv/bin/python" -c 'import importlib.util, os; s = importlib.util.find_spec("vllm"); print(os.path.dirname(os.path.dirname(os.path.realpath(s.origin))))' 2>/dev/null)" || {
    warn "vllm: cannot locate site-packages in $venv -- skipping"; return 0; }
  target="$site/vllm/distributed/device_communicators/custom_all_reduce.py"
  [ -f "$target" ] || { warn "vllm $ver: custom_all_reduce.py not at $target -- skipping"; return 0; }

  if [ -f "$ROOT/patches/vllm-custom-allreduce-p2p-$ver.patch" ]; then
    pf="$ROOT/patches/vllm-custom-allreduce-p2p-$ver.patch"
  else
    for c in "$ROOT"/patches/vllm-custom-allreduce-p2p-*.patch; do
      [ -f "$c" ] && { pf="$c"; break; }
    done
    [ -n "$pf" ] || die "no vllm-custom-allreduce-p2p patch in $ROOT/patches"
    warn "vllm $ver: no exact-version port; trying $(basename "$pf") (the context check decides)"
  fi
  step "vllm $ver: custom all-reduce P2P"
  apply_patch_root "$site" "$pf" "vllm $ver"
}

# ---------------------------------------------------------------------------
# resolve the venvs
# ---------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  UHOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  UHOME="$HOME"
fi

find_venv() {  # $1 = module name (vllm|sglang) -> echoes a venv path
  local mod="$1" c
  for c in "$UHOME/venv-$mod" "$UHOME/venv"; do
    [ -x "$c/bin/python" ] || continue
    "$c/bin/python" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$mod') else 1)" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  for c in /home/*/venv-"$mod"; do
    [ -x "$c/bin/python" ] || continue
    "$c/bin/python" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$mod') else 1)" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

VLLM_VENV=""
SGLANG_VENV=""
if [ "$VLLM_ONLY" = 1 ]; then
  VLLM_VENV="${POS[0]:-}"
elif [ "$SGLANG_ONLY" = 1 ]; then
  SGLANG_VENV="${POS[0]:-}"
else
  VLLM_VENV="${POS[0]:-}"
  SGLANG_VENV="${POS[1]:-}"
fi

if [ -n "$VLLM_VENV" ]; then
  [ -x "$VLLM_VENV/bin/python" ] || die "vllm venv has no bin/python: $VLLM_VENV"
else
  VLLM_VENV="$(find_venv vllm || true)"
fi
if [ -n "$SGLANG_VENV" ]; then
  [ -x "$SGLANG_VENV/bin/python" ] || die "sglang venv has no bin/python: $SGLANG_VENV"
else
  SGLANG_VENV="$(find_venv sglang || true)"
fi

[ -n "$VLLM_VENV" ] || [ "$SGLANG_ONLY" = 1 ] || warn "no vLLM venv found (pass one as an argument)"
[ -n "$SGLANG_VENV" ] || [ "$VLLM_ONLY" = 1 ] || warn "no sglang venv found (pass one as an argument)"
[ -n "$VLLM_VENV$SGLANG_VENV" ] || die "nothing to patch; pass the venv paths"

# ---------------------------------------------------------------------------
if [ -n "$VLLM_VENV" ]; then
  patch_barlink "$VLLM_VENV" "vllm ($VLLM_VENV)"
  patch_vllm_allreduce "$VLLM_VENV"
fi
if [ -n "$SGLANG_VENV" ]; then
  patch_barlink "$SGLANG_VENV" "sglang ($SGLANG_VENV)"
fi

step "done"
[ "$CHECK" = 1 ] && echo "  --check: nothing was written."
echo "  Restart any running vLLM/sglang server to pick up the patches."
