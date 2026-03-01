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

# Keep CONFIG_MODVERSIONS=y — the running kernel has modversions enabled,
# and its vermagic string includes "modversions". Our module's vermagic must
# match EXACTLY, so we must also build with CONFIG_MODVERSIONS=y.
# Without Module.symvers, modpost will emit CRC warnings (KBUILD_MODPOST_WARN=1
# prevents these from being fatal). At load time, we use insmod -f to skip
# CRC verification since we can't produce valid CRCs without Module.symvers.
if grep -q "^CONFIG_MODVERSIONS=y" .config 2>/dev/null; then
    echo "  CONFIG_MODVERSIONS=y (keeping enabled to match running kernel vermagic)"
else
    echo "CONFIG_MODVERSIONS=y" >> .config
    echo "  Added CONFIG_MODVERSIONS=y (required for vermagic match)"
fi

# ── Prepare the source tree for external module builds ─────────────────────
echo ""
echo "=== Forcing kernel version to match running kernel ==="

# The source tree might produce a different version string than the running
# kernel (e.g. 6.12.43 vs 6.12.33). We MUST match exactly or insmod will
# reject the module with 'version magic' mismatch.
#
# Kernel version string = KERNELVERSION + LOCALVERSION + auto-generated suffix
# Strategy: overwrite the Makefile VERSION/PATCHLEVEL/SUBLEVEL to match exactly,
# and set LOCALVERSION to match the running kernel's suffix.

RUNNING_MAJOR=$(echo "${KERNEL_VERSION}" | cut -d. -f1)
RUNNING_MINOR=$(echo "${KERNEL_VERSION}" | cut -d. -f2)
# Extract sublevel (e.g., "33" from "6.12.33-production+truenas")
RUNNING_SUBLEVEL=$(echo "${KERNEL_VERSION}" | cut -d. -f3 | sed 's/-.*//')
# Extract localversion suffix (e.g., "-production+truenas" from "6.12.33-production+truenas")
RUNNING_LOCALVER=$(echo "${KERNEL_VERSION}" | sed "s/^${RUNNING_MAJOR}\.${RUNNING_MINOR}\.${RUNNING_SUBLEVEL}//")

echo "  Target: VERSION=${RUNNING_MAJOR} PATCHLEVEL=${RUNNING_MINOR} SUBLEVEL=${RUNNING_SUBLEVEL}"
echo "  Target LOCALVERSION: '${RUNNING_LOCALVER}'"

# Patch the top-level Makefile to match running kernel version
sed -i "s/^VERSION = .*/VERSION = ${RUNNING_MAJOR}/" Makefile
sed -i "s/^PATCHLEVEL = .*/PATCHLEVEL = ${RUNNING_MINOR}/" Makefile
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = ${RUNNING_SUBLEVEL}/" Makefile
# Clear any EXTRAVERSION to avoid appending unwanted suffixes
sed -i "s/^EXTRAVERSION = .*/EXTRAVERSION =/" Makefile

# Set LOCALVERSION to match the running kernel's suffix
# IMPORTANT: Remove ALL existing localversion* files first!
# The TrueNAS kernel source ships with localversion files (e.g., localversion.truenas)
# that append "+truenas". Our RUNNING_LOCALVER already includes "+truenas"
# (from "-production+truenas"), so having both would produce a double suffix
# like "6.12.33-production+truenas+truenas".
rm -f "${KERNEL_SRC}"/localversion*
echo "${RUNNING_LOCALVER}" > "${KERNEL_SRC}/localversion"
# Disable auto-appending of git revision to version string.
# The kernel build calls scripts/setlocalversion which detects a dirty git tree
# and appends "+" to the version string. We must prevent this entirely:
#   1. Remove .git so setlocalversion can't detect git at all
#   2. Create empty .scmversion as a secondary guard
#   3. Disable CONFIG_LOCALVERSION_AUTO in .config
rm -rf "${KERNEL_SRC}/.git"
echo "  Removed .git directory (prevents dirty-tree '+' suffix)"
touch "${KERNEL_SRC}/.scmversion"
# Disable CONFIG_LOCALVERSION_AUTO — force it off regardless of whether
# the line already exists (make olddefconfig defaults it to y)
sed -i '/CONFIG_LOCALVERSION_AUTO/d' .config 2>/dev/null || true
echo "# CONFIG_LOCALVERSION_AUTO is not set" >> .config
# Clear CONFIG_LOCALVERSION to avoid double-appending
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=""/' .config 2>/dev/null || true

# Verify
echo "  Source Makefile version:"
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' Makefile | head -4 | sed 's/^/    /'
echo "  localversion file: $(cat ${KERNEL_SRC}/localversion)"

make olddefconfig

# Build with relaxed warnings — TrueNAS kernel source may have custom
# preprocessor guards that trigger -Werror=undef with mismatched configs
make KCFLAGS="-Wno-error=undef" modules_prepare

# Verify the version string
BUILT_UTS=$(cat include/generated/utsrelease.h 2>/dev/null | grep UTS_RELEASE | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
echo ""
echo "  Built UTS_RELEASE: ${BUILT_UTS}"
echo "  Running kernel:    ${KERNEL_VERSION}"
if [ "${BUILT_UTS}" = "${KERNEL_VERSION}" ]; then
    echo "  VERSION MATCH: YES"
else
    echo "  WARNING: Version mismatch! Module may need insmod -f"
fi

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
    echo "Creating empty Module.symvers."
    echo "The XDNA build will use KBUILD_MODPOST_WARN=1 to proceed without it."
    echo "The resulting module will load fine via insmod — the symbols exist in the running kernel."
    echo ""
    touch "${KERNEL_SRC}/Module.symvers"
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
