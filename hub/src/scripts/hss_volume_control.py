#!/usr/bin/env python3
"""
Optimized Volume Controller for Snapcast with GC9A01 Display & EC11 Encoder.
Includes smooth state interpolation for fluid arc animations and dimming transitions.
"""

import json
import queue
import select
import signal
import socket
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional
import spidev
from PIL import Image, ImageDraw, ImageFont
import RPi.GPIO as GPIO
from gpiozero import RotaryEncoder, Button

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

# Hardware pin configuration (BCM numbering)
DC_PIN = 24
RST_PIN = 25

# EC11 Rotary Encoder pin configuration
ENCODER_A = 17
ENCODER_B = 27
ENCODER_SW = 22

# ==============================================================================
# ENCODER & ACCELERATION CONFIGURATION
# ==============================================================================
INVERT_DIRECTION = True

ACCEL_VERY_FAST_THRESHOLD = 0.015  # 15ms
ACCEL_FAST_THRESHOLD      = 0.035  # 35ms

ACCEL_VERY_FAST_STEP = 3.0
ACCEL_FAST_STEP      = 2.0
ACCEL_NORMAL_STEP    = 1.0

# ==============================================================================
# ANIMATION & SMOOTHING CONFIGURATION
# ==============================================================================
# Higher value = snappier response, Lower value = smoother floating transition
VOLUME_LERP_FACTOR = 0.35
BRIGHTNESS_LERP_FACTOR = 0.08
TARGET_FPS = 60.0
BACKLIGHT_PIN = 18
BACKLIGHT_PWM_FREQUENCY = 1000
IDLE_AFTER_S = 10.0
SYNC_DELAY_S = 0.5
# ==============================================================================


@dataclass(frozen=True)
class VolumeSnapshot:
    """Immutable state snapshot shared by the worker threads."""

    volume: float
    muted: bool
    last_activity: float


class Backlight:
    """Hardware PWM backlight with an idempotent resource lifecycle."""

    def __init__(self, pin=BACKLIGHT_PIN, frequency_hz=BACKLIGHT_PWM_FREQUENCY):
        self._pin = pin
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        GPIO.setup(self._pin, GPIO.OUT)
        self._pwm = GPIO.PWM(self._pin, frequency_hz)
        self._pwm.start(100.0)
        self._last_percent = 100.0

    def set_brightness(self, brightness):
        percent = max(2.0, min(100.0, brightness * 100.0))
        if abs(percent - self._last_percent) >= 0.1:
            self._pwm.ChangeDutyCycle(percent)
            self._last_percent = percent

    def close(self):
        self._pwm.stop()


