#!/usr/bin/with-contenv bashio

set -u

# Module search order: bundled in the image first, then a user-provided copy.
MODULE_DIRS="/opt/ath3k/modules /share/ath3k/modules"
# Container view of the share (used only to check that the firmware is present).
FIRMWARE_ROOT="/share/firmware"
# Firmware loading runs in the host's initial mount namespace, so the kernel
# parameter must point at the HAOS host path, not the container bind mount.
HOST_FIRMWARE_ROOT="/mnt/data/supervisor/share/firmware"
REQUIRED_FIRMWARE="ar3k/AthrBT_0x01020200.dfu ar3k/ramps_0x01020200_40.dfu"
USB_VENDOR="13d3"
USB_PRODUCT="3362"
LOADED_BY_US=0
VERMAGIC_MISMATCH=0

log() {
  echo "[ath3k-loader] $*"
}

# modinfo pads -F vermagic with a trailing space, so raw string equality is
# unreliable: compare on collapsed whitespace instead.
normalize_ws() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

find_module() {
  kernel="$1"
  for dir in ${MODULE_DIRS}; do
    candidate="${dir}/${kernel}/ath3k.ko"
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
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

diagnostics() {
  log "--- diagnostics ---"
  log "kernel=$(uname -r)"
  for dir in ${MODULE_DIRS}; do
    if [ -d "${dir}" ]; then
      log "modules in ${dir}: $(ls -1 "${dir}" 2>/dev/null | tr '\n' ' ')"
    else
      log "modules dir absent: ${dir}"
    fi
  done
  for fw in ${REQUIRED_FIRMWARE}; do
    if [ -f "/share/firmware/${fw}" ]; then
      log "firmware present: /share/firmware/${fw}"
    else
      log "firmware MISSING in container: /share/firmware/${fw}"
    fi
  done
  if [ -e /sys/module/firmware_class/parameters/path ]; then
    log "firmware_class.path=$(cat /sys/module/firmware_class/parameters/path)"
  else
    log "firmware_class.path is absent"
  fi
  log "ath3k in /proc/modules: $(grep '^ath3k ' /proc/modules || echo no)"
  log "bluetooth class: $(ls -1 /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
  log "usb interfaces for ${USB_VENDOR}:${USB_PRODUCT}: $(find_usb_interface || echo none)"
  log "--- end diagnostics ---"
}

report_hci() {
  if [ -e /sys/class/bluetooth/hci0/address ]; then
    log "hci0 address: $(cat /sys/class/bluetooth/hci0/address)"
  fi
}

load_once() {
  kernel="$(uname -r)"
  module="$(find_module "${kernel}" || true)"

  if [ -z "${module}" ]; then
    log "No module for kernel ${kernel} in: ${MODULE_DIRS}"
    return 1
  fi

  expected_vermagic="$(normalize_ws "${kernel} SMP preempt mod_unload")"
  actual_vermagic="$(normalize_ws "$(modinfo -F vermagic "${module}" 2>/dev/null || true)")"
  if [ "${actual_vermagic}" != "${expected_vermagic}" ]; then
    log "Refusing ${module}: vermagic='${actual_vermagic}', expected='${expected_vermagic}'"
    VERMAGIC_MISMATCH=1
    return 1
  fi

  for fw in ${REQUIRED_FIRMWARE}; do
    if [ ! -f "${FIRMWARE_ROOT}/${fw}" ]; then
      log "Required AR3012 firmware is missing: ${FIRMWARE_ROOT}/${fw}"
      return 1
    fi
  done

  if [ -e /sys/module/firmware_class/parameters/path ]; then
    if ! printf '%s' "${HOST_FIRMWARE_ROOT}" > /sys/module/firmware_class/parameters/path; then
      log "Cannot set firmware_class.path (is /sys writable in this container?)"
      return 1
    fi
  else
    log "firmware_class.path is absent; relying on default firmware search paths"
  fi

  if [ -e /sys/class/bluetooth/hci0 ]; then
    log "hci0 already exists; no module load needed (${module})"
    report_hci
    return 0
  fi

  if ! grep -q '^ath3k ' /proc/modules; then
    log "Loading ${module} for kernel ${kernel}"
    if ! insmod "${module}"; then
      log "insmod failed"
      return 1
    fi
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
    report_hci
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
  if [ "${VERMAGIC_MISMATCH}" -eq 1 ]; then
    log "vermagic mismatch cannot resolve itself; stopping retries"
    break
  fi
  log "Retry ${attempt}/60 in 5 seconds"
  sleep 5
done

if [ ! -e /sys/class/bluetooth/hci0 ]; then
  log "AR3012 was not initialized; keeping the app alive for diagnostics"
  diagnostics
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
