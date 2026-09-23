#!/usr/bin/env python3
import json
import time
import urllib.request

SYSFS_ADC_PATH = "/sys/bus/iio/devices/iio:device0/in_voltage0_raw"
SNAPCAST_URL = "http://localhost:1705/jsonrpc"

NOISE_THRESHOLD = 150
IDLE_TIMEOUT = 1.0
IDLE_SLEEP = 1.0
ACTIVE_SLEEP = 0.05


def read_adc_raw():
    try:
        with open(SYSFS_ADC_PATH, "r") as f:
            return int(f.read().strip())
    except Exception:
        return 0


def set_snapcast_volume(percent):
    payload = {"id": 1, "jsonrpc": "2.0", "method": "Server.GetStatus"}
    req = urllib.request.Request(
        SNAPCAST_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(req) as response:
            res_data = json.loads(response.read().decode("utf-8"))
            groups = res_data.get("result", {}).get("server", {}).get("groups", [])
            for group in groups:
                vol_payload = {
                    "id": 2,
                    "jsonrpc": "2.0",
                    "method": "Group.SetVolume",
                    "params": {
                        "id": group.get("id"),
                        "volume": {"percent": percent, "muted": False},
                    },
                }
                vol_req = urllib.request.Request(
                    SNAPCAST_URL,
                    data=json.dumps(vol_payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                )
                urllib.request.urlopen(vol_req)
    except Exception:
        pass


def main():
    last_volume = -1
    last_raw = read_adc_raw()
    last_change_time = time.time()
    while True:
        raw = read_adc_raw()
        scaled_vol = int(min(100, max(0, (raw / 26000.0) * 100)))
        if abs(raw - last_raw) > NOISE_THRESHOLD:
            last_change_time = time.time()
            if abs(scaled_vol - last_volume) >= 1:
                set_snapcast_volume(scaled_vol)
                last_volume = scaled_vol
            last_raw = raw
        time.sleep(IDLE_SLEEP if (time.time() - last_change_time) >= IDLE_TIMEOUT else ACTIVE_SLEEP)


if __name__ == "__main__":
    main()