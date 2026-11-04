import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import sys
import unittest

import fixture
import lab


def integer(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


class FixtureTests(unittest.TestCase):
    def test_index_points_to_three_bdj_objects(self):
        data = fixture.index()
        start = integer(data, 8)
        self.assertEqual(start, 78)
        self.assertEqual(integer(data, 40), 34)
        self.assertEqual(integer(data, start), len(data) - start - 4)
        self.assertEqual(struct.unpack_from(">H", data, start + 28)[0], 1)
        for offset in (start + 4, start + 16, start + 30):
            self.assertEqual(integer(data, offset) >> 30, 2)
            self.assertEqual(data[offset + 6:offset + 11], b"00000")

    def test_bdjo_sections_have_exact_boundaries(self):
        data = fixture.bdjo()
        addresses = struct.unpack_from(">6I", data, 8)
        self.assertEqual(addresses[0], 48)
        for start, end in zip(addresses[:4], addresses[1:5]):
            self.assertEqual(start + 4 + integer(data, start), end)
        self.assertEqual(data[addresses[2] + 8:addresses[3]], b"00001\0" + b"00002\0")
        self.assertIn(b"org.plozz.disclab.MenuXlet", data)
        self.assertEqual(addresses[-1] + 2, len(data))

    def test_playlists_are_distinct_single_clip_titles(self):
        for clip in ("00001", "00002"):
            data = fixture.playlist(clip)
            start = integer(data, 8)
            marks = integer(data, 12)
            self.assertEqual(start, 64)
            self.assertEqual(start + 4 + integer(data, start), marks)
            self.assertEqual(data[start + 12:start + 17], clip.encode())
            self.assertEqual(integer(data, start + 28), 8 * 45000)
            self.assertEqual(marks + 4 + integer(data, marks), len(data))

    def test_clip_info_includes_real_access_point(self):
        data = fixture.clip_info(500)
        cpi = integer(data, 16)
        mark = integer(data, 20)
        self.assertEqual(integer(data, 56), 500)
        self.assertEqual(cpi + 4 + integer(data, cpi), mark)
        self.assertEqual(data[cpi + 7], 1)
        descriptor = int.from_bytes(data[cpi + 8:cpi + 20], "big")
        self.assertEqual(descriptor >> 80, 0x1011)
        self.assertEqual((descriptor >> 50) & 0xFFFF, 1)
        self.assertEqual((descriptor >> 32) & 0x3FFFF, 1)
        self.assertEqual(descriptor & 0xFFFFFFFF, 14)

    def test_fixture_refuses_existing_destination_and_partial_packets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(FileExistsError):
                fixture.create(root, root)
            (root / "00001.m2ts").write_bytes(b"partial")
            with self.assertRaisesRegex(ValueError, "192-byte"):
                fixture.create(root / "disc", root)

    def test_checksum_failures_are_fatal(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "archive"
            archive.write_bytes(b"test")
            lab.verify_archive(archive, {"sha256": hashlib.sha256(b"test").hexdigest()})
            with self.assertRaisesRegex(ValueError, "mismatch"):
                lab.verify_archive(archive, {"sha256": "0" * 64})

    def test_dependencies_have_pinned_https_sources(self):
        manifest = json.loads((lab.HERE / "dependencies.json").read_text())
        self.assertEqual(set(manifest), {"libbluray", "host-jdk", "ant", "zero-source"})
        for specification in manifest.values():
            self.assertTrue(specification["url"].startswith("https://"))
            algorithm = "sha256" if "sha256" in specification else "sha512"
            self.assertEqual(len(bytes.fromhex(specification[algorithm])),
                             32 if algorithm == "sha256" else 64)

    def test_deadline_stops_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = object.__new__(lab.Lab)
            runner.run_dir = Path(temporary)
            runner.commands = []
            runner.environment = dict(os.environ)
            runner.lease_fds = ()
            pid_file = runner.run_dir / "pid"
            command = (
                "import os,pathlib,sys,time; "
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(20)"
            )
            with self.assertRaisesRegex(RuntimeError, "exceeded"):
                runner.run("deadline", [sys.executable, "-c", command, pid_file], timeout=1)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)


if __name__ == "__main__":
    unittest.main()
