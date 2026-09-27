#!/usr/bin/env python3
import json
import queue
import select
import signal
import socket
import threading
import time
import spidev
from PIL import Image, ImageDraw, ImageFont
import RPi.GPIO as GPIO

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
# Invert direction: Set to True if turning left makes it louder
INVERT_DIRECTION = True

# Acceleration Thresholds in seconds (lower delta_t means faster turning)
# Increase these values to make fast-scrolling triggers wider/easier to reach.
ACCEL_VERY_FAST_THRESHOLD = 0.015  # Default: 15ms
ACCEL_FAST_THRESHOLD      = 0.035  # Default: 35ms

# Multipliers for acceleration steps
ACCEL_VERY_FAST_STEP = 3.0  # Step size when spinning very fast
ACCEL_FAST_STEP      = 2.0  # Step size when spinning fast
ACCEL_NORMAL_STEP    = 1.0  # Step size for normal single detents
# ==============================================================================

class GC9A01Direct:
    """High-performance direct SPI driver for GC9A01 operating at 60MHz SPI clock."""
    def __init__(self, port=0, device=0, speed_hz=60000000, dc=DC_PIN, rst=RST_PIN):
        self.dc = dc
        self.rst = rst
        self.width = 240
        self.height = 240

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
        self.send_command(0xEF)
        self.send_command(0xEB)
        self.send_data(0x14)
        self.send_command(0xFE)
        self.send_command(0xEF)
        self.send_command(0xEB)
        self.send_data(0x14)
        self.send_command(0x84)
        self.send_data(0x40)
        self.send_command(0x85)
        self.send_data(0xFF)
        self.send_command(0x86)
        self.send_data(0xFF)
        self.send_command(0x87)
        self.send_data(0xFF)
        self.send_command(0x88)
        self.send_data(0x0A)
        self.send_command(0x89)
        self.send_data(0x21)
        self.send_command(0x8A)
        self.send_data(0x00)
        self.send_command(0x8B)
        self.send_data(0x80)
        self.send_command(0x8C)
        self.send_data(0x01)
        self.send_command(0x8D)
        self.send_data(0x01)
        self.send_command(0x8E)
        self.send_data(0xFF)
        self.send_command(0x8F)
        self.send_data(0xFF)
        self.send_command(0xB6)
        self.send_data([0x00, 0x00])

        self.send_command(0x36)
        self.send_data(0x48)

        self.send_command(0x3A)
        self.send_data(0x05)
        self.send_command(0x90)
        self.send_data([0x08, 0x08, 0x08, 0x08])
        self.send_command(0xBD)
        self.send_data(0x06)
        self.send_command(0xBC)
        self.send_data(0x00)
        self.send_command(0xFF)
        self.send_data([0x60, 0x01, 0x04])
        self.send_command(0xC3)
        self.send_data(0x13)
        self.send_command(0xC4)
        self.send_data(0x13)
        self.send_command(0xC9)
        self.send_data(0x22)
        self.send_command(0xBE)
        self.send_data(0x11)
        self.send_command(0xE1)
        self.send_data([0x10, 0x0E])
        self.send_command(0xDF)
        self.send_data([0x21, 0x0C, 0x02])
        self.send_command(0xF0)
        self.send_data([0x45, 0x09, 0x08, 0x08, 0x26, 0x2A])
        self.send_command(0xF1)
        self.send_data([0x43, 0x70, 0x72, 0x36, 0x37, 0x6F])
        self.send_command(0xF2)
        self.send_data([0x45, 0x09, 0x08, 0x08, 0x26, 0x2A])
        self.send_command(0xF3)
        self.send_data([0x43, 0x70, 0x72, 0x36, 0x37, 0x6F])
        self.send_command(0xED)
        self.send_data([0x1B, 0x0B])
        self.send_command(0xAE)
        self.send_data(0x77)
        self.send_command(0xCD)
        self.send_data(0x63)
        self.send_command(0x70)
        self.send_data([0x07, 0x07, 0x04, 0x0E, 0x0F, 0x09, 0x07, 0x08, 0x03])
        self.send_command(0xE8)
        self.send_data(0x34)
        self.send_command(0x62)
        self.send_data([0x18, 0x0D, 0x71, 0xED, 0x70, 0x70, 0x18, 0x0D, 0x71, 0xED, 0x70, 0x70])
        self.send_command(0x63)
        self.send_data([0x18, 0x11, 0x71, 0xF1, 0x70, 0x70, 0x18, 0x11, 0x71, 0xF1, 0x70, 0x70])
        self.send_command(0x64)
        self.send_data([0x28, 0x29, 0xF1, 0x01, 0xF1, 0x00, 0x07])
        self.send_command(0x66)
        self.send_data([0x3C, 0x00, 0xCD, 0x67, 0x45, 0x45, 0x10, 0x00, 0x00, 0x00])
        self.send_command(0x67)
        self.send_data([0x00, 0x3C, 0x00, 0x00, 0x00, 0x01, 0x54, 0x10, 0x32, 0x98])
        self.send_command(0x74)
        self.send_data([0x10, 0x85, 0x80, 0x00, 0x00, 0x4E, 0x00])
        self.send_command(0x98)
        self.send_data([0x3E, 0x07])
        self.send_command(0x35)
        self.send_command(0x21)
        self.send_command(0x11)
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
            img_arr = np.frombuffer(image.tobytes(), dtype=np.uint8).reshape((self.height, self.width, 3))

            if brightness < 0.99:
                b_scale = int(max(0.02, brightness) * 256)
                img_arr = ((img_arr.astype(np.uint16) * b_scale) >> 8).astype(np.uint8)

            r = (img_arr[:, :, 0].astype(np.uint16) & 0xF8) << 8
            g = (img_arr[:, :, 1].astype(np.uint16) & 0xFC) << 3
            b = img_arr[:, :, 2].astype(np.uint16) >> 3
            rgb565 = r | g | b

            buf = np.empty((self.height, self.width, 2), dtype=np.uint8)
            buf[:, :, 0] = (rgb565 >> 8) & 0xFF
            buf[:, :, 1] = rgb565 & 0xFF
            raw_bytes = buf.tobytes()
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
            raw_bytes = bytes(buffer)

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
        """Close the SPI device without touching GPIO shared by the application."""
        self.spi.close()

