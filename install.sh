#!/usr/bin/env bash
# Omarchy on Android installer.
# Runs on a rooted ARM64 Android phone from Termux.
# Steps: check | container | seed | omarchy | display | verify | all | plan
#
# Design notes:
#  - Every mutating command goes through run(); --dry-run/plan prints them
#    without executing, so the plan is honest (no second code path).
#  - check refuses to proceed on a fatal kernel gap.
#  - verify reports facts (is-active, version strings), not "should work".
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CONTAINER="${OA_CONTAINER:-archlinux}"
IMAGE="${OA_IMAGE:-docker.io/menci/archlinuxarm:base-devel}"
OMARCHY_REPO="${OA_OMARCHY_REPO:-https://github.com/alexisraitano-myffu/omarchy-arm.git}"
OMARCHY_BRANCH="${OA_OMARCHY_BRANCH:-arm64}"
OA_USER="${OA_USER:-omarchy}"
OA_UID="${OA_UID:-1001}"
DRY=0
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'

step(){ printf '\n%s==> %s%s\n' "$BLD$BLU" "$1" "$RST"; }
say(){ printf '    %s\n' "$1"; }
ok(){ printf '    %s%s%s\n' "$GRN" "$1" "$RST"; }
warn(){ printf '    %s%s%s\n' "$YLW" "$1" "$RST"; }
die(){ printf '\n%sError: %s%s\n' "$RED" "$1" "$RST" >&2; exit 1; }

run(){ if (( DRY )); then printf '    %s[plan]%s %s\n' "$YLW" "$RST" "${*@Q}"; else "$@"; fi; }

# chroot-distro is a pip package (PyPI: chroot-distro, GPL-3.0, stdlib-only).
# Auto-install it on a fresh phone: Termux 'pkg' for python/pip, then pip.
ensure_chroot_distro(){
  command -v chroot-distro >/dev/null && return 0
  warn "chroot-distro missing — auto-installing"
  command -v pkg >/dev/null && run pkg install -y python pip
  command -v pip >/dev/null || die "no pip available — install Termux 'python' package first"
  run pip install -U chroot-distro
  command -v chroot-distro >/dev/null || die "chroot-distro still missing after pip install"
  ok "chroot-distro $(chroot-distro -V 2>/dev/null | head -1) installed"
}

# Run a command inside the container. chroot-distro self-elevates on Termux
# (it invokes the root manager's su itself) — do NOT wrap it in `su -c`, which
# strips PATH and degrades its mount logic. `login -- CMD` runs an arbitrary
# command; `run` is for the image's entrypoint, so use login here.
in_ct(){ chroot-distro login "$CONTAINER" -- bash -c "$*" 2>&1; }

usage(){ cat <<USAGE
Usage: ./install.sh [options] <step>

Steps:
  check      Audit kernel + device against Droidspaces requirements.
  container  Create the Arch Linux ARM container (menci/archlinuxarm).
  seed       User, sudo, keyring, locale, pacman tweaks.
  omarchy    Clone omarchy-arm and run its install.sh.
  display    Test display paths (native DRM, nested X, headless) and report.
  verify     Report facts: systemd, sddm, hyprland, display.
  all        check -> container -> seed -> omarchy -> display -> verify
  plan       Print the full plan, change nothing.

Options:
  --dry-run  Same as plan for the chosen step.
  -y         No prompts.
USAGE
}

