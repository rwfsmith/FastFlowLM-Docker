# =============================================================================
# FastFlowLM-Docker: Multi-stage Dockerfile
# Builds FastFlowLM from source and packages it with a Wyoming Protocol server
# Target: Ubuntu 24.04 with AMD XDNA2 NPU support
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build FastFlowLM from source
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies (mirroring FastFlowLM's official Dockerfile)
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cargo \
        cmake \
        git \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libboost-dev \
        libboost-program-options-dev \
        libcurl4-openssl-dev \
        libdrm-dev \
        libfftw3-dev \
        libreadline-dev \
        libswresample-dev \
        libswscale-dev \
        libxrt-dev \
        ninja-build \
        patchelf \
        pkg-config \
        rustc \
        uuid-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone FastFlowLM with submodules
RUN git clone --recursive https://github.com/FastFlowLM/FastFlowLM.git /build/FastFlowLM

# Build using CMake presets (Linux)
WORKDIR /build/FastFlowLM/src
RUN cmake --preset linux-default \
    && cmake --build build -j$(nproc)

# Install to /opt/fastflowlm
RUN cmake --install build

# ---------------------------------------------------------------------------
# Stage 2: Runtime image with Wyoming Protocol server
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        # FastFlowLM runtime libs
        libavcodec60 \
        libavformat60 \
        libavutil58 \
        libboost-program-options1.83.0 \
        libcurl4t64 \
        libdrm2 \
        libfftw3-single3 \
        libreadline8t64 \
        libswresample4 \
        libswscale7 \
        uuid-runtime \
        # XRT runtime for NPU access
        xrt \
        # Python for Wyoming server
        python3 \
        python3-pip \
        python3-venv \
        # Audio processing utilities
        ffmpeg \
        # Misc
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy FastFlowLM installation from builder stage
COPY --from=builder /opt/fastflowlm /opt/fastflowlm

# Add FLM to PATH
ENV PATH="/opt/fastflowlm/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/fastflowlm/lib:${LD_LIBRARY_PATH}"

# Set up Python virtual environment for Wyoming server
WORKDIR /app
RUN python3 -m venv /app/.venv

# Install Python dependencies
COPY requirements.txt /app/
RUN /app/.venv/bin/pip install --no-cache-dir -U pip setuptools wheel \
    && /app/.venv/bin/pip install --no-cache-dir -r requirements.txt

# Copy Wyoming server code
COPY wyoming_flm/ /app/wyoming_flm/
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

# Create model storage directory
RUN mkdir -p /data/models
ENV FLM_MODEL_PATH=/data/models

# Default configuration
ENV FLM_ASR_ENABLED=true \
    FLM_LLM_ENABLED=true \
    FLM_LLM_MODEL=llama3.2:1b \
    FLM_ASR_MODEL=whisper-v3:turbo \
    FLM_SERVER_PORT=52625 \
    WYOMING_ASR_PORT=10300 \
    WYOMING_LLM_PORT=10400 \
    FLM_ASR_LANGUAGE=en \
    FLM_LLM_SYSTEM_PROMPT="You are a helpful voice assistant for a smart home. Keep responses concise and conversational." \
    FLM_LOG_LEVEL=INFO

# Expose ports: Wyoming ASR, Wyoming LLM, FastFlowLM API
EXPOSE 10300 10400 52625

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD /app/scripts/healthcheck.sh || exit 1

# Volume for model persistence
VOLUME ["/data/models"]

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["both"]
