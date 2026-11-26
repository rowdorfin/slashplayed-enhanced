#!/usr/bin/env python3
"""Generate and compare the Metal shim using its current output-relevant import records."""

import argparse
import difflib
import sys
from pathlib import Path

from gen_stubs import gen_shim, shim_build_line

GENERATED = Path(__file__).resolve().parents[2] / "shims" / "generated"
# These are the Metal stubs emitted from the current merged imports. Refresh this
# fixture if a full SDK/client regeneration changes Metal's stub set.
SYMBOLS = {
    "function": ("_MTLCopyAllDevicesWithObserver", "_MTLRemoveDeviceObserver"),
    "data": ("_MTLDeviceRemovalRequestedNotification", "_MTLDeviceWasRemovedNotification"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--emit", action="store_true", help="print the generated source")
    mode.add_argument("--emit-build-line", action="store_true", help="print the generated Metal build command")
    mode.add_argument("--check", type=Path)
    args = parser.parse_args()
    records = [
        {"stub": True, "kind": kind, "symbol": symbol}
        for kind, symbols in SYMBOLS.items()
        for symbol in symbols
    ]
    expected = gen_shim("Metal", records, {}, set(), GENERATED).encode("utf-8")
    if args.emit:
        sys.stdout.buffer.write(expected)
        return 0
    build_line = shim_build_line("libspMetal", ["-Wl,-reexport_framework,Metal"], GENERATED).encode("utf-8")
    if args.emit_build_line:
        sys.stdout.buffer.write(build_line)
        return 0
    source = args.check or GENERATED / "libspMetal.m"
    actual = source.read_bytes()
    if actual != expected:
        sys.stderr.writelines(difflib.unified_diff(
            actual.decode("utf-8", errors="replace").splitlines(keepends=True),
            expected.decode("utf-8").splitlines(keepends=True),
            fromfile=str(source), tofile="generator output",
        ))
        print("Metal shim differs from the generator (byte comparison).", file=sys.stderr)
        return 1
    print("Metal shim matches the generator byte for byte.")
    if args.check is None:
        commands = (GENERATED / "build.sh").read_bytes().splitlines(keepends=True)
        if [line for line in commands if line.startswith(b"$CC ") and b" libspMetal.m " in line] != [build_line]:
            print("Metal build command differs from the generator (byte comparison).", file=sys.stderr)
            return 1
        print("Metal build command matches the generator byte for byte.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