# ---------------------------------------------------------------- check
step_check(){
  step "Kernel + device audit"
  command -v su >/dev/null || die "no su — root required (Magisk/KernelSU)"
  local k; k=$(uname -r); say "kernel: $k"
  [ "$(uname -m)" = aarch64 ] || die "not aarch64: $(uname -m)"

  # Droidspaces fatal symbols (GKI set). Read /proc/config.gz.
  local cfg="$PREFIX/tmp/.oa_cfg"
  su -c "cat /proc/config.gz" 2>/dev/null | gunzip > "$cfg" 2>/dev/null \
    || su -c "zcat /proc/config.gz" > "$cfg" 2>/dev/null \
    || { warn "no /proc/config.gz — cannot audit kernel symbols"; return 0; }
  local fatal=0
  for c in CONFIG_PID_NS CONFIG_IPC_NS CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE \
           CONFIG_CGROUP_DEVICE CONFIG_DEVTMPFS CONFIG_NAMESPACES CONFIG_UTS_NS; do
    if grep -q "^$c=y" "$cfg"; then ok "$c present"
    else warn "$c MISSING (fatal)"; fatal=$((fatal+1)); fi
  done
  for c in CONFIG_CGROUP_PIDS CONFIG_FAIR_GROUP_SCHED CONFIG_TMPFS_POSIX_ACL \
           CONFIG_TMPFS_XATTR CONFIG_NF_TABLES CONFIG_USER_NS CONFIG_FHANDLE; do
    grep -q "^$c=y" "$cfg" && say "$c present" || warn "$c missing (degrades features)"
  done
  rm -f "$cfg"
  # Droidspaces installed?
  pm list packages 2>/dev/null | grep -q com.droidspaces.app \
    && ok "Droidspaces installed" || warn "Droidspaces not installed"
  # GPU
  su -c "ls /dev/dri/card0 /dev/dri/renderD128" >/dev/null 2>&1 \
    && ok "/dev/dri present (host)" || warn "no /dev/dri"
  su -c "ls /dev/kgsl-3d0" >/dev/null 2>&1 \
    && warn "Adreno kgsl present (proprietary, not DRM)"
  if (( fatal )); then
    die "$fatal fatal kernel symbol(s) missing. Patch the kernel first — see docs/kernel.md. Refusing to proceed."
  fi
  ok "kernel audit: no fatal gaps"
}

# ------------------------------------------------------------- container
step_container(){
  step "Container: $CONTAINER from $IMAGE"
  ensure_chroot_distro
  if chroot-distro list 2>/dev/null | grep -qw "$CONTAINER"; then
    ok "container '$CONTAINER' exists"; return 0
  fi
  # chroot-distro self-elevates; run it directly so its PATH/mount logic is intact.
  run chroot-distro install "$IMAGE" --name "$CONTAINER"
  ok "container created"
}

# ------------------------------------------------------------------ seed
step_seed(){
  step "Seed container"
  # pacman 7.x sandboxes downloads with Landlock/seccomp; the 5.4 GKI kernel has
  # no Landlock -> "restricting filesystem access failed". These are BARE global
  # options in [options] (no '= true' — pacman rejects valued forms).
  in_ct "sed -i '/^DisableSandbox/d' /etc/pacman.conf"
  in_ct "sed -i '/^\[options\]/a DisableSandboxFilesystem\nDisableSandboxSyscalls' /etc/pacman.conf"
  in_ct "sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf"
  in_ct "pacman -Sy --noconfirm"
  # keyring (menci image strips signing keys)
  in_ct "pacman -S --needed --noconfirm archlinuxarm-keyring"
  in_ct "pacman -S --needed --noconfirm sudo bash git base-devel"
  # user
  in_ct "id $OA_USER >/dev/null 2>&1 || useradd -m -u $OA_UID -s /bin/bash $OA_USER"
  in_ct "printf '$OA_USER ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/$OA_USER"
  in_ct "chmod 1777 /dev/shm"
  in_ct "locale-gen en_US.UTF-8 >/dev/null 2>&1 || true"
  ok "seeded (user=$OA_USER, sudo, keyring, shm)"
}

# --------------------------------------------------------------- omarchy
step_omarchy(){
  step "Omarchy (omarchy-arm, $OMARCHY_BRANCH)"
  in_ct "su $OA_USER -s /bin/bash -c 'cd ~ && [ -d omarchy-arm ] || git clone -b $OMARCHY_BRANCH $OMARCHY_REPO omarchy-arm'"
  in_ct "su $OA_USER -s /bin/bash -c 'cd ~/omarchy-arm && ./install.sh --dry-run'"
  warn "review the dry-run above, then run: ./install.sh omarchy --yes"
  (( DRY )) && return 0
  in_ct "su $OA_USER -s /bin/bash -c 'cd ~/omarchy-arm && ./install.sh --yes --profile generic-aarch64'"
  ok "omarchy installed"
}

