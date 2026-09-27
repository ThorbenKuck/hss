#!/usr/bin/env python3
"""Early-boot loading animation for the HSS GC9A01 display."""

import math
import signal
import time
from threading import Event

import RPi.GPIO as GPIO
import spidev


WIDTH = 240
HEIGHT = 240
DC_PIN = 24
RST_PIN = 25


class GC9A01Direct:
    """Small direct-SPI GC9A01 driver used before the volume controller starts."""

    def __init__(self, port=0, device=0, speed_hz=60_000_000):
        self.spi = spidev.SpiDev()
        self.closed = False
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        GPIO.setup(DC_PIN, GPIO.OUT)
        GPIO.setup(RST_PIN, GPIO.OUT)
        self.spi.open(port, device)
        self.spi.max_speed_hz = speed_hz
        self.spi.mode = 0
        self._reset()
        self._init_display()

    def _write(self, data, is_data):
        GPIO.output(DC_PIN, GPIO.HIGH if is_data else GPIO.LOW)
        if isinstance(data, int):
            payload = bytes([data])
        elif isinstance(data, (bytes, bytearray)):
            payload = data
        else:
            payload = bytes(data)

        if hasattr(self.spi, "writebytes2"):
            self.spi.writebytes2(payload)
        else:
            self.spi.writebytes(list(payload))

    def _command(self, command):
        self._write(command, False)

    def _data(self, data):
        self._write(data, True)

    def _reset(self):
        GPIO.output(RST_PIN, GPIO.HIGH)
        time.sleep(0.01)
        GPIO.output(RST_PIN, GPIO.LOW)
        time.sleep(0.01)
        GPIO.output(RST_PIN, GPIO.HIGH)
        time.sleep(0.12)

    def _init_display(self):
        # Initialization sequence matching hss_volume_control.py.
        for command, data in (
            (0xEF, None), (0xEB, (0x14,)), (0xFE, None), (0xEF, None),
            (0xEB, (0x14,)), (0x84, (0x40,)), (0x85, (0xFF,)),
            (0x86, (0xFF,)), (0x87, (0xFF,)), (0x88, (0x0A,)),
            (0x89, (0x21,)), (0x8A, (0x00,)), (0x8B, (0x80,)),
            (0x8C, (0x01,)), (0x8D, (0x01,)), (0x8E, (0xFF,)),
            (0x8F, (0xFF,)), (0xB6, (0x00, 0x00)), (0x36, (0x48,)),
            (0x3A, (0x05,)), (0x90, (0x08, 0x08, 0x08, 0x08)),
            (0xBD, (0x06,)), (0xBC, (0x00,)),
            (0xFF, (0x60, 0x01, 0x04)), (0xC3, (0x13,)),
            (0xC4, (0x13,)), (0xC9, (0x22,)), (0xBE, (0x11,)),
            (0xE1, (0x10, 0x0E,)), (0xDF, (0x21, 0x0C, 0x02)),
            (0xF0, (0x45, 0x09, 0x08, 0x08, 0x26, 0x2A)),
            (0xF1, (0x43, 0x70, 0x72, 0x36, 0x37, 0x6F)),
            (0xF2, (0x45, 0x09, 0x08, 0x08, 0x26, 0x2A)),
            (0xF3, (0x43, 0x70, 0x72, 0x36, 0x37, 0x6F)),
            (0xED, (0x1B, 0x0B)), (0xAE, (0x77,)), (0xCD, (0x63,)),
            (0x70, (0x07, 0x07, 0x04, 0x0E, 0x0F, 0x09, 0x07, 0x08, 0x03)),
            (0xE8, (0x34,)),
            (0x62, (0x18, 0x0D, 0x71, 0xED, 0x70, 0x70, 0x18, 0x0D, 0x71, 0xED, 0x70, 0x70)),
            (0x63, (0x18, 0x11, 0x71, 0xF1, 0x70, 0x70, 0x18, 0x11, 0x71, 0xF1, 0x70, 0x70)),
            (0x64, (0x28, 0x29, 0xF1, 0x01, 0xF1, 0x00, 0x07)),
            (0x66, (0x3C, 0x00, 0xCD, 0x67, 0x45, 0x45, 0x10, 0x00, 0x00, 0x00)),
            (0x67, (0x00, 0x3C, 0x00, 0x00, 0x00, 0x01, 0x54, 0x10, 0x32, 0x98)),
            (0x74, (0x10, 0x85, 0x80, 0x00, 0x00, 0x4E, 0x00)),
            (0x98, (0x3E, 0x07)), (0x35, None), (0x21, None),
            (0x11, None),
        ):
            self._command(command)
            if data is not None:
                self._data(data)
            if command == 0x11:
                time.sleep(0.12)
        self._command(0x29)
        time.sleep(0.02)

    def display(self, pixels):
        self._command(0x2A)
        self._data((0x00, 0x00, 0x00, WIDTH - 1))
        self._command(0x2B)
        self._data((0x00, 0x00, 0x00, HEIGHT - 1))
        self._command(0x2C)
        self._write(pixels, True)

    def close(self):
        if not self.closed:
            # Do not clear the display: the next service can render over this frame.
            self.spi.close()
            self.closed = True


