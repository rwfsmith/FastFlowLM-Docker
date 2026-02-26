"""Wyoming Protocol event handler for FastFlowLM ASR (Whisper on NPU)."""

import asyncio
import logging
import os
import tempfile
import wave
from typing import Optional

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioChunkConverter, AudioStop
from wyoming.event import Event
from wyoming.info import Describe, Info
from wyoming.server import AsyncEventHandler

from .flm_client import FLMClient
from .const import FLM_ASR_LANGUAGE, WHISPER_RATE, WHISPER_WIDTH, WHISPER_CHANNELS

_LOGGER = logging.getLogger(__name__)


class ASREventHandler(AsyncEventHandler):
    """Handles Wyoming ASR events by bridging to FastFlowLM's Whisper API.

    Flow:
      1. Client sends Transcribe → set language preference
      2. Client sends AudioStart + AudioChunks + AudioStop
      3. Audio is collected into a WAV file
      4. WAV is sent to FLM's /v1/audio/transcriptions endpoint
      5. Transcript event is returned to the client
    """

    def __init__(
        self,
        wyoming_info: Info,
        flm_client: FLMClient,
        default_language: str = FLM_ASR_LANGUAGE,
        *args,
        **kwargs,
    ) -> None:
        super().__init__(*args, **kwargs)

        self.wyoming_info_event = wyoming_info.event()
        self._flm_client = flm_client
        self._default_language = default_language
        self._language: Optional[str] = default_language

        # Temporary directory for WAV files
        self._wav_dir = tempfile.TemporaryDirectory()
        self._wav_path = os.path.join(self._wav_dir.name, "speech.wav")
        self._wav_file: Optional[wave.Wave_write] = None

        # Convert incoming audio to 16kHz 16-bit mono (Whisper format)
        self._audio_converter = AudioChunkConverter(
            rate=WHISPER_RATE,
            width=WHISPER_WIDTH,
            channels=WHISPER_CHANNELS,
        )

    async def handle_event(self, event: Event) -> bool:
        """Process incoming Wyoming events."""

        # ── Describe: return service info ────────────────────────────────
        if Describe.is_type(event.type):
            await self.write_event(self.wyoming_info_event)
            _LOGGER.debug("Sent ASR service info")
            return True

        # ── Transcribe: set language for this request ─────────────────────
        if Transcribe.is_type(event.type):
            transcribe = Transcribe.from_event(event)
            self._language = transcribe.language or self._default_language
            _LOGGER.debug("ASR language set to: %s", self._language)
            return True

        # ── AudioChunk: accumulate audio data ─────────────────────────────
        if AudioChunk.is_type(event.type):
            chunk = self._audio_converter.convert(AudioChunk.from_event(event))

            if self._wav_file is None:
                self._wav_file = wave.open(self._wav_path, "wb")
                self._wav_file.setframerate(chunk.rate)
                self._wav_file.setsampwidth(chunk.width)
                self._wav_file.setnchannels(chunk.channels)

            self._wav_file.writeframes(chunk.audio)
            return True

        # ── AudioStop: finalize WAV and transcribe ────────────────────────
        if AudioStop.is_type(event.type):
            _LOGGER.debug("Audio stream stopped, starting transcription")

            if self._wav_file is not None:
                self._wav_file.close()
                self._wav_file = None

                # Send to FastFlowLM Whisper in a thread to avoid blocking
                text = await self._flm_client.transcribe(
                    audio_path=self._wav_path,
                    language=self._language,
                )

                _LOGGER.info("Transcription: %s", text)
                await self.write_event(Transcript(text=text).event())
            else:
                _LOGGER.warning("AudioStop received but no audio was captured")
                await self.write_event(Transcript(text="").event())

            _LOGGER.debug("ASR request completed")

            # Reset for next request
            self._language = self._default_language
            return False

        return True

    async def disconnect(self) -> None:
        """Clean up temporary resources."""
        if self._wav_file is not None:
            self._wav_file.close()
            self._wav_file = None

        try:
            self._wav_dir.cleanup()
        except Exception:
            pass
