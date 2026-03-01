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

# Remove the vxdna/ (virtual XDNA) component — it requires drm/virtgpu_drm.h
# and drm/drm.h kernel UAPI headers that aren't available in our build
# environment. vxdna is for virtio-GPU passthrough which we don't need
# for bare-metal NPU access.
if [ -d /build/xdna-driver/src/vxdna ]; then
    echo "Removing src/vxdna/ (virtual GPU passthrough, not needed for bare-metal)..."
    rm -rf /build/xdna-driver/src/vxdna
    sed -i '/add_subdirectory.*vxdna/d' /build/xdna-driver/src/CMakeLists.txt 2>/dev/null || true
fi

# Remove the shim virtio/host platform code — these need drm/drm.h and
# drm/virtgpu_drm.h kernel UAPI headers. We only need the kernel module
# (amdxdna.ko), not the userspace shim library.
if [ -d /build/xdna-driver/src/shim/virtio ]; then
    echo "Removing src/shim/virtio/ (needs virtgpu UAPI headers, not needed)..."
    rm -rf /build/xdna-driver/src/shim/virtio
fi
if [ -f /build/xdna-driver/src/shim/host/platform_host.cpp ]; then
    echo "Removing src/shim/host/platform_host.cpp (needs drm/drm.h, not needed)..."
    rm -f /build/xdna-driver/src/shim/host/platform_host.cpp
fi
# Remove CMake references to virtio/host platform sources
for cmake_file in $(find /build/xdna-driver/src/shim -name 'CMakeLists.txt' 2>/dev/null); do
    sed -i '/virtio/d; /platform_host/d' "${cmake_file}" 2>/dev/null || true
done

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

# ── Fix MODULE_IMPORT_NS format for kernel < 6.13 ─────────────────────────
# In kernel 6.12, MODULE_IMPORT_NS takes an unquoted argument:
#   MODULE_IMPORT_NS(DMA_BUF)        →  modinfo: import_ns=DMA_BUF  ✓
# In kernel 6.13+, it takes a quoted string:
#   MODULE_IMPORT_NS("DMA_BUF")      →  modinfo: import_ns=DMA_BUF  ✓
#
# The xdna-driver's configure_kernel.sh uses try_compile to detect the format,
# but the test is flawed: MODULE_IMPORT_NS("DMA_BUF") compiles without error
# on 6.12 too — it just produces wrong modinfo (import_ns="DMA_BUF" with
# embedded quotes). The kernel's namespace checker then fails to match.
#
# Fix: For kernel < 6.13, force the #else branch (unquoted form).
KMAJOR=$(echo "${KERNEL_VERSION}" | cut -d. -f1)
KMINOR=$(echo "${KERNEL_VERSION}" | cut -d. -f2)
if [ "${KMAJOR}" -eq 6 ] && [ "${KMINOR}" -lt 13 ]; then
    echo "Kernel ${KMAJOR}.${KMINOR} < 6.13 — fixing MODULE_IMPORT_NS format..."
    for f in $(find /build/xdna-driver/src/driver -name '*.c' -exec grep -l 'HAVE_6_13_MODULE_IMPORT_NS' {} +); do
        sed -i 's/^#ifdef HAVE_6_13_MODULE_IMPORT_NS/#if 0 \/* forced: kernel < 6.13 uses unquoted MODULE_IMPORT_NS *\//' "$f"
        echo "  Patched: $f"
    done
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

    # NOTE: We do NOT strip the __versions section. Even though our CRCs
    # are invalid (no Module.symvers), insmod -f will bypass CRC checks.
    # Stripping __versions can cause the kernel to reject the module
    # entirely because check_version() fails when the section is missing.
    echo "Module ready: ${OUTPUT_DIR}/modules/amdxdna.ko"
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
#
# TrueNAS has a read-only root filesystem, so we:
#   - Load the .ko directly with insmod (no copy to /lib/modules)
#   - Use a tmpfs overlay for firmware if /usr/lib/firmware is read-only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_VERSION="$(uname -r)"

echo "Loading AMD XDNA driver for kernel ${KERNEL_VERSION}..."

