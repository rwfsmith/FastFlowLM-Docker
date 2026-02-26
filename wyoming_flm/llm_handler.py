"""Wyoming Protocol event handler for FastFlowLM LLM conversation (intent handling)."""

import logging
from typing import Optional

from wyoming.asr import Transcript
from wyoming.event import Event
from wyoming.handle import Handled, NotHandled
from wyoming.info import Describe, Info
from wyoming.server import AsyncEventHandler

from .flm_client import FLMClient

_LOGGER = logging.getLogger(__name__)


class LLMEventHandler(AsyncEventHandler):
    """Handles Wyoming conversation/intent events by bridging to FastFlowLM's LLM API.

    Flow:
      1. Client sends Transcript with text to handle
      2. Text is sent to FLM's /v1/chat/completions endpoint
      3. Handled event is returned to the client with the response
    """

    def __init__(
        self,
        wyoming_info: Info,
        flm_client: FLMClient,
        *args,
        **kwargs,
    ) -> None:
        super().__init__(*args, **kwargs)

        self.wyoming_info_event = wyoming_info.event()
        self._flm_client = flm_client

    async def handle_event(self, event: Event) -> bool:
        """Process incoming Wyoming events."""

        # ── Describe: return service info ────────────────────────────────
        if Describe.is_type(event.type):
            await self.write_event(self.wyoming_info_event)
            _LOGGER.debug("Sent LLM service info")
            return True

        # ── Transcript: handle text via LLM ──────────────────────────────
        if Transcript.is_type(event.type):
            transcript = Transcript.from_event(event)
            user_text = transcript.text

            if not user_text or not user_text.strip():
                _LOGGER.warning("Empty transcript received")
                await self.write_event(
                    NotHandled(text="I didn't catch that.").event()
                )
                return False

            _LOGGER.info("Handling text: %s", user_text[:200])

            try:
                response_text = await self._flm_client.chat(
                    user_message=user_text,
                )
                _LOGGER.info("LLM response: %s", response_text[:200])
                await self.write_event(
                    Handled(text=response_text).event()
                )
            except Exception as e:
                _LOGGER.error("LLM chat failed: %s", e, exc_info=True)
                await self.write_event(
                    NotHandled(
                        text="Sorry, I encountered an error processing your request."
                    ).event()
                )

            return False

        return True
