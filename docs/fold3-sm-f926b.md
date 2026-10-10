# Fold3 (SM-F926B) field notes: every wall hit, measured

Device: Samsung Galaxy Z Fold3, SM-F926B, Android 13 (F926BXXSFJYK1),
Magisk 31.0, custom kernel `5.4.274-qgki-30958977-abF926BXXSFJYK1`
(built from the Samsung q2q tree with Clang 10.0 + Android 4.9 GCC).
Container: Droidspaces `omarchy-android` (Arch ARM rootfs, systemd as PID 1).

All findings below are from live runs on this device. Each entry: symptom →
root cause → fix (or current status).

---

## 1. Stock kernel cannot run containers

`CONFIG_PID_NS`, `CONFIG_IPC_NS`, `CONFIG_CGROUP_DEVICE`, `CONFIG_DEVTMPFS`,
`CONFIG_FHANDLE`, `CONFIG_SYSVIPC`, `CONFIG_POSIX_MQUEUE` are compiled out of
the stock kernel. Droidspaces containers cannot start at all. See
[kernel.md](kernel.md) for the full audit and the kABI patch set.

**Fix applied:** rebuilt the stock `q2q_kor_singlex` tree with the namespace
block enabled + the two 5.4 kABI padding patches. `vermagic` kept byte-exact
against stock (`5.4.274-qgki-30958977-abF926BXXSFJYK1`) so all 101 stock
vendor `.ko` modules load unchanged. Verified: all vendor modules load,
container namespaces exist.

## 2. Flashing: Odin rejects the image, `dd` oflag fails

- Odin with a repacked `boot.img` in AP: **"md5 error! binary is invalid"** —
  Samsung firmware packages are md5-manifested; a repacked image fails the
  manifest check. Don't fight it.
- `adb reboot bootloader` on this device **does not enter fastboot** — it
  reboots to Android with the unlocked-bootloader warning. Fastboot on the
  Fold3 is only reachable from download-mode/recovery paths; treat fastboot
  as unavailable.
- BusyBox `dd` on the phone rejects `oflag=sync` (**`dd: bad oflag=sync`**).

**Fix applied:** flash via `dd` as root:

```bash
su -c 'dd if=/data/local/tmp/boot_patched.img of=/dev/block/by-name/boot bs=4M conv=fsync; sync'
```

Keep the stock boot dump (`boot`, `vendor_boot`, `dtbo`) — recovery is
`dd` back.

## 3. "Service provider update — restart required" popup after every reboot

Symptom: modal popup on every boot, CSC/carrier integrity check failing
because the install is modified (unlocked + rooted).

**Root cause:** `com.samsung.android.cidmanager` (carrier update service) +
`com.samsung.sec.android.application.csc` (the popup UI).

**Fix applied:**

```bash
pm disable-user --user 0 com.samsung.sec.android.application.csc
pm disable-user --user 0 com.samsung.android.cidmanager
```

Reversible with `pm enable <pkg>`. Popup gone.

## 4. Spontaneous reboots every ~10–20 minutes (forced fsck)

Symptom: phone reboots by itself; `ro.boot.bootreason=reboot`, no panic,
pstore empty. Dropbox entry: `SYSTEM_FSCK@…` with
`cache has been mounted 31 times without being checked, check forced.`

**Root cause:** `fs_mgr` forces a filesystem check when ext4 mount-count
reaches the superblock threshold; the check requires a reboot. Measured:
`cache` 31/31, `persist` 27/27, `efs` 39/39.

**Fix applied** (Magisk `post-fs-data.sh`, runs every boot):

```sh
for p in cache persist efs; do
  dev=/dev/block/bootdevice/by-name/$p
  [ -b "$dev" ] && /system/bin/tune2fs -C 0 -c 0 -i 0 "$dev" >/dev/null 2>&1
done
```

Note: Samsung's boot-time `e2fsck`/`fs_stat` **rewrites the superblock
defaults** (`max=31`, `interval=6mo`) on `cache` specifically, after
post-fs-data. `persist`/`efs` hold the fix. Re-zeroing every boot keeps
the count below threshold permanently.

## 5. Spontaneous reboots, second source: softdog watchdog

`/proc/cmdline` carries `softdog.soft_margin=100 softdog.soft_panic=1`.
A CPU storm (e.g. a container init crash-looping: console full of
`sh-5.3# sh-5.3# …`, load average 30 at 2-min uptime) starves the
watchdog petter → panic → reboot. `wb_reason=0xE02` in cmdline.

**Fix applied** (same `post-fs-data.sh`): magic-close the watchdog:

```sh
echo V > /dev/watchdog
echo V > /dev/watchdog0
```

`V` is the magic-close; softdog is built-in and re-arms at boot, so this
must run every boot. After this, CPU storms no longer reboot the phone.

## 6. THE WALL: Samsung DEFEX LSM blocks containers (and reboots on exec)

Symptom A: systemd in the container fails at
`Failed to mount API filesystems` / `Protocol driver not attached`
(`ENOPROTOOPT`) on `mount -t proc` / `cgroup2` / `tmpfs`.
SELinux permissive (`setenforce 0`) does **not** help. `noseccomp` does
**not** help.

Symptom B: **exec'ing Arch binaries from a chroot reboots the phone within
seconds.**

