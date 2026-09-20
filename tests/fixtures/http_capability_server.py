"""Recording loopback endpoint for native capability transport conformance."""
import http.server
import json
import socketserver
import ssl
import sys
import threading

records = sys.argv[1]
record_lock = threading.Lock()
release = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle_request(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        record = {
            "method": self.command,
            "target": self.path,
            "version": self.request_version,
            "host": self.headers.get("Host", ""),
            "authorization": self.headers.get("Authorization", ""),
            "cookie": self.headers.get("Cookie", ""),
            "expect": self.headers.get("Expect", ""),
            "body": body if len(body) <= 4096 else "[large body]",
            "body_size": len(body),
        }
        with record_lock:
            with open(records, "a", encoding="utf-8") as out:
                out.write(json.dumps(record) + "\n")
        if self.path.startswith("/hold"):
            release.wait(20)
        if self.path == "/upgrade":
            self.wfile.write(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Connection: Upgrade\r\nUpgrade: test\r\n\r\n"
                b"must-not-reach-the-application"
            )
            self.wfile.flush()
            self.close_connection = True
            return
        payload = json.dumps(record).encode()
        status = 302 if self.path == "/redirect" else 417 if self.path == "/expectation" else 200
        self.send_response(status)
        if self.path == "/redirect":
            self.send_header("Location", "/destination")
            self.send_header("Set-Cookie", "host-managed=forbidden")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    do_GET = handle_request
    do_POST = handle_request
    do_HEAD = handle_request


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 32

    def server_bind(self):
        # These loopback fixtures must not perform reverse DNS at startup.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = Server(("127.0.0.1", 0), Handler)
if len(sys.argv) == 4:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = context.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
print(server.server_port, flush=True)
for command in sys.stdin:
    if command.strip() == "release":
        release.set()
    elif command.strip() == "stop":
        break
release.set()
server.shutdown()
server.server_close()
