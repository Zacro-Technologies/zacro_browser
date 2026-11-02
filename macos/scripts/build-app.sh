#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
native_output="$native_root/dist"
native_sign="-"
native_runtime_record="${ZACRO_RUNTIME_BUILD:-$native_root/.build/native-runtime/zacro-runtime-build.json}"
native_stock=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-build|--output|--sign)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --runtime-build) native_runtime_record="$2" ;;
        --output) native_output="$2" ;;
        --sign) native_sign="$2" ;;
      esac
      shift 2 ;;
    --stock-runtime) native_stock=1; shift ;;
    --help|-h)
      echo 'Usage: build-app.sh [--runtime-build receipt.json] [--output directory] [--sign identity]'
      echo 'Requires the pinned custom Chromium runtime. --stock-runtime is for diagnostic builds only.'
      exit 0 ;;
    *) echo "Unknown build option: $1" >&2; exit 2 ;;
  esac
done
native_framework_args=()
if [[ "$native_stock" == 0 ]]; then
  native_framework="$(python3 -B "$native_root/scripts/validate-runtime.py" "$native_runtime_record")"
  native_framework_args=(--framework "$native_framework")
else
  echo 'Building a diagnostic app with stock CEF; native extension integration is unavailable.' >&2
fi
mkdir -p "$native_output"
native_output="$(cd "$native_output" && pwd)"
swift package --package-path "$native_root" \
  --allow-writing-to-package-directory --allow-network-connections all \
  cef bundle --product ZacroNative --configuration release \
  --manifest "$native_root/Engine/CefSwift/CEF_VERSION.json" \
  --bundle-id com.zacro.browser.native --name 'Zacro Native' \
  --output "$native_output" --sign "$native_sign" ${native_framework_args[@]+"${native_framework_args[@]}"}

native_app="$native_output/Zacro Native.app"
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
if [[ "$native_stock" == 0 ]]; then
  python3 -B "$native_root/scripts/validate-runtime.py" "$native_runtime_record" \
    --write-provenance "$native_app/Contents/Resources/zacro-runtime-build.json" > /dev/null
fi
# This script produces development bundles only. Re-sign the changed outer
# resources without weakening the already-signed Chromium helper entitlements.
codesign --force --sign "$native_sign" --preserve-metadata=entitlements,requirements,flags "$native_providers/codex"
codesign --force --sign "$native_sign" "$native_providers/ZacroTextExtractor"
codesign --force --sign "$native_sign" --preserve-metadata=entitlements,requirements,flags "$native_app"
codesign --verify --deep --strict "$native_app"
