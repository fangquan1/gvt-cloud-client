from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import socket
import time
import tkinter as tk
from ctypes import wintypes


user32 = ctypes.windll.user32
GA_ROOT = 2
VK_CAPITAL = 0x14


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


KEYMAP = {
    "Return": "ret",
    "BackSpace": "backspace",
    "Tab": "tab",
    "Escape": "esc",
    "space": "spc",
    "minus": "minus",
    "equal": "equal",
    "bracketleft": "bracket_left",
    "bracketright": "bracket_right",
    "semicolon": "semicolon",
    "apostrophe": "apostrophe",
    "grave": "grave_accent",
    "backslash": "backslash",
    "comma": "comma",
    "period": "dot",
    "slash": "slash",
    "asterisk": "asterisk",
    "Shift_L": "shift",
    "Shift_R": "shift_r",
    "Control_L": "ctrl",
    "Control_R": "ctrl_r",
    "Alt_L": "alt",
    "Alt_R": "alt_r",
    "Caps_Lock": "caps_lock",
    "Num_Lock": "num_lock",
    "Scroll_Lock": "scroll_lock",
    "Left": "left",
    "Right": "right",
    "Up": "up",
    "Down": "down",
    "Home": "home",
    "End": "end",
    "Prior": "pgup",
    "Next": "pgdn",
    "Insert": "insert",
    "Delete": "delete",
    "Print": "print",
    "Pause": "pause",
    "Menu": "menu",
    "Win_L": "meta_l",
    "Win_R": "meta_r",
}

for i in range(1, 25):
    KEYMAP[f"F{i}"] = f"f{i}"
for i in range(10):
    KEYMAP[f"KP_{i}"] = f"kp_{i}"
KEYMAP.update({
    "KP_Divide": "kp_divide",
    "KP_Multiply": "kp_multiply",
    "KP_Subtract": "kp_subtract",
    "KP_Add": "kp_add",
    "KP_Enter": "kp_enter",
    "KP_Decimal": "kp_decimal",
})


def find_window_by_title(title_part: str) -> int | None:
    needle = title_part.lower()
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def enum_proc(hwnd: int, _lparam: int) -> bool:
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        if needle in buf.value.lower():
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(enum_proc, 0)
    return found[0] if found else None


def client_rect_on_screen(hwnd: int) -> tuple[int, int, int, int] | None:
    rect = RECT()
    origin = POINT(0, 0)
    if not user32.GetClientRect(hwnd, ctypes.byref(rect)):
        return None
    if not user32.ClientToScreen(hwnd, ctypes.byref(origin)):
        return None
    width = max(1, rect.right - rect.left)
    height = max(1, rect.bottom - rect.top)
    return origin.x, origin.y, width, height


def foreground_window() -> int:
    return int(user32.GetForegroundWindow())


def root_window(hwnd: int) -> int:
    root = int(user32.GetAncestor(hwnd, GA_ROOT))
    return root or hwnd


def local_caps_on() -> bool:
    return bool(user32.GetKeyState(VK_CAPITAL) & 1)