# --------------------------------------------------------------- display
step_display(){
  step "Display paths (measured — see docs/findings.md)"
  in_ct "pacman -S --needed --noconfirm hyprland cage labwc foot mesa xorg-server-xvfb >/dev/null"
  in_ct "chmod 1777 /dev/shm"
  # Write the probe to Termux tmp, then copy into the container rootfs
  # (the container's /tmp is not Termux's /tmp).
  cat > "$PREFIX/tmp/oa_display.sh" <<'DISP'
#!/bin/bash
RT=/tmp/oa-rt; rm -rf $RT; mkdir -p -m 700 $RT
export XDG_RUNTIME_DIR=$RT LIBGL_ALWAYS_SOFTWARE=1 AQ_BACKEND=wayland
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 4
export DISPLAY=:99
echo "[1] native DRM (Hyprland on /dev/dri):"
if [ -e /dev/dri/renderD128 ]; then
  hyprland --i-am-really-stupid >/tmp/oa-drm.log 2>&1 & P=$!; sleep 8
  kill -0 $P 2>/dev/null && echo "    RUNNING on DRM" || { echo "    failed"; grep -iE "aquamarine|allocator|drm|fail" /tmp/oa-drm.log | head -4 | sed 's/^/      /'; kill $P 2>/dev/null; }
else echo "    no /dev/dri in container (enable GPU access in Droidspaces)"; fi
echo "[2] nested X (cage x11 -> Hyprland):"
WLR_BACKENDS=x11 cage -- sleep 600 >$RT/cage.log 2>&1 & CP=$!; sleep 6
S=$(ls -t $RT 2>/dev/null | grep -m1 '^wayland-[0-9]*$')
if [ -n "$S" ]; then
  WAYLAND_DISPLAY=$S hyprland --i-am-really-stupid >$RT/h.log 2>&1 & HP=$!; sleep 10
  kill -0 $HP 2>/dev/null && echo "    RUNNING nested" || { echo "    failed (expected: allocator needs linux-dmabuf/DRI3)"; kill $HP 2>/dev/null; }
  kill $CP 2>/dev/null
else echo "    cage did not start"; fi
echo "[3] headless Hyprland (software, for streaming):"
hyprland --i-am-really-stupid >/tmp/oa-hl.log 2>&1 & HP2=$!; sleep 8
kill -0 $HP2 2>/dev/null && echo "    RUNNING headless" || { echo "    failed"; grep -iE "aquamarine|allocator|no backend|fail" /tmp/oa-hl.log | head -4 | sed 's/^/      /'; kill $HP2 2>/dev/null; }
DISP
  # Storage layout on Termux: $PREFIX/var/lib/chroot-distro/containers/<name>/rootfs
  local rf="$PREFIX/var/lib/chroot-distro/containers/$CONTAINER/rootfs"
  su -c "cp $PREFIX/tmp/oa_display.sh $rf/tmp/oa_display.sh && chmod 755 $rf/tmp/oa_display.sh" >/dev/null
  in_ct "bash /tmp/oa_display.sh"
}

# ---------------------------------------------------------------- verify
step_verify(){
  step "Verify (facts)"
  in_ct "systemctl is-system-running 2>&1 | head -1" 2>/dev/null | sed 's/^/    systemd: /'
  in_ct "pacman -Q hyprland 2>&1" 2>/dev/null | sed 's/^/    /'
  in_ct "command -v hyprctl >/dev/null && hyprctl version 2>&1 | head -2 || echo 'hyprland: not running'" 2>/dev/null | sed 's/^/    /'
  in_ct "systemctl is-active sddm 2>&1" 2>/dev/null | sed 's/^/    sddm: /'
}

# ------------------------------------------------------------------ main
CMD="${1:-}"; shift || true
for a in "$@"; do case "$a" in --dry-run) DRY=1;; -y|--yes) ;; esac; done
case "$CMD" in
  check) step_check ;;
  container) step_container ;;
  seed) step_seed ;;
  omarchy) step_omarchy ;;
  display) step_display ;;
  verify) step_verify ;;
  plan) DRY=1; step_check; step_container; step_seed; step_omarchy; step_display; step_verify ;;
  all) step_check; step_container; step_seed; step_omarchy; step_display; step_verify ;;
  *) usage; exit 1 ;;
esac
