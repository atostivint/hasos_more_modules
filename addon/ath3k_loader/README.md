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
attempt to load a module for another kernel. It also sets the kernel firmware
search path and verifies that `hci0` appears.

This mechanism is not supported by Home Assistant. Keep the EchoMuse Bluetooth
proxy as a fallback and replace the module after every HAOS kernel update.
