#!/usr/bin/env python3
"""Bounded, loopback-only FTP/implicit-FTPS fixtures for native playback tests.

Run in a private venv with ftp-playback-requirements.txt. Media and TLS keys are
generated in an owned temporary directory and removed on exit. An optional
remote configuration contains only an endpoint, path and Keychain references;
its password is read into memory, never written into test artifacts.
"""
import argparse
import ftplib
import hashlib
import json
import logging
import os
from pathlib import Path
import signal
import secrets
import ssl
import socket
import struct
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import DTPHandler, FTPHandler, TLS_DTPHandler, TLS_FTPHandler
from pyftpdlib.ioloop import IOLoop
from pyftpdlib.servers import FTPServer


class DelayedTLSData(TLS_DTPHandler):
    """Wait for the transfer command before starting the data TLS handshake."""

    def __init__(self, sock, control):
        protected = control._prot
        control._prot = False
        try:
            super().__init__(sock, control)
        finally:
            control._prot = protected

    def readable(self):
        return self._ssl_requested and super().readable()

    def _begin_tls(self):
        if not self._ssl_requested:
            self.secure_connection(self.cmd_channel.ssl_context)

    def push(self, data):
        self._begin_tls()
        return super().push(data)

    def push_with_producer(self, producer):
        self._begin_tls()
        return super().push_with_producer(producer)


class ImplicitTLS(TLS_FTPHandler):
    tls_control_required = True
    tls_data_required = True

    def handle(self):
        self.secure_connection(self.ssl_context)

    def handle_ssl_established(self):
        FTPHandler.handle(self)


class ResetData(DTPHandler):
    armed = False
    interruptions = 0

    def use_sendfile(self):
        return False

    def send(self, data):
        count = super().send(data[:16384])
        if type(self).armed and self.tot_bytes_sent >= 16384:
            type(self).armed = False
            type(self).interruptions += 1
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.close()
        return count


class BrokenEPSVTLS(ImplicitTLS):
    def ftp_EPSV(self, line):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        self.respond(f"229 Passive (|||{port}|)")


def run_command(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120)


def remote_configuration(path):
    path = Path(path)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Remote configuration must be owner-only.")
    value = json.loads(path.read_text())
    password = subprocess.run(
        ["security", "find-generic-password", "-s", value["keychainService"],
         "-a", value["keychainAccount"], "-w"],
        check=True, capture_output=True, timeout=15,
    ).stdout.decode().rstrip("\n")
    # Verify the exact selected file, without saving authenticated replies.
    with ftplib.FTP() as client:
        client.connect(value["host"], value["port"], timeout=15)
        client.login(value["username"], password)
        client.voidcmd("TYPE I")
        if not client.size("/" + value["path"].lstrip("/")):
            raise ValueError("Remote fixture must be a nonempty file.")
    return {key: value[key] for key in ("host", "port", "username", "path")} | {"password": password}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote-config", type=Path)
    parser.add_argument("--lifetime", type=int, default=1200)
    args = parser.parse_args()
    if not 30 <= args.lifetime <= 3600:
        parser.error("lifetime must be 30..3600 seconds")
    logging.getLogger("pyftpdlib").setLevel(logging.ERROR)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    loop = IOLoop()
    servers = []
    http = None
    ftp_thread = None
    http_thread = None
    with tempfile.TemporaryDirectory(prefix="plozz-ftp-fixture-") as directory:
        root = Path(directory)
        media = root / "media"
        media.mkdir()
        try:
            run_command([
                "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "75",
                "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-pix_fmt", "yuv420p",
                "-c:a", "aac", str(media / "tail.mp4"),
            ])
            run_command(["ffmpeg", "-nostdin", "-v", "error", "-i", str(media / "tail.mp4"),
                         "-c", "copy", str(media / "movie.mkv")])
            # Sparse, >4-GiB identity/offset fixture, not a purported video.
            with (media / "large.bin").open("wb") as file:
                file.seek(4 * 1024**3 + 123)
                file.write(b"large-offset-marker")
            run_command([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=localhost", "-keyout", str(root / "key.pem"),
                "-out", str(root / "cert.pem"),
            ])
            os.chmod(root / "key.pem", 0o600)
            certificate = ssl.PEM_cert_to_DER_cert((root / "cert.pem").read_text())
            fingerprint = list(hashlib.sha256(certificate).digest())
            authorizer = DummyAuthorizer()
            authorizer.add_anonymous(str(media), perm="elr")
            configurations = {}
            for name, base, delayed in [
                ("plain", FTPHandler, False), ("tls", ImplicitTLS, False),
                ("delayedTLS", ImplicitTLS, True),
                ("reset", FTPHandler, False), ("tlsPassiveFallback", BrokenEPSVTLS, False),
            ]:
                attributes = {"authorizer": authorizer, "timeout": 60}
                secure = issubclass(base, ImplicitTLS)
                if secure:
                    attributes.update(certfile=str(root / "cert.pem"), keyfile=str(root / "key.pem"))
                    if delayed:
                        attributes["dtp_handler"] = DelayedTLSData
                if name == "reset":
                    attributes["dtp_handler"] = ResetData
                handler = type(f"Fixture_{name}", (base,), attributes)
                server = FTPServer(("127.0.0.1", 0), handler, ioloop=loop)
                servers.append(server)
                configurations[name] = {
                    "host": "127.0.0.1", "port": server.socket.getsockname()[1],
                    "username": "anonymous", "password": "anonymous@plozz",
                    "path": "tail.mp4", "pin": fingerprint if secure else None,
                }
            if args.remote_config:
                configurations["remote"] = remote_configuration(args.remote_config)
            route = "/" + secrets.token_urlsafe(32)

            class ConfigurationHandler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path != route:
                        self.send_error(404)
                        return
                    configurations["reset"]["interruptions"] = ResetData.interruptions
                    body = json.dumps(configurations).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def do_POST(self):
                    if self.path != route + "/reset-drop":
                        self.send_error(404)
                        return
                    ResetData.armed = True
                    self.send_response(204)
                    self.end_headers()

                def log_message(self, *_):
                    pass

            http = ThreadingHTTPServer(("127.0.0.1", 0), ConfigurationHandler)
            http_thread = threading.Thread(target=http.serve_forever)
            ftp_thread = threading.Thread(target=loop.loop, kwargs={"timeout": 0.1})
            http_thread.start()
            ftp_thread.start()
            print(f"PLOZZ_FTP_FIXTURE_URL=http://127.0.0.1:{http.server_port}{route}", flush=True)
            stopped.wait(args.lifetime)
        finally:
            if http:
                http.shutdown()
                http.server_close()
            if http_thread:
                http_thread.join(timeout=10)
            # Close FTP sockets on their owning loop, then join it.
            if ftp_thread:
                loop.call_later(0, lambda: [server.close_all() for server in servers])
                ftp_thread.join(timeout=10)
            else:
                for server in servers:
                    server.close_all()
            loop.close()


if __name__ == "__main__":
    main()
