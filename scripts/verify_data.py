#!/usr/bin/env python3
"""Run data-only offline tests; no mobile builds, provider or private-data reads."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TASKS = ("D01", "D02", "D03", "D04", "D05")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", choices=TASKS + ("all",), default="all")
    args = parser.parse_args()
    selected = TASKS if args.task == "all" else (args.task,)
    for task in selected:
        directory = ROOT / "data" / task / "tests"
        if not directory.is_dir():
            print(f"Missing public tests for {task}", file=sys.stderr)
            return 2
        print(f"Running {task} offline synthetic tests", flush=True)
        result = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", str(directory), "-p", "test_*.py"], cwd=ROOT)
        if result.returncode:
            return result.returncode
    print("Data-only checks passed; this is not human recording, frozen gold or real model evaluation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
