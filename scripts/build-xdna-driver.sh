#!/usr/bin/env bash
# =============================================================================
# build-xdna-driver.sh — Build the AMD XDNA driver for TrueNAS Scale
#
# This script automates the entire process:
#   1. Detects the running kernel version
#   2. Builds a Docker image with all build tools + TrueNAS kernel source
#   3. Builds the XDNA driver inside Docker
#   4. Extracts the .ko module + firmware
#   5. Offers to load the driver on the host
#
# Usage:
#   sudo bash scripts/build-xdna-driver.sh
#
# Requirements:
#   - Docker must be running
#   - Must be run as root (or with sudo) on the TrueNAS host
#   - Internet access to clone kernel source and XDNA driver
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/xdna-driver-output"

echo "============================================="
echo " AMD XDNA Driver Builder for TrueNAS Scale"
echo "============================================="
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────
KERNEL_VERSION="$(uname -r)"
echo "Host kernel: ${KERNEL_VERSION}"

# Determine kernel branch for TrueNAS source
KMAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KMINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
TRUENAS_BRANCH="truenas/linux-${KMAJOR}.${KMINOR}"

# Try to find a specific TrueNAS release tag for the exact kernel version.
# The branch HEAD may have a newer kernel (e.g. 6.12.43 vs running 6.12.33).
# TrueNAS tags like TS-25.10.1 point to the exact commit for each release.
echo "Detecting best kernel source tag/branch..."
KPATCH=$(echo "$KERNEL_VERSION" | cut -d. -f3 | sed 's/-.*//')
echo "  Running kernel: ${KMAJOR}.${KMINOR}.${KPATCH}"
echo "  Default branch: ${TRUENAS_BRANCH}"
echo "  Will force vermagic to match running kernel at build time."

# Verify kernel >= 6.10
if [ "$KMAJOR" -lt 6 ] || ([ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -lt 10 ]); then
    echo -e "${RED}ERROR: Kernel ${KERNEL_VERSION} is too old. XDNA driver requires >= 6.10.${NC}"
    exit 1
fi

# Verify NPU hardware
NPU_PCI=$(lspci 2>/dev/null | grep -i "neural\|xdna\|amdnpu" || true)
if [ -z "$NPU_PCI" ]; then
    echo -e "${YELLOW}WARNING: No AMD NPU detected in lspci. Continuing anyway...${NC}"
else
    echo "NPU hardware: ${NPU_PCI}"
fi

# Verify Docker
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Docker not found. Docker is required to build the driver.${NC}"
    exit 1
fi

# Check kernel config availability
if [ -f /proc/config.gz ]; then
    echo "Kernel config: /proc/config.gz (available)"
elif [ -f "/boot/config-${KERNEL_VERSION}" ]; then
    echo "Kernel config: /boot/config-${KERNEL_VERSION} (available)"
else
    echo -e "${YELLOW}WARNING: No kernel config found. Build may use defconfig.${NC}"
fi

echo ""

# ── Create output directory ───────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"

# ── Extract kernel config on the host ─────────────────────────────────────
# Docker's /proc mount doesn't always expose config.gz reliably, so we
# extract it here on the host and pass the plain-text config file in.
KERNEL_CONFIG_FILE="${OUTPUT_DIR}/kernel-config"
if [ -f /proc/config.gz ]; then
    echo "Extracting kernel config from /proc/config.gz..."
    zcat /proc/config.gz > "${KERNEL_CONFIG_FILE}"
    echo "  Saved to ${KERNEL_CONFIG_FILE}"
elif [ -f "/boot/config-${KERNEL_VERSION}" ]; then
    echo "Copying kernel config from /boot/config-${KERNEL_VERSION}..."
    cp "/boot/config-${KERNEL_VERSION}" "${KERNEL_CONFIG_FILE}"
else
    echo -e "${YELLOW}WARNING: Could not extract kernel config.${NC}"
    echo "  Neither /proc/config.gz nor /boot/config-${KERNEL_VERSION} found."
    echo "  The build will use defconfig + CONFIG_TRUENAS=y as fallback."
    echo "  This may produce a module with version mismatch."
    KERNEL_CONFIG_FILE=""
