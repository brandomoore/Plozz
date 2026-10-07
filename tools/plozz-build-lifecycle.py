#!/usr/bin/python3 -B
"""Inspect Plozz-owned build storage; registration requires a shared build lease."""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from plozz_build_lifecycle import main

if __name__ == "__main__":
    sys.exit(main())