class GC9A01Display:
    """High-performance direct SPI driver for GC9A01 operating at 60MHz SPI clock."""
    def __init__(self, port=0, device=0, speed_hz=60000000, dc=DC_PIN, rst=RST_PIN):
        self.dc = dc
        self.rst = rst
        self.width = 240
        self.height = 240
        self._pixel_buffer = bytearray(self.width * self.height * 2)
        self._closed = False

        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        GPIO.setup(self.dc, GPIO.OUT)
        GPIO.setup(self.rst, GPIO.OUT)

        self.spi = spidev.SpiDev()
        self.spi.open(port, device)
        self.spi.max_speed_hz = speed_hz
        self.spi.mode = 0

        self.reset()
        self.init_display()

    def send_command(self, cmd):
        GPIO.output(self.dc, GPIO.LOW)
        if hasattr(self.spi, "writebytes2"):
            self.spi.writebytes2(bytes([cmd]))
        else:
            self.spi.writebytes([cmd])

    def send_data(self, data):
        GPIO.output(self.dc, GPIO.HIGH)
        if isinstance(data, int):
            b = bytes([data])
        elif isinstance(data, (list, bytearray, bytes)):
            b = bytes(data)

        if hasattr(self.spi, "writebytes2"):
            self.spi.writebytes2(b)
        else:
            self.spi.writebytes(list(b))

    def reset(self):
        GPIO.output(self.rst, GPIO.HIGH)
        time.sleep(0.01)
        GPIO.output(self.rst, GPIO.LOW)
        time.sleep(0.01)
        GPIO.output(self.rst, GPIO.HIGH)
        time.sleep(0.12)

    def init_display(self):
        for cmd, data in (
            (0xEF, None), (0xEB, 0x14), (0xFE, None), (0xEF, None),
            (0xEB, 0x14), (0x84, 0x40), (0x85, 0xFF), (0x86, 0xFF),
            (0x87, 0xFF), (0x88, 0x0A), (0x89, 0x21), (0x8A, 0x00),
            (0x8B, 0x80), (0x8C, 0x01), (0x8D, 0x01), (0x8E, 0xFF),
            (0x8F, 0xFF), (0xB6, [0x00, 0x00]), (0x36, 0x48), (0x3A, 0x05),
            (0x90, [0x08, 0x08, 0x08, 0x08]), (0xBD, 0x06), (0xBC, 0x00),
            (0xFF, [0x60, 0x01, 0x04]), (0xC3, 0x13), (0xC4, 0x13),
            (0xC9, 0x22), (0xBE, 0x11), (0xE1, [0x10, 0x0E]),
            (0xDF, [0x21, 0x0C, 0x02]), (0xF0, [0x45, 0x09, 0x08, 0x08, 0x26, 0x2A]),
            (0xF1, [0x43, 0x70, 0x72, 0x36, 0x37, 0x6F]),
            (0xF2, [0x45, 0x09, 0x08, 0x08, 0x26, 0x2A]),
            (0xF3, [0x43, 0x70, 0x72, 0x36, 0x37, 0x6F]),
            (0xED, [0x1B, 0x0B]), (0xAE, 0x77), (0xCD, 0x63),
            (0x70, [0x07, 0x07, 0x04, 0x0E, 0x0F, 0x09, 0x07, 0x08, 0x03]),
            (0xE8, 0x34),
            (0x62, [0x18, 0x0D, 0x71, 0xED, 0x70, 0x70, 0x18, 0x0D, 0x71, 0xED, 0x70, 0x70]),
            (0x63, [0x18, 0x11, 0x71, 0xF1, 0x70, 0x70, 0x18, 0x11, 0x71, 0xF1, 0x70, 0x70]),
            (0x64, [0x28, 0x29, 0xF1, 0x01, 0xF1, 0x00, 0x07]),
            (0x66, [0x3C, 0x00, 0xCD, 0x67, 0x45, 0x45, 0x10, 0x00, 0x00, 0x00]),
            (0x67, [0x00, 0x3C, 0x00, 0x00, 0x00, 0x01, 0x54, 0x10, 0x32, 0x98]),
            (0x74, [0x10, 0x85, 0x80, 0x00, 0x00, 0x4E, 0x00]),
            (0x98, [0x3E, 0x07]), (0x35, None), (0x21, None), (0x11, None)
        ):
            self.send_command(cmd)
            if data is not None:
                self.send_data(data)
            if cmd == 0x11:
                time.sleep(0.12)
        self.send_command(0x29)
        time.sleep(0.02)

    def set_window(self, x0, y0, x1, y1):
        self.send_command(0x2A)
        self.send_data([x0 >> 8, x0 & 0xFF, x1 >> 8, x1 & 0xFF])
        self.send_command(0x2B)
        self.send_data([y0 >> 8, y0 & 0xFF, y1 >> 8, y1 & 0xFF])
        self.send_command(0x2C)

    def display(self, image, brightness=1.0):
        self.set_window(0, 0, self.width - 1, self.height - 1)

        if HAS_NUMPY:
            img_arr = np.frombuffer(
                image.tobytes(), dtype=np.uint8
            ).reshape((self.height, self.width, 3))

            if brightness < 0.99:
                b_scale = int(max(0.02, brightness) * 256)
                img_arr = ((img_arr.astype(np.uint16) * b_scale) >> 8).astype(np.uint8)

            r = (img_arr[:, :, 0].astype(np.uint16) & 0xF8) << 8
            g = (img_arr[:, :, 1].astype(np.uint16) & 0xFC) << 3
            b = img_arr[:, :, 2].astype(np.uint16) >> 3
            rgb565 = r | g | b

            self._pixel_buffer[0::2] = ((rgb565 >> 8) & 0xFF).astype(np.uint8).tobytes()
            self._pixel_buffer[1::2] = (rgb565 & 0xFF).astype(np.uint8).tobytes()
            raw_bytes = self._pixel_buffer
        else:
            raw = image.convert("RGB").tobytes()
            buffer = bytearray(self.width * self.height * 2)
            buf_idx = 0
            b_factor = max(0.02, brightness) if brightness < 0.99 else 1.0
            for i in range(0, len(raw), 3):
                r_val = int(raw[i] * b_factor)
                g_val = int(raw[i+1] * b_factor)
                b_val = int(raw[i+2] * b_factor)
                rgb565 = ((r_val & 0xF8) << 8) | ((g_val & 0xFC) << 3) | (b_val >> 3)
                buffer[buf_idx] = (rgb565 >> 8) & 0xFF
                buffer[buf_idx + 1] = rgb565 & 0xFF
                buf_idx += 2
            self._pixel_buffer[:] = buffer
            raw_bytes = self._pixel_buffer

        GPIO.output(self.dc, GPIO.HIGH)
        chunk_size = 8192
        use_writebytes2 = hasattr(self.spi, "writebytes2")

        for i in range(0, len(raw_bytes), chunk_size):
            chunk = raw_bytes[i : i + chunk_size]
            if use_writebytes2:
                self.spi.writebytes2(chunk)
            else:
                self.spi.writebytes(list(chunk))

    def close(self):
        if not self._closed:
            self.spi.close()
            self._closed = True


