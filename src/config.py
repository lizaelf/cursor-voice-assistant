"""Шляхи та параметри MVP. Пізніші модулі (HTTP, Cursor) читають це саме місце."""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2

LANGUAGE = "uk"
MIN_DURATION_SEC = 0.4

# Фізична клавіша D на macOS (kVK_ANSI_D). Command+D не залежить від розкладки.
HOTKEY_KEY_VK = 0x02
HOTKEY_LABEL = "Command+D"

INITIAL_PROMPT = "Українською мовою."

MODEL_PATH = ROOT / "models" / "ggml-small.bin"
RECORDINGS_DIR = ROOT / "recordings"
OUTPUT_DIR = ROOT / "out"
LAST_TRANSCRIPT_PATH = OUTPUT_DIR / "last_transcript.txt"

WHISPER_CLI_ENV = "WHISPER_CLI"

# Локальна збірка, якщо brew не поставив whisper-cli у PATH.
LOCAL_WHISPER_CANDIDATES = (
    ROOT / "third_party" / "whisper.cpp" / "build" / "bin" / "whisper-cli",
    ROOT / "third_party" / "whisper.cpp" / "build" / "bin" / "main",
)


def whisper_cli_override() -> Path | None:
    raw = os.environ.get(WHISPER_CLI_ENV, "").strip()
    if not raw:
        return None
    return Path(raw)
