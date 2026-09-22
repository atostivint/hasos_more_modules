# AR3012 Bluetooth loader

Unsupported Home Assistant OS app for the CyberDeck integrated Atheros AR3012
USB Bluetooth controller (`13d3:3362`).

**Role on HAOS 18.3 / kernel `6.18.52-haos`: power-loss recovery.** Nothing in
HAOS re-uploads the AR3012 firmware at boot — HAOS ships no `ath3k.ko` and
`btusb` has no AR3012 firmware path — so the controller only works while the
chip keeps its firmware in RAM. A VM reboot does not cut USB power, which is why
the adapter survives VM restarts on its own. A real power cycle (host reboot,
unplug/re-plug) drops the firmware and the chip returns to boot mode; this app
is the mechanism that pushes the firmware back. It is enabled with `boot: auto`.
See [Post-reboot result](#post-reboot-result-2026-09-22) and
[Power-loss recovery](#power-loss-recovery).

## What it does

1. Finds `ath3k.ko` for the running kernel, bundled in the image first, then a
   user-provided copy:

   ```text
   /opt/ath3k/modules/<kernel-version>/ath3k.ko   (bundled, primary)
   /share/ath3k/modules/<kernel-version>/ath3k.ko (fallback)
   ```

2. Refuses to load anything whose `vermagic` differs from the running kernel.
   For HAOS 18.3 the expected value is:

   ```text
   6.18.52-haos SMP preempt mod_unload
   ```

   The comparison collapses whitespace because `modinfo -F vermagic` pads the
   value with a trailing space, which would otherwise reject a valid module.

3. Checks that the two AR3012 firmware files are present:

   ```text
   /share/firmware/ar3k/AthrBT_0x01020200.dfu
   /share/firmware/ar3k/ramps_0x01020200_40.dfu
   ```

4. Obtains a writable sysfs view to set `firmware_class.path`, because app
   containers receive `/sys` read-only: if `/sys` is not writable it mounts a
   second `sysfs` instance under `/run/ath3k-sys` (same kernel, same
   parameters) or remounts `/sys` read-write.
5. Points the kernel firmware loader at the HAOS host path
   `/mnt/data/supervisor/share/firmware` (the `share` map is
   `/mnt/data/supervisor/share` on the host). The host path is required because
   firmware loading runs in the host's initial mount namespace, where the app's
   `/share` bind mount does not exist.
6. Loads the module, rebinds the USB interface if needed, and waits for `hci0`.

`ath3k` only uploads the AR3012 firmware and then lets go of the device; `btusb`
(shipped with HAOS) claims the operational interface and provides `hci0`. That is
why the loaded `ath3k` module shows a zero reference count while `hci0` is
present and working.

Do not unbind a live interface to "test" a reload: writing to
`/sys/bus/usb/drivers/ath3k/unbind` killed the app container (Supervisor
reported exit code 1) with no further output. The boot path is exercised by
rebooting HAOS, not by tearing down a working adapter.

The module stays loaded when the app stops: unloading `ath3k` while Home
Assistant is using `hci0` would remove the adapter from under the Bluetooth
integration. Disable the app and reboot HAOS to revert completely.

## Bundled module provenance

| Item | Value |
| --- | --- |
| HAOS version | `18.3` |
| Board | `ova` |
| Kernel | `6.18.52-haos` |
| Build | GitHub Actions run `35702890707`, artifact `modules-18.3-ova` |
| SHA-256 | `5dee3490a90ff3265ffb617450992156d4431dfb318fc38783f253b5f5f61e3e` |
| Path in image | `/opt/ath3k/modules/6.18.52-haos/ath3k.ko` |

The module carries the USB alias

```text
usb:v13D3p3362d*dc*dsc*dp*ic*isc*ip*in*
```

The module is bundled, not downloaded, so the app installs and starts without
any manual file placement.

## Requirements

- `arch: amd64` (HAOS OVA on x86-64).
- Supervisor privileges: `kernel_modules`, `full_access`, `SYS_MODULE`,
  `SYS_ADMIN`, AppArmor disabled.
- The two firmware files above, installed on the HAOS host.

## Options

None. The app takes no configuration.

## Kernel updates

`ath3k.ko` is valid only for the kernel it was built for. After a HAOS update
changes `uname -r`, this app logs a vermagic mismatch and stays idle instead of
loading a wrong module. Rebuild the module for the new kernel, add it under
`addon/ath3k_loader/modules/<new-kernel>/`, bump the app version and reinstall.

## Rollback

- Stop or disable the app: the module stays loaded so the Bluetooth adapter is
  not pulled out from under Home Assistant.
- To remove the driver entirely: disable the app, then reboot HAOS (the module
  and `firmware_class.path` are reset on boot).
- Restore the preserved Proxmox snapshot if needed.
- The EchoMuse Bluetooth proxy remains the fallback scanner
  (`sensor.chambre_alex_bt_proxy_ble_advertisements`).

## Verification status

Verified on the CyberDeck HAOS VM:

- The bundled module matches the running kernel (`vermagic`
  `6.18.52-haos SMP preempt mod_unload`, alias `13d3:3362`).
- The app sets `firmware_class.path` from inside the container (writable sysfs
  obtained by remounting `/sys`; a second sysfs instance is not writable for
  this attribute).
- `hci0` exists and Home Assistant holds a loaded `bluetooth` config entry for
  `Atheros Communications Bluetooth USB Host Controller (E0:B9:A5:F6:3E:EB)`.
  Its diagnostics report the adapter as `powered: true` and `advertise: true`
  (`13d3:3362`, `Atheros Communications`), so Home Assistant is actively
  scanning through it.

## Post-reboot result (2026-09-22)

One full reboot of the HAOS VM (`hassio.host_reboot`; HAOS 18.3, kernel
`6.18.52-haos`, boot at 12:03 Paris) was allowed to test persistence. The
adapter works after the reboot with no manual intervention and no `ath3k`
module — but **not** through this app.

App log after the reboot (verbatim, as returned newest-first):

```text
[ath3k-loader] ath3k module: not loaded
[ath3k-loader] hci0 already exists; no module load needed (/opt/ath3k/modules/6.18.52-haos/ath3k.ko)
[ath3k-loader] remounted /sys read-write
[ath3k-loader] sysfs mounted on /run/ath3k-sys but module/firmware_class/parameters/path is not writable
```

The expected `Loading /opt/ath3k/modules/6.18.52-haos/ath3k.ko` line never
appeared: the app short-circuited on `hci0 already exists`, which is exactly
the outcome the persistence test was meant to rule out. **Criterion not met.**

Why it short-circuited — the first reading of this result was wrong, and the
correction is what makes this app necessary again:

- HAOS does point the kernel firmware loader at the persistent share
  (`/sys/module/firmware_class/parameters/path` = `/mnt/data/supervisor/share/firmware`)
  and both AR3012 files are there — but **no driver requests them at boot**:
  HAOS ships no `ath3k.ko` at all (`find /lib/modules/$(uname -r) -name 'ath3k*'`
  → 0 hits) and `btusb.ko` has no AR3012 firmware path (no `ar3k/` or `AthrBT`
  strings, `depends: bluetooth,btmtk,btintel,btbcm,btrtl`, no `firmware:` field).
  Installing the files is necessary but not sufficient.
- The working adapter therefore runs firmware pushed **once** by `ath3k.ko` (the
  manual load of 2026-09-21) and **kept in the chip's RAM as long as the device
  stays powered**. The firmware files' access time still pointed at that manual
  load, not at the boot — the files were never read again.
- `ath3k` short-circuits whenever `hci0` already exists, which is the case while
  the chip still holds its firmware. So the app cannot load at boot in that
  state — but it is not redundant: it is the only recovery path after a power
  cycle. See [Power-loss recovery](#power-loss-recovery).

Evidence collected after the reboot:

| Check | Result |
| --- | --- |
| `dmesg` | `usb 9-1: New USB device found, idVendor=13d3, idProduct=3362`; no firmware or `ath3k` errors |
| `/proc/modules` | `ath3k` absent, `btusb` present |
| `hci0` | under `.../usb9/9-1/9-1:1.0/bluetooth/hci0`, i.e. the dongle, driven by `btusb` |
| HA bluetooth entry `01M344RRQM1YP5DFHMSAZHWY0V` diagnostics | `hci0`: `vendor_id 13d3`, `product_id 3362`, `E0:B9:A5:F6:3E:EB`, `powered: true`, `advertise: true`, `issues: []` |
| HA log, search `ath3k` and `btusb` | 0 entries each |

Two side findings:

- The app cannot write `firmware_class.path` from a container on this build
  (`module/firmware_class/parameters/path is not writable`, even on the second
  sysfs instance). It does not matter: the host value is already correct.
- On kernel 6.18 the `bluetooth` sysfs class no longer exposes `address`,
  `name` or `type`. A missing `/sys/class/bluetooth/hci0/address` is **not** a
  sign of a dead adapter; reading it that way caused a wrong mid-test diagnosis.

## Power-loss recovery

After a power cycle of the CyberDeck the AR3012 comes back with **no firmware**
and must be re-initialised:

1. The chip enumerates in boot mode, i.e. with a vendor-specific interface class,
   so `btusb`'s class match (`icE0isc01ip01`) cannot claim it.
2. This app's `insmod` loads `ath3k`, whose aliases match on VID:PID with a
   wildcard class (`usb:v13D3p3362d*dc*dsc*dp*ic*isc*ip*in*`), so it claims the
   device and uploads `ar3k/*.dfu` from the share.
3. The device re-enumerates as a Bluetooth interface (class `0xE0`), `btusb`
   binds it, and `hci0` appears.

Expected app log in that case (this is the evidence to look for):

```text
[ath3k-loader] Loading /opt/ath3k/modules/6.18.52-haos/ath3k.ko for kernel 6.18.52-haos
[ath3k-loader] AR3012 is available as hci0
```

Prerequisites: the bundled module must match the running kernel (see
[Kernel updates](#kernel-updates)) and the two firmware files must still be in
the share. The app retries for five minutes, so a slow USB enumeration is
tolerated.

If the adapter is still missing afterwards, the likely cause is `btusb` having
claimed the device first: the log then repeats
`ath3k loaded but hci0 is not available yet`. The manual fix (only when `hci0`
is absent — never on a working adapter) is to move the interface to `ath3k`:

```text
echo -n "9-1:1.0" > /sys/bus/usb/drivers/btusb/unbind
echo -n "9-1:1.0" > /sys/bus/usb/drivers/ath3k/bind
```

Then reload the Home Assistant Bluetooth integration so it picks `hci0` up.
This path has **not** been exercised: proving it needs a real power cycle of the
chip, which the test scope excluded.

## Status

- The AR3012 works across VM restarts **without** this app, because the chip
  keeps its firmware while it stays powered. That is not proof of permanence.
- The app is the only mechanism that can push the firmware back after a power
  cycle. It is **enabled** (`boot: auto`, `startup: system`) as the recovery
  path: when the chip has no firmware, `hci0` is absent and its load path runs.
- Unproven: the power-loss path itself (see
  [Power-loss recovery](#power-loss-recovery)).
- This mechanism is community work and is not supported by Home Assistant.
