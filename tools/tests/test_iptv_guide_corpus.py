from datetime import datetime, timezone
import gzip
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "iptv_guide_corpus", Path(__file__).resolve().parents[1] / "iptv-guide-corpus.py"
)
CORPUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORPUS)


class GuideCorpusTests(unittest.TestCase):
    def test_reference_dates_handle_reduced_precision_offsets_and_invalid_days(self):
        expected = datetime(2026, 1, 1, tzinfo=timezone.utc)
        for value in ["2026", "202601", "20260101", "20260101000000 +0000"]:
            self.assertEqual(CORPUS.timestamp(value), expected)
        self.assertEqual(CORPUS.timestamp("20260101010000 +0100"), expected)
        for value in ["20260229", "2026010124", "2026 CST", None]:
            self.assertIsNone(CORPUS.timestamp(value))

    def test_reference_counts_only_current_explicit_usable_intervals(self):
        xml = b"""<tv>
        <channel id="g"><display-name>Guide</display-name></channel>
        <programme channel="g" start="2026010100" stop="2026010101"><title>Good</title></programme>
        <programme channel="g" start="2026010100" stop="2026010101"><title>Duplicate interval</title></programme>
        <programme channel="g" start="2026010101"><title>Missing stop</title></programme>
        <programme channel="g" start="2027010100" stop="2027010101"><title>Outside</title></programme>
        <programme channel="g" start="2026010100" stop="2026010101"><title> </title></programme>
        </tv>"""
        result = CORPUS.inspect(gzip.compress(xml), datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.assertEqual(result["sourceProgrammes"], 5)
        self.assertEqual(result["channels"][0]["intervals"], [[1767225600, 1767229200]])

    def test_oversized_empty_and_malformed_guides_cannot_supply_reference_success(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        for xml in [b"<tv/>", b"<tv>", b"<tv>" + b"x" * 100 + b"</tv>"]:
            with patch.object(CORPUS, "MAXIMUM_EXPANDED_BYTES", 64):
                with self.assertRaises((ValueError, CORPUS.ET.ParseError)):
                    CORPUS.inspect(gzip.compress(xml), now)


if __name__ == "__main__":
    unittest.main()
