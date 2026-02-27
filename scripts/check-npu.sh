#!/usr/bin/env bash
# =============================================================================
# check-npu.sh — Diagnostic script for AMD NPU on TrueNAS Scale
#
# Run this on the TrueNAS host to check if the NPU is accessible
# and ready for FastFlowLM-Docker.
#
# Usage: sudo bash scripts/check-npu.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
info()  { echo -e "  [INFO] $1"; }

echo "============================================="
echo " AMD NPU Diagnostic Check"
echo " For TrueNAS Scale + FastFlowLM-Docker"
echo "============================================="
echo ""

ERRORS=0

# ── 1. Check kernel version ────────────────────────────────────────────────
echo "1. Kernel Version"
KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)

info "Kernel: $KVER"

if [ "$KMAJOR" -gt 6 ] || ([ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -ge 10 ]); then
    pass "Kernel >= 6.10 (required for XDNA driver)"
else
    fail "Kernel $KVER is too old. Need >= 6.10 for XDNA driver support."
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 2. Check for NPU hardware ──────────────────────────────────────────────
echo "2. NPU Hardware Detection"
NPU_PCI=$(lspci 2>/dev/null | grep -i "neural\|xdna\|amdnpu" || true)

if [ -n "$NPU_PCI" ]; then
    pass "NPU hardware detected:"
    echo "       $NPU_PCI"
else
    fail "No AMD NPU hardware found in lspci output."
    info "This machine may not have a Ryzen AI processor with XDNA2 NPU."
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 3. Check kernel config for DRM_ACCEL ───────────────────────────────────
echo "3. Kernel Configuration"
DRM_ACCEL=""

# Try /proc/config.gz first (common on TrueNAS)
if [ -f /proc/config.gz ]; then
    DRM_ACCEL=$(zcat /proc/config.gz 2>/dev/null | grep "CONFIG_DRM_ACCEL" || true)
elif [ -f "/boot/config-$KVER" ]; then
    DRM_ACCEL=$(grep "CONFIG_DRM_ACCEL" "/boot/config-$KVER" || true)
fi

if echo "$DRM_ACCEL" | grep -q "CONFIG_DRM_ACCEL=y"; then
    pass "CONFIG_DRM_ACCEL=y (required for /dev/accel/)"
elif echo "$DRM_ACCEL" | grep -q "CONFIG_DRM_ACCEL=m"; then
    warn "CONFIG_DRM_ACCEL=m (module). Run: sudo modprobe drm_accel"
else
    fail "CONFIG_DRM_ACCEL not found or not enabled."
    info "The kernel must be compiled with CONFIG_DRM_ACCEL=y"
    ERRORS=$((ERRORS + 1))
fi

# Check AMD_IOMMU
AMD_IOMMU=""
if [ -f /proc/config.gz ]; then
    AMD_IOMMU=$(zcat /proc/config.gz 2>/dev/null | grep "CONFIG_AMD_IOMMU=" || true)
elif [ -f "/boot/config-$KVER" ]; then
    AMD_IOMMU=$(grep "CONFIG_AMD_IOMMU=" "/boot/config-$KVER" || true)
fi

if echo "$AMD_IOMMU" | grep -q "CONFIG_AMD_IOMMU=y"; then
    pass "CONFIG_AMD_IOMMU=y"
else
    warn "CONFIG_AMD_IOMMU not confirmed. May cause issues."
fi
echo ""

# ── 4. Check XDNA driver module ───────────────────────────────────────────
echo "4. XDNA Driver Module"
if lsmod 2>/dev/null | grep -q "amdxdna"; then
    pass "amdxdna module is loaded"
else
    fail "amdxdna module is NOT loaded"
    info "Try: sudo modprobe amdxdna"
    info "If that fails, build the driver via Docker:"
    info "  sudo bash scripts/build-xdna-driver.sh"
    info "  sudo bash xdna-driver-output/load-driver.sh"
    ERRORS=$((ERRORS + 1))
