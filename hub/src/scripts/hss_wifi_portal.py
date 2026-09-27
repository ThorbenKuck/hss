import html
import http.server
import os
import socketserver
import subprocess
import threading
import time
import urllib.parse


HOST = os.environ.get("HSS_WIFI_PORTAL_HOST", "127.0.0.1")
PORT = int(os.environ.get("HSS_WIFI_PORTAL_PORT", "8080"))


def networks():
    try:
        subprocess.run(["nmcli", "device", "wifi", "rescan"], capture_output=True, timeout=10)
        time.sleep(1)
        result = subprocess.run(
            ["nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi", "list"],
            capture_output=True, text=True, check=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return []

    found = {}
    for line in result.stdout.splitlines():
        ssid, separator, signal = line.rpartition(":")
        if separator and ssid:
            found[ssid] = signal
    return sorted(found.items(), key=lambda item: item[0].lower())


def page(message="", error=False):
    options = "".join(
        f'<option value="{html.escape(ssid, quote=True)}">'
        f'{html.escape(ssid)} ({html.escape(signal)}%)</option>'
        for ssid, signal in networks()
    )
    notice = (
        f'<p class="notice {"error" if error else "success"}" role="status">'
        f'{html.escape(message)}</p>' if message else ""
    )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#0b1120"><title>HSS Wi-Fi Setup</title>
<style>
:root {{ color-scheme: dark; --bg:#0b1120; --panel:#111b2d; --text:#eef4ff; --muted:#9aaaca; --accent:#65d6b1; --error:#ff8c8c; }}
* {{ box-sizing:border-box; }} body {{ margin:0; min-height:100vh; display:grid; place-items:center; padding:1rem; background:var(--bg); color:var(--text); font:16px/1.5 system-ui,sans-serif; }}
main {{ width:min(100%, 30rem); background:var(--panel); border-radius:1.25rem; padding:clamp(1.25rem,6vw,2.5rem); box-shadow:0 1rem 3rem #0005; }}
.eyebrow {{ color:var(--accent); font-weight:700; letter-spacing:.14em; text-transform:uppercase; margin:0; }} h1 {{ margin:.25rem 0 .5rem; font-size:clamp(1.8rem,8vw,2.5rem); }} p {{ color:var(--muted); }} label {{ display:block; margin-top:1.2rem; font-weight:600; }} select,input,button {{ width:100%; min-height:3.25rem; margin-top:.45rem; padding:.75rem 1rem; border:1px solid #344563; border-radius:.7rem; background:#17243a; color:var(--text); font:inherit; }} button {{ border:0; background:var(--accent); color:#07151a; font-weight:800; cursor:pointer; }} button:disabled {{ opacity:.6; cursor:wait; }} .notice {{ padding:.75rem 1rem; border-radius:.7rem; color:var(--text); }} .success {{ background:#16463d; }} .error {{ background:#552d38; color:#ffdede; }}
</style></head><body><main><p class="eyebrow">HSS</p><h1>Connect to Wi-Fi</h1>
<p>Choose the network that should connect this hub to your home network.</p>{notice}
<form method="post" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Connecting…';">
<label for="ssid">Wi-Fi network</label><select id="ssid" name="ssid" required>{options or '<option value="">No networks found</option>'}</select>
<label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required>
<button type="submit">Connect hub</button></form></main></body></html>"""


class WifiPortalHandler(http.server.BaseHTTPRequestHandler):
    def respond(self, body, status=200):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path.rstrip("/") not in ("", "/setup"):
            self.respond("Not found", 404)
            return
        self.respond(page())

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        params = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
        ssid = params.get("ssid", [""])[0].strip()
        password = params.get("password", [""])[0]
        if not ssid:
            self.respond(page("Select a Wi-Fi network first.", True), 400)
            return

        self.respond(page("Connection started. The setup hotspot will close when the hub joins the network."))
        threading.Thread(target=connect, args=(ssid, password), daemon=True).start()

    def log_message(self, *_args):
        return


def connect(ssid, password):
    try:
        subprocess.run(["nmcli", "connection", "down", "HSS-Hotspot"], check=False, timeout=15)
        subprocess.run(["nmcli", "device", "wifi", "connect", ssid, "password", password, "name", ssid], check=True, timeout=30)
        subprocess.run(["nmcli", "connection", "modify", ssid, "connection.autoconnect", "yes", "connection.autoconnect-priority", "10"], check=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


if __name__ == "__main__":
    class ReusableTCPServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    with ReusableTCPServer((HOST, PORT), WifiPortalHandler) as httpd:
        httpd.serve_forever()