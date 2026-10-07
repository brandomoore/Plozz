#!/usr/bin/python3 -B
"""Inventory or remove exact owner-released Apple build-output trees."""

import sys

sys.dont_write_bytecode = True
import os
from pathlib import Path

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from apple_build_cleanup import main


if __name__ == "__main__":
    sys.exit(main())
