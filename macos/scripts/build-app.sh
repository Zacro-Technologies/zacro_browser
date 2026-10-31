#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
swift package --package-path "$native_root" \
  --allow-writing-to-package-directory --allow-network-connections all \
  cef bundle --product ZacroNative --configuration release \
  --manifest "$native_root/Engine/CefSwift/CEF_VERSION.json" \
  --bundle-id com.zacro.browser.native --name 'Zacro Native' \
  "$@"

native_app="$native_root/dist/Zacro Native.app"
mkdir -p "$native_app/Contents/Resources"
cp "$native_root/../assets/icon.icns" "$native_app/Contents/Resources/Zacro.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.11.0' "$native_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Zacro.icns' "$native_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string Allow websites you approve in Zacro to use your camera.' "$native_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string Allow websites you approve in Zacro to use your microphone.' "$native_app/Contents/Info.plist"
# This script produces development bundles only. Re-sign the changed outer
# resources without weakening the already-signed Chromium helper entitlements.
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$native_app"
codesign --verify --deep --strict "$native_app"
