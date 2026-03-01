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

# Disable CONFIG_MODVERSIONS — we MUST build without it.
# The running kernel has modversions enabled, but we don't have Module.symvers
# so the build generates CRC stubs. When these get partially linked (ld -r),
# the CRC relocations get pre-resolved, leaving non-zero values at relocation
# targets. Kernel 6.12+ rejects this with:
#   "Invalid relocation target, existing value is nonzero for type 1"
#
# Building without modversions means no CRC symbols, no bad relocations.
# The vermagic won't include "modversions" but insmod -f bypasses BOTH
# vermagic and modversions checks, so this is fine.
sed -i 's/^CONFIG_MODVERSIONS=y/# CONFIG_MODVERSIONS is not set/' .config 2>/dev/null || true
sed -i '/^# CONFIG_MODVERSIONS is not set$/!{/CONFIG_MODVERSIONS/d}' .config 2>/dev/null || true
if ! grep -q 'CONFIG_MODVERSIONS' .config 2>/dev/null; then
    echo '# CONFIG_MODVERSIONS is not set' >> .config
fi
# Also disable ASM_MODVERSIONS which depends on MODVERSIONS
sed -i 's/^CONFIG_ASM_MODVERSIONS=y/# CONFIG_ASM_MODVERSIONS is not set/' .config 2>/dev/null || true
echo "  CONFIG_MODVERSIONS=n (avoids invalid relocations without Module.symvers)"

# ── Prepare the source tree for external module builds ─────────────────────
echo ""
echo "=== Forcing kernel version to match running kernel ==="

# The source tree might produce a different version string than the running
# kernel (e.g. 6.12.43 vs 6.12.33). We MUST match exactly or insmod will
# reject the module with 'version magic' mismatch.
#
# Kernel version string = KERNELVERSION + setlocalversion output
# KERNELVERSION = VERSION.PATCHLEVEL.SUBLEVEL + EXTRAVERSION  (from Makefile)
# setlocalversion reads localversion* files and adds SCM (git) suffix.
#
# Strategy: Put the ENTIRE local version suffix into EXTRAVERSION in the
# Makefile. This is always used for KERNELVERSION, with no dependency on
# setlocalversion or localversion files. Then replace setlocalversion with
# a no-op so it can't add SCM suffixes. This way, even when the XDNA build
# regenerates utsrelease.h via `make M=... modules`, the correct version
# is produced from the Makefile alone.

RUNNING_MAJOR=$(echo "${KERNEL_VERSION}" | cut -d. -f1)
RUNNING_MINOR=$(echo "${KERNEL_VERSION}" | cut -d. -f2)
# Extract sublevel (e.g., "33" from "6.12.33-production+truenas")
RUNNING_SUBLEVEL=$(echo "${KERNEL_VERSION}" | cut -d. -f3 | sed 's/-.*//')
# Extract localversion suffix (e.g., "-production+truenas" from "6.12.33-production+truenas")
RUNNING_LOCALVER=$(echo "${KERNEL_VERSION}" | sed "s/^${RUNNING_MAJOR}\.${RUNNING_MINOR}\.${RUNNING_SUBLEVEL}//")

echo "  Target: VERSION=${RUNNING_MAJOR} PATCHLEVEL=${RUNNING_MINOR} SUBLEVEL=${RUNNING_SUBLEVEL}"
echo "  Target EXTRAVERSION: '${RUNNING_LOCALVER}'"

# Patch the top-level Makefile to match running kernel version.
# Put the local version suffix (e.g. -production+truenas) in EXTRAVERSION
# so that KERNELVERSION = 6.12.33-production+truenas entirely from the Makefile.
sed -i "s/^VERSION = .*/VERSION = ${RUNNING_MAJOR}/" Makefile
sed -i "s/^PATCHLEVEL = .*/PATCHLEVEL = ${RUNNING_MINOR}/" Makefile
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = ${RUNNING_SUBLEVEL}/" Makefile
sed -i "s/^EXTRAVERSION = .*/EXTRAVERSION = ${RUNNING_LOCALVER}/" Makefile

# Remove ALL localversion* files — they would double-append the suffix
# since we already have it in EXTRAVERSION.
rm -f "${KERNEL_SRC}"/localversion*
# Do NOT create a new localversion file — EXTRAVERSION handles everything.

# Prevent setlocalversion from adding SCM (git) suffixes:
#   1. Remove .git so it can't detect git at all
#   2. Replace scripts/setlocalversion with a no-op
#   3. Create .scmversion as additional guard
#   4. Disable CONFIG_LOCALVERSION_AUTO in .config
rm -rf "${KERNEL_SRC}/.git"
printf '#!/bin/sh\ntrue\n' > "${KERNEL_SRC}/scripts/setlocalversion"
chmod +x "${KERNEL_SRC}/scripts/setlocalversion"
touch "${KERNEL_SRC}/.scmversion"
echo "  Replaced scripts/setlocalversion with no-op"
# Disable CONFIG_LOCALVERSION_AUTO
sed -i '/CONFIG_LOCALVERSION_AUTO/d' .config 2>/dev/null || true
echo "# CONFIG_LOCALVERSION_AUTO is not set" >> .config
# Clear CONFIG_LOCALVERSION so it doesn't append anything extra
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=""/' .config 2>/dev/null || true

# Verify Makefile
echo "  Source Makefile version fields:"
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' Makefile | head -4 | sed 's/^/    /'

make olddefconfig

# Verify CONFIG_LOCALVERSION_AUTO is actually off after olddefconfig
# (olddefconfig may re-enable it since it defaults to y)
if grep -q "^CONFIG_LOCALVERSION_AUTO=y" .config 2>/dev/null; then
    echo "  WARNING: olddefconfig re-enabled CONFIG_LOCALVERSION_AUTO — forcing off again"
    sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' .config
fi

# Build with relaxed warnings — TrueNAS kernel source may have custom
# preprocessor guards that trigger -Werror=undef with mismatched configs
make KCFLAGS="-Wno-error=undef" modules_prepare

# ── Verify and force-correct the version string ───────────────────────────
# The EXTRAVERSION approach above should produce the right version. Verify it,
# and force-write as a safety net. Note: the XDNA build's `make M=... modules`
# will regenerate utsrelease.h from the Makefile, so EXTRAVERSION must be
# correct (the force-write here is just for verification/modules_prepare output).
BUILT_UTS=$(cat include/generated/utsrelease.h 2>/dev/null | grep UTS_RELEASE | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
echo ""
echo "  Built UTS_RELEASE: ${BUILT_UTS}"
echo "  Running kernel:    ${KERNEL_VERSION}"
if [ "${BUILT_UTS}" = "${KERNEL_VERSION}" ]; then
    echo "  VERSION MATCH: YES"
else
    echo "  WARNING: modules_prepare produced '${BUILT_UTS}' instead of '${KERNEL_VERSION}'"
    echo "  Force-writing correct UTS_RELEASE..."
    mkdir -p include/generated include/config
    echo "#define UTS_RELEASE \"${KERNEL_VERSION}\"" > include/generated/utsrelease.h
    echo "${KERNEL_VERSION}" > include/config/kernel.release
    echo "  (Note: XDNA build may regenerate this — check EXTRAVERSION in Makefile if vermagic is still wrong)"
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
