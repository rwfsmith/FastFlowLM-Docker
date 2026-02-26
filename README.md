# FastFlowLM-Docker

A Wyoming Protocol server running [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) on AMD Ryzen AI NPUs — supporting both **Whisper ASR** (speech-to-text) and **LLM conversation** (intent handling) for [Home Assistant](https://www.home-assistant.io/) and other Wyoming-compatible voice assistants.

> Powered by [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM)

## Features

- **Wyoming Protocol** — native integration with Home Assistant voice pipelines
- **Whisper ASR on NPU** — speech-to-text via FastFlowLM's `whisper-v3:turbo` model, fully accelerated on the NPU
- **LLM Conversation on NPU** — intent handling via any FLM-supported model (Llama, Qwen, Gemma, etc.)
- **Built from source** — FastFlowLM compiled directly inside the Docker image
- **NPU passthrough** — AMD XDNA2 NPU device access from within the container
- **Dual-mode** — run ASR only, LLM only, or both simultaneously on separate Wyoming ports

## Requirements

### Hardware
- AMD Ryzen AI processor with **XDNA2 NPU** (Strix, Strix Halo, or Kraken series)

### Host System
- **Ubuntu 24.04+** (or compatible Linux with kernel 6.8+)
- **AMD NPU driver** (`amdxdna`) installed — version >= 32.0.203.304
  - Check: `ls /dev/accel/accel*` should show your NPU device
- **Docker** with `--device` support (Docker Engine 20.10+)
- Internet access for initial model downloads from HuggingFace

### NPU Driver Setup (Host)

```bash
# Check if NPU is detected
ls /dev/accel/

# If not present, install the XDNA driver:
# See: https://ryzenai.docs.amd.com/en/latest/inst.html
sudo apt install -y linux-headers-$(uname -r)
# Follow AMD's official XDNA driver installation guide for your kernel
```

## Quick Start

### 1. Clone & Build

```bash
git clone https://github.com/your-username/FastFlowLM-Docker.git
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

### NPU not accessible in container
```bash
# Verify NPU device exists on host
ls -la /dev/accel/

# Check XDNA driver is loaded
lsmod | grep amdxdna

# Ensure correct device permissions
sudo chmod 666 /dev/accel/accel*
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
docker compose logs -f fastflowlm-asr
docker compose logs -f fastflowlm-llm
```

## License

- Wyoming server bridge code: MIT License
- FastFlowLM: [MIT (runtime) + proprietary (NPU kernels)](https://github.com/FastFlowLM/FastFlowLM/blob/main/LICENSE_RUNTIME.txt)
- See FastFlowLM's [TERMS.md](https://github.com/FastFlowLM/FastFlowLM/blob/main/TERMS.md) for commercial licensing details
