#!/usr/bin/env python3
"""Private JSON-lines worker for SQLite Graph Studio's pinned Pocket TTS preset.

The parent app owns all model downloads and verifies each pinned file before starting this
process. This worker runs offline, checks the same manifest again, loads the official 3.1.0
model API once, then streams bounded float32 PCM frames over stdout. Stdout is reserved for the
protocol; diagnostics go to stderr.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
from importlib.metadata import PackageNotFoundError, version
import json
import logging
import os
from pathlib import Path
import queue
import sys
import threading
from typing import Any


PROTOCOL_VERSION = 1
MAX_TEXT_CHARACTERS = 16_000
MAX_SAMPLES_PER_FRAME = 12_000  # 0.5 seconds at the 24 kHz model rate
EXPECTED_ASSETS = {
    "languages/english_2026-09/model.safetensors": (
        219_029_196,
        "916ccd2686e9311cb40054893a3c4284393d658825ffc714a276f3e9b152344f",
    ),
    "languages/english_2026-09/tokenizer.model": (
        59_339,
        "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6",
    ),
    "languages/english_2026-09/embeddings/alba.safetensors": (
        6_195_000,
        "d291428b416d6c36a1de7835e51dbe1e334b75e5af512bb18dd23a1047fe8f3b",
    ),
    "config/english_2026-09.yaml": (
        1_710,
        "c3f0f611f4c9db070b9fcb7e5f757756d659fb8b2c8c074669f7a0bedb5d348a",
    ),
}


class Protocol:
    def __init__(self) -> None:
        self._write_lock = threading.Lock()

    def write(self, message: dict[str, Any]) -> None:
        encoded = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        with self._write_lock:
            sys.stdout.buffer.write(encoded + b"\n")
            sys.stdout.buffer.flush()


def verify_assets(preset_root: Path) -> None:
    for relative_path, (expected_size, expected_digest) in EXPECTED_ASSETS.items():
        path = preset_root / relative_path
        if not path.is_file() or path.stat().st_size != expected_size:
            raise RuntimeError(f"verified Pocket TTS asset is missing or has the wrong size: {relative_path}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected_digest:
            raise RuntimeError(f"Pocket TTS asset failed its pinned SHA-256 check: {relative_path}")


def rewrite_config_for_local_assets(config_path: Path, preset_root: Path, temporary_root: Path) -> Path:
    """Use the paired SentencePiece file accepted by the pinned inference API."""
    import yaml

    with config_path.open("r", encoding="utf-8") as stream:
        config = yaml.safe_load(stream)
    if not isinstance(config, dict):
        raise RuntimeError("Pinned Pocket TTS config is not a YAML object.")

    model_path = str(preset_root / "languages/english_2026-09/model.safetensors")
    tokenizer_path = str(preset_root / "languages/english_2026-09/tokenizer.model")

    def replace_asset_paths(value: Any) -> None:
        if isinstance(value, dict):
            for key, child in list(value.items()):
                if key in {"weights_path", "weights_path_without_voice_cloning"} and child:
                    value[key] = model_path
                elif key == "tokenizer_path" and child:
                    value[key] = tokenizer_path
                else:
                    replace_asset_paths(child)
        elif isinstance(value, list):
            for child in value:
                replace_asset_paths(child)

    replace_asset_paths(config)
    if not any(key in config for key in ("weights_path", "flow_lm", "model_type")):
        raise RuntimeError("Pinned Pocket TTS config did not contain recognized model settings.")
    output_path = temporary_root / "english_2026-09-local.yaml"
    with output_path.open("w", encoding="utf-8") as stream:
        yaml.safe_dump(config, stream, sort_keys=False)
    return output_path


def load_model(preset_root: Path) -> tuple[Any, Any, Any]:
    # Import only after the app has verified the packaged worker and the user-installed assets.
    try:
        installed_version = version("pocket-tts")
    except PackageNotFoundError as error:
        raise RuntimeError("The packaged Pocket TTS 3.1.0 dependency is missing.") from error
    if installed_version != "3.1.0":
        raise RuntimeError(f"Expected Pocket TTS 3.1.0, found {installed_version}.")
    from pocket_tts import TTSModel

    verify_assets(preset_root)
    config_path = preset_root / "config/english_2026-09.yaml"
    model_path = preset_root / "languages/english_2026-09/model.safetensors"
    voice_path = preset_root / "languages/english_2026-09/embeddings/alba.safetensors"
    tokenizer_path = preset_root / "languages/english_2026-09/tokenizer.model"
    for file_path in (config_path, model_path, voice_path, tokenizer_path):
        if not file_path.is_file():
            raise RuntimeError(f"Pocket TTS asset is unavailable: {file_path.name}")

    # TTSModel 3.1.0 accepts a local YAML config. Its tokenizer implementation is SentencePiece,
    # while the September config points to the equivalent Hugging Face tokenizer.json. Use the
    # repository's paired tokenizer.model instead; its full 4,000-piece order and scores match the
    # JSON vocabulary exactly. Changing only these local paths prevents Hugging Face access at run
    # time and gives the released Python API the format it can load.
    from tempfile import TemporaryDirectory

    temporary = TemporaryDirectory(prefix="sgs-pocket-tts-")
    local_config = rewrite_config_for_local_assets(config_path, preset_root, Path(temporary.name))
    model = TTSModel.load_model(config=str(local_config), quantize=False)
    voice_state = model.get_state_for_audio_prompt(str(voice_path))
    # Keep the temporary config alive for the lifetime of the worker/model without depending on
    # the upstream model class allowing arbitrary attributes.
    return model, voice_state, temporary


class Worker:
    def __init__(self, preset_root: Path) -> None:
        self.preset_root = preset_root
        self.protocol = Protocol()
        self.model: Any = None
        self.voice_state: Any = None
        self.config_directory: Any = None
        self.active_id: str | None = None
        self.active_stop: threading.Event | None = None
        self.generation_thread: threading.Thread | None = None
        self.state_lock = threading.Lock()

    def start(self) -> None:
        logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        self.model, self.voice_state, self.config_directory = load_model(self.preset_root)
        self.protocol.write({
            "type": "ready",
            "protocol": PROTOCOL_VERSION,
            "provider": "pocket-tts",
            "version": "3.1.0",
            "voice": "alba",
            "sample_rate": int(self.model.sample_rate),
            "channels": 1,
            "format": "f32le",
        })

    def run(self) -> int:
        self.start()
        for line in sys.stdin.buffer:
            try:
                command = json.loads(line)
                if not isinstance(command, dict):
                    raise ValueError("Worker command must be a JSON object.")
                kind = command.get("type")
                if kind == "synthesize":
                    self.begin(command)
                elif kind == "cancel":
                    self.cancel(command)
                elif kind == "shutdown":
                    self.cancel_active()
                    return 0
                else:
                    raise ValueError("Unknown worker command.")
            except Exception as error:
                self.protocol.write({"type": "error", "id": None, "message": str(error)[:500]})
        self.cancel_active()
        if self.generation_thread is not None:
            self.generation_thread.join(timeout=3)
        return 0

    def begin(self, command: dict[str, Any]) -> None:
        request_id = command.get("id")
        text = command.get("text")
        if not isinstance(request_id, str) or not request_id or not isinstance(text, str):
            raise ValueError("Synthesis requires a request id and text.")
        text = text.strip()
        if not text or len(text) > MAX_TEXT_CHARACTERS:
            raise ValueError(f"Text must contain 1 to {MAX_TEXT_CHARACTERS} characters.")

        with self.state_lock:
            if self.active_id is not None:
                raise RuntimeError("Only one Pocket TTS synthesis request may run at a time.")
            stop = threading.Event()
            self.active_id = request_id
            self.active_stop = stop
            self.generation_thread = threading.Thread(
                target=self.generate,
                args=(request_id, text, stop),
                name="pocket-tts-generate",
                daemon=True,
            )
            self.generation_thread.start()

    def generate(self, request_id: str, text: str, stop: threading.Event) -> None:
        try:
            import torch

            for tensor in self.model.generate_audio_stream(
                model_state=self.voice_state,
                text_to_generate=text,
            ):
                if stop.is_set():
                    break
                samples = tensor.detach().to(device="cpu", dtype=torch.float32).contiguous().numpy().reshape(-1)
                for start in range(0, int(samples.size), MAX_SAMPLES_PER_FRAME):
                    if stop.is_set():
                        break
                    raw = samples[start : start + MAX_SAMPLES_PER_FRAME].astype("<f4", copy=False).tobytes()
                    self.protocol.write({
                        "type": "chunk",
                        "id": request_id,
                        "sample_count": len(raw) // 4,
                        "pcm": base64.b64encode(raw).decode("ascii"),
                    })
            self.protocol.write({"type": "finished", "id": request_id})
        except Exception as error:
            self.protocol.write({"type": "error", "id": request_id, "message": str(error)[:500]})
        finally:
            with self.state_lock:
                if self.active_id == request_id:
                    self.active_id = None
                    self.active_stop = None
                    self.generation_thread = None

    def cancel(self, command: dict[str, Any]) -> None:
        request_id = command.get("id")
        with self.state_lock:
            if request_id == self.active_id and self.active_stop is not None:
                self.active_stop.set()

    def cancel_active(self) -> None:
        with self.state_lock:
            if self.active_stop is not None:
                self.active_stop.set()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preset-root", required=True, type=Path)
    args = parser.parse_args()
    try:
        return Worker(args.preset_root).run()
    except BaseException as error:
        # A startup error is one protocol event so the Swift client can report a useful message.
        try:
            Protocol().write({"type": "startup_error", "message": str(error)[:500]})
        except BaseException:
            print(f"Pocket TTS worker startup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
