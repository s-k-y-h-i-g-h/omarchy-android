# Omarchy on Android

Omarchy (DHH's Hyprland-based Arch workflow) running on a rooted Android phone
at native speed, with systemd as PID 1.

Target device: Samsung Galaxy Z Fold3 (SM-F926B), Android 13, stock GKI kernel
`5.4.274-qgki`. The installer is device-agnostic for any rooted ARM64 phone
running a GKI kernel; the kernel work is device-specific.

**Status: the kernel and container path is proven. The Hyprland display path is
the open problem — see [docs/findings.md](docs/findings.md) for the measured
chain and the exact wall.**

## The stack

```
Android (rooted, patched GKI kernel)
  └─ Droidspaces            containers with real namespaces, systemd as PID 1
       └─ Arch Linux ARM    menci/archlinuxarm (Docker image, aarch64)
            └─ Omarchy      omarchy-arm (aarch64 port), Hyprland + Quickshell
                 └─ display  Hyprland on /dev/dri (GPU access) — the goal
```

Why each piece:

- **Droidspaces** gives the container its own PID/mount/UTS/IPC/cgroup/net
  namespaces on the phone kernel. This is what makes `systemd` work as PID 1 —
  the stock GKI kernel has `CONFIG_PID_NS`/`CONFIG_IPC_NS`/`CONFIG_FHANDLE`
  compiled out, so plain chroot cannot run systemd.
- **menci/archlinuxarm** is a daily-built multiarch aarch64 Arch image.
- **omarchy-arm** installs onto a *running* Arch ARM system (no ISO), which is
  the only shape that fits a container. Its preflight (`uname -m == aarch64`,
  `ID=archarm`, `pacman`, `sudo`, `bash 5`) is exactly a Droidspaces container.

## Install

Run from Termux on the phone (rooted, Magisk/KernelSU):

```bash
git clone https://github.com/s-k-y-h-i-g-h/omarchy-android.git
cd omarchy-android
./install.sh check          # audit kernel + device, report fatal gaps
./install.sh plan           # print the full plan, change nothing
./install.sh all            # container + seed + omarchy + display
```

Steps are idempotent and individually runnable: `check`, `container`, `seed`,
`omarchy`, `display`, `verify`.

Dependencies are auto-installed: `chroot-distro` (PyPI, GPL-3.0) is fetched via
`pip` on first run if missing. The seed step also disables pacman 7.x's
Landlock/seccomp download sandbox — the 5.4 GKI kernel has no Landlock, and
without this `pacman -Sy` fails with "restricting filesystem access failed".

## Kernel (the prerequisite)

The stock Fold3 kernel is missing the namespace primitives Droidspaces needs.
See [docs/kernel.md](docs/kernel.md) for the exact GKI patch set and defconfig
block. Summary:

- Apply the two kABI patches for kernels below 6.12 (the 5.4 kABI padding
  patches). Without them the device bootloops when `CONFIG_SYSVIPC`/`CONFIG_IPC_NS`
  are enabled.
- Edit `arch/arm64/configs/gki_defconfig` directly with the GKI-only block
  (no fragments — fragments break the kABI).
- Build, flash, then verify in the app: **Settings → Requirements → Check
  Requirements**.

Kernel flashing is a manual, device-specific step. The installer's `check`
step tells you exactly which symbols are missing and refuses to proceed on a
fatal gap.

## Display

Two paths, measured:

1. **Native DRM (the goal).** Inside a Droidspaces container with GPU access,
   Hyprland runs on `/dev/dri` directly. Requires the patched kernel + a GPU
   driver the container can use. On the Fold3 the GPU is Adreno via `kgsl`
   (proprietary, not DRM) — this is the hard part.
2. **Nested under X (fallback).** A wlroots compositor (cage/labwc) runs nested
   under an X server (Termux:X11). **Measured: cage/labwc nest fine and run
   Wayland clients. Hyprland does not nest** — its aquamarine allocator needs
   `linux-dmabuf-v1`, which needs DRI3 in the parent X server, which no
   available X server provides on this device. Details in
   [docs/findings.md](docs/findings.md).

## Credits

- [Droidspaces](https://www.droidspaces.org/) (GPLv3) — the container runtime.
- [omarchy-arm](https://github.com/alexisraitano-myffu/omarchy-arm) (MIT) — the aarch64 port.
- [Omarchy](https://omarchy.org/) by DHH / Basecamp.
- [menci/archlinuxarm](https://hub.docker.com/r/menci/archlinuxarm) — the base image.

MIT (this installer). The Omarchy copyright stays David Heinemeier Hansson's.
