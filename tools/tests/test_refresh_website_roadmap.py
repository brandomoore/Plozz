"""Offline tests for fixed-target, bounded website roadmap dispatch."""

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import unittest
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("refresh_website_roadmap", ROOT / "tools/refresh-website-roadmap.py")
REFRESH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFRESH)


class Response:
    status = 204

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass


def http_error(status, headers=None):
    return urllib.error.HTTPError(REFRESH.DISPATCH_URL, status, "not logged", headers or {}, None)


class WebsiteRoadmapRefreshTests(unittest.TestCase):
    def test_fixed_target_has_no_issue_content_or_ref_input(self):
        calls = []

        def open_url(request, timeout):
            calls.append(request)
            self.assertLessEqual(timeout, 20)
            return Response()

        REFRESH.dispatch("synthetic-token", open_url=open_url)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].full_url, REFRESH.DISPATCH_URL)
        self.assertEqual(calls[0].method, "POST")
        self.assertEqual(calls[0].data, b'{"ref":"main"}')
        self.assertEqual(calls[0].get_header("Authorization"), "Bearer synthetic-token")

    def test_missing_credential_does_not_make_a_request(self):
        with self.assertRaisesRegex(RuntimeError, "Configure WEBSITE_ROADMAP_DISPATCH_TOKEN"):
            REFRESH.dispatch(None, open_url=lambda *_: self.fail("Unexpected network access"))

    def test_transient_failures_retry_with_bounded_delays(self):
        for error in [http_error(s) for s in REFRESH.RETRYABLE_STATUS] + [
            urllib.error.URLError("offline"), TimeoutError(),
        ]:
            with self.subTest(error=type(error).__name__, status=getattr(error, "code", None)):
                calls, delays = [], []

                def open_url(request, timeout):
                    calls.append(request.data)
                    if len(calls) < 4:
                        raise error
                    return Response()

                output = io.StringIO()
                with redirect_stderr(output):
                    REFRESH.dispatch("synthetic-token", open_url=open_url, sleep=delays.append)
                self.assertEqual(delays, [1, 2, 4])
                self.assertEqual(calls, [b'{"ref":"main"}'] * 4)
                self.assertNotIn("synthetic-token", output.getvalue())

    def test_exhausted_retries_fail_instead_of_reporting_success(self):
        calls, delays = [], []

        def open_url(request, timeout):
            calls.append(request)
            raise http_error(500)

        with redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "four attempts"):
            REFRESH.dispatch("synthetic-token", open_url=open_url, sleep=delays.append)
        self.assertEqual(len(calls), 4)
        self.assertEqual(delays, [1, 2, 4])

    def test_permanent_failures_and_redirects_do_not_retry(self):
        for status in [301, 302, 307, 308, 400, 401, 403, 404, 422]:
            with self.subTest(status=status):
                def open_url(request, timeout):
                    raise http_error(status)

                with self.assertRaisesRegex(RuntimeError, f"HTTP {status}"):
                    REFRESH.dispatch("synthetic-token", open_url=open_url,
                                     sleep=lambda *_: self.fail("Unexpected retry"))
        self.assertIsNone(REFRESH.NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.com"))

    def test_rate_limit_delay_is_respected_or_fails_closed(self):
        self.assertEqual(REFRESH.retry_delay("10", 0), 10)
        self.assertEqual(REFRESH.retry_delay("invalid", 2), 4)
        with self.assertRaisesRegex(RuntimeError, "rate limit"):
            REFRESH.retry_delay("120", 0)

    def test_unexpected_success_response_is_not_accepted(self):
        response = Response()
        response.status = 200
        with self.assertRaisesRegex(RuntimeError, "Unexpected"):
            REFRESH.dispatch("synthetic-token", open_url=lambda *_args, **_kwargs: response)

    def test_workflow_uses_only_trusted_main_and_dedicated_credential(self):
        workflow = (ROOT / ".github/workflows/website-roadmap-refresh.yml").read_text()
        self.assertIn("ref: main", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("secrets.WEBSITE_ROADMAP_DISPATCH_TOKEN", workflow)
        self.assertIn("vars.WEBSITE_ROADMAP_REFRESH_ENABLED == 'true'", workflow)
        self.assertIn("!github.event.issue.pull_request", workflow)
        self.assertIn("workflow_run.head_repository.full_name == 'brandomoore/Plozz'", workflow)
        self.assertIn("workflows: [Issue triage, Discord issue bridge, TestFlight issue resolutions]", workflow)
        self.assertNotIn("COPILOT_GITHUB_TOKEN", workflow)
        self.assertNotIn("pull_request_target:", workflow)
        self.assertNotIn("github.event.issue.body", workflow)
        self.assertNotIn("github.event.comment.body", workflow)


if __name__ == "__main__":
    unittest.main()
