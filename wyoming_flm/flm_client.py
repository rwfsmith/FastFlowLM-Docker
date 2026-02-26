"""HTTP client for communicating with the FastFlowLM OpenAI-compatible API."""

import io
import logging
from pathlib import Path
from typing import Optional

import aiohttp

from .const import FLM_API_KEY, FLM_BASE_URL, FLM_ASR_MODEL, FLM_LLM_MODEL, FLM_LLM_SYSTEM_PROMPT

_LOGGER = logging.getLogger(__name__)


class FLMClient:
    """Async client for the FastFlowLM server API."""

    def __init__(
        self,
        base_url: str = FLM_BASE_URL,
        api_key: str = FLM_API_KEY,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self._session: Optional[aiohttp.ClientSession] = None

    async def _get_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                headers={"Authorization": f"Bearer {self.api_key}"},
                timeout=aiohttp.ClientTimeout(total=120),
            )
        return self._session

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()

    # ── ASR: Audio Transcription ─────────────────────────────────────────

    async def transcribe(
        self,
        audio_path: str,
        model: str = FLM_ASR_MODEL,
        language: Optional[str] = None,
    ) -> str:
        """Transcribe an audio file using FastFlowLM's Whisper endpoint.

        Sends audio to POST /v1/audio/transcriptions (OpenAI-compatible).

        Args:
            audio_path: Path to the WAV/audio file.
            model: Whisper model name (e.g., "whisper-v3").
            language: Language code for transcription (e.g., "en").

        Returns:
            Transcribed text string.
        """
        session = await self._get_session()
        url = f"{self.base_url}/audio/transcriptions"

        data = aiohttp.FormData()
        data.add_field("model", model)
        if language:
            data.add_field("language", language)

        # Read the audio file and send it
        audio_bytes = Path(audio_path).read_bytes()
        data.add_field(
            "file",
            io.BytesIO(audio_bytes),
            filename="speech.wav",
            content_type="audio/wav",
        )

        _LOGGER.debug("Sending transcription request to %s", url)

        async with session.post(url, data=data) as response:
            if response.status != 200:
                error_text = await response.text()
                _LOGGER.error(
                    "Transcription failed (HTTP %d): %s",
                    response.status,
                    error_text,
                )
                return ""

            result = await response.json()
            text = result.get("text", "").strip()
            _LOGGER.info("Transcription result: %s", text)
            return text

    # ── LLM: Chat Completion ─────────────────────────────────────────────

    async def chat(
        self,
        user_message: str,
        model: str = FLM_LLM_MODEL,
        system_prompt: str = FLM_LLM_SYSTEM_PROMPT,
    ) -> str:
        """Send a chat completion request to FastFlowLM.

        Uses POST /v1/chat/completions (OpenAI-compatible).

        Args:
            user_message: The user's text input.
            model: LLM model name (e.g., "llama3.2:1b").
            system_prompt: System prompt for the conversation.

        Returns:
            The assistant's response text.
        """
        session = await self._get_session()
        url = f"{self.base_url}/chat/completions"

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
        }

        _LOGGER.debug("Sending chat request to %s: %s", url, user_message[:100])

        async with session.post(url, json=payload) as response:
            if response.status != 200:
                error_text = await response.text()
                _LOGGER.error(
                    "Chat completion failed (HTTP %d): %s",
                    response.status,
                    error_text,
                )
                return "Sorry, I could not process that request."

            result = await response.json()
            try:
                text = result["choices"][0]["message"]["content"].strip()
            except (KeyError, IndexError):
                _LOGGER.error("Unexpected chat response format: %s", result)
                return "Sorry, I received an unexpected response."

            _LOGGER.info("Chat response: %s", text[:200])
            return text

    # ── Health Check ─────────────────────────────────────────────────────

    async def health_check(self) -> bool:
        """Check if the FastFlowLM server is responding."""
        try:
            session = await self._get_session()
            url = f"{self.base_url}/models"
            async with session.get(url) as response:
                return response.status == 200
        except Exception as e:
            _LOGGER.debug("Health check failed: %s", e)
            return False
