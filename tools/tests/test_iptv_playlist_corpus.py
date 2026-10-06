import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "iptv_playlist_corpus", Path(__file__).resolve().parents[1] / "iptv-playlist-corpus.py"
)
CORPUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORPUS)


class PlaylistCorpusTests(unittest.TestCase):
    def download(self, payload, directory):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = payload
        with patch.object(CORPUS.urllib.request, "urlopen", return_value=response) as fetch:
            result = CORPUS.download(("fixture", "https://public.example/list"), directory)
        fetch.assert_called_once()
        response.read.assert_called_once_with(CORPUS.MAXIMUM_BYTES + 1)
        return result

    def test_snapshot_counts_real_addresses_separately_from_placeholders(self):
        payload = (
            b"\xef\xbb\xbf#EXTM3U\n#EXTINF:-1,News\nhttps://public.example/live\n"
            b"#EXTINF:-1,Missing\n[NO PUBLIC STREAM]\n"
            b"#EXTINF:-1,Unsupported\nrtsp://public.example/live\n"
        )
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            result = self.download(payload, directory)
            self.assertEqual(result["entries"], 3)
            self.assertEqual(result["httpEntries"], 1)
            self.assertEqual(result["bytes"], len(payload))
            self.assertEqual(result["sha256"], CORPUS.hashlib.sha256(payload).hexdigest())
            self.assertEqual((directory / "fixture.m3u8").read_bytes(), payload)

    def test_invalid_empty_and_oversized_inputs_are_explicit_failures(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            for payload in [b"<html>Login</html>", b"#EXTM3U\n", b"#EXTM3U\n" + b"x" * 100]:
                with patch.object(CORPUS, "MAXIMUM_BYTES", 80):
                    result = self.download(payload, directory)
                self.assertIn("error", result)
                self.assertNotIn("sha256", result)
                self.assertFalse((directory / "fixture.m3u8").exists())

    def test_unavailable_source_cannot_be_reported_as_a_valid_snapshot(self):
        with tempfile.TemporaryDirectory() as root:
            error = urllib.error.HTTPError("https://public.example/list", 404, "Not found", {}, None)
            with patch.object(CORPUS.urllib.request, "urlopen", side_effect=error):
                result = CORPUS.download(("fixture", error.url), Path(root))
            self.assertIn("404", result["error"])
            self.assertNotIn("sha256", result)


if __name__ == "__main__":
    unittest.main()