fi

# Ensure CONFIG_TRUENAS is set (TrueNAS kernel source requires it)
if [ -n "${KERNEL_CONFIG_FILE}" ] && [ -f "${KERNEL_CONFIG_FILE}" ]; then
    if ! grep -q "CONFIG_TRUENAS" "${KERNEL_CONFIG_FILE}"; then
        echo "CONFIG_TRUENAS=y" >> "${KERNEL_CONFIG_FILE}"
        echo "  Added CONFIG_TRUENAS=y to kernel config"
    fi
fi

# ── Extract Module.symvers from running kernel ────────────────────────────
# TrueNAS doesn't ship Module.symvers in /lib/modules. Without it, the build
# can't produce valid CRC checksums, and CONFIG_MODVERSIONS generates stubs
# that cause "Invalid relocation target" errors on kernel 6.12+.
#
# Strategy (in priority order):
#   1. Use pre-built Module.symvers from /lib/modules (standard distros)
#   2. Use symvers.gz from /lib/modules (some distros)
#   3. Extract CRCs from installed .ko files via modprobe --dump-modversions
#      Each .ko contains the CRCs of symbols it IMPORTS. Since all modules
#      were built against the same kernel, these CRCs match the kernel's
#      export CRCs. Collecting from ALL modules covers vmlinux + module symbols.
MODULE_SYMVERS_FILE="${OUTPUT_DIR}/Module.symvers"
if [ -f "/lib/modules/${KERNEL_VERSION}/build/Module.symvers" ]; then
    echo "Found Module.symvers in /lib/modules/*/build/ — copying..."
    cp "/lib/modules/${KERNEL_VERSION}/build/Module.symvers" "${MODULE_SYMVERS_FILE}"
elif [ -f "/lib/modules/${KERNEL_VERSION}/Module.symvers" ]; then
    echo "Found Module.symvers in /lib/modules/ — copying..."
    cp "/lib/modules/${KERNEL_VERSION}/Module.symvers" "${MODULE_SYMVERS_FILE}"
elif [ -f "/lib/modules/${KERNEL_VERSION}/symvers.gz" ]; then
    echo "Found symvers.gz in /lib/modules/ — extracting..."
    zcat "/lib/modules/${KERNEL_VERSION}/symvers.gz" > "${MODULE_SYMVERS_FILE}"
else
    echo "Extracting Module.symvers from installed kernel modules..."
    echo "  (This reads CRCs from every .ko file — may take a minute)"
    # modprobe --dump-modversions outputs: 0xCRC\tsymbol_name
    # Convert to Module.symvers format: 0xCRC\tsymbol\tmodule\tEXPORT_TYPE
    # The module field doesn't matter for modpost CRC validation.
    > "${MODULE_SYMVERS_FILE}"  # truncate
    FOUND_MODULES=0
    for ko in $(find "/lib/modules/${KERNEL_VERSION}/kernel" \
                     -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \
                     2>/dev/null); do
        modprobe --dump-modversions "$ko" 2>/dev/null | while IFS=$'\t' read -r crc sym; do
            # Clean whitespace from sym
            sym=$(echo "$sym" | tr -d ' \t')
            [ -n "$sym" ] && printf "%s\t%s\tvmlinux\tEXPORT_SYMBOL\n" "$crc" "$sym"
        done >> "${MODULE_SYMVERS_FILE}"
        FOUND_MODULES=$((FOUND_MODULES + 1))
    done
    # Remove duplicate symbol entries (keep first occurrence)
    if [ -s "${MODULE_SYMVERS_FILE}" ]; then
        sort -u -k2,2 "${MODULE_SYMVERS_FILE}" -o "${MODULE_SYMVERS_FILE}"
        SYMCOUNT=$(wc -l < "${MODULE_SYMVERS_FILE}")
        echo "  Extracted ${SYMCOUNT} unique symbol CRCs from ${FOUND_MODULES} modules"
    else
        echo -e "${YELLOW}WARNING: Could not extract any CRCs from kernel modules.${NC}"
        echo "  The build will proceed without Module.symvers."
        echo "  Module loading may fail on kernel 6.12+ due to relocation checks."
        MODULE_SYMVERS_FILE=""
    fi
