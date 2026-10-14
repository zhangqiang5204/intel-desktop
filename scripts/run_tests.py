#!/usr/bin/env python3
"""Run repository-relative Python regressions with fake native backends."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    environment = dict(os.environ)
    environment["PYTHONPATH"] = os.pathsep.join([str(ROOT / "scripts"), str(ROOT / "tests"), environment.get("PYTHONPATH", "")])
    return subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", *sys.argv[1:]],
                          cwd=ROOT, env=environment, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
