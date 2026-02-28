# FastFlowLM-Docker

A Wyoming Protocol server running [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) on AMD Ryzen AI NPUs — supporting both **Whisper ASR** (speech-to-text) and **LLM conversation** (intent handling) for [Home Assistant](https://www.home-assistant.io/) and other Wyoming-compatible voice assistants.

> Powered by [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM)

## Features

- **Wyoming Protocol** — native integration with Home Assistant voice pipelines
- **Whisper ASR on NPU** — speech-to-text via FastFlowLM's `whisper-v3:turbo` model, fully accelerated on the NPU
- **LLM Conversation on NPU** — intent handling via any FLM-supported model (Llama, Qwen, Gemma, etc.)
- **Built from source** — FastFlowLM compiled directly inside the Docker image
- **NPU passthrough** — AMD XDNA2 NPU device access from within the container
- **One-command setup** — automated script installs driver, Docker, and deploys everything
- **Dual-mode** — run ASR only, LLM only, or both simultaneously on separate Wyoming ports

## Requirements

### Hardware
- AMD Ryzen AI processor with **XDNA2 NPU** (Strix, Strix Halo, or Kraken series)

### Host System
- **Ubuntu 24.04+** with kernel >= 6.10 (recommended)
- Or **any Debian-based Linux** with kernel >= 6.10
- Or **TrueNAS Scale** with an Ubuntu VM (see [TrueNAS VM Setup](#truenas-scale-vm-setup) below)

---

## Quick Start (Ubuntu)

On a bare-metal Ubuntu system or VM with NPU access:

```bash
git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
cd FastFlowLM-Docker
sudo bash scripts/vm-setup.sh
```

This single script:
1. Verifies NPU hardware and kernel version
2. Installs all build dependencies
3. Installs Docker
4. Builds and installs the AMD XDNA driver
5. Builds the FastFlowLM Docker image (compiles from source)
6. Starts the Wyoming Protocol services

After setup, add Wyoming integrations in Home Assistant:
- **ASR (Whisper)**: `tcp://YOUR_HOST_IP:10300`
- **LLM (Conversation)**: `tcp://YOUR_HOST_IP:10400`

---

## TrueNAS Scale VM Setup

TrueNAS Scale's locked-down kernel makes direct driver installation impractical. Instead, run FastFlowLM inside an **Ubuntu VM** with NPU passthrough — the driver installs cleanly and survives TrueNAS updates.

### Step 1: Identify the NPU on TrueNAS

```bash
# On the TrueNAS host shell:
lspci -nn | grep -i neural
# Example: c7:00.1 Signal processing controller [1180]: AMD Strix Neural Processing Unit [1022:17f0]
```

### Step 2: Isolate the NPU for passthrough

1. **TrueNAS UI → System → Advanced → Isolated GPU Devices**
2. Check the NPU entry (e.g., "Strix Neural Processing Unit")
3. **Reboot TrueNAS** (required for isolation to take effect)

Verify isolation after reboot:
```bash
lspci -k | grep -A2 -i neural
# Should show: Kernel driver in use: vfio-pci
```

### Step 3: Create the Ubuntu VM

1. **TrueNAS UI → Virtualization → Add VM**
   - **Guest OS:** Linux
   - **CPUs:** 4+ (8 recommended for build speed)
   - **Memory:** 8192 MB+ (16384 recommended)
   - **Disk:** 32+ GB (zvol)
   - **NIC:** attach to your LAN bridge
   - **Install Media:** Ubuntu Server 24.04 LTS ISO

2. **Add PCI passthrough:**
   - VM → Devices → Add → **PCI Passthrough Device**
   - Select the NPU (e.g., `0000:c7:00.1 Strix Neural Processing Unit`)

3. **Install Ubuntu Server** (minimal install is fine)

4. **After install, upgrade the kernel** (if default is < 6.10):
   ```bash
   sudo apt install linux-generic-hwe-24.04
   sudo reboot
   ```

### Step 4: Run the setup script

SSH into the VM and run:

```bash
git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
cd FastFlowLM-Docker
sudo bash scripts/vm-setup.sh
```

### Step 5: Connect Home Assistant

In Home Assistant, add Wyoming integrations pointing to the **VM's IP**:
- **ASR**: `tcp://VM_IP:10300`
- **LLM**: `tcp://VM_IP:10400`

> **Tip:** Give the VM a static IP or DHCP reservation so Home Assistant doesn't lose the connection.

---

## Manual Setup

If you prefer to install components individually:

### 1. Install the XDNA driver

```bash
sudo apt install -y linux-headers-$(uname -r) git cmake build-essential \
  libelf-dev libdrm-dev pkg-config python3 pciutils libudev-dev \
  libboost-dev libboost-filesystem-dev libboost-program-options-dev \
  libssl-dev rapidjson-dev uuid-dev curl protobuf-compiler \
  libprotobuf-dev ocl-icd-opencl-dev opencl-headers bc bison flex

git clone --recursive https://github.com/amd/xdna-driver.git
cd xdna-driver
./tools/amdxdna_deps.sh
cd build && ./build.sh -release

sudo dpkg -i Release/xrt_*-amd64-base.deb
sudo dpkg -i Release/xrt_plugin*-amdxdna.deb
sudo modprobe amdxdna

# Verify
ls -la /dev/accel/
```

### 2. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

### 3. Deploy FastFlowLM-Docker

```bash
git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
cd FastFlowLM-Docker
cp .env.example .env    # Edit to customize models/ports
docker compose build    # ~15-20 min (compiles FastFlowLM from source)
docker compose up -d
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker Container                                   │
│                                                     │
│  ┌──────────────┐     ┌─────────────────────────┐   │
│  │ FastFlowLM   │     │ Wyoming Protocol Server │   │
│  │ Server       │◄───►│                         │   │
│  │              │     │  ASR Handler  :10300    │   │
│  │ :52625       │     │  LLM Handler  :10400    │   │
│  │ (OpenAI API) │     │                         │   │
│  └──────┬───────┘     └─────────────────────────┘   │
│         │                                           │
│    /dev/accel/*  (NPU device passthrough)            │
└─────────┼───────────────────────────────────────────┘
          │
    ┌─────┴─────┐
    │  AMD NPU  │
    │  (XDNA2)  │
    └───────────┘
```

**Flow:**
1. Home Assistant sends Wyoming audio/text events to the container
2. The Wyoming server receives events and bridges them to FastFlowLM's OpenAI-compatible API
3. FastFlowLM processes requests on the AMD NPU
4. Results flow back through Wyoming protocol to Home Assistant

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `FLM_ASR_ENABLED` | `true` | Enable Whisper ASR Wyoming server |
| `FLM_LLM_ENABLED` | `true` | Enable LLM conversation Wyoming server |
| `FLM_LLM_MODEL` | `llama3.2:1b` | LLM model to load (any FLM-supported model) |
| `FLM_ASR_MODEL` | `whisper-v3:turbo` | Whisper model for ASR |
| `FLM_SERVER_PORT` | `52625` | FastFlowLM internal API port |
| `WYOMING_ASR_PORT` | `10300` | Wyoming ASR server port |
| `WYOMING_LLM_PORT` | `10400` | Wyoming LLM conversation port |
| `FLM_ASR_LANGUAGE` | `en` | Default ASR language |
| `FLM_LLM_SYSTEM_PROMPT` | `You are a helpful voice assistant...` | System prompt for LLM |
| `FLM_MODEL_PATH` | `/data/models` | Model storage directory |
| `FLM_LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |

## Service Profiles

```bash
# Start both ASR + LLM (default)
docker compose up -d

# ASR only (Whisper speech-to-text)
docker compose --profile asr up -d

# LLM only (conversation/intent handling)
docker compose --profile llm up -d

# All services
docker compose --profile all up -d
```

## Supported Models

### ASR (Speech-to-Text)
- `whisper-v3:turbo` — OpenAI Whisper Large V3 Turbo (recommended)

### LLM (Conversation)
Any model supported by FastFlowLM:
- `llama3.2:1b`, `llama3.2:3b`
- `qwen2.5:1.5b`, `qwen2.5:3b`, `qwen3:4b`
- `gemma3:1b`, `gemma3:4b`
- `phi4-mini`
- `deepseek-r1:1.5b`
- And more — run `flm list` inside the container to see all available models

## Troubleshooting

### NPU not detected in VM
```bash
# Check if the NPU is visible
lspci | grep -i "neural\|17f0\|1502"

# If not visible:
# 1. Ensure the device is isolated on the TrueNAS host (System → Advanced → Isolated GPU Devices)
# 2. Reboot TrueNAS after isolating
# 3. Stop and start (not reboot) the VM after adding the PCI device
```

### No `/dev/accel/` after driver install
```bash
# Check if module is loaded
lsmod | grep amdxdna

# Load manually
sudo modprobe amdxdna

# Check dmesg for errors
dmesg | grep -i xdna

# If firmware is missing:
dmesg | grep -i "firmware\|amdnpu"
# Firmware should be in /usr/lib/firmware/amdnpu/
```

### NPU not accessible inside the container
```bash
# Check host device exists
ls -la /dev/accel/

# Check device permissions
sudo chmod 666 /dev/accel/accel*
sudo chmod 666 /dev/dri/renderD*

# Verify inside container
docker exec -it fastflowlm-docker ls -la /dev/accel/ /dev/dri/
```

### Model download failures
```bash
# Force re-download a model
docker exec -it fastflowlm-docker flm pull llama3.2:1b --force

# Check model storage
docker exec -it fastflowlm-docker ls -la /data/models/
```

### Container logs
```bash
docker compose logs -f              # All services
docker compose logs -f fastflowlm   # Combined service
```

### Rebuild after kernel update
If the kernel is updated (e.g., via `apt upgrade`), the XDNA driver must be rebuilt:
```bash
cd ~/xdna-driver  # or re-clone
cd build && ./build.sh -release
sudo dpkg -i Release/xrt_plugin*-amdxdna.deb
sudo modprobe amdxdna
```

## Development

### Build from source locally

```bash
DOCKER_BUILDKIT=1 docker build -t fastflowlm-docker .

# Run interactively for debugging
docker run -it --rm \
  --device /dev/accel \
  --device /dev/dri \
  -v fastflowlm-models:/data/models \
  -p 10300:10300 \
  -p 10400:10400 \
  fastflowlm-docker bash
```

### Run the Wyoming server outside Docker

```bash
pip install wyoming openai aiohttp

# Start FLM server on the host
flm serve llama3.2:1b --asr 1

# Run Wyoming bridge
python -m wyoming_flm \
  --flm-host 127.0.0.1 \
  --flm-port 52625 \
  --asr-uri tcp://0.0.0.0:10300 \
  --llm-uri tcp://0.0.0.0:10400 \
  --mode both
```

## License

- Wyoming server bridge code: MIT License
- FastFlowLM: [MIT (runtime) + proprietary (NPU kernels)](https://github.com/FastFlowLM/FastFlowLM/blob/main/LICENSE_RUNTIME.txt)
- See FastFlowLM's [TERMS.md](https://github.com/FastFlowLM/FastFlowLM/blob/main/TERMS.md) for commercial licensing details