fi

if [ -n "${MODULE_SYMVERS_FILE}" ] && [ -f "${MODULE_SYMVERS_FILE}" ]; then
    SYMCOUNT=$(wc -l < "${MODULE_SYMVERS_FILE}")
    echo "Module.symvers: ${SYMCOUNT} symbols"
fi

echo ""

# ── Build the Docker image ────────────────────────────────────────────────
echo ">>> Building Docker image (this downloads ~2GB and takes 10-30 min)..."
echo "    Use --no-cache to force a clean rebuild if packages changed."
echo ""

docker build \
    --no-cache \
    -f "${PROJECT_DIR}/Dockerfile.driver" \
    --build-arg "KERNEL_VERSION=${KERNEL_VERSION}" \
    --build-arg "TRUENAS_KERNEL_TAG=${TRUENAS_BRANCH}" \
    -t xdna-driver-builder \
    "${PROJECT_DIR}"

echo ""
echo ">>> Docker image built successfully."
echo ""

# ── Run the builder container ──────────────────────────────────────────────
echo ">>> Building XDNA driver inside container..."
echo ""

# Mount the extracted config file (or the output dir if no config)
CONFIG_MOUNT=""
if [ -n "${KERNEL_CONFIG_FILE}" ] && [ -f "${KERNEL_CONFIG_FILE}" ]; then
    CONFIG_MOUNT="-v ${KERNEL_CONFIG_FILE}:/host-config/kernel.config:ro"
fi

# Mount Module.symvers if we extracted it
SYMVERS_MOUNT=""
if [ -n "${MODULE_SYMVERS_FILE}" ] && [ -f "${MODULE_SYMVERS_FILE}" ]; then
    SYMVERS_MOUNT="-v ${MODULE_SYMVERS_FILE}:/host-config/Module.symvers:ro"
fi

docker run --rm \
    ${CONFIG_MOUNT} \
    ${SYMVERS_MOUNT} \
    -v /lib/modules:/host-modules:ro \
    -v "${OUTPUT_DIR}:/output" \
    -e "KERNEL_VERSION=${KERNEL_VERSION}" \
    xdna-driver-builder

echo ""

# ── Verify output ─────────────────────────────────────────────────────────
if [ ! -f "${OUTPUT_DIR}/modules/amdxdna.ko" ] && [ ! -f "${OUTPUT_DIR}/modules/amdxdna.ko.xz" ]; then
    echo -e "${RED}ERROR: Driver module not found in output!${NC}"
    echo "Check the build output above for errors."
    exit 1
fi

echo -e "${GREEN}Driver built successfully!${NC}"
echo ""
echo "Output: ${OUTPUT_DIR}/"
ls -la "${OUTPUT_DIR}/modules/" 2>/dev/null
echo ""

# ── Offer to load the driver ──────────────────────────────────────────────
echo "============================================="
echo " Ready to install the driver."
echo "============================================="
echo ""
echo "To load the driver now, run:"
echo ""
echo "  sudo bash ${OUTPUT_DIR}/load-driver.sh"
echo ""

# If running as root, ask if they want to load now
if [ "$(id -u)" -eq 0 ]; then
    echo -n "Load the driver now? [y/N] "
    read -r REPLY
    if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
        bash "${OUTPUT_DIR}/load-driver.sh"
    else
        echo ""
        echo "Skipped. Run the command above when ready."
    fi
fi

echo ""
echo "============================================="
echo " After the driver is loaded, start FastFlowLM-Docker:"
echo ""
echo "   cd ${PROJECT_DIR}"
echo "   cp .env.example .env"
echo "   docker compose build"
echo "   docker compose up -d"
echo "============================================="
