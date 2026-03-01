#!/usr/bin/env bash
# =============================================================================
# vm-setup.sh — One-shot setup for FastFlowLM-Docker on Ubuntu VM
#
# Run this on a fresh Ubuntu 24.04+ VM with AMD NPU passthrough.
# It installs everything needed: XDNA driver, Docker, and deploys the
# FastFlowLM Wyoming Protocol service.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/rwfsmith/FastFlowLM-Docker/main/scripts/vm-setup.sh | sudo bash
#   # or:
#   git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
#   cd FastFlowLM-Docker
#   sudo bash scripts/vm-setup.sh
#
# Requirements:
#   - Ubuntu 24.04+ (Server or Desktop)
#   - AMD Ryzen AI NPU visible via lspci (PCIe passthrough or bare metal)
#   - Kernel >= 6.10 (use linux-generic-hwe-24.04 if default kernel is older)
#   - Internet access
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════${NC}\n"; }

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (sudo bash scripts/vm-setup.sh)"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~${REAL_USER}")

echo ""
echo "  ███████╗ █████╗ ███████╗████████╗███████╗██╗      ██████╗ ██╗    ██╗"
echo "  ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔════╝██║     ██╔═══██╗██║    █
echo "  █████╗  ███████║███████╗   ██║   █████╗  ██║     ██║   ██║██║ █╗ ██║"
echo "  ██╔══╝  ██╔══██║╚════██║   ██║   ██╔══╝  ██║     ██║   ██║██║███╗██║"
echo "  ██║     ██║  ██║███████║   ██║   ██║     ███████╗╚██████╔╝╚███╔███╔╝"
echo "  ╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝"
echo "                    FastFlowLM on AMD Ryzen AI NPU"
echo ""

# ── Step 1: Pre-flight checks ─────────────────────────────────────────────
step "Step 1/6: Pre-flight checks"

# Check for AMD NPU
NPU_PCI=$(lspci 2>/dev/null | grep -i "neural\|xdna\|17f0\|1502" || true)
if [ -z "$NPU_PCI" ]; then
    err "No AMD NPU detected in lspci."
    echo "  If running in a VM, ensure PCIe passthrough is configured."
    echo "  On the host: lspci -nn | grep -i neural"
    exit 1
fi
log "NPU detected: ${NPU_PCI}"

# Check kernel version
KERNEL_VERSION=$(uname -r)
KMAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KMINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
log "Kernel: ${KERNEL_VERSION}"

if [ "$KMAJOR" -lt 6 ] || ([ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -lt 10 ]); then
    err "Kernel ${KERNEL_VERSION} is too old (need >= 6.10)."
    echo ""
    echo "  Install the HWE kernel:"
    echo "    sudo apt install linux-generic-hwe-24.04"
    echo "    sudo reboot"
    exit 1
fi

# Check kernel headers
if [ ! -d "/lib/modules/${KERNEL_VERSION}/build" ]; then
    warn "Kernel headers not found. Installing..."
    apt-get update
    apt-get install -y "linux-headers-${KERNEL_VERSION}"
fi
log "Kernel headers: /lib/modules/${KERNEL_VERSION}/build"

# Check CONFIG_DRM_ACCEL — required for /dev/accel/ to exist
DRM_ACCEL_FOUND=false
if [ -f /proc/config.gz ]; then
    if zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_DRM_ACCEL=[ym]"; then
        DRM_ACCEL_FOUND=true
    fi
elif [ -f "/boot/config-${KERNEL_VERSION}" ]; then
    if grep -q "CONFIG_DRM_ACCEL=[ym]" "/boot/config-${KERNEL_VERSION}"; then
        DRM_ACCEL_FOUND=true
    fi
fi

if [ "$DRM_ACCEL_FOUND" = true ]; then
    log "CONFIG_DRM_ACCEL enabled in kernel config."
else
    err "CONFIG_DRM_ACCEL is not enabled in the kernel."
    echo "  /dev/accel/ cannot exist without this kernel option."
    echo "  Install a kernel with DRM_ACCEL support:"
    echo "    sudo apt install linux-generic-hwe-24.04"
    echo "    sudo reboot"
    exit 1
fi

# ── Step 2: Install system dependencies ────────────────────────────────────
step "Step 2/6: Installing system dependencies"

# Check if key build packages are already installed
DEPS_NEEDED=false
for pkg in build-essential cmake git libelf-dev libdrm-dev dkms; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        DEPS_NEEDED=true
        break
    fi
done

