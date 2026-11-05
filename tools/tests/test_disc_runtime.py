import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("embed_disc_runtime", ROOT / "tools/embed-disc-runtime.py")
EMBED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EMBED)


class DiscRuntimeEmbeddingTests(unittest.TestCase):
    def test_incremental_embedding_replaces_read_only_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            destination = root / "destination"
            source.write_bytes(b"current runtime")
            source.chmod(0o444)
            destination.write_bytes(b"previous runtime")
            destination.chmod(0o444)
            EMBED.replace_file(source, destination)
            self.assertEqual(destination.read_bytes(), b"current runtime")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o444)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["destination", "source"])


if __name__ == "__main__":
    unittest.main()
