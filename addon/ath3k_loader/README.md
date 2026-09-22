# AR3012 Bluetooth loader

Unsupported Home Assistant OS app for the CyberDeck integrated Atheros AR3012
USB Bluetooth controller (`13d3:3362`).

**Superseded on HAOS 18.3 / kernel `6.18.52-haos`.** After a full reboot of the
HAOS VM the controller came up on its own: `btusb` (shipped with HAOS) claimed
`13d3:3362` and initialised it from the firmware files that live in the HAOS
firmware path, so no `ath3k` module load was needed and this app short-circuited.
See [Post-reboot result](#post-reboot-result-2026-09-22). The app is disabled;
the section below documents what it does if the adapter ever fails to come up.

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

`ath3k` only uploads the AR3012 firmware; `btusb` (shipped with HAOS) then owns
the controller and provides `hci0`. That is why the loaded `ath3k` module shows
a zero reference count while `hci0` is present and working.

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

Why it short-circuited — the premise of the app was wrong:

- HAOS itself points the kernel firmware loader at the persistent share:
  `/sys/module/firmware_class/parameters/path` = `/mnt/data/supervisor/share/firmware`.
- The two AR3012 firmware files are there (`ar3k/AthrBT_0x01020200.dfu`,
  `ar3k/ramps_0x01020200_40.dfu`) and `/mnt/data` survives reboots.
- `btusb` therefore initialises the controller by itself at boot. `ath3k` only
  uploads firmware, so once the firmware is reachable it is never needed:
  `/proc/modules` has no `ath3k`, while `/sys/bus/usb/drivers/btusb/` owns
  `9-1:1.0` and `9-1:1.1`.

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

## Status

- The AR3012 works permanently on this HAOS/kernel **without** this app.
- The app is redundant (it always finds `hci0` at boot) and is **disabled** in
  Home Assistant. It stays in the repository as the fallback for the case where
  HAOS fails to initialise the adapter (probe failure, firmware unavailable):
  then `hci0` is missing and its load path runs.
- This mechanism is community work and is not supported by Home Assistant.
