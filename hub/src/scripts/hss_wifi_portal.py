#!/usr/bin/env python3
import http.server
import socketserver
import subprocess
import urllib.parse

PORT = 80


class WifiPortalHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        cmd = "nmcli -t -f SSID,SIGNAL dev wifi list"
        try:
            output = subprocess.check_output(cmd, shell=True, text=True)
        except Exception:
            output = ""

        options = []
        for line in output.strip().split("\n"):
            if line:
                parts = line.split(":")
                if len(parts) >= 2 and parts[0]:
                    options.append(f"<option value='{parts[0]}'>{parts[0]} ({parts[1]}%)</option>")

        html = f"""
        <!DOCTYPE html>
        <html>
        <head><title>HSS Wi-Fi Setup</title></head>
        <body style='font-family:sans-serif; padding:20px;'>
        <h2>HSS Wi-Fi Setup</h2>
        <form method='POST'>
            <label>Wi-Fi Network:</label><br>
            <select name='ssid'>{''.join(options)}</select><br><br>
            <label>Password:</label><br>
            <input type='password' name='password'><br><br>
            <input type='submit' value='Connect'>
        </form>
        </body>
        </html>
        """
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length).decode('utf-8')
        params = urllib.parse.parse_qs(post_data)

        ssid = params.get('ssid', [''])[0]
        password = params.get('password', [''])[0]

        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h2>Connecting... Hotspot will turn off shortly.</h2>")

        connect_cmd = f"nmcli dev wifi connect '{ssid}' password '{password}'"
        subprocess.Popen(connect_cmd, shell=True)


if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), WifiPortalHandler) as httpd:
        httpd.serve_forever()