def rgb565(red, green, blue):
    value = ((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3)
    return bytes((value >> 8, value & 0xFF))


BACKGROUND = rgb565(10, 14, 23)
INNER_RING_COLOR = rgb565(25, 45, 55)
HEAD_COLOR = rgb565(220, 255, 250)

# Pre-calculate smooth gradient arc colors (80 steps)
SPINNER_STEPS = 80
GRADIENT = []
for i in range(SPINNER_STEPS):
    t = (i / (SPINNER_STEPS - 1)) ** 1.5
    r = int(15 + (0 - 15) * t)
    g = int(35 + (230 - 35) * t)
    b = int(40 + (200 - 40) * t)
    GRADIENT.append(rgb565(r, g, b))


def render_frame(angle):
    pixels = bytearray(BACKGROUND * (WIDTH * HEIGHT))
    cx, cy = 120, 120

    # Draw subtle inner structural ring at R = 45
    r_inner = 45
    for deg in range(0, 360, 4):
        rad = math.radians(deg)
        x = round(cx + r_inner * math.cos(rad))
        y = round(cy + r_inner * math.sin(rad))
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            offset = (y * WIDTH + x) * 2
            pixels[offset:offset + 2] = INNER_RING_COLOR

    # Draw smooth gradient arc spinner at R = 92
    r_spinner = 92
    arc_span = 1.5 * math.pi  # 270 degree arc

    for i in range(SPINNER_STEPS):
        t_arc = i / (SPINNER_STEPS - 1)
        theta = angle + t_arc * arc_span
        color = GRADIENT[i]

        px = round(cx + r_spinner * math.cos(theta))
        py = round(cy + r_spinner * math.sin(theta))

        dot_r = 3 if i < 15 else (5 if i < 60 else 6)

        for yy in range(py - dot_r, py + dot_r + 1):
            for xx in range(px - dot_r, px + dot_r + 1):
                if 0 <= xx < WIDTH and 0 <= yy < HEIGHT:
                    if (xx - px) ** 2 + (yy - py) ** 2 <= dot_r ** 2:
                        offset = (yy * WIDTH + xx) * 2
                        pixels[offset:offset + 2] = color

    # Draw glowing leading head node at the tip of the arc
    head_theta = angle + arc_span
    hx = round(cx + r_spinner * math.cos(head_theta))
    hy = round(cy + r_spinner * math.sin(head_theta))

    for yy in range(hy - 7, hy + 8):
        for xx in range(hx - 7, hx + 8):
            if 0 <= xx < WIDTH and 0 <= yy < HEIGHT:
                if (xx - hx) ** 2 + (yy - hy) ** 2 <= 49:
                    offset = (yy * WIDTH + xx) * 2
                    pixels[offset:offset + 2] = HEAD_COLOR

    return pixels


def main():
    stop_event = Event()

    def stop(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    display = None
    try:
        display = GC9A01Direct()
        angle = 0.0
        while not stop_event.is_set():
            display.display(render_frame(angle))
            angle = (angle + 0.18) % (2 * math.pi)
            stop_event.wait(0.03)
    finally:
        if display is not None:
            display.close()


if __name__ == "__main__":
    main()