#!/usr/bin/env python3
"""Main entry point for the FastFlowLM Wyoming Protocol server.

Runs one or both of:
  - ASR server (Whisper speech-to-text via NPU)
  - LLM server (conversation/intent handling via NPU)
"""

import argparse
import asyncio
import logging
import signal
from functools import partial
from typing import Optional

from wyoming.info import (
    AsrModel,
    AsrProgram,
    Attribution,
    HandleModel,
    HandleProgram,
    Info,
)
from wyoming.server import AsyncServer

from . import __version__
from .asr_handler import ASREventHandler
from .const import (
    FLM_ASR_LANGUAGE,
    FLM_ASR_MODEL,
    FLM_BASE_URL,
    FLM_LLM_MODEL,
    FLM_LLM_SYSTEM_PROMPT,
)
from .flm_client import FLMClient
from .llm_handler import LLMEventHandler

_LOGGER = logging.getLogger(__name__)


def build_asr_info() -> Info:
    """Build Wyoming service info for ASR (Whisper)."""
    return Info(
        asr=[
            AsrProgram(
                name="fastflowlm-whisper",
                description="Whisper speech-to-text on AMD Ryzen AI NPU via FastFlowLM",
                attribution=Attribution(
                    name="FastFlowLM / OpenAI",
                    url="https://github.com/FastFlowLM/FastFlowLM",
                ),
                installed=True,
                version=__version__,
                models=[
                    AsrModel(
                        name=FLM_ASR_MODEL,
                        description=f"OpenAI Whisper ({FLM_ASR_MODEL}) accelerated on NPU",
                        attribution=Attribution(
                            name="OpenAI",
                            url="https://huggingface.co/openai/whisper-large-v3-turbo",
                        ),
                        installed=True,
                        languages=[FLM_ASR_LANGUAGE] if FLM_ASR_LANGUAGE else [],
                        version=__version__,
                    )
                ],
            )
        ],
    )


def build_llm_info() -> Info:
    """Build Wyoming service info for LLM conversation handling."""
    return Info(
        handle=[
            HandleProgram(
                name="fastflowlm-llm",
                description="LLM conversation on AMD Ryzen AI NPU via FastFlowLM",
                attribution=Attribution(
                    name="FastFlowLM",
                    url="https://github.com/FastFlowLM/FastFlowLM",
                ),
                installed=True,
                version=__version__,
                models=[
                    HandleModel(
                        name=FLM_LLM_MODEL,
                        description=f"{FLM_LLM_MODEL} running on AMD NPU via FastFlowLM",
                        attribution=Attribution(
                            name="FastFlowLM",
                            url="https://github.com/FastFlowLM/FastFlowLM",
                        ),
                        installed=True,
                        languages=["en"],
                        version=__version__,
                    )
                ],
            )
        ],
    )


async def wait_for_flm(client: FLMClient, timeout: int = 300) -> bool:
    """Wait for FastFlowLM server to become ready.

    Args:
        client: FLM API client instance.
        timeout: Maximum seconds to wait.

    Returns:
        True if server is ready, False if timed out.
    """
    _LOGGER.info("Waiting for FastFlowLM server at %s ...", FLM_BASE_URL)
    elapsed = 0
    while elapsed < timeout:
        if await client.health_check():
            _LOGGER.info("FastFlowLM server is ready!")
            return True
        await asyncio.sleep(2)
        elapsed += 2
        if elapsed % 30 == 0:
            _LOGGER.info("Still waiting for FastFlowLM... (%ds elapsed)", elapsed)
    _LOGGER.error("Timed out waiting for FastFlowLM server after %ds", timeout)
    return False


async def run_asr_server(
    uri: str,
    flm_client: FLMClient,
    language: str,
) -> None:
    """Run the Wyoming ASR server."""
    wyoming_info = build_asr_info()
    server = AsyncServer.from_uri(uri)

    _LOGGER.info("ASR Wyoming server starting on %s", uri)
    await server.run(
        partial(
            ASREventHandler,
            wyoming_info,
            flm_client,
            language,
        )
    )


async def run_llm_server(
    uri: str,
    flm_client: FLMClient,
) -> None:
    """Run the Wyoming LLM conversation server."""
    wyoming_info = build_llm_info()
    server = AsyncServer.from_uri(uri)

    _LOGGER.info("LLM Wyoming server starting on %s", uri)
    await server.run(
        partial(
            LLMEventHandler,
            wyoming_info,
            flm_client,
        )
    )


async def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="FastFlowLM Wyoming Protocol Server"
    )

    parser.add_argument(
        "--mode",
        choices=["asr", "llm", "both"],
        default="both",
        help="Which services to run: asr (Whisper), llm (conversation), or both (default: both)",
    )
    parser.add_argument(
        "--asr-uri",
        default="tcp://0.0.0.0:10300",
        help="Wyoming ASR server URI (default: tcp://0.0.0.0:10300)",
    )
    parser.add_argument(
        "--llm-uri",
        default="tcp://0.0.0.0:10400",
        help="Wyoming LLM server URI (default: tcp://0.0.0.0:10400)",
    )
    parser.add_argument(
        "--flm-host",
        default="127.0.0.1",
        help="FastFlowLM server host (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--flm-port",
        type=int,
        default=52625,
        help="FastFlowLM server port (default: 52625)",
    )
    parser.add_argument(
        "--language",
        default=FLM_ASR_LANGUAGE,
        help=f"Default ASR language (default: {FLM_ASR_LANGUAGE})",
    )
    parser.add_argument(
        "--wait-for-flm",
        action="store_true",
        default=True,
        help="Wait for FastFlowLM server to become ready before starting (default: true)",
    )
    parser.add_argument(
        "--flm-timeout",
        type=int,
        default=300,
        help="Seconds to wait for FastFlowLM server (default: 300)",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging",
    )
    parser.add_argument(
        "--log-format",
        default=logging.BASIC_FORMAT,
        help="Log format string",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=__version__,
        help="Print version and exit",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format=args.log_format,
    )

    _LOGGER.info("FastFlowLM Wyoming Server v%s", __version__)
    _LOGGER.info("Mode: %s", args.mode)

    # Create shared FLM API client
    base_url = f"http://{args.flm_host}:{args.flm_port}/v1"
    flm_client = FLMClient(base_url=base_url)

    # Wait for FLM server to be ready
    if args.wait_for_flm:
        ready = await wait_for_flm(flm_client, timeout=args.flm_timeout)
        if not ready:
            _LOGGER.error("FastFlowLM server did not become ready. Exiting.")
            await flm_client.close()
            return

    # Start servers based on mode
    tasks = []

    if args.mode in ("asr", "both"):
        _LOGGER.info(
            "Starting ASR (Whisper) server on %s (language: %s)",
            args.asr_uri,
            args.language,
        )
        tasks.append(
            asyncio.create_task(
                run_asr_server(args.asr_uri, flm_client, args.language)
            )
        )

    if args.mode in ("llm", "both"):
        _LOGGER.info(
            "Starting LLM conversation server on %s (model: %s)",
            args.llm_uri,
            FLM_LLM_MODEL,
        )
        tasks.append(
            asyncio.create_task(
                run_llm_server(args.llm_uri, flm_client)
            )
        )

    if not tasks:
        _LOGGER.error("No servers configured to run!")
        await flm_client.close()
        return

    _LOGGER.info("Wyoming servers are ready")

    try:
        await asyncio.gather(*tasks)
    except asyncio.CancelledError:
        _LOGGER.info("Shutting down...")
    finally:
        await flm_client.close()


def run() -> None:
    """Entry point wrapper."""
    asyncio.run(main())


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        pass
