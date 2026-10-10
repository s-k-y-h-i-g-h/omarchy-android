#!/usr/bin/env bash
# Smoke tests for the vendored Charm gum dependency (t_927d7174).
# Host-agnostic: runs on any POSIX shell with bash + coreutils.
#   bash tests/test-gum.sh
# Exit 0 = all pass. Prints PASS/FAIL per check.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass(){ printf 'PASS  %s\n' "$1"; }
fail(){ printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }

V=vendor/gum
TB=gum_2.0.2_Linux_arm64.tar.gz

# 1. installer parses
if bash -n install.sh; then pass "bash -n install.sh"; else fail "bash -n install.sh"; fi

# 2. vendored artifact set is complete
for f in "$TB" checksums.txt checksums.txt.sigstore.json SHA256SUMS LICENSE VERSION README.md; do
  [ -f "$V/$f" ] && pass "vendor/gum/$f present" || fail "vendor/gum/$f MISSING"
done

# 3. pin marker
[ "$(sed -n 1p "$V/VERSION")" = "2.0.2" ] && pass "pin = 2.0.2" || fail "pin != 2.0.2"

# 4. sha256 of the tarball matches upstream's published checksums.txt
if ( cd "$V" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
  pass "tarball sha256 matches SHA256SUMS"
else
  fail "tarball sha256 mismatch"
fi
if grep -q "  $TB\$" "$V/checksums.txt" && grep -q "$(sha256sum "$V/$TB" | cut -d' ' -f1)" "$V/checksums.txt"; then
  pass "tarball sha256 present in upstream checksums.txt"
else
  fail "tarball sha256 not in upstream checksums.txt"
fi

# 5. tarball contains a static ELF64 aarch64 gum binary
tmp=$(mktemp -d)
tar xzf "$V/$TB" -C "$tmp" 2>/dev/null
bin="$tmp/gum_2.0.2_Linux_arm64/gum"
if [ -f "$bin" ]; then
  hdr=$(od -An -tx1 -N16 "$bin" | tr -d ' \n')
  [ "$hdr" = "7f454c46020101000000000000000000" ] && pass "gum is ELF64" || fail "gum not ELF64 ($hdr)"
  # e_machine at offset 18..19, little-endian: 183 = AARCH64
  mach=$(od -An -j18 -N2 -tu2 "$bin" | tr -d ' ')
  [ "$mach" = "183" ] && pass "gum machine = AARCH64 (183)" || fail "gum machine = $mach (want 183)"
  # ET_EXEC (2) = static, no dynamic interpreter -> blackout-safe
  etype=$(od -An -j16 -N2 -tu2 "$bin" | tr -d ' ')
  [ "$etype" = "2" ] && pass "gum is static ET_EXEC (no interpreter)" || fail "gum e_type=$etype (want 2)"
  [ -f "$tmp/gum_2.0.2_Linux_arm64/LICENSE" ] && pass "tarball ships gum LICENSE" || fail "tarball LICENSE missing"
else
  fail "tarball has no gum binary at expected path"
fi
rm -rf "$tmp"

# 6. ensure_gum() resolves without a system gum: graceful plain-ANSI fallback
out=$(./install.sh plan --no-gum 2>&1)
case "$out" in
  *"gum disabled"*) pass "--no-gum forces plain-ANSI path" ;;
  *) fail "--no-gum did not report plain-ANSI path" ;;
esac

# 7. ensure_gum() reports availability status on a non-arm64 host and never
#    crashes the installer (it dies later at the root check, which is expected).
out=$(./install.sh plan 2>&1); rc=$?
case "$out" in
  *"gum 2.0.2 missing — auto-installing"*) pass "ensure_gum reports missing gum" ;;
  *"gum version"*|*"gum"*"installed"*) pass "ensure_gum reports gum availability" ;;
  *) fail "ensure_gum printed no availability line (rc=$rc)" ;;
esac
case "$out" in
  *"plain-ANSI output"*|*"Error: no su"*) pass "installer degrades gracefully off-device (rc=$rc)" ;;
  *) fail "installer did not degrade gracefully (rc=$rc)" ;;
esac

# 8. gum classes are actually usable: run the vendored binary.
#    Native arm64 host -> run directly. Otherwise use a linux/arm64 container
#    under qemu (binfmt), which is what the phone will do natively.
tmp="$PWD/.gumtest-tmp"; rm -rf "$tmp"; mkdir -p "$tmp"
tar xzf "$V/$TB" -C "$tmp" 2>/dev/null
bin="$tmp/gum_2.0.2_Linux_arm64/gum"
if [ "$(uname -m)" = aarch64 ] && [ -x "$bin" ]; then
  v=$("$bin" --version 2>/dev/null)
  case "$v" in *"2.0.2"*) pass "vendored gum executes natively: $v" ;; *) fail "vendored gum did not execute: $v" ;; esac
elif command -v docker >/dev/null; then
  v=$(docker run --rm --platform linux/arm64 -v "$tmp/gum_2.0.2_Linux_arm64:/g:ro" alpine:latest /g/gum --version 2>/dev/null)
  case "$v" in
    *"2.0.2"*)
      pass "vendored gum executes (arm64 container): $v"
      # the UI classes the installer will use.
      # NOTE: `gum log` writes to **stderr** (zap default) — capture 2>&1.
      ui=$(docker run --rm --platform linux/arm64 -v "$tmp/gum_2.0.2_Linux_arm64:/g:ro" alpine:latest \
            sh -c '/g/gum style --bold --foreground 39 "audit"; /g/gum log -l info "info line"; /g/gum log -l warn "warn line"; /g/gum spin --title working -- sh -c "echo spun"' 2>&1)
      for want in audit "info line" "warn line" spun; do
        case "$ui" in *"$want"*) : ;; *) fail "gum UI class missing: $want (got: $ui)" ;; esac
      done
      case "$ui" in *audit*"info line"*"warn line"*spun*) pass "gum style/log/spin all work" ;; *) fail "gum UI output order unexpected: $ui" ;; esac
      # non-TTY must stay ANSI-free (loggability requirement)
      piped=$(docker run --rm --platform linux/arm64 -v "$tmp/gum_2.0.2_Linux_arm64:/g:ro" alpine:latest \
               sh -c '/g/gum log -l info probe 2>&1 | cat -v')
      case "$piped" in
        *"$(printf '\033')"*) fail "gum emitted ANSI on a pipe" ;;
        *"INFO probe"*) pass "gum non-TTY output is ANSI-free" ;;
        *) fail "gum non-TTY output unexpected: $piped" ;;
      esac
      ;;
    *) fail "vendored gum did not execute in arm64 container: $v" ;;
  esac
else
  printf 'SKIP  vendored gum execution test (no arm64 runtime available)\n'
fi
rm -rf "$tmp"

echo
if (( fails )); then echo "$fails check(s) FAILED"; exit 1; fi
echo "all gum checks passed"