**Root cause (source-verified in the q2q tree):**
`security/samsung/defex_lsm` — `CONFIG_SECURITY_DEFEX=y`, built-in (bool,
no `rmmod`), rules compiled in (`defex_packed_rules.inc`), signed. Its
catch list includes `__DEFEX_mount`, `__DEFEX_clone`, `__DEFEX_umount`,
`__DEFEX_execve`. The syscall filter (`defex_syscall_enter` in
`arch/arm64/kernel/syscall.c`) denies `mount()` from non-Android domains
with `ENOPROTOOPT`. Exec-integrity violations go
`defex_report_violation` → **DSMS** (`dsms_policy.c` maps exactly that) →
`dsmsd` → **reboot**. One LSM explains both symptoms.

Notes:
- `DEFEX_DEPENDING_ON_OEMUNLOCK` is **not compiled in** (no "Device is
  unlocked and DEFEX will be disabled" in dmesg despite
  `androidboot.verifiedbootstate=orange` in the live cmdline) — DEFEX
  enforces unconditionally on this build. Unlock state does not save you.
- SELinux permissive is irrelevant: DEFEX is a separate LSM
  (`CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor"`
  plus Samsung's own hook registration).
- PROCA (`CONFIG_PROCA=y`) runs alongside and spams
  `file path /system/bin/init and cert app name … doesn't match` — noise,
  not the blocker.

**Fix (verified safe, build in progress):** rebuild with
`CONFIG_SECURITY_DEFEX=n`.
- All core-kernel call sites (`fs/exec.c`, `fs/open.c`, `fs/read_write.c`,
  `kernel/sys.c`, `arch/arm64/kernel/syscall.c`) are `#ifdef
  CONFIG_SECURITY_DEFEX` guarded.
- **No vendor `.ko` references DEFEX symbols** (checked all 101 modules in
  `/vendor/lib/modules` for `task_defex_enforce`, `defex_syscall_enter`,
  `defex_get_features`, `defex_report_violation`) — kABI/CRCs stay intact.
- `dsms_policy.c` resolves DEFEX hooks via kallsyms at runtime; with DEFEX
  absent the lookup fails gracefully.

## 7. droidspaces CLI quirks (v-current on device)

- `droidspaces run <cmd>` returns **255** for script paths and complex
  quoting through `adb shell → su`. Don't use it for tests.
- `droidspaces enter` requires an interactive TTY; `enter -c` also refuses
  through `adb shell` even with `-tt`.
- Working pattern for one-shot commands: `su -c "droidspaces --name=X run
  /bin/sh -c '…'"` with **single-quoted, quoting-light** payloads.
- `--init=/bin/sh start` keeps a broken container alive for debugging;
  remember to `stop` it — a crash-looping init is a CPU storm (see §5).

## 8. Windows → phone script transfer: CRLF

Scripts written on Windows and pushed with `adb push` carry `\r\n`.
`#!/bin/sh\r` → "invalid interpreter" → silent 255. Always strip:

```bash
tr -d '\r' < /data/local/tmp/x.sh > /path/x.sh && chmod 755 /path/x.sh
```

## 9. chroot into the Arch rootfs: PATH inheritance

`chroot /mnt/rtest /usr/bin/sh` inherits Android's PATH
(`/product/bin:/apex/…:/system/bin`), so Arch's `mkdir`/`mount`/`ls` are
"command not found". Use a clean env:

```bash
chroot /mnt/rtest /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/root /usr/bin/sh /tmp/t.sh
```

Rootfs is an image: `mount -o loop …/rootfs.img /mnt/rtest` (mkdir first;
`su -c` heredocs eat `$p` — write scripts locally, push, strip CR).

## 10. Wireless ADB: the port rotates constantly

Samsung rotates the wireless-debugging port on every reboot **and** on
session drops. `adb connect` to a stale port hangs, then the device shows
`offline`. USB is stable (`RFCR90FY2TB`); prefer USB for long sessions.
For wireless, re-read the port from Developer options each time.

## 11. Build environment notes (WSL Arch)

- Toolchain: `Toolchains_for_Snapdragon` (Clang 10.0 +
  `aarch64-linux-android-4.9`), `LLVM=1`, `LLVM_IAS=1`,
  `CC_COMPAT=arm-none-eabi-gcc`, `DISABLE_WRAPPER=1`,
  `KCFLAGS=-Wno-error CONFIG_SECTION_MISMATCH_WARN_ONLY=y`.
- `olddefconfig` via a wrapper script can fail on host-tool builds
  (`scripts/basic/fixdep Error 1`) when the script's PATH differs from a
  login shell — run `make O=… LLVM=1 olddefconfig` in a login shell.
- Build output through a pipe + `timeout` buffers and dies with the
  timeout; run `nohup make … > build.log` and poll the log.
- Config lives at `/home/user/kernel/out/.config` (O= dir), not in the
  source tree.

## Status snapshot (2026-10-10)

| Item | State |
|---|---|
| Custom kernel flashed, vendor modules load | ✅ |
| Namespace symbols | ✅ all `=y`, verified live |
| CSC popup loop | ✅ killed (cidmanager + csc disabled) |
| fsck forced reboots | ✅ killed (per-boot tune2fs zeroing) |
| softdog panic reboots | ✅ killed (per-boot magic-close) |
| Container systemd PID 1 | ⏳ blocked on DEFEX; rebuild with `SECURITY_DEFEX=n` in progress |
| Display (Hyprland) | ⏳ see findings.md — native DRM path, gated on container booting |
