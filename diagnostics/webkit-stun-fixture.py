from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import ThreadingUDPServer, BaseRequestHandler
from threading import Lock, Thread
from urllib.parse import parse_qs, urlsplit
import json
import struct
import sys


class StunServer(ThreadingUDPServer):
    daemon_threads = True
    requests = 0
    lock = Lock()


class BindingRequest(BaseRequestHandler):
    def handle(self):
        packet, transport = self.request
        if self.client_address[0] != "127.0.0.1" or len(packet) < 20:
            return
        kind, length, cookie, transaction = struct.unpack("!HHI12s", packet[:20])
        if kind != 1 or cookie != 0x2112A442 or len(packet) != length + 20:
            return
        with self.server.lock:
            self.server.requests += 1
        # A documentation address provides a measurable srflx candidate without
        # involving a remote network service.
        xor_port = self.client_address[1] ^ (cookie >> 16)
        xor_address = 0xC6336407 ^ cookie
        attribute = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, xor_port, xor_address)
        response = struct.pack("!HHI12s", 0x0101, len(attribute), cookie, transaction) + attribute
        transport.sendto(response, self.client_address)


class Control(BaseHTTPRequestHandler):
    servers = {}

    def do_GET(self):
        request = urlsplit(self.path)
        if request.path == "/new":
            if len(self.servers) >= 16:
                self.send_error(429)
                return
            server = StunServer(("127.0.0.1", 0), BindingRequest)
            port = server.server_address[1]
            self.servers[port] = server
            Thread(target=server.serve_forever, daemon=True).start()
            self.respond({"port": port})
        elif request.path == "/count":
            try:
                port = int(parse_qs(request.query)["port"][0])
                server = self.servers[port]
            except (ValueError, KeyError, IndexError):
                self.send_error(400)
                return
            with server.lock:
                self.respond({"requests": server.requests})
        elif request.path == "/page":
            self.respond("<!doctype html><title>Owned RTC policy</title>", "text/html")
        else:
            self.send_error(404)

    def respond(self, value, mime="application/json"):
        contents = (value if isinstance(value, str) else json.dumps(value)).encode()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(contents)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(contents)


with ThreadingHTTPServer(("127.0.0.1", 0), Control) as server:
    Path(sys.argv[1]).write_text(str(server.server_port))
    try:
        server.serve_forever()
    finally:
        for stun in Control.servers.values():
            stun.shutdown()
            stun.server_close()
