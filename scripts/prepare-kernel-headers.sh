#!/usr/bin/env bash
# =============================================================================
# prepare-kernel-headers.sh — Set up kernel build tree from TrueNAS source
#
# Called inside the Docker builder container.
# Prepares the kernel source so out-of-tree modules can be built against it.
# =============================================================================
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION must be set}"
KERNEL_SRC="/build/linux-src"

echo "=== Preparing kernel headers for ${KERNEL_VERSION} ==="

cd "${KERNEL_SRC}"

# ── Get the kernel config ──────────────────────────────────────────────────
# Priority order:
# 1. Mounted from host at /host-config (bind mount of /proc/config.gz or /boot/config-*)
# 2. /host-proc/config.gz (if /proc is bind-mounted)
# 3. Fall back to defconfig + enable required options

CONFIG_FOUND=false

if [ -f /host-config/config.gz ]; then
    echo "Using kernel config from /host-config/config.gz"
    zcat /host-config/config.gz > .config
    CONFIG_FOUND=true
elif [ -f "/host-config/config-${KERNEL_VERSION}" ]; then
    echo "Using kernel config from /host-config/config-${KERNEL_VERSION}"
    cp "/host-config/config-${KERNEL_VERSION}" .config
    CONFIG_FOUND=true
elif [ -f /host-proc/config.gz ]; then
    echo "Using kernel config from /host-proc/config.gz"
    zcat /host-proc/config.gz > .config
    CONFIG_FOUND=true
fi

if [ "$CONFIG_FOUND" = false ]; then
    echo "WARNING: No host kernel config found. Using defconfig."
    echo "For best results, mount the host's /proc/config.gz:"
    echo "  -v /proc:/host-proc:ro"
    make defconfig
fi

# ── Prepare the source tree for external module builds ─────────────────────
# Set the kernel version to match the running kernel
# This ensures Module.symvers and version magic align
make olddefconfig
make modules_prepare

# Create the expected symlink for module builds
HEADERS_DIR="/lib/modules/${KERNEL_VERSION}"
mkdir -p "${HEADERS_DIR}"
ln -sf "${KERNEL_SRC}" "${HEADERS_DIR}/build"
ln -sf "${KERNEL_SRC}" "${HEADERS_DIR}/source"

echo "=== Kernel headers ready at ${KERNEL_SRC} ==="
echo "=== Module build dir linked at ${HEADERS_DIR}/build ==="
