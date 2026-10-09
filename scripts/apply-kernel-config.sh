#!/usr/bin/env bash
# Merge the Droidspaces GKI block into a kernel tree's gki_defconfig.
# Usage: ./scripts/apply-kernel-config.sh /path/to/kernel [gki_defconfig|defconfig]
# Idempotent: skips options already present.
set -euo pipefail
TREE="${1:?kernel tree path required}"
BLOCK="$(dirname "$0")/../kernel/gki-droidspaces.config"
if [ -f "$TREE/arch/arm64/configs/gki_defconfig" ]; then
  DEF="$TREE/arch/arm64/configs/gki_defconfig"
elif [ -f "$TREE/arch/arm64/configs/defconfig" ]; then
  DEF="$TREE/arch/arm64/configs/defconfig"
else
  echo "no gki_defconfig or defconfig under $TREE/arch/arm64/configs" >&2; exit 1
fi
echo "target: $DEF"
added=0; present=0
while read -r line; do
  case "$line" in \#*|"") continue ;; esac
  opt="${line%%=*}"
  if grep -q "^${opt}=" "$DEF"; then
    present=$((present+1))
  elif grep -q "^# ${opt} is not set" "$DEF"; then
    sed -i "s|^# ${opt} is not set|${opt}=y|" "$DEF"; added=$((added+1))
  else
    printf '%s=y\n' "$opt" >> "$DEF"; added=$((added+1))
  fi
done < "$BLOCK"
echo "added=$added present=$present"
echo "Now apply the kABI patches (kernels <6.12) BEFORE building:"
echo "  001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
echo "  002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
