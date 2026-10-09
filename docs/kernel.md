# Kernel configuration

Droidspaces needs kernel namespace primitives. The stock Samsung GKI kernel
(compiled out) and the GKI kABI rules make this the hardest part of the project.

## Device baseline (measured on SM-F926B)

```
uname -r: 5.4.274-qgki-30958977-abF926BXXSFJYK1
```

Requirement audit against Droidspaces' GKI list (from `/proc/config.gz`):

| Symbol | Stock kernel | Droidspaces impact if missing |
|---|---|---|
| `CONFIG_NAMESPACES` | y | Fatal |
| `CONFIG_UTS_NS` | y | Fatal |
| `CONFIG_NET_NS` | y | NAT/None modes unavailable |
| `CONFIG_SECCOMP` / `_FILTER` | y | Seccomp shield disabled |
| `CONFIG_CGROUPS` | y | Fatal |
| `CONFIG_MEMCG` | y | `--memory` skipped |
| `CONFIG_CGROUP_SCHED` | y | — |
| `CONFIG_CGROUP_FREEZER` | y | — |
| `CONFIG_OVERLAY_FS` | y | Volatile mode unavailable |
| `CONFIG_VETH` / `CONFIG_BRIDGE` | y | NAT mode unavailable |
| `CONFIG_NF_NAT` | y | NAT mode unavailable |
| `CONFIG_PID_NS` | **not set** | **Fatal. Containers cannot start.** |
| `CONFIG_IPC_NS` | **not set** | **Fatal. Containers cannot start.** |
| `CONFIG_SYSVIPC` | **not set** | Fatal (IPC) |
| `CONFIG_POSIX_MQUEUE` | **not set** | Fatal (IPC) |
| `CONFIG_CGROUP_DEVICE` | **not set** | **Fatal. Containers cannot start.** |
| `CONFIG_CGROUP_PIDS` | **not set** | `--pids-limit` skipped |
| `CONFIG_FAIR_GROUP_SCHED` | **not set** | CPU limits |
| `CONFIG_DEVTMPFS` | **not set** | **Fatal. Cannot set up `/dev`.** |
| `CONFIG_TMPFS_POSIX_ACL` / `_XATTR` | **not set** | NixOS/xattr |
| `CONFIG_NF_TABLES` | **not set** | nftables (Docker/Podman) |
| `CONFIG_USER_NS` | **not set** | Docker unsafe-procfs |
| `CONFIG_FHANDLE` | **not set** | systemd `--user` (ENOPROTOOPT) |
| `CONFIG_DRM_MSM` | **not set** | freedreno (mainline Adreno) |
| `CONFIG_DRM_FBDEV_EMULATION` | **not set** | fbdev fallback |
| `CONFIG_FB` | **not set** | legacy framebuffer |

The host has `/dev/dri/card0` and `/dev/dri/renderD128` (Android owns them;
SELinux-restricted). The GPU is Adreno 650 via `kgsl` (`/dev/kgsl-3d0`),
proprietary, **not DRM** — Hyprland cannot composite on it.

## GKI kernel path (5.4, 5.10, 5.15, 6.1, 6.6)

GKI enforces strict kABI. Enabling `CONFIG_SYSVIPC`/`CONFIG_IPC_NS`/
`CONFIG_POSIX_MQUEUE` shifts offsets in `task_struct`; vendor GPU/camera
modules then crash or the device bootloops. Droidspaces ships kABI-friendly
patches that enable these options without shifting offsets.

### Step 1 — mandatory kABI patches (below 6.12)

From `assets/resources/kernel-patches/GKI/below-kernel-6.12/`:

1. `001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch`
2. `002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch`
   (required for 5.4/5.10 — this is the Fold3's case)

```bash
patch -p1 < 001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch
patch -p1 < 002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch
```

### Step 2 — edit `gki_defconfig` directly

Edit `arch/arm64/configs/gki_defconfig`. **Do not use fragments** on GKI —
fragments break the kABI. Apply the GKI-only block:

```
# IPC
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
# Namespaces
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
# HW access
CONFIG_DEVTMPFS=y
# Networking (enhanced NAT)
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
# --- optional, recommended ---
CONFIG_USER_NS=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
# UFW
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
# fail2ban
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
# tmpfs xattr / posix acl (NixOS)
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y
```

The block above is the *GKI* block. The legacy (non-GKI) block is larger
(OverlayFS, VETH/BRIDGE, full netfilter, IPv6 NAT, `CONFIG_ANDROID_PARANOID_NETWORK=n`)
— on GKI those are already present in the stock config, so only the block above
is needed.

### Step 3 — build and flash

Device-specific. For the Fold3 (SM-F926B) the kernel source tree is
`himekifee/glide-kernel-F926` (GPL-2.0, branch `CVIG`) — a legacy Samsung tree.
A GKI 5.4 tree with the kABI patches is the target; the exact tree depends on
the ROM. Flash via fastboot (`fastboot flash boot ...`) or KernelSU LKM patching.

KernelSU v3.3.0 ships prebuilt LKMs for 5.10/5.15/6.1/6.6/6.12/6.18 — **no
5.4 LKM**. On 5.4, KernelSU must be built into the kernel (GKI build), not
patched as a LKM.

### Step 4 — verify

In the Droidspaces app: **Settings → Requirements → Check Requirements**.
This runs the full `droidspaces check` suite and names every missing symbol.

## Root

Root is required (Magisk or KernelSU). KernelSU v3.3.0 is current.
