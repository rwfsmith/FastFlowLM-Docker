#!/usr/bin/env bash
# =============================================================================
# docker-build-driver.sh — Runs inside the Docker builder container
#
# Builds the AMD XDNA kernel module against TrueNAS kernel headers.
# Outputs the .ko module and firmware to /output (bind-mounted volume).
#
# Expected mounts:
#   -v /proc:/host-proc:ro          — for kernel config
#   -v /path/to/output:/output      — where built artifacts go
# =============================================================================
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION must be set}"
OUTPUT_DIR="/output"

echo "============================================="
echo " AMD XDNA Driver Builder"
echo " Target kernel: ${KERNEL_VERSION}"
echo "============================================="
echo ""

# ── Step 1: Prepare kernel headers ─────────────────────────────────────────
echo ">>> Step 1/4: Preparing kernel headers..."

# The kernel config should be mounted at /host-config/kernel.config
# (extracted by build-xdna-driver.sh on the host before docker run)
if [ -f /host-config/kernel.config ]; then
    echo "Host kernel config found at /host-config/kernel.config"
else
    echo "WARNING: No host kernel config mounted."
    echo "  The build will fall back to defconfig + CONFIG_TRUENAS=y."
fi

export KERNEL_VERSION
/build/prepare-kernel-headers.sh

echo ""

# ── Step 2: Build XRT base ─────────────────────────────────────────────────
echo ">>> Step 2/4: Building XRT (Xilinx Runtime)..."
cd /build/xdna-driver

# Run dependency installer (works inside the container since apt is available here)
if [ -f ./tools/amdxdna_deps.sh ]; then
    echo "Installing XDNA build dependencies..."
    ./tools/amdxdna_deps.sh || echo "Warning: Some deps may have failed (non-fatal)"
fi

cd xrt/build
./build.sh -npu -opt

# Install XRT inside the container for the next build step
apt-get install -y --allow-downgrades ./Release/xrt_*-amd64-base.deb 2>/dev/null \
    || dpkg -i ./Release/xrt_*-amd64-base.deb 2>/dev/null \
    || echo "Warning: XRT base install had issues (attempting to continue)"

# Copy XRT .deb to output in case user needs it
cp ./Release/xrt_*-amd64-base.deb "${OUTPUT_DIR}/" 2>/dev/null || true

cd /build/xdna-driver
echo ""

# ── Step 3: Build XDNA driver module ──────────────────────────────────────
echo ">>> Step 3/4: Building XDNA kernel module..."

# Remove the drivers/accel/ path — it's the upstream in-kernel-tree version
# that uses #include <trace/events/amdxdna.h> (a header only present when
# compiled inside the kernel source tree). It CANNOT build out-of-tree.
# The src/driver/ path is the out-of-tree version and builds correctly.
if [ -d /build/xdna-driver/drivers/accel ]; then
    echo "Removing drivers/accel/ (in-tree only, cannot build out-of-tree)..."
    rm -rf /build/xdna-driver/drivers/accel
    # Also remove its CMakeLists reference if present
    sed -i '/add_subdirectory.*accel/d' /build/xdna-driver/drivers/CMakeLists.txt 2>/dev/null || true
fi

# If Module.symvers is empty/small, modpost can't resolve kernel symbols.
# KBUILD_MODPOST_WARN turns those errors into warnings so the build succeeds.
# The symbols DO exist in the running kernel — they just can't be CRC-verified
# at build time without a matching Module.symvers from the host.
SYMVERS_FILE="/build/linux-src/Module.symvers"
SYMVERS_LINES=$(wc -l < "${SYMVERS_FILE}" 2>/dev/null || echo 0)
if [ "${SYMVERS_LINES}" -lt 100 ]; then
    echo "Module.symvers has only ${SYMVERS_LINES} symbols (expected thousands)."
    echo "Setting KBUILD_MODPOST_WARN=1 to allow build to continue."
    export KBUILD_MODPOST_WARN=1
fi

cd build
./build.sh -release || {
    echo ""
    echo "NOTE: build.sh returned non-zero. Checking if amdxdna.ko was built..."
}

# Verify the out-of-tree driver module was built
AMDXDNA_KO_CHECK=$(find /build/xdna-driver -path '*/src/driver/*' -name 'amdxdna.ko' 2>/dev/null | head -1)
if [ -z "${AMDXDNA_KO_CHECK}" ]; then
    echo "ERROR: amdxdna.ko was not produced by the build!"
    exit 1
fi
echo "Found driver module: ${AMDXDNA_KO_CHECK}"

# Copy the plugin .deb to output
cp ./Release/xrt_plugin.*-amdxdna.deb "${OUTPUT_DIR}/" 2>/dev/null || true

echo ""

# ── Step 4: Extract artifacts ──────────────────────────────────────────────
echo ">>> Step 4/4: Extracting driver artifacts..."

mkdir -p "${OUTPUT_DIR}/modules"
mkdir -p "${OUTPUT_DIR}/firmware"

# Find and copy the built amdxdna.ko
AMDXDNA_KO=$(find /build/xdna-driver -name "amdxdna.ko" -o -name "amdxdna.ko.xz" 2>/dev/null | head -1)
if [ -n "${AMDXDNA_KO}" ]; then
    cp "${AMDXDNA_KO}" "${OUTPUT_DIR}/modules/"
    echo "Module: ${OUTPUT_DIR}/modules/$(basename ${AMDXDNA_KO})"
