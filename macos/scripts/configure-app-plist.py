#!/usr/bin/env python3
"""Apply Zacro's native bundle metadata before the final codesign operation."""
import argparse
import json
from pathlib import Path
import plistlib


def configure(plist_path: Path, package_path: Path, version: str) -> None:
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    package = json.loads(package_path.read_text())
    original = package["build"]["mac"]["extendInfo"]
    info.update({
        "CFBundleShortVersionString": version,
        "CFBundleIconFile": "Zacro.icns",
        "LSApplicationCategoryType": package["build"]["mac"]["category"],
        # The Swift package and native Chromium integration require macOS 14.
        "LSMinimumSystemVersion": "14.0",
    })
    # These capabilities have real application/delegate handlers. Do not claim
    # document types, file://, or OS permissions unsupported by the native app.
    for key in (
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSLocationUsageDescription",
        "NSLocationWhenInUseUsageDescription",
    ):
        info[key] = original[key]
    info["CFBundleURLTypes"] = []
    for source_type in original["CFBundleURLTypes"]:
        url_type = dict(source_type)
        # The old Electron manifest misspelled Apple's required URL role key.
        # CFBundleTypeRole is the same key for URL types and document types.
        url_type["CFBundleTypeRole"] = url_type.pop("CFBundleURLRole", "Viewer")
        info["CFBundleURLTypes"].append(url_type)
    temporary = plist_path.with_suffix(".plist.zacro-tmp")
    try:
        with temporary.open("wb") as destination:
            plistlib.dump(info, destination, fmt=plistlib.FMT_XML, sort_keys=False)
        temporary.replace(plist_path)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("plist", type=Path)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    configure(arguments.plist, Path(__file__).resolve().parents[2] / "package.json", arguments.version)
