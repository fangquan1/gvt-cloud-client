from __future__ import annotations

import argparse
import ctypes
import json
import os
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from ctypes import wintypes
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GSTROOT = ROOT / "tools" / "gstreamer-1.0-mingw-x86_64-1.18.6" / "gstreamer" / "1.0" / "mingw_x86_64"
LOG_PATH = Path(__file__).with_name("native-client.log")

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)

GWL_STYLE = -16
GWLP_WNDPROC = -4
WS_CHILD = 0x40000000
WS_POPUP = 0x80000000
WS_CAPTION = 0x00C00000
WS_THICKFRAME = 0x00040000
WS_SYSMENU = 0x00080000
WS_MINIMIZEBOX = 0x00020000
WS_MAXIMIZEBOX = 0x00010000
SWP_NOZORDER = 0x0004
SWP_FRAMECHANGED = 0x0020

WM_DESTROY = 0x0002
WM_CLOSE = 0x0010
WM_SETFOCUS = 0x0007
WM_KILLFOCUS = 0x0008
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_RBUTTONDOWN = 0x0204
WM_RBUTTONUP = 0x0205
WM_MBUTTONDOWN = 0x0207
WM_MBUTTONUP = 0x0208
WM_MOUSEWHEEL = 0x020A
WM_SIZE = 0x0005
SW_HIDE = 0

VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12
VK_LSHIFT = 0xA0
VK_RSHIFT = 0xA1
VK_LCONTROL = 0xA2
VK_RCONTROL = 0xA3
VK_LMENU = 0xA4
VK_RMENU = 0xA5
MAPVK_VSC_TO_VK_EX = 3


if ctypes.sizeof(ctypes.c_void_p) == 8:
    GetWindowLongPtr = user32.GetWindowLongPtrW
    SetWindowLongPtr = user32.SetWindowLongPtrW
else:
    GetWindowLongPtr = user32.GetWindowLongW
    SetWindowLongPtr = user32.SetWindowLongW

