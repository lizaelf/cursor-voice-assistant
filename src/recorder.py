"""Запис з мікрофона за замовчуванням у WAV 16 kHz mono."""

from __future__ import annotations

import threading
import time
import wave
from pathlib import Path

import numpy as np
import sounddevice as sd

from src.config import CHANNELS, RECORDINGS_DIR, SAMPLE_RATE, SAMPLE_WIDTH_BYTES


class RecorderError(RuntimeError):
    """Мікрофон недоступний або запис зірвався."""


class MicrophoneRecorder:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._recording = False
        self._frames: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None

    @property
    def is_recording(self) -> bool:
        return self._recording

    def start(self) -> bool:
        """Почати запис. Повторний виклик під час активного запису нічого не робить."""
        with self._lock:
            if self._recording:
                return False
            self._frames = []
            self._recording = True

        try:
            stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=self._on_audio,
            )
            stream.start()
        except Exception as exc:
            with self._lock:
                self._recording = False
                self._stream = None
            raise RecorderError(
                "Не вдалося відкрити мікрофон. Дозвольте доступ Microphone "
                "для Terminal або Cursor і перевірте, що встановлено portaudio "
                "(brew install portaudio)."
            ) from exc

        with self._lock:
            if not self._recording:
                stream.stop()
                stream.close()
                return False
            self._stream = stream
        return True

    def stop(self) -> tuple[Path | None, float]:
        """Зупинити запис. Без активного запису повертає (None, 0.0)."""
        with self._lock:
            if not self._recording:
                return None, 0.0
            self._recording = False
            stream = self._stream
            self._stream = None
            frames = self._frames
            self._frames = []

        if stream is not None:
            stream.stop()
            stream.close()

        if not frames:
            return None, 0.0

        audio = np.concatenate(frames, axis=0)
        duration = float(audio.shape[0]) / SAMPLE_RATE
        path = self._write_wav(audio)
        return path, duration

    def _on_audio(self, indata: np.ndarray, frames: int, time_info, status) -> None:
        del frames, time_info, status
        if not self._recording:
            return
        chunk = indata.copy()
        with self._lock:
            if self._recording:
                self._frames.append(chunk)

    def _write_wav(self, audio: np.ndarray) -> Path:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        path = RECORDINGS_DIR / f"recording-{time.time_ns()}.wav"
        with wave.open(str(path), "wb") as handle:
            handle.setnchannels(CHANNELS)
            handle.setsampwidth(SAMPLE_WIDTH_BYTES)
            handle.setframerate(SAMPLE_RATE)
            handle.writeframes(audio.tobytes())
        return path
