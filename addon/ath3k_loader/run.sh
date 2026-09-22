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
FW_PATH_ATTR="module/firmware_class/parameters/path"
ATH3K_DRIVER_DIR="bus/usb/drivers/ath3k"
SYS_RW_ROOT=""
LOADED_BY_US=0
FATAL=0
# The watchdog re-checks this often: small enough to catch a re-plugged dongle or
# a late USB enumeration, cheap enough to run forever.
WATCH_INTERVAL=15

log() {
  echo "[ath3k-loader] $*"
}

# modinfo pads -F vermagic with a trailing space, so raw string equality is
# unreliable: compare on collapsed whitespace instead.
normalize_ws() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

is_loaded() {
  grep -q '^ath3k ' /proc/modules
}

# App containers get /sys mounted read-only. A second sysfs instance mounted
# here is read-write and exposes the same kernel parameters, because sysfs
# attributes are kernel objects, not mount-local state.
ensure_sys_rw() {
  if [ -n "${SYS_RW_ROOT}" ] && [ -w "${SYS_RW_ROOT}/${FW_PATH_ATTR}" ]; then
    return 0
  fi
  if [ -w "/sys/${FW_PATH_ATTR}" ]; then
    SYS_RW_ROOT="/sys"
    log "using /sys directly"
    return 0
  fi
  local tmp="/run/ath3k-sys"
  mkdir -p "${tmp}"
  if mount -t sysfs sysfs "${tmp}" 2>/dev/null; then
    if [ -w "${tmp}/${FW_PATH_ATTR}" ]; then
      SYS_RW_ROOT="${tmp}"
      log "mounted a read-write sysfs instance on ${tmp}"
      return 0
    fi
    log "sysfs mounted on ${tmp} but ${FW_PATH_ATTR} is not writable"
  else
    log "mounting sysfs on ${tmp} failed"
  fi
  if mount -o remount,rw /sys 2>/dev/null && [ -w "/sys/${FW_PATH_ATTR}" ]; then
    SYS_RW_ROOT="/sys"
    log "remounted /sys read-write"
    return 0
  fi
  return 1
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

sysfs_write() {
  # $1 = path relative to the writable sysfs root, $2 = value
  if [ -z "${SYS_RW_ROOT}" ]; then
    return 1
  fi
  printf '%s' "$2" > "${SYS_RW_ROOT}/$1" 2>/dev/null
}

bind_interface() {
  iface="$1"
  sysfs_write "${ATH3K_DRIVER_DIR}/bind" "$(basename "${iface}")"
}

# CAP_SYS_MODULE (bit 16) is what lets a container call insmod at all.
has_sys_module_cap() {
  cap="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [ -n "${cap}" ] || return 1
  # CapEff is hex; test bit 16 with a right shift.
  val=$((0x${cap}))
  [ $(( (val >> 16) & 1 )) -eq 1 ]
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
  log "/sys mount: $(grep ' /sys ' /proc/mounts || echo unknown)"
  log "sysfs rw root: ${SYS_RW_ROOT:-none}"
  if [ -n "${SYS_RW_ROOT}" ] && [ -e "${SYS_RW_ROOT}/${FW_PATH_ATTR}" ]; then
    log "firmware_class.path=$(cat "${SYS_RW_ROOT}/${FW_PATH_ATTR}")"
  fi
  log "ath3k in /proc/modules: $(grep '^ath3k ' /proc/modules || echo no)"
  log "bluetooth class: $(ls -1 /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
  log "usb interfaces for ${USB_VENDOR}:${USB_PRODUCT}: $(find_usb_interface || echo none)"
  log "ath3k driver dir: $(ls -1 "${SYS_RW_ROOT:-/sys}/${ATH3K_DRIVER_DIR}" 2>/dev/null | tr '\n' ' ' || echo none)"
  log "hci0 driver: $(basename "$(readlink -f /sys/class/bluetooth/hci0/device/driver 2>/dev/null)" 2>/dev/null || echo unknown)"
  if has_sys_module_cap; then
    log "CAP_SYS_MODULE: present"
  else
    log "CAP_SYS_MODULE: absent (insmod would fail)"
  fi
  log "--- end diagnostics ---"
}

report_state() {
  log "ath3k module: $(grep '^ath3k ' /proc/modules || echo 'not loaded')"
  if [ -e /sys/class/bluetooth/hci0/address ]; then
    log "hci0 address: $(cat /sys/class/bluetooth/hci0/address)"
    log "hci0 driver: $(basename "$(readlink -f /sys/class/bluetooth/hci0/device/driver 2>/dev/null)" 2>/dev/null || echo unknown)"
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
    FATAL=1
    return 1
  fi

  for fw in ${REQUIRED_FIRMWARE}; do
    if [ ! -f "${FIRMWARE_ROOT}/${fw}" ]; then
      log "Required AR3012 firmware is missing: ${FIRMWARE_ROOT}/${fw}"
      return 1
    fi
  done

  # HAOS already sets firmware_class.path to the persistent share, so failing to
  # write it must never block a power-loss recovery: warn and carry on. If the
  # effective path were wrong the load would fail loudly (no hci0) anyway.
  if ! ensure_sys_rw; then
    log "WARNING: no writable sysfs instance for ${FW_PATH_ATTR}; continuing"
  elif ! sysfs_write "${FW_PATH_ATTR}" "${HOST_FIRMWARE_ROOT}"; then
    log "WARNING: cannot write firmware_class.path via ${SYS_RW_ROOT}; continuing"
  fi

  if [ -e /sys/class/bluetooth/hci0 ]; then
    log "hci0 already exists; no module load needed (${module})"
    report_state
    return 0
  fi

  if ! is_loaded; then
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
      log "Binding USB interface $(basename "${iface}") to ath3k"
      bind_interface "${iface}"
      sleep 2
    fi
  fi

  if [ -e /sys/class/bluetooth/hci0 ]; then
    log "AR3012 is available as hci0"
    report_state
    return 0
  fi

  log "ath3k loaded but hci0 is not available yet"
  return 1
}

# The USB pass-through can enumerate after this app starts, and a power cycle or
# a re-plug makes the chip reappear at any time: watch, do not retry once.
load_once || true

if [ "${FATAL}" -eq 1 ]; then
  log "unrecoverable condition reached; not retrying"
  diagnostics
fi

if [ ! -e /sys/class/bluetooth/hci0 ]; then
  log "AR3012 was not initialized; keeping the app alive for diagnostics"
  diagnostics
fi

cleanup() {
  if [ "${LOADED_BY_US}" -eq 1 ]; then
    log "not unloading ath3k on shutdown: the adapter would disappear for HA"
    log "(disable the app and reboot HAOS to fully revert)"
  fi
}
trap cleanup TERM INT

# Watchdog: keep the service running (Supervisor must not restart it in a tight
# loop) and pick the chip up whenever it comes back without firmware.
attempt=0
while :; do
  if [ -e /sys/class/bluetooth/hci0 ]; then
    attempt=0
    sleep "${WATCH_INTERVAL}"
    continue
  fi
  attempt=$((attempt + 1))
  if load_once; then
    log "AR3012 recovered by the watchdog (attempt ${attempt})"
    report_state
    attempt=0
  elif [ "${FATAL}" -eq 1 ]; then
    log "unrecoverable condition reached; watchdog idle"
    diagnostics
    while sleep 3600; do :; done
  elif [ $((attempt % 20)) -eq 1 ]; then
    log "AR3012 still absent; attempt ${attempt}, next in ${WATCH_INTERVAL}s"
  fi
  sleep "${WATCH_INTERVAL}"
done