if [ "$DEPS_NEEDED" = true ]; then
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        cmake \
        libelf-dev \
        libdrm-dev \
        pkg-config \
        python3 \
        python3-pip \
        pciutils \
        dkms \
        libudev-dev \
        libboost-dev \
        libboost-filesystem-dev \
        libboost-program-options-dev \
        libssl-dev \
        rapidjson-dev \
        uuid-dev \
        curl \
        protobuf-compiler \
        libprotobuf-dev \
        ocl-icd-opencl-dev \
        ocl-icd-libopencl1 \
        opencl-headers \
        bc \
        bison \
        flex \
        kmod \
        ca-certificates \
        gnupg \
        lsb-release
    log "System dependencies installed."
else
    log "System dependencies already installed. Skipping."
fi

# ── Step 3: Install Docker ─────────────────────────────────────────────────
step "Step 3/6: Installing Docker"

if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    # Install Docker from official repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add the real user to the docker group
    usermod -aG docker "${REAL_USER}"
    log "Docker installed. User '${REAL_USER}' added to docker group."
fi

# Ensure Docker is running
systemctl enable docker
systemctl start docker
log "Docker daemon running."

# ── Step 4: Build & install AMD XDNA driver ────────────────────────────────
step "Step 4/6: Building AMD XDNA driver"

XDNA_BUILD_DIR="/tmp/xdna-driver-build"

# Check if driver is already installed AND loaded
DRIVER_INSTALLED=false
if dpkg -s xrt-amdxdna >/dev/null 2>&1 || dpkg -l | grep -q xrt-plugin.*amdxdna; then
    DRIVER_INSTALLED=true
fi

if [ -c /dev/accel/accel0 ] 2>/dev/null && [ "$DRIVER_INSTALLED" = true ]; then
    log "XDNA driver already installed and loaded (/dev/accel/accel0 exists). Skipping build."
else
    if [ "$DRIVER_INSTALLED" = true ]; then
        log "XDNA driver packages installed but device not active. Loading modules..."

        # Ensure prerequisite DRM/accel subsystem modules are loaded
        modprobe drm 2>/dev/null || true
        modprobe accel 2>/dev/null || true

        # Rebuild module dependency list in case it's stale
        depmod -a

        # Load amdxdna and show errors instead of hiding them
        if ! modprobe amdxdna; then
            warn "modprobe amdxdna failed. Check 'dmesg | tail -30' for details."
        fi

        # Trigger udev to create device nodes
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=accel 2>/dev/null || true
        sleep 3

        if [ -c /dev/accel/accel0 ] 2>/dev/null; then
            log "XDNA driver loaded successfully!"
            ls -la /dev/accel/
        else
            warn "modprobe didn't create /dev/accel/accel0."
            echo "  Diagnostics:"
            echo "  - dmesg | grep -i 'xdna\|accel\|drm' | tail -20"
            echo "  - lsmod | grep amdxdna"
            echo "  - ls -la /dev/accel/ 2>/dev/null"
            echo "  A reboot may be required after first install."
        fi
    else
        # Full build needed
        rm -rf "${XDNA_BUILD_DIR}"
        mkdir -p "${XDNA_BUILD_DIR}"

        echo "Cloning AMD XDNA driver..."
        git clone --recursive https://github.com/amd/xdna-driver.git "${XDNA_BUILD_DIR}/xdna-driver"
        cd "${XDNA_BUILD_DIR}/xdna-driver"

        # Install XDNA-specific dependencies
        if [ -f ./tools/amdxdna_deps.sh ]; then
            echo "Running XDNA dependency installer..."
            ./tools/amdxdna_deps.sh || warn "Some optional deps may have failed (non-fatal)"
        fi

        # Build
        echo "Building XDNA driver (this takes 10-20 minutes)..."
        cd build
        ./build.sh -release

        # Install
        echo "Installing XDNA driver packages..."
        dpkg -i ./Release/xrt_*-amd64-base.deb 2>/dev/null || apt-get install -f -y
        dpkg -i ./Release/xrt_plugin*-amdxdna.deb 2>/dev/null || apt-get install -f -y

        # Rebuild module dependency list so modprobe can find the new module
        depmod -a
        log "Module dependencies rebuilt."

        # Ensure prerequisite DRM/accel subsystem modules are loaded
        modprobe drm 2>/dev/null || true
        modprobe accel 2>/dev/null || true

        # Load the amdxdna module (show errors)
        if ! modprobe amdxdna; then
            warn "modprobe amdxdna failed. Check 'dmesg | tail -30' for details."
        fi

        # Trigger udev to create device nodes
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=accel 2>/dev/null || true

        # Wait for device to appear (up to 10 seconds)
        echo "Waiting for /dev/accel/accel0 to appear..."
        for i in $(seq 1 10); do
            if [ -c /dev/accel/accel0 ] 2>/dev/null; then
                break
            fi
            sleep 1
        done

        if [ -c /dev/accel/accel0 ] 2>/dev/null; then
            log "XDNA driver loaded successfully!"
            ls -la /dev/accel/
        else
            warn "Driver installed but /dev/accel/accel0 not found."
            echo "  Diagnostics:"
            echo "  - dmesg | grep -i 'xdna\|accel\|drm' | tail -20"
            echo "  - lsmod | grep amdxdna"
            echo "  - ls -la /dev/accel/ 2>/dev/null"
            echo "  A reboot is likely required after first install."
        fi

        # Clean up build directory
        cd /
        rm -rf "${XDNA_BUILD_DIR}"
        log "Build directory cleaned up."
    fi
