# AR3012 Bluetooth loader

Unsupported Home Assistant OS app for the CyberDeck integrated Atheros AR3012
USB Bluetooth controller (`13d3:3362`), which HAOS does not ship a driver for.

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

## Status

This mechanism is community work and is not supported by Home Assistant.
