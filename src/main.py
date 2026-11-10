"""Command+D вмикає запис і виводить Cursor наперед. Ще раз Command+D зупиняє його."""

from __future__ import annotations

import subprocess
import sys

from pynput import keyboard
from Quartz import (
    CGEventGetFlags,
    CGEventGetIntegerValueField,
    kCGEventFlagMaskCommand,
    kCGKeyboardEventKeycode,
)

from src.config import HOTKEY_KEY_VK, HOTKEY_LABEL, LAST_TRANSCRIPT_PATH, OUTPUT_DIR
from src.recorder import RecorderError
from src.session import VoiceSession
from src.transcriber import TranscriberError

_COMMAND_KEYS = {keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r}


def save_transcript(text: str) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    LAST_TRANSCRIPT_PATH.write_text(text.strip() + "\n", encoding="utf-8")


def is_command(key: keyboard.Key | keyboard.KeyCode) -> bool:
    return key in _COMMAND_KEYS


def is_d(key: keyboard.Key | keyboard.KeyCode) -> bool:
    return isinstance(key, keyboard.KeyCode) and key.vk == HOTKEY_KEY_VK


def swallow_hotkey(event_type, event):
    """Не дає Command+D спрацювати у вікні, яке зараз у фокусі."""
    del event_type
    keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)
    flags = CGEventGetFlags(event)
    if keycode == HOTKEY_KEY_VK and flags & kCGEventFlagMaskCommand:
        return None
    return event


def focus_cursor() -> None:
    completed = subprocess.run(
        ["osascript", "-e", 'tell application "Cursor" to activate'],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        print(f"Не вдалося активувати Cursor. {detail}")


def main() -> int:
    session = VoiceSession()
    command_down = False
    combo_held = False

    print(f"{HOTKEY_LABEL} — почати запис, ще раз {HOTKEY_LABEL} — зупинити. Ctrl+C — вихід.")
    print("Cursor сам вийде наперед. macOS може попросити Microphone і Accessibility.")

    def finish() -> None:
        print("Processing...")
        try:
            text = session.stop()
        except (RecorderError, TranscriberError) as exc:
            print(exc)
            return
        if text is None:
            print("Занадто короткий запис, розпізнавання пропущено.")
            return
        if not text:
            print("Нічого не розпізнано.")
            return
        print("---")
        print(text)
        print("---")
        save_transcript(text)
        print(f"Збережено: {LAST_TRANSCRIPT_PATH}")

    def on_press(key: keyboard.Key | keyboard.KeyCode) -> None:
        nonlocal command_down, combo_held
        if is_command(key):
            command_down = True
            return
        if not is_d(key) or not command_down or combo_held:
            return
        combo_held = True
        if session.is_recording:
            finish()
            return
        focus_cursor()
        try:
            started = session.start()
        except RecorderError as exc:
            print(f"\n{exc}")
            return
        if started:
            print(f"\nRecording... {HOTKEY_LABEL} ще раз — зупинити.")
            return
        if session.is_busy:
            print("\nЩе обробляю попередній запис.")

    def on_release(key: keyboard.Key | keyboard.KeyCode) -> None:
        nonlocal command_down, combo_held
        if is_command(key):
            command_down = False
            return
        if is_d(key):
            combo_held = False

    try:
        with keyboard.Listener(
            on_press=on_press,
            on_release=on_release,
            darwin_intercept=swallow_hotkey,
        ) as listener:
            listener.join()
    except KeyboardInterrupt:
        print("\nЗупинено.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
