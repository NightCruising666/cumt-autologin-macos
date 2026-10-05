"""Developer-only localhost server for native transport tests; not shipped in app."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading

class Portal(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/never-follow")
            self.end_headers()
        elif self.path == "/204":
            self.send_response(204); self.end_headers()
        else:
            self.send_response(200)
            if self.path == "/":
                self.send_header("Set-Cookie", "campus=native; Path=/")
            self.end_headers()
            self.wfile.write(b"cookie-ok" if self.headers.get("Cookie") == "campus=native" else b"no-cookie")
    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Portal)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    executable = Path(__file__).resolve().parents[2] / "build/native-tests"
    subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"], check=True)
finally:
    server.shutdown(); server.server_close(); thread.join()