class SnapcastRPCClient:
    """Single-worker Snapcast client with coalesced writes and idle polling."""
    IDLE_AFTER_S = 10.0
    STATUS_INTERVAL_S = 5.0
    RPC_TIMEOUT_S = 0.5

    def __init__(self, state: "VolumeState", host: str = "127.0.0.1",
                 port: int = 1705):
        self.state = state
        self.host = host
        self.port = port
        self.connected = False
        self._stop_event = threading.Event()
        self._volume_queue = queue.Queue(maxsize=1)
        self._client_ids = ()
        self._client_lock = threading.Lock()
        self._worker = threading.Thread(target=self._run, name="snapcast-rpc")
        self._worker.start()

    def _send_rpc(self, method: str, params: Optional[dict] = None) -> Optional[dict]:
        if self._stop_event.is_set():
            return None

        try:
            with socket.create_connection((self.host, self.port), timeout=self.RPC_TIMEOUT_S) as sock:
                sock.setblocking(False)
                req = {"id": 1, "jsonrpc": "2.0", "method": method}
                if params:
                    req["params"] = params
                request_data = (json.dumps(req) + "\r\n").encode("utf-8")
                sent = 0
                deadline = time.monotonic() + self.RPC_TIMEOUT_S
                while sent < len(request_data) and not self._stop_event.is_set():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return None
                    _, writable, _ = select.select([], [sock], [], remaining)
                    if not writable:
                        return None
                    try:
                        sent += sock.send(request_data[sent:])
                    except BlockingIOError:
                        continue

                response_data = bytearray()
                while not self._stop_event.is_set():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    readable, _, _ = select.select([sock], [], [], remaining)
                    if not readable:
                        break
                    try:
                        chunk = sock.recv(4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        break
                    response_data.extend(chunk)
                    if b"\r\n" in response_data:
                        break
                if response_data:
                    return json.loads(response_data.decode("utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            self.connected = False
        return None

    @staticmethod
    def _status_values(response: Any):
        """Return discovered clients and the first active client's volume."""
        if not isinstance(response, dict):
            return (), None
        groups = response.get("result", {}).get("server", {}).get("groups", [])
        if not isinstance(groups, list):
            return (), None
        discovered_ids = tuple(
            client_id
            for group in groups
            for client in group.get("clients", [])
            if (client_id := client.get("id"))
        )
        clients = [client for group in groups for client in group.get("clients", [])]
        if not clients:
            return discovered_ids, None

        volume = clients[0].get("config", {}).get("volume", {})
        try:
            percentage = float(volume.get("percent", 50.0))
        except (TypeError, ValueError):
            percentage = 50.0
        return discovered_ids, (max(0.0, min(100.0, percentage)),
                                bool(volume.get("muted", False)))

    def _apply_status(self, response, force=False):
        client_ids, remote_state = self._status_values(response)
        with self._client_lock:
            self._client_ids = client_ids

        if remote_state is None:
            return

        if force:
            self.state.set_from_snapcast(*remote_state)
            return

        remote_volume, remote_muted = remote_state
        self.state.set_from_snapcast_if_idle(
            remote_volume,
            remote_muted,
            self.IDLE_AFTER_S,
        )

    def _initial_sync(self):
        res = self._send_rpc("Server.GetStatus")
        if res:
            self.connected = True
            self._apply_status(res, force=True)

    def _poll_if_idle(self):
        now = time.monotonic()
        snapshot = self.state.snapshot()
        if now - snapshot.last_activity < self.IDLE_AFTER_S:
            return False

        response = self._send_rpc("Server.GetStatus")
        if response:
            self.connected = True
            self._apply_status(response)
        return True

    def push_volume(self, target_vol, muted):
        update = (float(target_vol), bool(muted))
        try:
            self._volume_queue.put_nowait(update)
        except queue.Full:
            try:
                self._volume_queue.get_nowait()
            except queue.Empty:
                pass
            try:
                self._volume_queue.put_nowait(update)
            except queue.Full:
                pass

    def _run(self):
        self._initial_sync()
        next_status_poll = time.monotonic() + self.STATUS_INTERVAL_S
        while not self._stop_event.is_set():
            now = time.monotonic()
            if now >= next_status_poll:
                self._poll_if_idle()
                next_status_poll = time.monotonic() + self.STATUS_INTERVAL_S

            poll_due = max(0.0, next_status_poll - time.monotonic())
            try:
                target_vol, muted = self._volume_queue.get(timeout=min(0.1, poll_due))
            except queue.Empty:
                continue

            with self._client_lock:
                client_ids = self._client_ids
            if not client_ids:
                self._initial_sync()
                with self._client_lock:
                    client_ids = self._client_ids

            params = {"volume": {"percent": int(round(target_vol)), "muted": muted}}
            for client_id in client_ids:
                if self._stop_event.is_set():
                    break
                self._send_rpc("Client.SetVolume", {"id": client_id, **params})

    def close(self):
        self._stop_event.set()
        try:
            self._volume_queue.put_nowait((0.0, False))
        except queue.Full:
            pass
        self._worker.join(timeout=1.5)


class EC11DebouncedEncoder:
    """Robust EC11 encoder using gpiozero with time-based acceleration."""
    def __init__(
        self,
        gpio_a: int,
        gpio_b: int,
        gpio_sw: int,
        callback: Callable[[float], None],
        button_callback: Callable[..., None],
        debounce_time_s: float = 0.030,
    ):
        self.gpio_a = gpio_a
        self.gpio_b = gpio_b
        self.gpio_sw = gpio_sw
        self.callback = callback
        self.button_callback = button_callback
        self.debounce_time_s = debounce_time_s

        self.encoder = RotaryEncoder(
            a=self.gpio_a,
            b=self.gpio_b,
            max_steps=0,
        )
        self.button = Button(
            self.gpio_sw,
            pull_up=True,
            bounce_time=0.2,
        )
        self.last_encoder_steps = self.encoder.steps
        self.last_step_time = time.monotonic()
        self._state_lock = threading.Lock()

        self.encoder.when_rotated = self._handle_rotation
        self.button.when_pressed = self.button_callback

    def _handle_rotation(self):
        now = time.monotonic()
        current_steps = self.encoder.steps

        with self._state_lock:
            step_delta = current_steps - self.last_encoder_steps
            self.last_encoder_steps = current_steps
            if step_delta == 0:
                return

            direction = 1 if step_delta > 0 else -1
            if INVERT_DIRECTION:
                direction = -direction

            delta_t = now - self.last_step_time
            if delta_t < self.debounce_time_s:
                return

            self.last_step_time = now
            step_size = (ACCEL_VERY_FAST_STEP if delta_t < ACCEL_VERY_FAST_THRESHOLD else
                         ACCEL_FAST_STEP if delta_t < ACCEL_FAST_THRESHOLD else
                         ACCEL_NORMAL_STEP)
            step = step_size if direction > 0 else -step_size

        self.callback(step)

    def close(self):
        self.encoder.close()
        self.button.close()


def get_volume_color(pct):
    pct = max(0.0, min(100.0, pct))
    col_green = (0, 230, 118)
    col_orange = (255, 152, 0)
    col_red = (255, 52, 52)

    if pct <= 33.0:
        factor = pct / 33.0
        r = int(col_green[0] + factor * (col_orange[0] - col_green[0]))
        g = int(col_green[1] + factor * (col_orange[1] - col_green[1]))
        b = int(col_green[2] + factor * (col_orange[2] - col_green[2]))
    elif pct <= 66.0:
        factor = (pct - 33.0) / 33.0
        r = int(col_orange[0] + factor * (col_red[0] - col_orange[0]))
        g = int(col_orange[1] + factor * (col_red[1] - col_orange[1]))
        b = int(col_orange[2] + factor * (col_red[2] - col_orange[2]))
    else:
        r, g, b = col_red

    return (r, g, b)


def build_gradient_base_image():
    img = Image.new("RGB", (240, 240), (10, 14, 24))
    draw = ImageDraw.Draw(img)
    ring_box = [14, 14, 226, 226]
    ring_width = 14

    for deg in range(-90, 270, 2):
        current_pct = ((deg + 90) / 360.0) * 100.0
        slice_color = get_volume_color(current_pct)
        draw.arc(ring_box, start=deg, end=deg + 3, fill=slice_color, width=ring_width)

    return img


def load_font(size, bold=False):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        pass

    font_paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf" if bold else "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation/LiberationSans.ttf",
    ]
    for path in font_paths:
        try:
            return ImageFont.truetype(path, size)
        except IOError:
            continue

    return ImageFont.load_default()


# Pre-render background elements
base_gradient_img = build_gradient_base_image()
font_large = load_font(84, bold=True)
ring_box = [14, 14, 226, 226]
ring_width = 14
track_color = (28, 38, 58)
muted_ring_color = (90, 15, 15)


def render_frame(volume_pct, muted=False):
    """Render a full UI frame using precise floating point volume values for smooth arc motion."""
    image = base_gradient_img.copy()
    draw = ImageDraw.Draw(image)

    if muted:
        draw.ellipse(ring_box, outline=muted_ring_color, width=ring_width)
    else:
        fill_angle = (volume_pct / 100.0) * 360.0
        if fill_angle < 360.0:
            unfilled_start = -90 + fill_angle
            draw.arc(ring_box, start=unfilled_start, end=270, fill=track_color, width=ring_width)

    # Convert volume to display integer string
    vol_str = f"{int(round(volume_pct))}"
    bbox_vol = draw.textbbox((0, 0), vol_str, font=font_large)
    vw = bbox_vol[2] - bbox_vol[0]
    vh = bbox_vol[3] - bbox_vol[1]

    x_pos = (240 - vw) // 2 - bbox_vol[0]
    if muted:
        volume_center_y = 80
        y_pos = volume_center_y - (bbox_vol[1] + bbox_vol[3]) // 2
    else:
        y_pos = (240 - vh) // 2 - bbox_vol[1]

    volume_color = (60, 68, 80) if muted else (255, 255, 255)
    draw.text((x_pos, y_pos), vol_str, fill=volume_color, font=font_large)

    if muted:
        icon_color = muted_ring_color
        icon_center_x = 120
        icon_top = 128
        speaker_left = icon_center_x - 32
        speaker_right = icon_center_x + 22
        speaker_top = icon_top + 8
        speaker_bottom = icon_top + 72
        draw.polygon(
            [
                (speaker_left, icon_top + 24),
                (speaker_left + 20, icon_top + 24),
                (speaker_right, speaker_top),
                (speaker_right, speaker_bottom),
                (speaker_left + 20, icon_top + 56),
                (speaker_left, icon_top + 56),
            ],
            fill=icon_color,
        )
        draw.line(
            (icon_center_x - 46, icon_top, icon_center_x + 46, icon_top + 80),
            fill=icon_color,
            width=8,
        )

    return image


class VolumeState:
    """Thread-safe synchronized container managing target state and user activity."""
    def __init__(self, volume: float = 50.0):
        self._volume = max(0.0, min(100.0, float(volume)))
        self._muted = False
        self._last_activity = time.monotonic()
        self._pending_sync = False
        self._lock = threading.Lock()

    def on_encoder_step(self, step: float) -> None:
        now = time.monotonic()
        with self._lock:
            self._muted = False
            self._volume = max(0.0, min(100.0, self._volume + step))
            self._last_activity = now
            self._pending_sync = True

    def toggle_mute(self, _event=None) -> bool:
        now = time.monotonic()
        with self._lock:
            self._muted = not self._muted
            self._last_activity = now
            self._pending_sync = True
            return self._muted

    def set_from_snapcast(self, volume: float, muted: bool) -> None:
        with self._lock:
            self._volume = max(0.0, min(100.0, volume))
            self._muted = bool(muted)

    def set_from_snapcast_if_idle(
        self, volume: float, muted: bool, idle_after_s: float
    ) -> bool:
        now = time.monotonic()
        with self._lock:
            if now - self._last_activity < idle_after_s:
                return False

            volume = max(0.0, min(100.0, volume))
            muted = bool(muted)
            changed = abs(self._volume - volume) > 0.01 or self._muted != muted
            if changed:
                self._volume = volume
                self._muted = muted
            return changed

    def snapshot(self) -> VolumeSnapshot:
        with self._lock:
            return VolumeSnapshot(self._volume, self._muted, self._last_activity)

    def take_pending_sync(
        self, now: float, delay_s: float
    ) -> Optional[tuple[float, bool]]:
        with self._lock:
            if self._pending_sync and now - self._last_activity >= delay_s:
                self._pending_sync = False
                return self._volume, self._muted
            return None


app_state = VolumeState()
driver = None
backlight = None
snap_controller = None
encoder = None
shutdown_event = threading.Event()


def request_shutdown(signum, frame):
    shutdown_event.set()


def render_loop():
    """
    High-performance render loop applying linear interpolation (lerp) for smooth 60 FPS
    volume animations and dimming transitions.
    """
    displayed_volume = 50.0
    displayed_brightness = 1.0

    last_rendered_volume = -1.0
    last_rendered_muted = None
    last_rendered_brightness = -1.0

    # Initial state sync
    snapshot = app_state.snapshot()
    displayed_volume = snapshot.volume

    while not shutdown_event.is_set():
        now = time.monotonic()
        snapshot = app_state.snapshot()
        target_vol = snapshot.volume
        last_activity = snapshot.last_activity
        muted = snapshot.muted

        # Calculate target brightness based on inactivity (10 seconds timeout)
        target_brightness = 0.15 if (now - last_activity > 10.0) else 1.0

        # Smooth volume interpolation
        vol_diff = target_vol - displayed_volume
        if abs(vol_diff) > 0.01:
            displayed_volume += vol_diff * VOLUME_LERP_FACTOR
        else:
            displayed_volume = target_vol

        # Smooth brightness interpolation
        bright_diff = target_brightness - displayed_brightness
        if abs(bright_diff) > 0.001:
            displayed_brightness += bright_diff * BRIGHTNESS_LERP_FACTOR
        else:
            displayed_brightness = target_brightness

        # Check if active animation is in progress
        is_animating = (displayed_volume != target_vol) or (displayed_brightness != target_brightness)

        # Detect visual changes requiring display updates
        mute_changed = (muted != last_rendered_muted)
        vol_changed = (abs(displayed_volume - last_rendered_volume) > 0.02)
        bright_changed = (abs(displayed_brightness - last_rendered_brightness) > 0.005)

        if mute_changed or vol_changed or bright_changed:
            image = render_frame(displayed_volume, muted=muted)
            driver.display(image)
            backlight.set_brightness(displayed_brightness)

            last_rendered_volume = displayed_volume
            last_rendered_muted = muted
            last_rendered_brightness = displayed_brightness

        # Adaptive refresh rate: 60 FPS during smooth animations, 20 FPS when idle
        sleep_interval = (1.0 / TARGET_FPS) if is_animating else 0.05
        shutdown_event.wait(sleep_interval)


def run():
    global driver, backlight, snap_controller, encoder
    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)

    try:
        driver = GC9A01Display(port=0, device=0, speed_hz=60000000)
        backlight = Backlight()
        snap_controller = SnapcastRPCClient(app_state)
        encoder = EC11DebouncedEncoder(
            ENCODER_A,
            ENCODER_B,
            ENCODER_SW,
            app_state.on_encoder_step,
            app_state.toggle_mute,
        )

        render_thread = threading.Thread(target=render_loop, name="display-render")
        render_thread.start()
        print("Smooth Animated Volume Control Service running...")

        while not shutdown_event.is_set():
            now = time.monotonic()

            pending_update = app_state.take_pending_sync(now, SYNC_DELAY_S)
            if pending_update is not None:
                pending_volume, pending_muted = pending_update
                snap_controller.push_volume(pending_volume, pending_muted)

            shutdown_event.wait(0.05)
    finally:
        shutdown_event.set()
        if 'render_thread' in locals():
            render_thread.join(timeout=2.0)
        if encoder is not None:
            encoder.close()
        if snap_controller is not None:
            snap_controller.close()
        if backlight is not None:
            backlight.close()
        if driver is not None:
            driver.close()
        GPIO.cleanup()


if __name__ == "__main__":
    run()