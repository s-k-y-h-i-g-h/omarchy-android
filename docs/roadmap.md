# Roadmap

What is proven, what is open, and the order to attack it.

## Proven (measured on SM-F926B, stock 5.4.274-qgki)

- The stock GKI kernel lacks `PID_NS`/`IPC_NS`/`CGROUP_DEVICE`/`DEVTMPFS` →
  plain chroot cannot run systemd. Droidspaces is the correct runtime.
- The GKI patch recipe is known (2 kABI patches + gki_defconfig block).
- `menci/archlinuxarm` + `omarchy-arm` fit: preflight passes, packages resolve
  (hyprland/sddm/waybar/foot/firefox in repos; mise/ags via AUR).
- A wlroots desktop (cage/labwc) nests under an X server and runs Wayland
  clients (foot).
- Hyprland does **not** nest (aquamarine allocator needs linux-dmabuf → DRI3,
  which no available X server provides). See findings.md.

## Open, in order

1. **Patched kernel + Droidspaces container with systemd.** Flash the patched
   kernel, create the Arch container, confirm `systemd` is PID 1 and
   `systemctl` works. This is the foundation; everything below assumes it.
2. **GPU access in the container.** Droidspaces has a hardware/GPU access
   switch. Determine what it exposes: a DRM render node? Turnip/VirGL? Test
   whether aquamarine's allocator works (gbm/dmabuf from the host GPU).
3. **Hyprland as root compositor.** With a render node, run Hyprland directly
   (not nested). If it starts, Omarchy's desktop is live.
4. **Display on the phone.** Android owns the panel. Options:
   - Droidspaces Termux:X11 switch (X11 output to an Android window).
   - Sunshine in the container → Moonlight on another device (streaming).
   - A DRM lease (`CONFIG_DRM_LEASES`) of the panel to the container — needs
     kernel support and Android cooperation; speculative.
5. **AUR packages.** `mise-bin`, `ufw-docker`, `xdg-terminal-exec` are
   load-bearing for Omarchy. Build on-device (slow) or pre-seed.

## The honest claim

"Omarchy on Android at native speed with full systemd" is achievable if step 3
lands (Hyprland as root compositor on a GPU the container can drive). The
nested-X fallback gives a working wlroots desktop, not Hyprland. The installer
tests all paths and reports which one lands, so the claim is verifiable, not
aspirational.

## Known-hard

- Adreno 650 is `kgsl` (proprietary, not DRM). Mainline freedreno on SM8350
  needs `CONFIG_DRM_MSM` + GMU firmware + a DSI panel driver for the Fold3
  panel (largely vendor code). This is the long pole for native GPU.
- KernelSU has no prebuilt 5.4 LKM; on 5.4 it must be built into the kernel.
- Kernel flashing is device-specific and manual. The installer does not flash.