GetWindowLongPtr.restype = ctypes.c_longlong
GetWindowLongPtr.argtypes = [wintypes.HWND, ctypes.c_int]
SetWindowLongPtr.restype = ctypes.c_longlong
SetWindowLongPtr.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_longlong]
user32.CallWindowProcW.restype = ctypes.c_longlong
user32.CallWindowProcW.argtypes = [ctypes.c_longlong, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SetParent.argtypes = [wintypes.HWND, wintypes.HWND]
user32.SetParent.restype = wintypes.HWND
user32.SetWindowPos.argtypes = [
    wintypes.HWND,
    wintypes.HWND,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint,
]
user32.SetFocus.argtypes = [wintypes.HWND]
user32.SetFocus.restype = wintypes.HWND


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


KEYMAP: dict[int, str] = {
    0x08: "backspace",
    0x09: "tab",
    0x0D: "ret",
    0x1B: "esc",
    0x20: "spc",
    0x21: "pgup",
    0x22: "pgdn",
    0x23: "end",
    0x24: "home",
    0x25: "left",
    0x26: "up",
    0x27: "right",
    0x28: "down",
    0x2D: "insert",
    0x2E: "delete",
    0x5B: "meta_l",
    0x5C: "meta_r",
    0x5D: "menu",
    VK_LSHIFT: "shift",
    VK_RSHIFT: "shift_r",
    VK_LCONTROL: "ctrl",
    VK_RCONTROL: "ctrl_r",
    VK_LMENU: "alt",
    VK_RMENU: "alt_r",
    0x14: "caps_lock",
    0x90: "num_lock",
    0x91: "scroll_lock",
    0xBA: "semicolon",
    0xBB: "equal",
    0xBC: "comma",
    0xBD: "minus",
    0xBE: "dot",
    0xBF: "slash",
    0xC0: "grave_accent",
    0xDB: "bracket_left",
    0xDC: "backslash",
    0xDD: "bracket_right",
    0xDE: "apostrophe",
}

for vk in range(ord("A"), ord("Z") + 1):
    KEYMAP[vk] = chr(vk).lower()
for vk in range(ord("0"), ord("9") + 1):
    KEYMAP[vk] = chr(vk)
for i in range(1, 25):
    KEYMAP[0x70 + i - 1] = f"f{i}"
for i in range(10):
    KEYMAP[0x60 + i] = f"kp_{i}"
KEYMAP.update({
    0x6A: "kp_multiply",
    0x6B: "kp_add",
    0x6D: "kp_subtract",
    0x6E: "kp_decimal",
    0x6F: "kp_divide",
})


def signed_word(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def windows_by_pid(pid: int) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def enum_proc(hwnd: int, _lparam: int) -> bool:
        if not user32.IsWindowVisible(hwnd):
            return True
        proc_id = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(proc_id))
        if proc_id.value == pid:
            length = user32.GetWindowTextLengthW(hwnd)
            title = ""
            if length > 0:
                buf = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(hwnd, buf, length + 1)
                title = buf.value
            found.append((hwnd, title))
        return True

    user32.EnumWindows(enum_proc, 0)
    return found


def find_video_window_by_pid(pid: int) -> int | None:
    found = windows_by_pid(pid)
    for hwnd, title in found:
        if "direct3d" in title.lower() or "renderer" in title.lower():
            return hwnd
    return None


class InputSender:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self.sock: socket.socket | None = None
        self.lock = threading.Lock()
        self.last_error = ""

    def close(self) -> None:
        with self.lock:
            if self.sock is not None:
                try:
                    self.sock.close()
                except OSError:
                    pass
            self.sock = None

    def connect(self) -> None:
        if self.sock is not None:
            return
        sock = socket.create_connection((self.host, self.port), timeout=1.5)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self.last_error = ""

    def send(self, msg: dict) -> None:
        with self.lock:
            try:
                self.connect()
                assert self.sock is not None
                self.sock.sendall((json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8"))
            except OSError as exc:
                self.last_error = str(exc)
                if self.sock is not None:
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                self.sock = None


class NativeClient:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.sender = InputSender(args.input_host, args.input_port)
        self.gst_proc: subprocess.Popen | None = None
        self.video_hwnd: int | None = None
        self.old_proc: int | None = None
        self.wndproc_ref: WNDPROC | None = None
        self.last_move = 0.0
        self.buttons_down: set[str] = set()
        self.keys_down: set[str] = set()
        self.running = True

        self.root = tk.Tk()
        self.root.title("GVT Native Client")
        self.root.geometry(f"{args.width}x{args.height}+80+80")
        self.root.minsize(640, 400)
        self.root.configure(bg="black")
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.bind("<Configure>", lambda _event: self.resize_video())
        self.root.bind("<FocusIn>", lambda _event: self.focus_video())
        self.status = tk.Label(
            self.root,
            text="starting video...",
            fg="#d6f6ff",
            bg="black",
            anchor="w",
            padx=8,
        )
        self.status.pack(side="bottom", fill="x")

    def gst_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = str(GSTROOT / "bin") + os.pathsep + env.get("PATH", "")
        env["GST_PLUGIN_PATH"] = str(GSTROOT / "lib" / "gstreamer-1.0")
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = env["GST_PLUGIN_PATH"]
        env["GST_REGISTRY"] = str(ROOT / "tools" / "gst-registry-gvt-native.bin")
        return env

    def gst_command(self) -> list[str]:
        caps = (
            "application/x-rtp, media=(string)video, clock-rate=(int)90000, "
            "encoding-name=(string)H264, payload=(int)96, ssrc=(uint)2222"
        )
        return [
            str(GSTROOT / "bin" / "gst-launch-1.0.exe"),
            "-e",
            "udpsrc",
            f"port={self.args.rtp_port}",
            "buffer-size=4194304",
            f"caps={caps}",
            "!",
            "rtpstorage",
            "size-time=1000000000",
            "name=storage",
            "!",
            "rtpjitterbuffer",
            f"latency={self.args.latency_ms}",
            "drop-on-latency=false",
            "do-lost=true",
            "!",
            "rtpulpfecdec",
            "pt=122",
            "!",
            "rtph264depay",
            "!",
            "h264parse",
            "!",
            "d3d11h264dec",
            "!",
            "d3d11videosink",
            "sync=false",
        ]

    def start_video(self) -> None:
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
        self.gst_proc = subprocess.Popen(
            self.gst_command(),
            cwd=str(ROOT),
            env=self.gst_env(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )
        deadline = time.monotonic() + self.args.video_window_timeout
        while time.monotonic() < deadline:
            hwnd = find_video_window_by_pid(self.gst_proc.pid)
            if hwnd:
                self.embed_video(hwnd)
                self.hide_extra_gst_windows(hwnd)
                return
            if self.gst_proc.poll() is not None:
                raise RuntimeError("GStreamer receiver exited before creating a window")
            time.sleep(0.1)
        if self.gst_proc and self.gst_proc.poll() is None:
            try:
                self.gst_proc.terminate()
            except Exception:
                pass
        raise RuntimeError("Timed out waiting for GStreamer video window")

    def embed_video(self, hwnd: int) -> None:
        self.video_hwnd = hwnd
        parent = int(self.root.winfo_id())
        user32.SetParent(hwnd, parent)
        style = int(GetWindowLongPtr(hwnd, GWL_STYLE))
        style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)
        style |= WS_CHILD
        SetWindowLongPtr(hwnd, GWL_STYLE, style)
        self.wndproc_ref = WNDPROC(self.window_proc)
        self.old_proc = int(SetWindowLongPtr(hwnd, GWLP_WNDPROC, ctypes.cast(self.wndproc_ref, ctypes.c_void_p).value))
        self.status.configure(text="video ready - click inside this window to control the VM")
        self.resize_video()
        self.focus_video()

    def hide_extra_gst_windows(self, video_hwnd: int) -> None:
        if not self.gst_proc:
            return
        for hwnd, _title in windows_by_pid(self.gst_proc.pid):
            if hwnd != video_hwnd:
                user32.ShowWindow(hwnd, SW_HIDE)

    def resize_video(self) -> None:
        if not self.video_hwnd:
            return
        width = max(1, self.root.winfo_width())
        height = max(1, self.root.winfo_height() - self.status.winfo_height())
        user32.SetWindowPos(self.video_hwnd, 0, 0, 0, width, height, SWP_NOZORDER | SWP_FRAMECHANGED)

    def focus_video(self) -> None:
        if self.video_hwnd:
            user32.SetFocus(self.video_hwnd)

    def qcoords(self, lparam: int) -> tuple[int, int]:
        x = signed_word(lparam)
        y = signed_word(lparam >> 16)
        rect = RECT()
        if self.video_hwnd and user32.GetClientRect(self.video_hwnd, ctypes.byref(rect)):
            w = max(1, rect.right - rect.left - 1)
            h = max(1, rect.bottom - rect.top - 1)
        else:
            w, h = max(1, self.args.width - 1), max(1, self.args.height - 1)
        x = max(0, min(w, x))
        y = max(0, min(h, y))
        return round(x * 0x7FFF / w), round(y * 0x7FFF / h)

    def send_move(self, lparam: int) -> None:
        now = time.monotonic()
        if now - self.last_move < 0.004:
            return
        self.last_move = now
        x, y = self.qcoords(lparam)
        self.sender.send({"type": "move", "x": x, "y": y})

    def send_button(self, button: str, down: bool, lparam: int) -> None:
        x, y = self.qcoords(lparam)
        self.sender.send({"type": "move", "x": x, "y": y})
        self.sender.send({"type": "button", "button": button, "down": down})
        if down:
            self.buttons_down.add(button)
        else:
            self.buttons_down.discard(button)

    def effective_vk(self, wparam: int, lparam: int) -> int:
        scancode = (lparam >> 16) & 0xFF
        extended = bool(lparam & 0x01000000)
        if wparam in (VK_SHIFT, VK_CONTROL, VK_MENU):
            vk = user32.MapVirtualKeyW(scancode | (0xE000 if extended else 0), MAPVK_VSC_TO_VK_EX)
            return int(vk) or int(wparam)
        return int(wparam)

    def send_key(self, wparam: int, lparam: int, down: bool) -> None:
        vk = self.effective_vk(wparam, lparam)
        qcode = KEYMAP.get(vk)
        if not qcode:
            return
        if down:
            self.keys_down.add(qcode)
        else:
            self.keys_down.discard(qcode)
        self.sender.send({"type": "key", "qcode": qcode, "down": down})

    def release_all(self) -> None:
        for button in list(self.buttons_down):
            self.sender.send({"type": "button", "button": button, "down": False})
        self.buttons_down.clear()
        for qcode in list(self.keys_down):
            self.sender.send({"type": "key", "qcode": qcode, "down": False})
        self.keys_down.clear()

    def window_proc(self, hwnd: int, msg: int, wparam: int, lparam: int) -> int:
        if msg == WM_SETFOCUS:
            self.status.configure(text="input: focused")
        elif msg == WM_KILLFOCUS:
            self.release_all()
            self.status.configure(text="input: not focused")
        elif msg == WM_MOUSEMOVE:
            self.send_move(lparam)
        elif msg == WM_LBUTTONDOWN:
            user32.SetFocus(hwnd)
            self.send_button("left", True, lparam)
        elif msg == WM_LBUTTONUP:
            self.send_button("left", False, lparam)
        elif msg == WM_RBUTTONDOWN:
            user32.SetFocus(hwnd)
            self.send_button("right", True, lparam)
        elif msg == WM_RBUTTONUP:
            self.send_button("right", False, lparam)
        elif msg == WM_MBUTTONDOWN:
            user32.SetFocus(hwnd)
            self.send_button("middle", True, lparam)
        elif msg == WM_MBUTTONUP:
            self.send_button("middle", False, lparam)
        elif msg == WM_MOUSEWHEEL:
            wheel = signed_word(wparam >> 16)
            self.sender.send({"type": "wheel", "delta": 1 if wheel > 0 else -1})
        elif msg in (WM_KEYDOWN, WM_SYSKEYDOWN):
            self.send_key(wparam, lparam, True)
        elif msg in (WM_KEYUP, WM_SYSKEYUP):
            self.send_key(wparam, lparam, False)
        elif msg == WM_CLOSE:
            self.close()
            return 0
        if self.old_proc:
            return user32.CallWindowProcW(self.old_proc, hwnd, msg, wparam, lparam)
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam)

    def poll_status(self) -> None:
        if not self.running:
            return
        if self.gst_proc and self.gst_proc.poll() is not None:
            self.status.configure(text=f"video receiver exited ({self.gst_proc.returncode})")
        elif self.sender.last_error:
            self.status.configure(text=f"input reconnecting: {self.sender.last_error}")
        self.root.after(1000, self.poll_status)

    def close(self) -> None:
        if not self.running:
            return
        self.running = False
        self.release_all()
        self.sender.close()
        if self.video_hwnd and self.old_proc:
            try:
                SetWindowLongPtr(self.video_hwnd, GWLP_WNDPROC, self.old_proc)
            except OSError:
                pass
        if self.gst_proc and self.gst_proc.poll() is None:
            try:
                self.gst_proc.terminate()
                self.gst_proc.wait(timeout=2)
            except Exception:
                try:
                    self.gst_proc.kill()
                except Exception:
                    pass
        self.root.destroy()

    def run(self) -> None:
        try:
            self.root.update()
            self.start_video()
            self.root.after(1000, self.poll_status)
            self.root.mainloop()
        except Exception:
            self.close()
            raise


def main() -> None:
    try:
        log = LOG_PATH.open("a", encoding="utf-8", buffering=1)
        sys.stdout = log
        sys.stderr = log
        print(f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}] starting gvt native client")
    except OSError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--rtp-port", type=int, default=5004)
    parser.add_argument("--input-host", default="192.168.0.188")
    parser.add_argument("--input-port", type=int, default=5905)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--latency-ms", type=int, default=80)
    parser.add_argument("--video-window-timeout", type=float, default=30.0)
    args = parser.parse_args()
    try:
        NativeClient(args).run()
    except Exception as exc:
        print(f"gvt native client failed: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
