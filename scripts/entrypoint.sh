#!/usr/bin/env bash
# =============================================================================
# FastFlowLM-Docker Entrypoint
# Starts the FastFlowLM server and then the Wyoming Protocol bridge
# =============================================================================
set -e

MODE="${1:-both}"

echo "============================================="
echo " FastFlowLM-Docker"
echo " Mode: ${MODE}"
echo "============================================="

# ── Configuration from environment ──────────────────────────────────────────
FLM_SERVER_PORT="${FLM_SERVER_PORT:-52625}"
FLM_LLM_MODEL="${FLM_LLM_MODEL:-llama3.2:1b}"
FLM_ASR_MODEL="${FLM_ASR_MODEL:-whisper-v3:turbo}"
FLM_ASR_ENABLED="${FLM_ASR_ENABLED:-true}"
FLM_LLM_ENABLED="${FLM_LLM_ENABLED:-true}"
FLM_ASR_LANGUAGE="${FLM_ASR_LANGUAGE:-en}"
FLM_LOG_LEVEL="${FLM_LOG_LEVEL:-INFO}"
WYOMING_ASR_PORT="${WYOMING_ASR_PORT:-10300}"
WYOMING_LLM_PORT="${WYOMING_LLM_PORT:-10400}"

# ── Determine FLM serve arguments ──────────────────────────────────────────
FLM_ARGS=""

case "${MODE}" in
    asr)
        # ASR only — load Whisper as standalone
        FLM_ARGS="--asr 1 --port ${FLM_SERVER_PORT}"
        WYOMING_MODE="asr"
        echo "Starting FastFlowLM in ASR-only mode (${FLM_ASR_MODEL})"
        ;;
    llm)
        # LLM only — load LLM model
        FLM_ARGS="${FLM_LLM_MODEL} --port ${FLM_SERVER_PORT}"
        WYOMING_MODE="llm"
        echo "Starting FastFlowLM in LLM-only mode (${FLM_LLM_MODEL})"
        ;;
    both|*)
        # Both ASR + LLM — load LLM with ASR enabled
        FLM_ARGS="${FLM_LLM_MODEL} --asr 1 --port ${FLM_SERVER_PORT}"
        WYOMING_MODE="both"
        echo "Starting FastFlowLM with LLM (${FLM_LLM_MODEL}) + ASR (${FLM_ASR_MODEL})"
        ;;
esac

# ── Check NPU device access ────────────────────────────────────────────────
echo "Checking NPU device access..."
if [ -d "/dev/accel" ] && ls /dev/accel/accel* >/dev/null 2>&1; then
    echo "NPU device(s) found:"
    ls -la /dev/accel/accel*
else
    echo "============================================="
    echo " WARNING: No NPU devices found at /dev/accel/"
    echo "============================================="
    echo ""
    echo "  The AMD XDNA driver (amdxdna.ko) must be loaded on the HOST."
    echo ""
    echo "  On TrueNAS Scale (apt is disabled), build the driver via Docker:"
    echo "    cd FastFlowLM-Docker"
    echo "    sudo bash scripts/build-xdna-driver.sh"
    echo "    sudo bash xdna-driver-output/load-driver.sh"
    echo ""
    echo "  Then verify:"
    echo "    ls /dev/accel/       # should show accel0"
    echo ""
    echo "  See: https://github.com/rwfsmith/FastFlowLM-Docker#truenas-scale-npu-driver-setup"
    echo ""
    echo "  Also ensure the container has device passthrough:"
    echo "    devices:"
    echo "      - /dev/accel:/dev/accel"
    echo "      - /dev/dri:/dev/dri"
    echo ""
    echo "  FastFlowLM will NOT be able to use NPU acceleration!"
    echo "  Continuing anyway — FLM may fall back to CPU mode."
    echo "============================================="
fi

# Check /dev/dri access (used for display/render)
if [ -d "/dev/dri" ]; then
    echo "DRI devices:"
    ls -la /dev/dri/
fi

# ── Start FastFlowLM server in background ──────────────────────────────────
echo "Starting FastFlowLM server..."
echo "Command: flm serve ${FLM_ARGS}"

# shellcheck disable=SC2086
flm serve ${FLM_ARGS} &
FLM_PID=$!

echo "FastFlowLM server started (PID: ${FLM_PID})"

# ── Trap signals for graceful shutdown ──────────────────────────────────────
cleanup() {
    echo "Shutting down..."
    kill "${FLM_PID}" 2>/dev/null || true
    wait "${FLM_PID}" 2>/dev/null || true
    echo "Shutdown complete."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Wait for FLM server to be ready ────────────────────────────────────────
echo "Waiting for FastFlowLM API to be ready on port ${FLM_SERVER_PORT}..."
TIMEOUT=300
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    if curl -sf "http://127.0.0.1:${FLM_SERVER_PORT}/v1/models" >/dev/null 2>&1; then
        echo "FastFlowLM API is ready! (took ${ELAPSED}s)"
        break
    fi

    # Check if FLM process is still running
    if ! kill -0 "${FLM_PID}" 2>/dev/null; then
        echo "ERROR: FastFlowLM server process died. Check logs above."
        exit 1
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))

    if [ $((ELAPSED % 30)) -eq 0 ]; then
        echo "  Still waiting... (${ELAPSED}s elapsed)"
    fi
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    echo "ERROR: Timed out waiting for FastFlowLM server after ${TIMEOUT}s"
    kill "${FLM_PID}" 2>/dev/null || true
    exit 1
fi

# ── Build Wyoming server arguments ─────────────────────────────────────────
WYOMING_ARGS="--mode ${WYOMING_MODE}"
WYOMING_ARGS="${WYOMING_ARGS} --flm-host 127.0.0.1"
WYOMING_ARGS="${WYOMING_ARGS} --flm-port ${FLM_SERVER_PORT}"
WYOMING_ARGS="${WYOMING_ARGS} --asr-uri tcp://0.0.0.0:${WYOMING_ASR_PORT}"
WYOMING_ARGS="${WYOMING_ARGS} --llm-uri tcp://0.0.0.0:${WYOMING_LLM_PORT}"
WYOMING_ARGS="${WYOMING_ARGS} --language ${FLM_ASR_LANGUAGE}"
WYOMING_ARGS="${WYOMING_ARGS} --wait-for-flm"
WYOMING_ARGS="${WYOMING_ARGS} --flm-timeout 60"

if [ "${FLM_LOG_LEVEL}" = "DEBUG" ]; then
    WYOMING_ARGS="${WYOMING_ARGS} --debug"
fi

# ── Start Wyoming Protocol server ──────────────────────────────────────────
echo "Starting Wyoming Protocol server..."
echo "  Mode: ${WYOMING_MODE}"
echo "  ASR port: ${WYOMING_ASR_PORT}"
echo "  LLM port: ${WYOMING_LLM_PORT}"

# shellcheck disable=SC2086
exec /app/.venv/bin/python3 -m wyoming_flm ${WYOMING_ARGS}