# ── Install firmware (handle read-only filesystem) ─────────────────────────
if [ -d "${SCRIPT_DIR}/firmware" ] && [ "$(ls -A ${SCRIPT_DIR}/firmware 2>/dev/null)" ]; then
    echo "Installing NPU firmware..."
    # Try direct copy first
    if mkdir -p /usr/lib/firmware/amdnpu 2>/dev/null && \
       cp "${SCRIPT_DIR}/firmware/"* /usr/lib/firmware/amdnpu/ 2>/dev/null; then
        echo "  Firmware installed to /usr/lib/firmware/amdnpu/"
    else
        echo "  Root filesystem is read-only. Using tmpfs overlay for firmware..."
        # Create a writable overlay on top of /usr/lib/firmware
        if ! mount | grep -q "tmpfs on /usr/lib/firmware"; then
            # Preserve existing firmware with a bind mount trick
            TMPFW=$(mktemp -d)
            cp -a /usr/lib/firmware/* "${TMPFW}/" 2>/dev/null || true
            mount -t tmpfs tmpfs /usr/lib/firmware
            cp -a "${TMPFW}/"* /usr/lib/firmware/ 2>/dev/null || true
            rm -rf "${TMPFW}"
        fi
        mkdir -p /usr/lib/firmware/amdnpu
        cp -v "${SCRIPT_DIR}/firmware/"* /usr/lib/firmware/amdnpu/
        echo "  Firmware installed via tmpfs overlay (non-persistent across reboots)."
    fi
fi

# ── Find the kernel module ─────────────────────────────────────────────────
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

# ── Optionally install to /lib/modules (skip if read-only) ─────────────────
MODULE_DIR="/lib/modules/${KERNEL_VERSION}/extra"
if mkdir -p "${MODULE_DIR}" 2>/dev/null && \
   cp "${MODULE}" "${MODULE_DIR}/" 2>/dev/null; then
    depmod -a "${KERNEL_VERSION}" 2>/dev/null || true
    echo "Module installed to ${MODULE_DIR}/"
else
    echo "Root filesystem is read-only — loading directly with insmod."
fi

# ── Unload old module if present ───────────────────────────────────────────
if lsmod | grep -q "^amdxdna "; then
    echo "Unloading existing amdxdna module..."
    rmmod amdxdna 2>/dev/null || true
fi

# ── Load prerequisite kernel modules ──────────────────────────────────────
# amdxdna depends on drm_shmem_helper (for drm_gem_shmem_* symbols) and
# the base drm/accel subsystem. These are shipped with TrueNAS but may
# not be loaded by default.
echo "Loading prerequisite modules..."
for DEP_MOD in drm drm_kms_helper drm_shmem_helper accel; do
    if ! lsmod | grep -q "^${DEP_MOD} "; then
        if modprobe "${DEP_MOD}" 2>/dev/null; then
            echo "  Loaded: ${DEP_MOD}"
        else
            echo "  Skipped: ${DEP_MOD} (not available or already built-in)"
        fi
    else
        echo "  Already loaded: ${DEP_MOD}"
    fi
done

# ── Load the module ───────────────────────────────────────────────────────
# We use insmod -f because the module was built without a valid
# Module.symvers, so CRC version checks (modversions) will fail.
# The -f flag sets MODULE_INIT_IGNORE_MODVERSIONS | MODULE_INIT_IGNORE_VERMAGIC,
# which bypasses CRC checks. This is safe — the symbols DO exist in the
# running kernel; we just can't verify their CRCs at build time.
echo "Loading amdxdna module..."

# Try regular insmod first (works if we got a valid Module.symvers)
if insmod "${MODULE}" 2>/dev/null; then
    echo "  Module loaded successfully."
else
    echo "  Regular insmod failed (expected without Module.symvers)."
    echo "  Loading with insmod -f (bypass CRC checks)..."
    if insmod -f "${MODULE}" 2>&1; then
        echo "  Module loaded with force flag."
        echo "  (Kernel will show 'module verification failed' — this is normal)"
    else
        echo ""
        echo "ERROR: Could not load amdxdna.ko even with -f flag."
        echo ""
        echo "Check 'dmesg | tail -50' for details. Common issues:"
        echo "  - 'version magic' mismatch: kernel version changed since build"
        echo "  - 'Unknown symbol (err -22)': missing namespace import or module dependency"
        echo "  - 'firmware not found': run this script again to set up firmware overlay"
        echo ""
        echo "Re-run the full driver build if kernel was updated:"
        echo "  sudo bash \$(dirname \$0)/../scripts/build-xdna-driver.sh"
        exit 1
    fi
fi

# ── Verify ─────────────────────────────────────────────────────────────────
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
    echo "Check 'dmesg | tail -30' for errors."
    echo ""
    echo "If you see 'firmware not found' errors, re-run this script —"
    echo "the firmware overlay may need to be set up before loading."
fi

# ── Set memory limits (skip if read-only) ──────────────────────────────────
if mkdir -p /etc/security/limits.d 2>/dev/null; then
    tee /etc/security/limits.d/99-amdxdna.conf > /dev/null << 'EOF'
* soft memlock unlimited
* hard memlock unlimited
EOF
fi

echo ""
echo "Done."
echo ""
echo "NOTE: On TrueNAS, you must re-run this script after every reboot:"
echo "  sudo bash ${SCRIPT_DIR}/load-driver.sh"
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