fi

# Ensure module auto-load, udev rules, and limits are always set
# (idempotent — safe to re-run)
if [ ! -f /etc/modules-load.d/amdxdna.conf ]; then
    echo "amdxdna" > /etc/modules-load.d/amdxdna.conf
    log "Module set to auto-load on boot."
else
    log "Module auto-load already configured."
fi

if [ ! -f /etc/udev/rules.d/99-amdxdna.rules ]; then
    cat > /etc/udev/rules.d/99-amdxdna.rules << 'UDEV_EOF'
SUBSYSTEM=="accel", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
UDEV_EOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    log "Udev rules installed for NPU device permissions."
else
    log "Udev rules already installed."
fi

if [ ! -f /etc/security/limits.d/99-amdxdna.conf ]; then
    cat > /etc/security/limits.d/99-amdxdna.conf << 'LIMITS_EOF'
* soft memlock unlimited
* hard memlock unlimited
LIMITS_EOF
    log "Memory lock limits set to unlimited."
else
    log "Memory lock limits already configured."
fi

# ── Step 5: Clone / update FastFlowLM-Docker ───────────────────────────────
step "Step 5/6: Setting up FastFlowLM-Docker"

PROJECT_DIR="${REAL_HOME}/FastFlowLM-Docker"

if [ -d "${PROJECT_DIR}/.git" ]; then
    log "FastFlowLM-Docker already cloned at ${PROJECT_DIR}. Pulling latest..."
    cd "${PROJECT_DIR}"
    sudo -u "${REAL_USER}" git pull || true
else
    echo "Cloning FastFlowLM-Docker..."
    sudo -u "${REAL_USER}" git clone https://github.com/rwfsmith/FastFlowLM-Docker.git "${PROJECT_DIR}"
    cd "${PROJECT_DIR}"
fi

# Create .env if it doesn't exist
if [ ! -f "${PROJECT_DIR}/.env" ]; then
    cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
    log "Created .env from .env.example (edit to customize models/ports)."
else
    log ".env already exists. Keeping current configuration."
fi

chown -R "${REAL_USER}:${REAL_USER}" "${PROJECT_DIR}"
log "Project ready at ${PROJECT_DIR}"

# ── Step 6: Build & start Docker containers ────────────────────────────────
step "Step 6/6: Building and starting FastFlowLM containers"

cd "${PROJECT_DIR}"

# Check if the Docker image already exists
if docker images --format '{{.Repository}}' 2>/dev/null | grep -q 'fastflowlm'; then
    log "FastFlowLM Docker image already built."
    # Check if containers are running
    if docker compose ps --status running 2>/dev/null | grep -q 'fastflowlm'; then
        log "FastFlowLM containers already running. Skipping."
    else
        echo "Starting services..."
        sudo -u "${REAL_USER}" docker compose up -d
    fi
else
    echo "Building Docker image (compiles FastFlowLM from source — ~15-20 min)..."
    sudo -u "${REAL_USER}" docker compose build

    echo "Starting services..."
    sudo -u "${REAL_USER}" docker compose up -d
fi

# ── Summary ────────────────────────────────────────────────────────────────
VM_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VM_IP")

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  NPU device:     $(lspci | grep -i '17f0\|neural\|xdna' | head -1 || echo 'check lspci')"
echo "  XDNA driver:    $(lsmod | grep amdxdna | awk '{print "loaded (" $3 " dependents)"}' || echo 'not loaded — reboot may be needed')"
echo "  Docker:          $(docker --version 2>/dev/null || echo 'not found')"
echo "  Project dir:     ${PROJECT_DIR}"
echo ""
echo "  Wyoming ASR:     tcp://${VM_IP}:10300"
echo "  Wyoming LLM:     tcp://${VM_IP}:10400"
echo ""
echo "  Add these as Wyoming integrations in Home Assistant."
echo ""
echo "  Useful commands:"
echo "    docker compose logs -f          # Watch container logs"
echo "    docker compose restart          # Restart services"
echo "    docker compose down && up -d    # Full restart"
echo ""
echo "  Note: If you just installed Docker, log out and back in"
echo "  (or run 'newgrp docker') to use docker without sudo."
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