class ControlOverlay:
    def __init__(
        self,
        host: str,
        port: int,
        width: int,
        height: int,
        alpha: float,
        follow_title: str | None,
        follow_interval_ms: int,
        active_only: bool,
        motion_interval_ms: int,
        debug_log: str | None,
        invert_case: bool,
    ) -> None:
        self.host = host
        self.port = port
        self.sock: socket.socket | None = None
        self.motion_interval_ms = max(1, motion_interval_ms)
        self.last_motion_sent = 0.0
        self.pending_motion: tuple[int, int] | None = None
        self.motion_flush_scheduled = False
        self.follow_title = follow_title
        self.follow_interval_ms = follow_interval_ms
        self.active_only = active_only
        self.last_geometry: tuple[int, int, int, int] | None = None
        self.visible = True
        self.status_item: int | None = None
        self.guest_modifiers: set[str] = set()
        self.invert_case = invert_case
        self.seq = 0
        self.debug_path = Path(debug_log) if debug_log else None
        self.debug_fp = None
        self.debug_sample = 0
        if self.debug_path is not None:
            self.debug_path.parent.mkdir(parents=True, exist_ok=True)
            self.debug_fp = self.debug_path.open("a", encoding="utf-8", buffering=1)
            self.debug("start")

        self.root = tk.Tk()
        self.root.title("GVT Direct Input Overlay")
        self.root.geometry(f"{width}x{height}+80+80")
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", alpha)
        if follow_title:
            self.root.overrideredirect(True)
        self.root.configure(bg="#102030")
        self.root.focus_force()

        self.canvas = tk.Canvas(self.root, bg="#102030", highlightthickness=2, highlightbackground="#66ccff")
        self.canvas.pack(fill="both", expand=True)
        self.title_item = self.canvas.create_text(
            width // 2,
            28,
            text="GVT Direct Input Overlay",
            fill="#e8f8ff",
            font=("Segoe UI", 14, "bold"),
        )
        self.help_item = self.canvas.create_text(
            width // 2,
            56,
            text="Esc closes. Ctrl+Alt+End sends Ctrl+Alt+Del. Ctrl+Alt+I flips case. Ctrl+Alt+C toggles guest Caps. Ctrl+Alt+R resets keys.",
            fill="#d0e8ff",
            font=("Segoe UI", 10),
        )
        self.status_item = self.canvas.create_text(
            12,
            12,
            anchor="nw",
            text="input: connecting",
            fill="#99ffcc",
            font=("Segoe UI", 9),
        )

        for sequence, handler in (
            ("<Motion>", self.on_motion),
            ("<ButtonPress>", self.on_button_press),
            ("<ButtonRelease>", self.on_button_release),
            ("<MouseWheel>", self.on_wheel),
            ("<Enter>", self.on_enter),
        ):
            self.canvas.bind(sequence, handler)

        for sequence, handler in (
            ("<KeyPress>", self.on_key_press),
            ("<KeyRelease>", self.on_key_release),
            ("<Configure>", self.on_configure),
        ):
            self.root.bind(sequence, handler)

        if self.follow_title:
            self.root.after(200, self.follow_video_window)
        self.root.after(500, self.release_modifiers)

    def connect(self) -> None:
        if self.sock is not None:
            return
        sock = socket.create_connection((self.host, self.port), timeout=2)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self.set_status("input: connected")

    def send(self, msg: dict) -> None:
        try:
            self.connect()
            assert self.sock is not None
            self.seq += 1
            msg["seq"] = self.seq
            msg["client_epoch_ns"] = time.time_ns()
            msg["client_perf_ns"] = time.perf_counter_ns()
            self.sock.sendall((json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8"))
            self.debug_send(msg)
        except OSError:
            if self.sock is not None:
                try:
                    self.sock.close()
                except OSError:
                    pass
            self.sock = None
            self.set_status("input: reconnecting")

    def debug(self, text: str) -> None:
        if self.debug_fp is not None:
            self.debug_fp.write(f"{time.time_ns()} {text}\n")

    def debug_send(self, msg: dict) -> None:
        typ = msg.get("type")
        if typ == "move":
            self.debug_sample += 1
            if self.debug_sample % 30:
                return
        self.debug(f"send seq={msg.get('seq')} type={self.describe_msg(msg)}")

    def describe_msg(self, msg: dict) -> str:
        typ = msg.get("type")
        if typ == "batch":
            inner = "+".join(str(item.get("type", "?")) for item in msg.get("items", []) if isinstance(item, dict))
            return f"batch:{inner}"
        if typ == "button":
            return f"button:{msg.get('button')}:{'down' if msg.get('down') else 'up'}"
        if typ == "key":
            return f"key:{msg.get('qcode')}:{'down' if msg.get('down') else 'up'}"
        return str(typ)

    def send_batch(self, items: list[dict]) -> None:
        if len(items) == 1:
            self.send(items[0])
        elif items:
            self.send({"type": "batch", "items": items})

    def set_status(self, text: str) -> None:
        if self.status_item is not None:
            self.canvas.itemconfigure(self.status_item, text=text)

    def on_enter(self, _event: tk.Event) -> None:
        self.root.focus_force()
        self.release_modifiers()

    def release_modifiers(self) -> None:
        for qcode in ("shift", "shift_r", "ctrl", "ctrl_r", "alt", "alt_r"):
            self.send_key(qcode, False)
        self.set_status("input: modifiers reset")

    def send_key(self, qcode: str, down: bool) -> None:
        if qcode in ("shift", "shift_r", "ctrl", "ctrl_r", "alt", "alt_r"):
            if down:
                self.guest_modifiers.add(qcode)
            else:
                self.guest_modifiers.discard(qcode)
        self.send({"type": "key", "qcode": qcode, "down": down})

    def tap_key(self, qcode: str) -> None:
        self.send_key(qcode, True)
        self.send_key(qcode, False)

    def tap_letter(self, qcode: str, want_upper: bool) -> None:
        held_shifts = [q for q in ("shift", "shift_r") if q in self.guest_modifiers]
        added_shift = False

        if want_upper and not held_shifts:
            self.send_key("shift", True)
            added_shift = True
        elif not want_upper and held_shifts:
            for q in held_shifts:
                self.send_key(q, False)

        self.send_key(qcode, True)
        self.send_key(qcode, False)

        if added_shift:
            self.send_key("shift", False)
        elif not want_upper and held_shifts:
            for q in held_shifts:
                self.send_key(q, True)

    def follow_video_window(self) -> None:
        if self.follow_title:
            hwnd = find_window_by_title(self.follow_title)
            rect = client_rect_on_screen(hwnd) if hwnd else None
            if self.active_only and hwnd:
                fg = root_window(foreground_window())
                overlay_hwnd = root_window(int(self.root.winfo_id()))
                target_hwnd = root_window(hwnd)
                should_show = fg in (target_hwnd, overlay_hwnd)
                if should_show and not self.visible:
                    self.root.deiconify()
                    self.root.attributes("-topmost", True)
                    self.root.lift()
                    self.visible = True
                    self.set_status("input: following video")
                elif not should_show and self.visible:
                    self.release_modifiers()
                    self.root.attributes("-topmost", False)
                    self.root.withdraw()
                    self.visible = False
            if rect and rect != self.last_geometry:
                x, y, w, h = rect
                self.root.geometry(f"{w}x{h}+{x}+{y}")
                self.last_geometry = rect
                self.set_status("input: following video")
            elif not rect:
                self.set_status("input: waiting for video")
        self.root.after(self.follow_interval_ms, self.follow_video_window)

    def on_configure(self, _event: tk.Event) -> None:
        w = self.canvas.winfo_width()
        self.canvas.coords(self.title_item, w // 2, 28)
        self.canvas.coords(self.help_item, w // 2, 56)

    def qcoords(self, event: tk.Event) -> tuple[int, int]:
        w = max(1, self.canvas.winfo_width() - 1)
        h = max(1, self.canvas.winfo_height() - 1)
        x = max(0, min(w, int(event.x)))
        y = max(0, min(h, int(event.y)))
        return round(x * 0x7FFF / w), round(y * 0x7FFF / h)

    def on_motion(self, event: tk.Event) -> None:
        self.pending_motion = self.qcoords(event)
        self.schedule_motion_flush()

    def schedule_motion_flush(self) -> None:
        if self.motion_flush_scheduled:
            return
        now = time.monotonic()
        elapsed_ms = (now - self.last_motion_sent) * 1000.0
        delay_ms = 0 if elapsed_ms >= self.motion_interval_ms else int(self.motion_interval_ms - elapsed_ms)
        self.motion_flush_scheduled = True
        self.root.after(delay_ms, self.flush_motion)

    def flush_motion(self) -> None:
        self.motion_flush_scheduled = False
        if self.pending_motion is None:
            return
        x, y = self.pending_motion
        self.pending_motion = None
        self.last_motion_sent = time.monotonic()
        self.send({"type": "move", "x": x, "y": y})
        if self.pending_motion is not None:
            self.schedule_motion_flush()

    def on_button_press(self, event: tk.Event) -> None:
        self.root.focus_force()
        button = {1: "left", 2: "middle", 3: "right"}.get(event.num)
        if button:
            x, y = self.qcoords(event)
            self.pending_motion = None
            self.last_motion_sent = time.monotonic()
            self.send_batch([
                {"type": "move", "x": x, "y": y},
                {"type": "button", "button": button, "down": True},
            ])

    def on_button_release(self, event: tk.Event) -> None:
        button = {1: "left", 2: "middle", 3: "right"}.get(event.num)
        if button:
            self.send({"type": "button", "button": button, "down": False})

    def on_wheel(self, event: tk.Event) -> None:
        delta = 1 if event.delta > 0 else -1
        self.send({"type": "wheel", "delta": delta})

    def qcode_for(self, event: tk.Event) -> str | None:
        ks = event.keysym
        if ks == "Escape":
            self.root.destroy()
            return None
        if len(ks) == 1:
            ch = ks.lower()
            if "a" <= ch <= "z" or "0" <= ch <= "9":
                return ch
        return KEYMAP.get(ks)

    def is_plain_letter(self, event: tk.Event) -> bool:
        if event.keysym in ("Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R"):
            return False
        return len(event.keysym) == 1 and event.keysym.lower() in "abcdefghijklmnopqrstuvwxyz"

    def wants_uppercase(self, event: tk.Event) -> bool:
        if event.char and len(event.char) == 1 and event.char.isalpha():
            want_upper = event.char.isupper()
        else:
            want_upper = bool(event.state & 0x0001)
        return not want_upper if self.invert_case else want_upper

    def on_key_press(self, event: tk.Event) -> None:
        if event.keysym == "End" and (event.state & 0x000c) == 0x000c:
            self.send({"type": "combo", "qcodes": ["ctrl", "alt", "delete"]})
            return
        if event.keysym.lower() == "c" and (event.state & 0x000c) == 0x000c:
            self.tap_key("caps_lock")
            self.set_status("input: toggled guest CapsLock")
            return
        if event.keysym.lower() == "i" and (event.state & 0x000c) == 0x000c:
            self.invert_case = not self.invert_case
            self.set_status(f"input: case invert {'on' if self.invert_case else 'off'}")
            return
        if event.keysym.lower() == "r" and (event.state & 0x000c) == 0x000c:
            self.release_modifiers()
            return
        if event.keysym == "Caps_Lock":
            self.set_status("input: host Caps only; Ctrl+Alt+C toggles guest Caps")
            return
        if self.is_plain_letter(event) and not (event.state & 0x000c):
            self.tap_letter(event.keysym.lower(), self.wants_uppercase(event))
            return
        qcode = self.qcode_for(event)
        if qcode:
            self.send_key(qcode, True)

    def on_key_release(self, event: tk.Event) -> None:
        if event.keysym == "Caps_Lock":
            return
        if self.is_plain_letter(event) and not (event.state & 0x000c):
            return
        qcode = self.qcode_for(event)
        if qcode:
            self.send_key(qcode, False)

    def run(self) -> None:
        self.root.mainloop()
        if self.debug_fp is not None:
            self.debug("stop")
            self.debug_fp.close()
        if self.sock is not None:
            self.sock.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="192.168.0.188")
    parser.add_argument("--port", type=int, default=5905)
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=600)
    parser.add_argument("--alpha", type=float, default=0.22)
    parser.add_argument("--follow-title")
    parser.add_argument("--follow-interval-ms", type=int, default=200)
    parser.add_argument("--active-only", action="store_true")
    parser.add_argument("--motion-interval-ms", type=int, default=16)
    parser.add_argument("--debug-log")
    parser.add_argument("--invert-case", action="store_true")
    args = parser.parse_args()

    ControlOverlay(
        args.host,
        args.port,
        args.width,
        args.height,
        args.alpha,
        args.follow_title,
        args.follow_interval_ms,
        args.active_only,
        args.motion_interval_ms,
        args.debug_log,
        args.invert_case,
    ).run()


if __name__ == "__main__":
    main()
