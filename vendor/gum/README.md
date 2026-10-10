# Vendored: gum 2.0.2 (Linux arm64)

Charm's shell front door: https://github.com/charmbracelet/gum — MIT.
Pinned to **2.0.2** (released 2026-09-24). Do not track `main`: Bubble Tea
v1→v2 was API-breaking, and gum's CLI follows it.

## Files

| File | What |
|---|---|
| `gum_2.0.2_Linux_arm64.tar.gz` | 4,543,876 B. Contains `gum` (static ELF64 aarch64, 13,500,576 B, ET_EXEC, no interpreter), `LICENSE`, `README.md`, `completions/`, `manpages/`. |
| `checksums.txt` | Upstream's published sha256 list for all 67 v2.0.2 assets. |
| `checksums.txt.sigstore.json` | Upstream's cosign bundle over `checksums.txt`. |
| `SHA256SUMS` | The single line for the tarball, extracted from `checksums.txt`. |
| `LICENSE` | Charmbracelet MIT text (identical to the LICENSE inside the tarball). |
| `VERSION` | Pin marker: `2.0.2`. |

## Why vendored

Blackout posture: gum is a single static Go binary with no network and no
telemetry, so `install.sh` can run with zero package-manager round-trips.
`ensure_gum()` in `install.sh` prefers a system gum (`pkg install gum` on
Termux, `pacman -S gum` inside the Arch Linux ARM container — both ship
2.0.2) and falls back to extracting this tarball.

## Verification

`install.sh` verifies with `sha256sum -c SHA256SUMS` before extracting.
For a stronger, offline-verifiable chain, verify upstream's signature over
`checksums.txt` with cosign (identity is Charm's shared goreleaser workflow,
not a per-repo one):

```bash
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity 'https://github.com/charmbracelet/meta/.github/workflows/goreleaser.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
# -> Verified OK
```

## Re-vendoring (bump procedure)

```bash
BASE=https://github.com/charmbracelet/gum/releases/download/v2.0.2
curl -sL -o gum_2.0.2_Linux_arm64.tar.gz $BASE/gum_2.0.2_Linux_arm64.tar.gz
curl -sL -o checksums.txt               $BASE/checksums.txt
curl -sL -o checksums.txt.sigstore.json $BASE/checksums.txt.sigstore.json
curl -sL -o LICENSE                     https://raw.githubusercontent.com/charmbracelet/gum/v2.0.2/LICENSE
grep 'gum_2.0.2_Linux_arm64.tar.gz$' checksums.txt | head -1 > SHA256SUMS
printf '2.0.2\n' > VERSION
sha256sum -c SHA256SUMS
```

## Known hazards

- Do **not** run gum under Windows Subsystem for Android:
  charmbracelet/gum#413 (open) — `SIGSYS` in `muesli/cancelreader`'s epoll
  reader (amd64 trace). Native Termux aarch64 is unaffected.
- On Termux, invoke spin as `gum spin --title X -- sh -c ./foo.sh`, not
  `-- ./foo.sh` (termux/termux-packages#18420, closed: precompiled binary +
  invocation form).
- `gum spin` allocates a pty (xpty) for the wrapped command.
- gum has **no determinate progress bar** in its CLI — spinner only.
