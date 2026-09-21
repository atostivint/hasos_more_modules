# hasos_more_modules

[![Build HAOS Kernel Modules](https://github.com/dianlight/hasos_more_modules/actions/workflows/main_build.yml/badge.svg)](https://github.com/dianlight/hasos_more_modules/actions/workflows/main_build.yml)

[![renovate](https://img.shields.io/badge/maintaied%20with-renovate-blue?logo=renovatebot)](https://app.renovatebot.com/dashboard)

> **Note:** this project is community-maintained and is not affiliated with Nabu Casa / official Home Assistant.
>
> **Warning:** installing custom kernel modules on HAOS is **unsupported** and may lead to system instability or security issues. Use at your own risk.
>
> **Alert:** the modules provided by this project are compiled with the same configuration as the official HAOS releases, but they are **not** signed with the HAOS private key. This means that they can be loaded on HAOS, but they will not be loaded automatically at boot and may require manual intervention to load.
>
> **Disclaimer:** the modules provided by this project are intended for advanced users who understand the risks and implications of installing custom kernel modules on HAOS. The maintainers of this project are not responsible for any issues that may arise from using these modules.
>
> **Very Big Alert:** the project is created and maintained with a heavy use of AI tools (GitHub Copilot, ChatGPT, etc.) to automate the generation of code and documentation. While this allows for rapid development and updates, it may also introduce errors or inconsistencies. Users are encouraged to review the code and documentation carefully before use.

Extra kernel modules for **Home Assistant OS (HAOS)** – automatically compiled for every new release.

Available modules:

The table below lists the top-level modules requested by this project. Each release also includes all runtime dependencies (other `.ko` files) that are discovered automatically and required by these modules but are not part of the standard HAOS kernel.

The table below is generated from `config/modules.json` and lists only the
top-level modules requested by this project. If one of these modules depends on
additional `.ko` files, the workflow discovers them with `modinfo` and ships
them automatically only when the full dependency chain is available.

<!-- modules-table:start -->
| Module | Description | Notes |
| :-------- | :------------- | :----- |
| `ath3k.ko` | Atheros AR3012 Bluetooth USB driver |  |
<!-- modules-table:end -->

Supported architectures: **x86_64** and **aarch64**.

---

## Table of Contents

- [hasos\_more\_modules](#hasos_more_modules)
  - [Table of Contents](#table-of-contents)
  - [Scope of the project](#scope-of-the-project)
  - [How the project works](#how-the-project-works)
  - [Installing modules on HAOS (Unsupported)](#installing-modules-on-haos-unsupported)
    - [Prerequisites](#prerequisites)
    - [Step 1 – Download the module](#step-1--download-the-module)
    - [Step 2 – Upload the module to the system](#step-2--upload-the-module-to-the-system)
    - [Step 3 – Remount `/` as read-write](#step-3--remount--as-read-write)
    - [Step 4 – Load the module](#step-4--load-the-module)
  - [Making modules persistent](#making-modules-persistent)
    - [Directory structure](#directory-structure)
    - [Startup script](#startup-script)
    - [Integration with containers (Advanced SSH \& Web Terminal Add-on)](#integration-with-containers-advanced-ssh--web-terminal-add-on)
  - [Warning about Kernel Version Magic](#warning-about-kernel-version-magic)
  - [Local development](#local-development)
    - [Requirements](#requirements)
    - [Check for missing releases](#check-for-missing-releases)
    - [Define new modules and CONFIG\_\* symbols](#define-new-modules-and-config_-symbols)
    - [Test the configuration patch](#test-the-configuration-patch)
    - [Regenerate README module table](#regenerate-readme-module-table)
  - [Testing a specific workflow variant locally](#testing-a-specific-workflow-variant-locally)
  - [Repository structure](#repository-structure)
  - [License](#license)

---

## Scope of the project

This project provides **pre-compiled kernel modules** for Home Assistant OS (HAOS) that are not included in the official HAOS releases. The modules are compiled for each HAOS release and made available as assets in the GitHub Releases of this repository.

For each top-level module requested, the build process also automatically discovers and includes all runtime dependencies (other `.ko` files) that are not part of the standard HAOS kernel. These dependencies are resolved via `modinfo` and packaged only when the complete dependency chain is available. This ensures that you download not just the requested module, but also all the kernel modules it depends on that aren't already in HAOS.

The primary use is by [SambaNAS2](https://github.com/dianlight/hassio-addons) app (add-on) to provide support for the XFS filesystem and NFS server/client capabilities on HAOS. However, the modules can be used for any purpose that requires them.

**Warning:** installing custom kernel modules on HAOS is **unsupported** and may lead to system instability or security issues. Use at your own risk.

## How the project works

```text
┌─────────────────────────────────────┐
│  GitHub Actions (main_build.yml)    │
│                                     │
│  1. check_releases.py               │
│     └─ compares HAOS releases       │
│        with already-built assets    │
│                                     │
│  2. patch_config.sh                 │
│     └─ modifies kernel.config       │
│        to enable modules as =m      │
│                                     │
│  3. make linux-modules              │
│     └─ compiles only .ko modules    │
│                                     │
│  4. modinfo dependency scan         │
│     └─ discovers dependencies not   │
│        included in HAOS release     │
│        and packages them if all     │
│        dependencies can be provided │
│                                     │
│  5. GitHub Release                  │
│     └─ uploads .ko assets named     │
│        {mod}_{ver}_{arch}.ko        │
│        including all dependencies   │
└─────────────────────────────────────┘
```

The workflow runs:

- **Automatically** every day at 06:00 UTC (cron).
- **Manually** from the *Actions* tab of the repository.
- **Via API** with a `repository_dispatch` event of type `build-modules`.

---

## Installing modules on HAOS (Unsupported)

### Prerequisites

- SSH access enabled on HAOS (see *Settings → System → SSH Access*).
- HAOS version matching the module to install.

### Step 1 – Download the module

Download the `.ko` file matching your version and architecture from the
[Releases](../../releases) page of this repository.  
Example: `xfs_13.2_x86_64.ko`.

### Step 2 – Upload the module to the system

```bash
# Copy the file to the system (from an SSH terminal)
scp xfs_13.2_x86_64.ko root@homeassistant.local:/tmp/
```

### Step 3 – Remount `/` as read-write

HAOS mounts the system partition (`/`) as **read-only** to ensure its
integrity. Before copying the module to its final location you need to
remount it as read-write:

```bash
# Remount / as read-write
mount -o remount,rw /

# Create the modules directory if it doesn't exist
mkdir -p /lib/modules/$(uname -r)/extra

# Copy the module
cp /tmp/xfs_13.2_x86_64.ko /lib/modules/$(uname -r)/extra/xfs.ko

# Update the module database
depmod -a
```

### Step 4 – Load the module

```bash
modprobe xfs        # load the module (and its dependencies)
# or
insmod /lib/modules/$(uname -r)/extra/xfs.ko
```

To verify that the module was loaded correctly:

```bash
lsmod | grep xfs
dmesg | tail -20
```

> **Warning:** on the next update/reboot, HAOS remounts `/` as read-only
> and files copied to `/lib/modules` are removed. See the next section
> to make the module persistent.

---

## Making modules persistent

The recommended method is to use the `/mnt/data` partition, which **survives
HAOS updates**.

### Directory structure

```text
/mnt/data/
└── modules/
    └── <kernel-version>/
        └── extra/
            ├── xfs.ko
            └── nfsd.ko
```

### Startup script

Create the file `/mnt/data/modules/load_modules.sh`:

```bash
#!/bin/sh
# Load extra modules at HAOS boot.

KERNEL_VER=$(uname -r)
MODULE_DIR="/mnt/data/modules/${KERNEL_VER}/extra"

if [ ! -d "${MODULE_DIR}" ]; then
    echo "[haos_more_modules] Module directory not found: ${MODULE_DIR}"
    exit 0
fi

# Copy modules to the system location
mount -o remount,rw /
mkdir -p "/lib/modules/${KERNEL_VER}/extra"
cp "${MODULE_DIR}"/*.ko "/lib/modules/${KERNEL_VER}/extra/" 2>/dev/null || true
depmod -a
mount -o remount,ro /

# Load modules
for mod in xfs nfsd; do
    modprobe "${mod}" 2>/dev/null && \
        echo "[haos_more_modules] Module ${mod} loaded." || \
        echo "[haos_more_modules] Module ${mod} not found or already built-in."
done
```

### Integration with containers (Advanced SSH & Web Terminal Add-on)

If you use the *Advanced SSH & Web Terminal* add-on, you can add the command to
the `~/.profile` file or to a custom `s6-rc` service.

For a permanent integration you can use the
[AppDaemon](https://github.com/hassio-addons/addon-appdaemon) add-on or create
an S6 script in `/mnt/data/supervisor/addons/local/`.

---

## Warning about Kernel Version Magic

Linux kernel modules embed a string called **"version magic"** that must match
**exactly** the string of the running kernel.

```bash
# Show the version magic of the running kernel
uname -r

# Show the version magic of the module
modinfo xfs.ko | grep vermagic
```

If the two strings **do not match**, loading the module will fail with:

```text
ERROR: could not insert module xfs.ko: Invalid module format
```

**Practical implications:**

| Situation                                                       | Result  |
| :-------------------------------------------------------------- | :------ |
| Module compiled for HAOS 13.2, running on HAOS 13.2             | ✅ Works|
| Module compiled for HAOS 13.2, running on HAOS 13.1             | ❌ Fails|
| Module compiled for HAOS 13.2, running after an upgrade to 13.3 | ❌ Fails|

**Solution:** always download the module that matches **exactly** the installed
HAOS version. After every HAOS update you must replace the modules with the
version compiled for the new kernel.

---

## Local development

### Requirements

- Python ≥ 3.10
- `pip install -r requirements.txt`

### Check for missing releases

```bash
export GITHUB_TOKEN=ghp_...  # optional, increases API rate-limit

python3 scripts/check_releases.py \
    --haos-repo home-assistant/operating-system \
    --this-repo dianlight/hasos_more_modules
```

### Define new modules and CONFIG_* symbols

To add a new module to the workflow, edit the `config/modules.json` file and
add the top-level module name, description and the corresponding `CONFIG_*`
symbol to enable it in the kernel configuration.

Do not add dependency-only helper modules that require no config changes.
Those are resolved from the built `.ko` files with `modinfo` during the
packaging step and are included automatically only when the full dependency
closure is present.

### Test the configuration patch

```bash
# Copy a sample kernel.config
cp /boot/config-$(uname -r) /tmp/test.config

bash scripts/patch_config.sh /tmp/test.config x86_64

# Verify the patched values
grep -E "CONFIG_MODULES|CONFIG_LOCALVERSION|CONFIG_XFS|CONFIG_NFS|CONFIG_EXPORTFS" \
    /tmp/test.config
```

### Regenerate README module table

```bash
python3 scripts/update_readme_modules.py
```

## Testing a specific workflow variant locally

For reproducible local simulation of one workflow variant (for example one
`version` + `board` matrix entry), see:

- [`docs/testing-specific-variant.md`](docs/testing-specific-variant.md)

---

## Repository structure

```text
hasos_more_modules/
├── .github/
│   └── workflows/
│       └── main_build.yml      # Main CI/CD workflow
├── config/
│   └── modules.json              # Single source of truth for modules and CONFIG_* symbols
├── scripts/
│   ├── check_releases.py       # HAOS missing-release detection
│   ├── modules_config.py       # Reads config/modules.json for CI/docs
│   ├── collect_module_artifacts.py # Packages requested modules plus modinfo-resolved dependencies
│   ├── patch_config.sh         # kernel.config patch (YAML-driven)
│   └── update_readme_modules.py # Regenerates README module table
├── .gitignore
├── LICENSE
├── README.md                   # This file
└── requirements.txt            # Python dependencies
```

---

## License

This project is distributed under the **MIT** license.  
See the [LICENSE](LICENSE) file for full details.
