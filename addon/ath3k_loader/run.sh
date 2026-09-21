#!/usr/bin/with-contenv bashio

set -u

MODULE_ROOT="/share/ath3k/modules"
FIRMWARE_ROOT="/share/firmware"
HOST_FIRMWARE_ROOT="/mnt/data/supervisor/share/firmware"
USB_VENDOR="13d3"
USB_PRODUCT="3362"
LOADED_BY_US=0

log() {
  echo "[ath3k-loader] $*"
}

find_usb_interface() {
  for iface in /sys/bus/usb/devices/*:*; do
    [ -f "${iface}/../idVendor" ] || continue
    [ -f "${iface}/../idProduct" ] || continue
    vendor="$(cat "${iface}/../idVendor" 2>/dev/null || true)"
    product="$(cat "${iface}/../idProduct" 2>/dev/null || true)"
    if [ "${vendor}" = "${USB_VENDOR}" ] && [ "${product}" = "${USB_PRODUCT}" ]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done
  return 1
}

try_rebind() {
  iface="$1"
  name="$(basename "${iface}")"
  if [ -e "/sys/bus/usb/devices/${name}/driver/unbind" ]; then
    printf '%s' "${name}" > "/sys/bus/usb/devices/${name}/driver/unbind" 2>/dev/null || true
  fi
  if [ -e /sys/bus/usb/drivers/ath3k/bind ]; then
    printf '%s' "${name}" > /sys/bus/usb/drivers/ath3k/bind 2>/dev/null || true
  fi
}

load_once() {
  kernel="$(uname -r)"
  module="${MODULE_ROOT}/${kernel}/ath3k.ko"

  if [ ! -f "${module}" ]; then
    log "No module for kernel ${kernel}: ${module}"
    return 1
  fi

  expected_vermagic="${kernel} SMP preempt mod_unload"
  actual_vermagic="$(modinfo -F vermagic "${module}" 2>/dev/null || true)"
  if [ "${actual_vermagic}" != "${expected_vermagic}" ]; then
    log "Refusing ${module}: vermagic='${actual_vermagic}', expected='${expected_vermagic}'"
    return 1
  fi

  if [ ! -f "${FIRMWARE_ROOT}/ar3k/AthrBT_0x01020200.dfu" ] || \
     [ ! -f "${FIRMWARE_ROOT}/ar3k/ramps_0x01020200_40.dfu" ]; then
    log "Required AR3012 firmware files are missing"
    return 1
  fi

  if [ -e /sys/module/firmware_class/parameters/path ]; then
    # Firmware loading runs in the host's initial mount namespace. The app's
    # /share bind mount is not visible there, so the kernel parameter must use
    # the HAOS host path rather than the container path.
    printf '%s' "${HOST_FIRMWARE_ROOT}" > /sys/module/firmware_class/parameters/path || {
      log "Cannot set firmware_class.path"
      return 1
    }
  fi

  if [ -e /sys/class/bluetooth/hci0 ]; then
    log "hci0 already exists; no module load needed"
    return 0
  fi

  if ! grep -q '^ath3k ' /proc/modules; then
    log "Loading ${module} for kernel ${kernel}"
    insmod "${module}" || {
      log "insmod failed"
      return 1
    }
    LOADED_BY_US=1
  else
    log "ath3k is already loaded"
  fi

  sleep 2
  if [ ! -e /sys/class/bluetooth/hci0 ]; then
    iface="$(find_usb_interface || true)"
    if [ -n "${iface}" ]; then
      log "Rebinding USB interface $(basename "${iface}") to ath3k"
      try_rebind "${iface}"
      sleep 2
    fi
  fi

  if [ -e /sys/class/bluetooth/hci0 ]; then
    log "AR3012 is available as hci0"
    return 0
  fi

  log "ath3k loaded but hci0 is not available yet"
  return 1
}

# Supervisor may start this app before the USB pass-through is enumerated.
for attempt in $(seq 1 60); do
  if load_once; then
    break
  fi
  log "Retry ${attempt}/60 in 5 seconds"
  sleep 5
done

if [ ! -e /sys/class/bluetooth/hci0 ]; then
  log "AR3012 was not initialized; keeping the app alive for diagnostics"
fi

cleanup() {
  if [ "${LOADED_BY_US}" -eq 1 ]; then
    log "Unloading ath3k during app shutdown"
    rmmod ath3k 2>/dev/null || log "ath3k could not be unloaded (it may be in use)"
  fi
}
trap cleanup TERM INT

# Keep the service running so Supervisor does not restart it in a tight loop.
while sleep 3600; do :; done
