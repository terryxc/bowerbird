#!/usr/bin/env python3
"""Check the complete app bundle for personal build paths and required licenses."""

import argparse
from pathlib import Path
import plistlib
import sys


def verify(app: Path) -> list[str]:
    repository = Path(__file__).resolve().parent.parent
    resources = app / "Contents/Resources"
    errors = []
    if not (app / "Contents/MacOS/Bowerbird").is_file():
        errors.append("Missing Bowerbird executable")

    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        bundled = resources / name
        if not bundled.is_file():
            errors.append(f"Missing bundled {name}")
        elif bundled.read_bytes() != (repository / name).read_bytes():
            errors.append(f"Bundled {name} differs from the source copy")

    try:
        actual = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        expected = plistlib.loads((repository / "Support/Info.plist").read_bytes())
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if actual.get(key) != expected[key]:
                errors.append(f"Bundle {key} differs from Support/Info.plist")
    except (OSError, ValueError) as error:
        errors.append(f"Could not read bundle version: {error}")

    # Scan every byte, including both Mach-O slices and their symbol tables.
    # macOS `strings -a` scans sections, so it misses paths in the symbol table.
    # Do not print matched paths: that would expose them in CI logs instead.
    markers = [
        prefix.encode(encoding)
        for prefix in ("/Users/", "/home/", ":\\Users\\")
        for encoding in ("utf-8", "utf-16-le", "utf-16-be")
    ]
    for file in sorted(app.rglob("*")):
        if file.is_file():
            data = file.read_bytes()
            if any(marker in data for marker in markers):
                errors.append(f"Personal build path in {file.relative_to(app)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    errors = verify(args.app)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Verified app version, bundled licenses and absence of personal build paths")
    return 0


if __name__ == "__main__":
    sys.exit(main())