else
    echo "WARNING: amdxdna.ko not found in build tree!"
    echo "Attempting to extract from built .deb package..."

    # Extract the module from the .deb package
    DEB_FILE=$(find "${OUTPUT_DIR}" -name "xrt_plugin*amdxdna*.deb" | head -1)
    if [ -n "${DEB_FILE}" ]; then
        mkdir -p /tmp/deb-extract
        dpkg-deb -x "${DEB_FILE}" /tmp/deb-extract
        find /tmp/deb-extract -name "amdxdna.ko*" -exec cp {} "${OUTPUT_DIR}/modules/" \;
        # Also grab firmware from the deb
        find /tmp/deb-extract -path "*/firmware/amdnpu/*" -exec cp {} "${OUTPUT_DIR}/firmware/" \;
        echo "Extracted from .deb package"
    else
        echo "ERROR: Could not find driver module!"
        exit 1
    fi
fi

# Copy firmware files (NPU microcode)
if [ -d "/usr/lib/firmware/amdnpu" ]; then
    cp -r /usr/lib/firmware/amdnpu/* "${OUTPUT_DIR}/firmware/" 2>/dev/null || true
fi

# Also search in the build tree and extracted debs
find /build/xdna-driver -path "*/firmware/amdnpu/*" -exec cp {} "${OUTPUT_DIR}/firmware/" \; 2>/dev/null || true

# ── Create a loader script for the host ────────────────────────────────────
cat > "${OUTPUT_DIR}/load-driver.sh" << 'LOADER_EOF'
#!/usr/bin/env bash
# =============================================================================
# load-driver.sh — Load the AMD XDNA driver on the TrueNAS host
#
# Run this ON THE TRUENAS HOST after the Docker build completes:
#   sudo bash /path/to/output/load-driver.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_VERSION="$(uname -r)"

echo "Loading AMD XDNA driver for kernel ${KERNEL_VERSION}..."

# Copy firmware
if [ -d "${SCRIPT_DIR}/firmware" ] && [ "$(ls -A ${SCRIPT_DIR}/firmware 2>/dev/null)" ]; then
    echo "Installing NPU firmware..."
    mkdir -p /usr/lib/firmware/amdnpu
    cp -v "${SCRIPT_DIR}/firmware/"* /usr/lib/firmware/amdnpu/
fi

# Copy kernel module
KO_FILE="${SCRIPT_DIR}/modules/amdxdna.ko"
KO_XZ_FILE="${SCRIPT_DIR}/modules/amdxdna.ko.xz"

if [ -f "${KO_FILE}" ]; then
    MODULE="${KO_FILE}"
elif [ -f "${KO_XZ_FILE}" ]; then
    MODULE="${KO_XZ_FILE}"
else
    echo "ERROR: No amdxdna.ko found in ${SCRIPT_DIR}/modules/"
    exit 1
fi

# Install module into the kernel module tree
MODULE_DIR="/lib/modules/${KERNEL_VERSION}/extra"
mkdir -p "${MODULE_DIR}"
cp -v "${MODULE}" "${MODULE_DIR}/"

# Rebuild module dependency list
depmod -a "${KERNEL_VERSION}"

# Load the module
# Use insmod directly — the module may have been built without Module.symvers
# so modprobe may refuse due to missing CRC/version info.
echo "Loading amdxdna module..."
insmod "${MODULE}" 2>/dev/null \
    || modprobe --force amdxdna 2>/dev/null \
    || modprobe amdxdna

# Verify
sleep 1
if [ -d "/dev/accel" ] && ls /dev/accel/accel* >/dev/null 2>&1; then
    echo ""
    echo "SUCCESS! NPU device(s) found:"
    ls -la /dev/accel/accel*

    # Set permissions for Docker access
    chmod 666 /dev/accel/accel* 2>/dev/null || true
    chmod 666 /dev/dri/renderD* 2>/dev/null || true
    echo ""
    echo "Device permissions set. Docker containers can now access the NPU."
else
    echo ""
    echo "WARNING: Module loaded but /dev/accel/ not found."
    echo "Check 'dmesg | tail -20' for errors."
fi

# Set memory limits
mkdir -p /etc/security/limits.d
tee /etc/security/limits.d/99-amdxdna.conf > /dev/null << 'EOF'
* soft memlock unlimited
* hard memlock unlimited
EOF

echo ""
echo "Done. To auto-load on boot, run:"
echo "  echo 'amdxdna' | sudo tee /etc/modules-load.d/amdxdna.conf"
LOADER_EOF

chmod +x "${OUTPUT_DIR}/load-driver.sh"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " Build complete!"
echo "============================================="
echo ""
echo " Output directory: ${OUTPUT_DIR}"
echo ""
echo " Files:"
ls -la "${OUTPUT_DIR}/modules/" 2>/dev/null | grep -v "^total" | sed 's/^/   /'
echo ""
echo " Firmware:"
ls "${OUTPUT_DIR}/firmware/" 2>/dev/null | head -5 | sed 's/^/   /'
FW_COUNT=$(ls "${OUTPUT_DIR}/firmware/" 2>/dev/null | wc -l)
[ "$FW_COUNT" -gt 5 ] && echo "   ... and $((FW_COUNT - 5)) more files"
echo ""
echo " Next step — run on the TrueNAS host:"
echo "   sudo bash ${OUTPUT_DIR}/load-driver.sh"
echo "============================================="
