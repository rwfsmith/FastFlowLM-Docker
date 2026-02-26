#!/usr/bin/env bash
# =============================================================================
# FastFlowLM-Docker Health Check
# Checks that both the FLM server and Wyoming servers are responding
# =============================================================================

FLM_SERVER_PORT="${FLM_SERVER_PORT:-52625}"
WYOMING_ASR_PORT="${WYOMING_ASR_PORT:-10300}"
WYOMING_LLM_PORT="${WYOMING_LLM_PORT:-10400}"
FLM_ASR_ENABLED="${FLM_ASR_ENABLED:-true}"
FLM_LLM_ENABLED="${FLM_LLM_ENABLED:-true}"

# Check FastFlowLM API
if ! curl -sf "http://127.0.0.1:${FLM_SERVER_PORT}/v1/models" >/dev/null 2>&1; then
    echo "UNHEALTHY: FastFlowLM API not responding on port ${FLM_SERVER_PORT}"
    exit 1
fi

# Check Wyoming ASR port (if enabled)
if [ "${FLM_ASR_ENABLED}" = "true" ]; then
    if ! (echo "" | timeout 2 bash -c "cat > /dev/tcp/127.0.0.1/${WYOMING_ASR_PORT}" 2>/dev/null); then
        echo "UNHEALTHY: Wyoming ASR server not listening on port ${WYOMING_ASR_PORT}"
        exit 1
    fi
fi

# Check Wyoming LLM port (if enabled)
if [ "${FLM_LLM_ENABLED}" = "true" ]; then
    if ! (echo "" | timeout 2 bash -c "cat > /dev/tcp/127.0.0.1/${WYOMING_LLM_PORT}" 2>/dev/null); then
        echo "UNHEALTHY: Wyoming LLM server not listening on port ${WYOMING_LLM_PORT}"
        exit 1
    fi
fi

echo "HEALTHY"
exit 0
