#!/usr/bin/env python3
"""Build and run portable protocol tests without an iOS SDK."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TESTS = (
    "test_jpeg_parser",
    "test_http_chunk_decoder",
    "test_mjpeg_playout",
    "test_shared_media_protocol",
    "test_local_orientation_math",
    "test_preference_validation",
)


def main() -> int:
    compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
    if not compiler:
        print("Set CC or install a C11 compiler to run the portable tests.", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="vcam-tests-") as directory:
        for name in TESTS:
            executable = Path(directory) / (name + (".exe" if os.name == "nt" else ""))
            print("Running", name, flush=True)
            subprocess.run(
                [compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pedantic", str(ROOT / "tests" / (name + ".c")), "-lm", "-o", str(executable)],
                check=True,
            )
            subprocess.run([str(executable)], check=True)
    subprocess.run([sys.executable, str(ROOT / "tests" / "test_stack_block_ir.py")], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