class SnapcastController:
    """Single-worker Snapcast client with coalesced writes and idle polling."""
    IDLE_AFTER_S = 10.0
    STATUS_INTERVAL_S = 5.0
    RPC_TIMEOUT_S = 0.5

    def __init__(self, host="127.0.0.1", port=1705):
        self.host = host
        self.port = port
        self.connected = False
        self._stop_event = threading.Event()
        self._volume_queue = queue.Queue(maxsize=1)
        self._client_ids = ()
        self._client_lock = threading.Lock()
        self._worker = threading.Thread(target=self._run, name="snapcast-rpc")
        self._worker.start()

    def _send_rpc(self, method, params=None):
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
    def _status_values(response):
        """Return discovered clients and the first client's volume settings."""
        groups = response.get("result", {}).get("server", {}).get("groups", [])
        discovered_ids = tuple(
            client_id
            for group in groups
            for client in group.get("clients", [])
            if (client_id := client.get("id"))
        )
        if not groups or not groups[0].get("clients"):
            return discovered_ids, None

        volume = groups[0]["clients"][0].get("config", {}).get("volume", {})
        return discovered_ids, (
            float(volume.get("percent", 50)),
            bool(volume.get("muted", False)),
        )

    def _apply_status(self, response, force=False):
        client_ids, remote_state = self._status_values(response)
        with self._client_lock:
            self._client_ids = client_ids

        if remote_state is None:
            return

        if force:
            app_state.set_from_snapcast(*remote_state)
            return

        remote_volume, remote_muted = remote_state
        app_state.set_from_snapcast_if_idle(
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
        _, last_activity, _ = app_state.snapshot()
        if now - last_activity < self.IDLE_AFTER_S:
            return False

        response = self._send_rpc("Server.GetStatus")
        if response:
            self.connected = True
            self._apply_status(response)
        return True

    def push_volume(self, target_vol, muted):
        """Queue the newest volume and mute state, discarding stale values."""
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
    """Robust EC11 Encoder state machine with strict time-based lockout debounce."""
    OUTCOME = (
         0,  1, -1,  0,
        -1,  0,  0,  1,
         1,  0,  0, -1,
         0, -1,  1,  0
    )
    def __init__(
        self,
        gpio_a,
        gpio_b,
        gpio_sw,
        callback,
        button_callback,
        debounce_time_s=0.030,
    ):
        self.gpio_a = gpio_a
        self.gpio_b = gpio_b
        self.gpio_sw = gpio_sw
        self.callback = callback
        self.button_callback = button_callback
        self.debounce_time_s = debounce_time_s  # Minimum time between valid steps (35ms default)

        GPIO.setup(self.gpio_a, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(self.gpio_b, GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(self.gpio_sw, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        self.last_state = (GPIO.input(self.gpio_a) << 1) | GPIO.input(self.gpio_b)
        self.last_step_time = time.monotonic()
        self.step_accumulator = 0
        self._state_lock = threading.Lock()

        GPIO.add_event_detect(self.gpio_a, GPIO.BOTH, callback=self._handle_edge)
        GPIO.add_event_detect(self.gpio_b, GPIO.BOTH, callback=self._handle_edge)
        GPIO.add_event_detect(
            self.gpio_sw,
            GPIO.FALLING,
            callback=self._handle_button,
            bouncetime=200,
        )

    def _handle_edge(self, channel):
        now = time.monotonic()
        a_val = GPIO.input(self.gpio_a)
        b_val = GPIO.input(self.gpio_b)
        current_state = (a_val << 1) | b_val

        with self._state_lock:
            if current_state == self.last_state:
                return

            idx = (self.last_state << 2) | current_state
            self.last_state = current_state
            direction = self.OUTCOME[idx]
            if INVERT_DIRECTION:
                direction = -direction
            if direction == 0:
                return

            self.step_accumulator += direction
            if abs(self.step_accumulator) < 2:
                return

            delta_t = now - self.last_step_time
            if delta_t < self.debounce_time_s:
                self.step_accumulator = 0
                return

            self.last_step_time = now
            step_size = (ACCEL_VERY_FAST_STEP if delta_t < ACCEL_VERY_FAST_THRESHOLD else
                         ACCEL_FAST_STEP if delta_t < ACCEL_FAST_THRESHOLD else
                         ACCEL_NORMAL_STEP)
            step = step_size if self.step_accumulator > 0 else -step_size
            self.step_accumulator = 0

        # Never perform network, display, or other blocking work under the lock.
        self.callback(step)

    def _handle_button(self, channel):
        self.button_callback()

    def close(self):
        GPIO.remove_event_detect(self.gpio_a)
        GPIO.remove_event_detect(self.gpio_b)
        GPIO.remove_event_detect(self.gpio_sw)

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

def render_frame(volume_pct, muted=False):
    image = base_gradient_img.copy()
    draw = ImageDraw.Draw(image)

    if muted:
        draw.ellipse(ring_box, outline=muted_ring_color, width=ring_width)
    else:
        fill_angle = (volume_pct / 100.0) * 360.0
        if fill_angle < 360.0:
            unfilled_start = -90 + fill_angle
            draw.arc(ring_box, start=unfilled_start, end=270, fill=track_color, width=ring_width)

    vol_str = f"{int(round(volume_pct))}"
    bbox_vol = draw.textbbox((0, 0), vol_str, font=font_large)
    vw = bbox_vol[2] - bbox_vol[0]
    vh = bbox_vol[3] - bbox_vol[1]

    x_pos = (240 - vw) // 2 - bbox_vol[0]
    if muted:
        # Keep the digit's ink centered on y=80, leaving a clear gap above
        # the separately positioned speaker pictogram.
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

# Pre-render background elements
base_gradient_img = build_gradient_base_image()
font_large = load_font(84, bold=True)
ring_box = [14, 14, 226, 226]
ring_width = 14
track_color = (28, 38, 58)
muted_ring_color = (90, 15, 15)

class VolumeState:
    """Small synchronized state container shared by GPIO, RPC, and main threads."""
    def __init__(self, volume=50.0):
        self._volume = volume
        self._muted = False
        self._last_activity = time.monotonic()
        self._pending_sync = False
        self._lock = threading.Lock()

    def on_encoder_step(self, step):
        now = time.monotonic()
        with self._lock:
            self._muted = False
            self._volume = max(0.0, min(100.0, self._volume + step))
            self._last_activity = now
            self._pending_sync = True

    def toggle_mute(self, _event=None):
        now = time.monotonic()
        with self._lock:
            self._muted = not self._muted
            self._last_activity = now
            self._pending_sync = True
            return self._muted

    def set_from_snapcast(self, volume, muted):
        with self._lock:
            self._volume = max(0.0, min(100.0, volume))
            self._muted = bool(muted)

    def set_from_snapcast_if_idle(self, volume, muted, idle_after_s):
        """Apply remote state only if no local interaction occurred recently."""
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

    def snapshot(self):
        with self._lock:
            return self._volume, self._last_activity, self._muted

    def take_pending_sync(self, now, delay_s):
        with self._lock:
            if self._pending_sync and now - self._last_activity >= delay_s:
                self._pending_sync = False
                return self._volume, self._muted
            return None


app_state = VolumeState()
driver = None
snap_controller = None
encoder = None
shutdown_event = threading.Event()


def request_shutdown(signum, frame):
    shutdown_event.set()


def run():
    global driver, snap_controller, encoder
    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)

    try:
        driver = GC9A01Direct(port=0, device=0, speed_hz=60000000)
        snap_controller = SnapcastController()
        encoder = EC11DebouncedEncoder(
            ENCODER_A,
            ENCODER_B,
            ENCODER_SW,
            app_state.on_encoder_step,
            app_state.toggle_mute,
        )

        last_rendered_volume = -1.0
        last_rendered_muted = None
        last_rendered_brightness = -1.0
        print("Debounced & Configurable Volume Control running...")

        while not shutdown_event.is_set():
            now = time.monotonic()
            volume, last_activity, muted = app_state.snapshot()

            pending_update = app_state.take_pending_sync(now, 0.5)
            if pending_update is not None:
                pending_volume, pending_muted = pending_update
                snap_controller.push_volume(pending_volume, pending_muted)

            target_brightness = 0.15 if now - last_activity > 10.0 else 1.0
            mute_changed = muted != last_rendered_muted
            vol_changed = abs(volume - last_rendered_volume) > 0.1
            bright_changed = abs(target_brightness - last_rendered_brightness) > 0.01

            if vol_changed or mute_changed or bright_changed:
                image = render_frame(volume, muted=muted)
                driver.display(image, brightness=target_brightness)
                last_rendered_volume = volume
                last_rendered_muted = muted
                last_rendered_brightness = target_brightness

            shutdown_event.wait(0.016)
    finally:
        if encoder is not None:
            encoder.close()
        if snap_controller is not None:
            snap_controller.close()
        if driver is not None:
            driver.close()
        GPIO.cleanup()


if __name__ == "__main__":
    run()