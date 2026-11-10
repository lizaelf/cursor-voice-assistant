"""Локальне розпізнавання через whisper.cpp (whisper-cli)."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

from src.config import (
    INITIAL_PROMPT,
    LANGUAGE,
    LOCAL_WHISPER_CANDIDATES,
    MODEL_PATH,
    whisper_cli_override,
)


class TranscriberError(RuntimeError):
    """whisper-cli не знайдено, модель відсутня або розпізнавання впало."""


class WhisperTranscriber:
    def __init__(self, model_path: Path = MODEL_PATH) -> None:
        self.model_path = model_path

    def transcribe(self, wav_path: Path) -> str:
        binary = find_whisper_cli()
        if not self.model_path.is_file():
            raise TranscriberError(
                "Немає моделі "
                f"{self.model_path}. Завантажте її командою з README "
                "(models/ggml-small.bin)."
            )
        if not wav_path.is_file():
            raise TranscriberError(f"Немає аудіофайлу: {wav_path}")

        command = [
            str(binary),
            "-m",
            str(self.model_path),
            "-f",
            str(wav_path),
            "-l",
            LANGUAGE,
            "-nt",
            "-np",
            "--prompt",
            INITIAL_PROMPT,
        ]
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            details = (completed.stderr or completed.stdout or "").strip()
            raise TranscriberError(
                f"whisper-cli завершився з кодом {completed.returncode}. {details}"
            )
        return _clean_transcript(completed.stdout)


def find_whisper_cli() -> Path:
    override = whisper_cli_override()
    if override is not None:
        if override.is_file():
            return override
        raise TranscriberError(
            f"WHISPER_CLI вказує на відсутній файл: {override}"
        )

    for name in ("whisper-cli", "whisper-cpp"):
        found = shutil.which(name)
        if found:
            return Path(found)

    for candidate in LOCAL_WHISPER_CANDIDATES:
        if candidate.is_file():
            return candidate

    searched = ", ".join(str(path) for path in LOCAL_WHISPER_CANDIDATES)
    raise TranscriberError(
        "Не знайдено whisper-cli. Встановіть whisper-cpp "
        "(brew install whisper-cpp) або зберіть whisper.cpp у third_party, "
        f"як описано в README. Шукав також: {searched}"
    )


_TIMESTAMP = re.compile(r"^\[\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}\.\d{3}\]\s*")


def _clean_transcript(stdout: str) -> str:
    lines = []
    for raw in stdout.splitlines():
        line = _TIMESTAMP.sub("", raw.strip()).strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            continue
        lines.append(line)
    return " ".join(lines).strip()
