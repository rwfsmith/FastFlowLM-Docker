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
# 1. Pre-extracted config at /host-config/kernel.config (from build-xdna-driver.sh)
# 2. Mounted /host-config/config.gz
# 3. Mounted /host-proc/config.gz
# 4. Fall back to defconfig + TrueNAS options

CONFIG_FOUND=false

if [ -f /host-config/kernel.config ]; then
    echo "Using pre-extracted kernel config from /host-config/kernel.config"
    cp /host-config/kernel.config .config
    CONFIG_FOUND=true
elif [ -f /host-config/config.gz ]; then
    echo "Using kernel config from /host-config/config.gz"
    zcat /host-config/config.gz > .config
    CONFIG_FOUND=true
elif [ -f /host-proc/config.gz ]; then
    echo "Using kernel config from /host-proc/config.gz"
    zcat /host-proc/config.gz > .config
    CONFIG_FOUND=true
fi

if [ "$CONFIG_FOUND" = false ]; then
    echo "WARNING: No host kernel config found. Using defconfig + TrueNAS options."
    make defconfig
fi

# ── Ensure TrueNAS-specific config options are set ─────────────────────────
# The TrueNAS kernel source has #if CONFIG_TRUENAS guards that cause
# -Werror=undef failures if this isn't defined.
if ! grep -q "^CONFIG_TRUENAS=y" .config 2>/dev/null; then
    echo "CONFIG_TRUENAS=y" >> .config
    echo "  Added CONFIG_TRUENAS=y"
fi

# Ensure DRM_ACCEL is enabled (required for XDNA)
if ! grep -q "^CONFIG_DRM_ACCEL=y" .config 2>/dev/null; then
    echo "CONFIG_DRM_ACCEL=y" >> .config
    echo "  Added CONFIG_DRM_ACCEL=y"
fi

# ── Prepare the source tree for external module builds ─────────────────────
make olddefconfig

# Build with relaxed warnings — TrueNAS kernel source may have custom
# preprocessor guards that trigger -Werror=undef with mismatched configs
make KCFLAGS="-Wno-error=undef" modules_prepare

# ── Module.symvers — required for out-of-tree module builds ────────────────
# Without Module.symvers, modpost can't resolve kernel symbols (drm_ioctl, etc.)
# Priority:
#   1. From the host at /host-modules/<version>/build/Module.symvers
#   2. From the host at /host-modules/<version>/Module.symvers
#   3. Generate by building the full kernel (slow but correct)

SYMVERS_FOUND=false

# Check host-mounted /lib/modules
for SYMPATH in \
    "/host-modules/${KERNEL_VERSION}/build/Module.symvers" \
    "/host-modules/${KERNEL_VERSION}/Module.symvers" \
    "/host-modules/${KERNEL_VERSION}/symvers.gz"; do
    if [ -f "${SYMPATH}" ]; then
        echo "Found Module.symvers from host: ${SYMPATH}"
        if [[ "${SYMPATH}" == *.gz ]]; then
            zcat "${SYMPATH}" > "${KERNEL_SRC}/Module.symvers"
        else
            cp "${SYMPATH}" "${KERNEL_SRC}/Module.symvers"
        fi
        SYMVERS_FOUND=true
        break
    fi
done

if [ "$SYMVERS_FOUND" = false ]; then
    echo ""
    echo "=== Module.symvers not found on host ==="
    echo "Building the kernel to generate Module.symvers..."
    echo "This will take 20-60 minutes but only needs to happen once."
    echo ""
    # Build vmlinux + in-tree modules to generate Module.symvers
    # -j uses all available CPUs to speed this up
    make KCFLAGS="-Wno-error=undef" -j"$(nproc)" || {
        echo ""
        echo "WARNING: Full kernel build failed."
        echo "Attempting module build with KBUILD_MODPOST_WARN=1 (fallback)."
        echo "The driver module will be built but may need 'insmod --force' to load."
        touch "${KERNEL_SRC}/Module.symvers"
    }
fi

SYMVERS_COUNT=$(wc -l < "${KERNEL_SRC}/Module.symvers" 2>/dev/null || echo 0)
echo "Module.symvers: ${SYMVERS_COUNT} symbols"

# Create the expected symlink for module builds
HEADERS_DIR="/lib/modules/${KERNEL_VERSION}"
mkdir -p "${HEADERS_DIR}"
ln -sf "${KERNEL_SRC}" "${HEADERS_DIR}/build"
ln -sf "${KERNEL_SRC}" "${HEADERS_DIR}/source"

echo "=== Kernel headers ready at ${KERNEL_SRC} ==="
echo "=== Module build dir linked at ${HEADERS_DIR}/build ==="
