# AR3012 Bluetooth loader

This is an unsupported Home Assistant OS local app for the CyberDeck integrated
Atheros AR3012 USB Bluetooth controller (`13d3:3362`).

It expects the matching module at:

```text
/share/ath3k/modules/<kernel-version>/ath3k.ko
```

The `share` map corresponds to the HAOS host directory
`/mnt/data/supervisor/share`. The AR3012 firmware files must be present at:

```text
/share/firmware/ar3k/AthrBT_0x01020200.dfu
/share/firmware/ar3k/ramps_0x01020200_40.dfu
```

The app checks the running kernel version before loading a module. It does not
attempt to load a module for another kernel. The firmware path written to
`firmware_class.path` is deliberately the HAOS host path
`/mnt/data/supervisor/share/firmware`, not `/share/firmware`: the kernel reads
firmware from the host's initial mount namespace, while `/share` exists only in
the app container. The app then verifies that `hci0` appears.

This mechanism is not supported by Home Assistant. Keep the EchoMuse Bluetooth
proxy as a fallback and replace the module after every HAOS kernel update.

To roll back, stop or disable this app. The shutdown handler attempts to unload
`ath3k` only when this app loaded it. If the module is in use, stop it from
Home Assistant first and run `rmmod ath3k` from an explicitly privileged
maintenance shell, or restore the preserved Proxmox snapshot.
