# Findings: the display problem, measured

All results below are from live runs on the SM-F926B (stock `5.4.274-qgki`)
inside the `archlinuxarm` chroot. Versions: hyprland 0.56.2-4, cage 0.3.1-1,
labwc 0.20.2-1 (wlroots 0.20.2), weston 15.0.1-3, foot 1.28.0-2, mesa 26.2.4.

## What works

- **X server in the container.** Xvfb starts, socket `/tmp/.X11-unix/X99`
  appears. Termux:X11 (`com.termux.x11`) is installed on the phone as the
  Android-side X server.
- **cage nests under X.** `WLR_BACKENDS=x11 cage` starts, creates a Wayland
  socket (`wayland-0`), maps x11-pointer/x11-touch, runs a Wayland session.
  Needs `XDG_RUNTIME_DIR` set and `/dev/shm` world-writable (the chroot mounts
  `/dev/shm` `mode=755` root-owned; `chmod 1777 /dev/shm` fixes it).
- **Wayland clients run under cage.** `foot` connects to cage's session
  (it warns "compositor does not implement XDG activation / fractional
  scaling / server-side cursors" — expected for cage — and runs).
- **labwc nests under X** the same way (wlroots 0.20.2, +xwayland).

So a wlroots desktop (cage/labwc) under an X server is a working path.

## What fails: Hyprland nested

Hyprland's compositor is **aquamarine** (0.6.8), not wlroots. Nested under
cage/labwc/weston it aborts:

```
ERR from aquamarine ]: Wayland backend cannot start: Missing protocols
ERR from aquamarine ]: Requested backend (wayland) could not start, enabling fallbacks
CRIT from aquamarine ]: Cannot open backend: no allocator available
CRIT ]: m_pAqBackend couldn't start! ... running on a Wayland session, NOT an X11 one.
terminate called ... what():  CBackend::create() failed!
```

Two distinct walls, both measured:

### Wall 1 — no `linux-dmabuf-v1` (the allocator)

`wayland-info` under cage lists the protocols cage advertises. It has
`wl_shm` v2, `wl_compositor` v6, `zwlr_export_dmabuf_manager_v1` — **no
`linux-dmabuf-v1`**. Aquamarine's allocator needs dmabuf; with only shm it
reports "no allocator available".

Why cage has no dmabuf: cage's x11 backend logs

```
X11 does not support DRI3 extension
Creating pixman renderer
```

wlroots advertises `linux-dmabuf-v1` from its X11 backend only when the parent
X server provides **DRI3**. No X server available here provides DRI3:

- Xvfb: no DRI3 (no `+dri3` option; extensions are GLX + RENDER only).
- Xephyr `-glamor`: glamor present, but cage still reports "X11 does not
  support DRI3" — Xephyr does not advertise the DRI3 extension.
- Termux:X11: pixman-based, no DRI3.

### Wall 2 — `wl_compositor` version too high

Under weston (x11 backend), Hyprland fails earlier:

```
wl_registry#2: error 0: invalid version for global wl_compositor (1):
expected at most 5, got 6
```

weston 15 advertises `wl_compositor` v6; Hyprland 0.56.2 binds at most v5.
Version negotiation fails. (cage also advertises v6; Hyprland's failure under
cage is the allocator, which it hits first.)

weston's own allocator also fails on this device:

```
warning: failed to query rendering device from EGL
failed to initialize allocator
EGL Wayland extension: no
```

Mesa EGL in the container reports `EGL Wayland extension: no` — weston's
allocator needs `EGL_EXT_platform_wayland` at runtime.

## Conclusion for the display

- **Hyprland does not nest on this device.** Its aquamarine allocator requires
  `linux-dmabuf-v1`, which requires DRI3 in the parent X server, which no
  available X server provides. This is a hard wall for the nested path.
- **cage / labwc do nest and run Wayland clients.** A wlroots desktop under
  Termux:X11 is a working fallback — it is not Hyprland, so it is not Omarchy.
- **The real path is native DRM.** Hyprland on `/dev/dri` inside a Droidspaces
  container with GPU access. That needs (a) the patched kernel (see
  kernel.md) and (b) a GPU the container can drive. The Fold3 GPU is Adreno
  via `kgsl` (proprietary, not DRM). Droidspaces advertises Turnip-on-Adreno
  and VirGL (Vulkan/GL inside a container) — not a DRM master. Mainline
  freedreno on SM8350 needs `CONFIG_DRM_MSM` + GMU firmware + a DSI panel
  driver for the Fold3 panel (largely vendor code).

## Open questions to resolve on the patched kernel + Droidspaces

1. Does Droidspaces' GPU-access switch expose a DRM render node the container
   can use for Hyprland's allocator (gbm/dmabuf via the host GPU)?
2. Does Turnip/VirGL give aquamarine a working allocator (dmabuf from the
   host GPU) so Hyprland starts headless and streams?
3. If Hyprland runs headless (software), does `WLR_RENDERER=pixman`-style
   software rendering let aquamarine's shm allocator work when Hyprland is
   the *root* compositor (not nested)? (Aquamarine's headless backend needs a
   GBM device; software GBM via `swrast`/`kms_swrast` is the test.)

The installer's `display` step tests these in order and reports which one
lands.
