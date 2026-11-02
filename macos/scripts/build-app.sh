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
native_licenses="$native_app/Contents/Resources/Licenses"
native_providers="$native_app/Contents/Resources/Providers"
mkdir -p "$native_licenses" "$native_providers"
# PDF parsing runs in a bounded, separately owned native process. Build it with
# the same configuration as the application before modifying the signed bundle.
swift build --package-path "$native_root" --configuration release --product ZacroTextExtractor
native_bin_path="$(swift build --package-path "$native_root" --configuration release --show-bin-path)"
install -m 755 "$native_bin_path/ZacroTextExtractor" "$native_providers/ZacroTextExtractor"
# Use the pinned, native Codex executable directly; the npm launcher and Node
# runtime are not part of the Swift application. Fail instead of shipping a
# provider setup screen whose required executable is absent.
case "$(uname -m)" in
  arm64) native_codex_arch=arm64; native_codex_triple=aarch64-apple-darwin ;;
  x86_64) native_codex_arch=x64; native_codex_triple=x86_64-apple-darwin ;;
  *) echo 'Unsupported macOS architecture for the bundled Codex provider.' >&2; exit 1 ;;
esac
native_codex="$native_root/../node_modules/@openai/codex-darwin-$native_codex_arch/vendor/$native_codex_triple/bin/codex"
if [[ ! -x "$native_codex" ]]; then
  echo "Missing pinned native Codex executable: $native_codex. Install the repository dependencies first." >&2
  exit 1
fi
native_codex_version="$("$native_codex" --version)"
if [[ "$native_codex_version" != 'codex-cli 0.164.0' ]]; then
  echo 'The native Codex provider does not match the pinned 0.164.0 protocol version.' >&2
  exit 1
fi
install -m 755 "$native_codex" "$native_providers/codex"
cp "$native_root/../assets/icon.icns" "$native_app/Contents/Resources/Zacro.icns"
# Include the complete redistribution notices before signing the final bundle.
cp "$native_root/../LICENSE" "$native_licenses/Zacro.txt"
cp "$native_root/Engine/CefSwift/LICENSE" "$native_licenses/CefSwift.txt"
cp "$native_root/Engine/CefSwift/Sources/CCef/LICENSE.CEF.txt" "$native_licenses/CEF.txt"
cp "$native_root/../assets/CODEX-LICENSE.txt" "$native_licenses/Codex.txt"
python3 "$native_root/scripts/configure-app-plist.py" "$native_app/Contents/Info.plist" --version 0.11.0
plutil -lint "$native_app/Contents/Info.plist"
# This script produces development bundles only. Re-sign the changed outer
# resources without weakening the already-signed Chromium helper entitlements.
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$native_providers/codex"
codesign --force --sign - "$native_providers/ZacroTextExtractor"
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$native_app"
codesign --verify --deep --strict "$native_app"
