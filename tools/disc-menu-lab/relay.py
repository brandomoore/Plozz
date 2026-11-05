"""Temporary, read-only range relay for one explicitly selected disc.

The private caller obtains upstream credentials in memory. Devices receive only
an expiring, disc-scoped bearer token, never the media share's credentials.
"""
import hmac
import http.client
import http.server
import json
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Upstream redirects are not allowed")


class RelayExpired(ValueError):
    pass


class RelayLimitReached(ValueError):
    pass


class DiscRelay(http.server.ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, address, *, upstream, headers, files, lifetime=7200, byte_limit=8 << 30):
        if not upstream.startswith(("http://", "https://")) or not upstream.endswith("/"):
            raise ValueError("Expected an absolute upstream directory URL")
        if not files or len(files) > 4096:
            raise ValueError("Invalid disc file inventory")
        for path, size in files.items():
            if (not path.startswith("BDMV/") or any(p in ("", ".", "..") for p in path.split("/"))
                    or not isinstance(size, int) or size < 0):
                raise ValueError("Invalid disc file entry")
        self.upstream = upstream
        self.headers = dict(headers)
        self.files = dict(files)
        self.authorization = "Bearer " + secrets.token_urlsafe(32)
        self.deadline = time.monotonic() + lifetime
        self.byte_limit = byte_limit
        self.bytes = 0
        self.failures = 0
        self.lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(8)
        self.timeout = 1
        super().__init__(address, Handler)

    def configuration(self, host):
        return {
            "baseURL": f"http://{host}:{self.server_port}/",
            "authorization": self.authorization,
            "files": [{"path": path, "size": size} for path, size in sorted(self.files.items())],
        }

    def run_until_expiry(self):
        try:
            while time.monotonic() < self.deadline:
                self.handle_request()
        finally:
            self.server_close()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # Request paths and authentication never enter the console.

    def setup(self):
        super().setup()
        self.connection.settimeout(20)

    def do_HEAD(self):
        self.respond(head=True)

    def do_GET(self):
        self.respond(head=False)

    def reject(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def respond(self, *, head):
        server = self.server
        if self.path == "/health":
            body = json.dumps({"ready": time.monotonic() < server.deadline}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return
        if time.monotonic() >= server.deadline:
            return self.reject(410)
        if not hmac.compare_digest(self.headers.get("Authorization", ""), server.authorization):
            return self.reject(401)
        url = urllib.parse.urlsplit(self.path)
        if url.query or url.fragment:
            return self.reject(404)
        path = urllib.parse.unquote(url.path).removeprefix("/")
        if path not in server.files:
            return self.reject(404)
        size = server.files[path]
        start, end = 0, size - 1
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header)
            if not match:
                return self.reject(416)
            start = int(match[1])
            end = min(int(match[2]) if match[2] else size - 1, size - 1)
            if start > end:
                return self.reject(416)
        if not server.slots.acquire(blocking=False):
            return self.reject(503)
        sent = False
        try:
            # Validate the first upstream block before sending success downstream.
            first = None if head or size == 0 else self.fetch(path, start, min(end, start + (512 << 10) - 1))
            self.send_response(206 if range_header else 200)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", "application/octet-stream")
            if range_header:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            sent = True
            if head:
                return
            cursor = start
            while cursor <= end:
                data = first if first is not None else self.fetch(
                    path, cursor, min(end, cursor + (512 << 10) - 1))
                first = None
                self.wfile.write(data)
                self.wfile.flush()
                cursor += len(data)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # Reader cancellation is not a successful completed response.
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException) as error:
            with server.lock:
                server.failures += 1
            reason = error.reason if isinstance(error, urllib.error.URLError) else error
            status = (410 if isinstance(error, RelayExpired) else
                      429 if isinstance(error, RelayLimitReached) else
                      error.code if isinstance(error, urllib.error.HTTPError) and error.code in (503, 504) else
                      504 if isinstance(reason, TimeoutError) else 502)
            if isinstance(error, urllib.error.HTTPError):
                error.close()
            if not sent:
                self.reject(status)
            self.close_connection = True
            print(f"Disc relay: {type(error).__name__}; HTTP {status}; response closed", flush=True)
        finally:
            server.slots.release()

    def fetch(self, path, start, end):
        server = self.server
        count = end - start + 1
        with server.lock:
            if time.monotonic() >= server.deadline:
                raise RelayExpired("Relay lifetime reached")
            if server.bytes + count > server.byte_limit:
                raise RelayLimitReached("Relay byte limit reached")
            server.bytes += count
        request = urllib.request.Request(
            server.upstream + urllib.parse.quote(path, safe="/"),
            headers={**server.headers, "Range": f"bytes={start}-{end}"},
        )
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=15) as response:
            if (response.status != 206 or response.headers.get("Content-Range")
                    != f"bytes {start}-{end}/{server.files[path]}"):
                raise ValueError("Invalid upstream range")
            data = response.read(count + 1)
            if len(data) != count:
                raise ValueError("Incomplete upstream range")
            return data