fi

# Check if the module file exists
MODPATH=$(find /lib/modules/"$KVER" -name "amdxdna.ko*" 2>/dev/null | head -1)
if [ -n "$MODPATH" ]; then
    pass "Driver module found: $MODPATH"
else
    fail "amdxdna.ko not found in /lib/modules/$KVER/"
    info "Build the driver: sudo bash scripts/build-xdna-driver.sh"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 5. Check /dev/accel/ ──────────────────────────────────────────────────
echo "5. NPU Device Node"
if [ -d "/dev/accel" ] && ls /dev/accel/accel* >/dev/null 2>&1; then
    pass "/dev/accel/ exists with device nodes:"
    ls -la /dev/accel/accel* | sed 's/^/       /'
else
    fail "/dev/accel/ does not exist or has no accel* devices"
    info "Once the amdxdna module is loaded, /dev/accel/accel0 should appear"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 6. Check /dev/dri/ ────────────────────────────────────────────────────
echo "6. DRI Device Nodes"
if [ -d "/dev/dri" ]; then
    pass "/dev/dri/ exists:"
    ls -la /dev/dri/ | sed 's/^/       /'
else
    warn "/dev/dri/ not found"
fi
echo ""

# ── 7. Check firmware ─────────────────────────────────────────────────────
echo "7. NPU Firmware"
if [ -d "/usr/lib/firmware/amdnpu" ]; then
    FW_COUNT=$(ls /usr/lib/firmware/amdnpu/ 2>/dev/null | wc -l)
    pass "Firmware directory exists ($FW_COUNT files)"
else
    warn "No firmware at /usr/lib/firmware/amdnpu/"
    info "Firmware is installed with the xrt_plugin package"
fi
echo ""

# ── 8. Check XRT installation ─────────────────────────────────────────────
echo "8. XRT Runtime"
if [ -d "/opt/xilinx/xrt" ]; then
    pass "XRT installed at /opt/xilinx/xrt/"
    if command -v xrt-smi >/dev/null 2>&1; then
        pass "xrt-smi is available"
    else
        warn "xrt-smi not in PATH. Run: source /opt/xilinx/xrt/setup.sh"
    fi
else
    fail "XRT not installed at /opt/xilinx/xrt/"
    info "XRT is built automatically by scripts/build-xdna-driver.sh"
    info "Or: XRT .deb is available in xdna-driver-output/ after build"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 9. Check Docker ───────────────────────────────────────────────────────
echo "9. Docker"
if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version 2>/dev/null | head -1)
    pass "Docker available: $DOCKER_VER"
else
    fail "Docker not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ── 10. Check memory limits ──────────────────────────────────────────────
echo "10. Memory Limits"
MEMLOCK=$(ulimit -l 2>/dev/null || echo "0")
if [ "$MEMLOCK" = "unlimited" ] || [ "$MEMLOCK" -gt 1048576 ] 2>/dev/null; then
    pass "memlock limit: $MEMLOCK (OK)"
else
    warn "memlock limit: $MEMLOCK kB (may be too low for large models)"
    info "Add to /etc/security/limits.d/99-amdxdna.conf:"
    info "  * soft memlock unlimited"
    info "  * hard memlock unlimited"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────
echo "============================================="
if [ $ERRORS -eq 0 ]; then
    echo -e " ${GREEN}All checks passed!${NC} NPU is ready for FastFlowLM-Docker."
    echo ""
    echo " Next steps:"
    echo "   cd FastFlowLM-Docker"
    echo "   cp .env.example .env"
    echo "   docker compose build"
    echo "   docker compose up -d"
else
    echo -e " ${RED}$ERRORS check(s) failed.${NC} See above for details."
    echo ""
    echo " Most likely fix: Build the XDNA driver via Docker:"
    echo "   sudo bash scripts/build-xdna-driver.sh"
    echo "   sudo bash xdna-driver-output/load-driver.sh"
fi
echo "============================================="
