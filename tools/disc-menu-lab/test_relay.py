import contextlib
import http.server
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

from relay import DiscRelay


class Upstream(http.server.BaseHTTPRequestHandler):
    payload = b"original-fixture-bytes"
    bad_range = False
    requests = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        type(self).requests.append((self.path, self.headers.get("Authorization")))
        start, end = map(int, self.headers["Range"][6:].split("-"))
        body = self.payload[start:end + 1]
        self.send_response(206)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Range", "invalid" if self.bad_range else
                         f"bytes {start}-{end}/{len(self.payload)}")
        self.end_headers()
        self.wfile.write(body)


@contextlib.contextmanager
def serving(server):
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError("Owned test server did not stop")


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.resources = contextlib.ExitStack()
        self.addCleanup(self.resources.close)
        Upstream.bad_range = False
        Upstream.requests = []
        upstream = self.resources.enter_context(serving(http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), Upstream)))
        self.relay = self.resources.enter_context(serving(DiscRelay(
            ("127.0.0.1", 0), upstream=f"http://127.0.0.1:{upstream.server_port}/disc/",
            headers={"Authorization": "Basic fixture-only"},
            files={"BDMV/STREAM/00001.m2ts": len(Upstream.payload)}, lifetime=30)))

    def get(self, path="BDMV/STREAM/00001.m2ts", *, auth=True, byte_range=None, method="GET"):
        headers = {"Authorization": self.relay.authorization} if auth else {}
        if byte_range is not None:
            headers["Range"] = byte_range
        return urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{self.relay.server_port}/{path}",
            headers=headers, method=method), timeout=3)

    def test_exact_range_and_separate_credentials(self):
        with self.get(byte_range="bytes=2-8") as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), Upstream.payload[2:9])
            self.assertEqual(response.headers["Content-Range"], f"bytes 2-8/{len(Upstream.payload)}")
        self.assertEqual(Upstream.requests, [("/disc/BDMV/STREAM/00001.m2ts", "Basic fixture-only")])
        self.assertNotIn("fixture-only", str(self.relay.configuration("127.0.0.1")))

    def test_unauthenticated_and_out_of_scope_requests_do_not_reach_origin(self):
        for path, auth, status in (
            ("BDMV/STREAM/00001.m2ts", False, 401),
            ("../other-movie.m2ts", True, 404),
            ("%2e%2e/other-movie.m2ts", True, 404),
            ("BDMV/STREAM/00002.m2ts", True, 404),
        ):
            with self.subTest(path=path, auth=auth):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    self.get(path, auth=auth)
                self.assertEqual(error.exception.code, status)
                error.exception.close()
        self.assertEqual(Upstream.requests, [])

    def test_head_does_not_download_media(self):
        with self.get(method="HEAD") as response:
            self.assertEqual(int(response.headers["Content-Length"]), len(Upstream.payload))
            self.assertEqual(response.read(), b"")
        self.assertEqual(Upstream.requests, [])

    def test_bad_upstream_range_is_not_a_success(self):
        Upstream.bad_range = True
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.get(byte_range="bytes=0-2")
        self.assertEqual(error.exception.code, 502)
        error.exception.close()
        self.assertEqual(self.relay.failures, 1)

    def test_expired_session_refuses_reads(self):
        self.relay.deadline = time.monotonic() - 1
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.get()
        self.assertEqual(error.exception.code, 410)
        error.exception.close()
        self.assertEqual(Upstream.requests, [])

    def test_byte_budget_stops_origin_reads(self):
        self.relay.byte_limit = 1
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.get()
        self.assertEqual(error.exception.code, 429)
        error.exception.close()
        self.assertEqual(Upstream.requests, [])

    def test_upstream_timeout_is_distinct_from_invalid_range(self):
        for failure in (TimeoutError(), urllib.error.URLError(TimeoutError())):
            with self.subTest(failure=type(failure).__name__), \
                 patch("relay.Handler.fetch", side_effect=failure):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    self.get(byte_range="bytes=0-2")
                self.assertEqual(error.exception.code, 504)
                error.exception.close()
        self.assertEqual(Upstream.requests, [])

    def test_upstream_busy_and_timeout_status_remain_retryable(self):
        for status in (503, 504):
            failure = urllib.error.HTTPError("http://fixture.invalid", status, "fixture", {}, None)
            with self.subTest(status=status), patch("relay.Handler.fetch", side_effect=failure):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    self.get(byte_range="bytes=0-2")
                self.assertEqual(error.exception.code, status)
                error.exception.close()
        self.assertEqual(Upstream.requests, [])


if __name__ == "__main__":
    unittest.main()
