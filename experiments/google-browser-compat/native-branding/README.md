# Zacro Prototype native source identity

This is a small source patch for the **full Chromium browser**, preserving `//chrome` and its native tabs, omnibox, connection-security UI, profiles, permissions and authentication interfaces. It does not patch an upstream binary, intercept requests or make a Google acceptance claim.

The native build uses **Chromium 156.0.8078.48**, source **`d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`**, matching the engine of the Brave reference. Its build pin is separate from the unchanged Chromium 159 snapshot experiment. The patch and its exact before/after file hashes are recorded in [manifest.json](manifest.json). A patch check is not a compiler or runtime result.

## Apply to the pinned source checkout

From the Zacro repository, with `SOURCE` replaced by the absolute native Chromium checkout root:

```sh
node experiments/google-browser-compat/native-branding/apply.cjs --source SOURCE --check
node experiments/google-browser-compat/native-branding/apply.cjs --source SOURCE --apply
```

Both commands require Git HEAD to equal the pinned revision. Create the checkout with `core.autocrlf=false` so its source bytes match upstream on Windows as well as Mac. Every affected source file must be exactly the reviewed original or exactly the reviewed patched version; a mixture, edited file, escaping link or patch digest mismatch stops before applying. Unrelated files and changes are preserved. Reapplying an already verified patch reports `alreadyApplied: true`. The build orchestrator can import `inspect({source})` and `apply({source})`; both return structured receipts with `compiled: false`.

Use the unbranded Chromium build path (`is_chrome_branded=false`, `is_chrome_for_testing=false`) and build the normal `chrome` target. No Google API credentials, Sync client secrets or source-level security bypass is added. Product metadata comes from the normal build templates. Native build flags and platform prerequisites belong to the separate build configuration.

| Identity                                     | Patched value                                                                                                                          |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Product and prominent native UI strings      | `Zacro Prototype`                                                                                                                      |
| macOS application                            | `Zacro Prototype.app/Contents/MacOS/Zacro Prototype`                                                                                   |
| macOS bundle ID                              | `com.zacro.prototype`; helper/framework IDs continue through upstream bundle generation                                                |
| macOS default profile                        | `~/Library/Application Support/Zacro Prototype`                                                                                        |
| macOS Keychain service / account             | `Zacro Prototype Safe Storage` / `Zacro Prototype`                                                                                     |
| Windows internal executable                  | `chrome.exe`, retained because upstream launch and installer code expect this filename                                                 |
| Windows AppUserModelID base / data namespace | `ZacroPrototype` / `%LOCALAPPDATA%\ZacroPrototype\User Data`                                                                           |
| Windows product registration                 | Separate HTML/PDF ProgID prefixes, direct-launch scheme, Active Setup, toast/elevation/tracing class GUIDs and AppContainer SID prefix |
| Reduced user-agent product tokens            | `Chrome/156.0.0.0 ZacroPrototype/156.0.0.0`                                                                                            |
| Full product tokens                          | `Chrome/156.0.8078.48 ZacroPrototype/156.0.8078.48`                                                                                    |
| User-agent client hints                      | `Zacro Prototype` plus upstream `Chromium` and GREASE brands; native version/order generation retained                                 |

The `Chrome/` token is the upstream engine compatibility token. The product is additionally disclosed in both user agent and client hints on all sites, with no Google-specific exceptions or override flags. This does not claim that the product is Google Chrome or that Google will accept it.

Windows COM class registrations are distinct. Their interface IIDs are intentionally retained because the existing interfaces and service implementations are unchanged. No service or installer is registered by the patch tools. The Google Update app GUID stays empty. macOS Keychain uses a new service/account namespace; it does not read or copy Chromium's existing storage secret. Browser permission/authentication APIs, certificate checks, encryption algorithms and sandbox enforcement are not replaced.

This is a minimal prototype identity, not a complete design migration. Chromium's icons, legal attribution, internal names and many secondary strings remain. Neither platform's signing, installer/update service, system registration, Keychain/native-auth capabilities nor default-profile behavior is established until an actual build is tested. Use new owned test profiles, do not import existing profiles, and do not register this prototype as the default browser during the first acceptance pass.

## Validation and source evidence

`validate-sparse.cjs ABS_REFERENCE_DIRECTORY` checks the selected upstream file hashes, copies only those files into a fresh external directory, runs real `git apply --check`, applies the patch, compares every resulting hash, and checks reverse applicability. It emits a result with `fullCheckoutRevisionVerified: false`, `compiled: false` and `executed: false`. It never turns a source check into a browser or Google test.

`generate.cjs ABS_REFERENCE_DIRECTORY` is a maintainer tool that regenerates the reviewed patch from the pinned originals. Existing manifest hashes prevent silent source drift. A new upstream revision requires an explicit review and new manifest. The fetched files stay outside the application repository; only the small patch and hash ledger are committed.

Primary source paths were retrieved on **2026-10-29 (Asia/Tokyo)**. Every changed file has a pinned URL in the manifest. Relevant unchanged generation and ownership paths were also inspected:

- [Native product and Mac bundle generation](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/chrome/BUILD.gn)
- [Product version generation](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/base/version_info/BUILD.gn)
- [Windows default-profile ownership](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/chrome/common/chrome_paths_win.cc)
- [Windows install-path composition](https://github.com/chromium/chromium/blob/d0c02bfad08ec92a6ffcf989e53cd995e6381a4c/chrome/install_static/install_util.cc)

After native compilation, verify executable metadata, bundle IDs, the actual default profile, Keychain/Windows storage behavior, displayed UA and client hints on a local fixture, and native browser/security UI. Then run a new manually operated Google acceptance matrix for the actual branded binaries on each OS. A password field in the separate Brave reference does not populate those results.
