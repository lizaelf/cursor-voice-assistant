"""Один сеанс запису. Клавіатура зараз, пізніше ті самі start/stop викличе HTTP."""

from __future__ import annotations

import threading

from src.config import MIN_DURATION_SEC
from src.recorder import MicrophoneRecorder
from src.transcriber import WhisperTranscriber


class VoiceSession:
    def __init__(
        self,
        recorder: MicrophoneRecorder | None = None,
        transcriber: WhisperTranscriber | None = None,
    ) -> None:
        self.recorder = recorder or MicrophoneRecorder()
        self.transcriber = transcriber or WhisperTranscriber()
        self._lock = threading.Lock()
        self._recording = False
        self._busy = False

    @property
    def is_recording(self) -> bool:
        return self._recording

    @property
    def is_busy(self) -> bool:
        return self._busy

    def start(self) -> bool:
        """Почати запис. False, якщо запис уже йде або ще триває розпізнавання."""
        with self._lock:
            if self._recording or self._busy:
                return False
            started = self.recorder.start()
            self._recording = started
            return started

    def stop(self) -> str | None:
        """Зупинити запис і розпізнати.

        None — не було активного запису, або він коротший за мінімум
        (whisper не викликався).
        Рядок — відповідь whisper, зокрема порожня, якщо мовлення не знайдено.
        """
        with self._lock:
            if not self._recording:
                return None
            self._recording = False
            self._busy = True

        try:
            path, duration = self.recorder.stop()
            if path is None or duration < MIN_DURATION_SEC:
                return None
            return self.transcriber.transcribe(path)
        finally:
            with self._lock:
                self._busy = False
