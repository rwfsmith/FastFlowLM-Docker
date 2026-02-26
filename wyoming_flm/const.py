"""Constants and configuration for the FastFlowLM Wyoming server."""

import os

# FastFlowLM server connection
FLM_HOST = os.environ.get("FLM_HOST", "127.0.0.1")
FLM_PORT = int(os.environ.get("FLM_SERVER_PORT", "52625"))
FLM_BASE_URL = f"http://{FLM_HOST}:{FLM_PORT}/v1"
FLM_API_KEY = "flm"  # Placeholder — FLM doesn't enforce auth

# ASR settings
FLM_ASR_MODEL = os.environ.get("FLM_ASR_MODEL", "whisper-v3:turbo")
FLM_ASR_LANGUAGE = os.environ.get("FLM_ASR_LANGUAGE", "en")

# LLM settings
FLM_LLM_MODEL = os.environ.get("FLM_LLM_MODEL", "llama3.2:1b")
FLM_LLM_SYSTEM_PROMPT = os.environ.get(
    "FLM_LLM_SYSTEM_PROMPT",
    "You are a helpful voice assistant for a smart home. "
    "Keep responses concise and conversational. "
    "When asked to control devices, describe what you would do.",
)

# Audio format expected by Whisper
WHISPER_RATE = 16000
WHISPER_WIDTH = 2  # 16-bit
WHISPER_CHANNELS = 1  # mono
