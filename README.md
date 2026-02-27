# FastFlowLM-Docker

A Wyoming Protocol server running [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) on AMD Ryzen AI NPUs — supporting both **Whisper ASR** (speech-to-text) and **LLM conversation** (intent handling) for [Home Assistant](https://www.home-assistant.io/) and other Wyoming-compatible voice assistants.

Designed for **TrueNAS Scale** with AMD Ryzen AI (Strix/Strix Halo/Kraken) processors.

> Powered by [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM)

## Features

- **Wyoming Protocol** — native integration with Home Assistant voice pipelines
- **Whisper ASR on NPU** — speech-to-text via FastFlowLM's `whisper-v3:turbo` model, fully accelerated on the NPU
- **LLM Conversation on NPU** — intent handling via any FLM-supported model (Llama, Qwen, Gemma, etc.)
- **Built from source** — FastFlowLM compiled directly inside the Docker image
- **NPU passthrough** — AMD XDNA2 NPU device access from within the container
- **TrueNAS Scale ready** — includes XDNA driver setup guide for TrueNAS's custom kernel
- **Dual-mode** — run ASR only, LLM only, or both simultaneously on separate Wyoming ports

## Requirements

### Hardware
- AMD Ryzen AI processor with **XDNA2 NPU** (Strix, Strix Halo, or Kraken series)

### Host System (TrueNAS Scale)
- **TrueNAS Scale 25.04+** (Debian-based, kernel 6.10+)
- **AMD XDNA driver** (`amdxdna.ko`) loaded — creates `/dev/accel/accel*`
- **Docker** (included with TrueNAS Scale)
- Internet access for initial model downloads from HuggingFace

> Also works on standard Ubuntu 24.04+ or any Debian-based Linux with kernel >= 6.10.

---

## TrueNAS Scale: NPU Driver Setup

TrueNAS Scale uses a custom kernel (e.g., `6.12.33-production+truenas`) that doesn't ship with the `amdxdna` module. Since **TrueNAS disables `apt`** to protect the appliance, we build the driver **inside a Docker container** and extract the compiled module to load on the host.

### Step 0: Verify NPU hardware is detected

```bash
# Should show your Strix NPU
lspci | grep -i neural
# Example output: XX:00.0 Signal processing controller: AMD Strix Neural Processing Unit

# Check kernel version (must be >= 6.10)
uname -r

# Check if DRM_ACCEL is enabled in the kernel (required for XDNA)
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_ACCEL
# Must show: CONFIG_DRM_ACCEL=y
```

You can also run the included diagnostic script:
```bash
sudo bash scripts/check-npu.sh
```

### Step 1: Build the XDNA driver (via Docker)

The build script clones the TrueNAS kernel source and AMD XDNA driver inside a Docker container, compiles everything against your running kernel, and extracts the module + firmware:

```bash
# Clone this repo on the TrueNAS host
git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
cd FastFlowLM-Docker

# Build the driver (takes 10-30 min on first run)
sudo bash scripts/build-xdna-driver.sh
```

**What happens under the hood:**
1. A Debian Docker image is built with all the build tools (gcc, cmake, etc.)
2. The [TrueNAS kernel source](https://github.com/truenas/linux) is cloned to generate matching headers
3. The [AMD XDNA driver](https://github.com/amd/xdna-driver) is compiled against those headers
4. The compiled `amdxdna.ko` module and NPU firmware are extracted to `./xdna-driver-output/`

> No packages are installed on the TrueNAS host — everything builds inside Docker.

### Step 2: Load the driver

```bash
# Install and load the built driver
sudo bash xdna-driver-output/load-driver.sh
```

This copies the kernel module to `/lib/modules/$(uname -r)/extra/`, installs NPU firmware, runs `depmod`, loads the module, and sets device permissions for Docker access.

```bash
# Verify the NPU device appeared
ls -la /dev/accel/
# Should show: accel0 (or similar)
```

### Step 3: Auto-load on boot (survives reboots, NOT TrueNAS updates)

```bash
# Auto-load the module at boot
echo "amdxdna" | sudo tee /etc/modules-load.d/amdxdna.conf

# Create a startup script to fix permissions after boot
sudo tee /etc/rc.local > /dev/null << 'BOOT_EOF'
#!/bin/bash
modprobe amdxdna
sleep 2
chmod 666 /dev/accel/accel* 2>/dev/null
chmod 666 /dev/dri/renderD* 2>/dev/null
BOOT_EOF
sudo chmod +x /etc/rc.local
```

> **Important:** After TrueNAS updates that change the kernel, re-run `sudo bash scripts/build-xdna-driver.sh` and `sudo bash xdna-driver-output/load-driver.sh` to rebuild the module for the new kernel.

---

## Quick Start

### 1. Clone & Build

```bash
git clone https://github.com/rwfsmith/FastFlowLM-Docker.git
cd FastFlowLM-Docker

# Build the Docker image (this compiles FastFlowLM from source — takes ~15-20 min)
docker compose build
```

### 2. Configure

```bash
cp .env.example .env
# Edit .env to set your preferred models and ports
```

### 3. Run

```bash
# Start both ASR + LLM Wyoming servers
docker compose up -d

# Or run a specific service only:
docker compose up -d fastflowlm-asr    # Whisper ASR only
docker compose up -d fastflowlm-llm    # LLM conversation only
```

### 4. Connect to Home Assistant

In Home Assistant, add a Wyoming integration:

- **ASR (Whisper)**: `tcp://YOUR_HOST_IP:10300`
- **LLM (Conversation)**: `tcp://YOUR_HOST_IP:10400`

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

## Development

### Build from source locally

```bash
# Build with BuildKit for faster builds
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
# Install dependencies
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

## Troubleshooting

### No `/dev/accel/` on TrueNAS Scale
```bash
# 1. Check that the NPU hardware is seen
lspci | grep -i neural
# Should show: AMD Strix Neural Processing Unit

# 2. Check if the XDNA driver module is loaded
lsmod | grep amdxdna
# If empty, the module isn't loaded

# 3. Check if kernel supports DRM_ACCEL
zcat /proc/config.gz 2>/dev/null | grep CONFIG_DRM_ACCEL
# Must show CONFIG_DRM_ACCEL=y

# 4. If the module exists but isn't loaded:
sudo modprobe amdxdna

# 5. If modprobe fails with "not found", rebuild the driver via Docker:
sudo bash scripts/build-xdna-driver.sh
sudo bash xdna-driver-output/load-driver.sh

# 6. Fix device permissions for Docker access
sudo chmod 666 /dev/accel/accel*
sudo chmod 666 /dev/dri/renderD*
```

### XDNA driver broke after TrueNAS update
TrueNAS updates can replace the kernel. Rebuild the XDNA driver:
```bash
cd FastFlowLM-Docker
sudo bash scripts/build-xdna-driver.sh
sudo bash xdna-driver-output/load-driver.sh
```

### NPU not accessible inside the container
```bash
# Check that the device is passed through
docker exec -it fastflowlm-docker ls -la /dev/accel/ /dev/dri/

# If /dev/accel doesn't exist in the container, verify host:
ls -la /dev/accel/
# And check docker-compose.yml has the devices: section
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
docker compose logs -f fastflowlm
docker compose logs -f fastflowlm-asr
docker compose logs -f fastflowlm-llm
```

## License

- Wyoming server bridge code: MIT License
- FastFlowLM: [MIT (runtime) + proprietary (NPU kernels)](https://github.com/FastFlowLM/FastFlowLM/blob/main/LICENSE_RUNTIME.txt)
- See FastFlowLM's [TERMS.md](https://github.com/FastFlowLM/FastFlowLM/blob/main/TERMS.md) for commercial licensing details
