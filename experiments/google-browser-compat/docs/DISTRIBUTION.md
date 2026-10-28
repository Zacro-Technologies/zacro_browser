# Platform builds, storage and distribution

The experiment assembles intact upstream artifacts in its own external root. A separate [Chromium 156 source-build pipeline](../build/NATIVE-BUILD.md) now implements native Zacro branding, runtime inventories and development packaging, but [its saved evidence](../evidence/windows-native-source.json) records no dependency synchronization, compilation or execution yet. Neither path produces a signed Zacro release, replaces installed applications, configures a system updater or migrates real profiles. Current upstream artifact pins are in `engines.lock.json`; the branded source pin is in `build/native-build.lock.json`.

## Executable assemblies versus source builds

| Platform    | Bounded executable experiment                                                                                  | Future source-built Zacro candidate                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Windows x64 | Verified upstream archive, isolated external runtime directory and experiment-owned regular/private data roots | Native Windows checkout/build using pinned Chromium and toolchain; separate product/installer/service identities |
| macOS arm64 | Verified upstream archive and isolated app/profile paths; native execution must be recorded on a Mac           | Native Mac checkout/build using the selected SDK and `target_cpu="arm64"`                                        |
| macOS Intel | No artifact in this experiment's snapshot matrix                                                               | Retained requirement from the existing product; separate x64 build and native acceptance before full migration   |

Keep archives, expanded runtimes and source outputs outside the application repository. Preserve complete upstream license/notice files. Record SHA-256, upstream origin metadata and assembly contents; verify a platform signature where present and record missing/unsupported verification explicitly. A verified checksum does not establish publisher signing or Google compatibility.

The [Windows Chromium 159 snapshot failure](../evidence/mechanics-chromium-win32-x64-engine-only.json) occurs before the fixture document is requested. Availability of an intact ZIP does not establish a usable browser on that host, and this startup failure must not be classified as Google's unsupported-browser response. The prebuilt-kit CI keeps mechanics failures visible even when it can assemble a diagnostic ZIP.

`assemble` writes `ROOT/output/zacro-google-browser-compat-<engine>-<version>-<platform>.zip`. The outer ZIP contains a `zacro-google-browser-compat/` tools directory and the original upstream ZIP under `payload/`; no Mac app bundle is expanded or rewritten on Windows. Extract the outer kit separately from the owned runtime/profile root and follow [the standalone manual instructions](MANUAL-ACCEPTANCE.md#start-from-a-downloaded-kit). Manual tools need only Node.js. Optional mechanics dependencies are pinned in the kit and installed separately; no browser profile, fixture directory or manual account result is bundled.

Do not rename or re-sign an upstream reference browser to pretend it is Zacro. The optional workspace component can be distributed with instructions as an integration experiment, with its own source/version identity. It does not change the upstream browser's identity or give Zacro ownership of its updater.

## Resource and toolchain preflight

The [saved Windows preflight](../evidence/windows-native-source.json) records **31.93 GiB RAM and 152.6 GiB free** after source preparation, with VS 2026, the required SDK and debugging tools still unavailable. This is a dated observation, not a current free-space guarantee. The checked-out source and reviewed patch do not establish dependency readiness or compilation.

For the pinned Windows source plan, verify native x64 Windows, an NTFS checkout without spaces, **Visual Studio 2026 ≥18.0.0**, Desktop C++, MFC/ATL, **Windows SDK 10.0.28000.2270** and **Debugging Tools ≥10.0.26100.3323**. The SDK product release and include-directory version differ: the corresponding include path is `Include/10.0.28000.0`. Chromium supplies clang tooling but still requires Visual Studio headers/libraries/tools. Record actual versions rather than treating an installed `cl.exe` as sufficient.

For Mac, verify the selected native architecture, APFS, accepted Xcode tools and SDK values in the pinned tree. The branded Chromium 156 source uses official SDK **26.5 / 25F70**; the older Chromium 159 source plan uses **27.0 / 26A425**. Both have `mac_sdk_min` **15**. An official-build SDK and a minimum supported SDK are different settings, and preflight reports the selected SDK. Runtime/deployment minimum remains macOS 13. Intel has its own `darwin-x64` source and acceptance lane.

Standard hosted CI runs the small source/tooling checks, not Chromium compilation. The native compile job requires an explicit dispatch and a provisioned self-hosted Windows or Mac worker; see [its labels, desktop-session requirements and evidence rules](../build/NATIVE-BUILD.md#outputs-and-ci). Check writable disk, free RAM, architecture, SDK and execution-time limits before preparing dependencies. Cache content-addressed dependencies carefully, keep credentials out of caches, and do not run untrusted pull requests on a signing worker.

Source-plan output is a reproducibility aid, not a successful build record. Any selected toolchain or GN flag change creates a new candidate configuration requiring recorded verification. A Mac build cannot establish Windows execution or vice versa.

## Credential and cookie capabilities

| Area                          | Prototype interpretation                                                               | Distribution gate                                                                                                        |
| ----------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Native cookie/profile storage | Let the upstream browser own its ordinary profile and off-the-record stores            | Verify persistence, sign-out, isolation and private cleanup in the exact package                                         |
| macOS Keychain                | Browser identity, keychain access and signing configuration matter                     | Test with the final bundle identity, entitlements and normal Keychain state; do not copy another product's storage entry |
| Windows DPAPI/OSCrypt         | Preserve upstream OS cryptography; record the actual build/install mode                | Verify normal-user persistence and supported encryption path                                                             |
| Windows app-bound encryption  | A portable executable and custom test data root are not proof of support               | Inspect final installer/elevation-service integration, default data path and upstream support conditions                 |
| Passkeys/security keys        | A browser controller in source is a capability hypothesis, not an authenticator result | Test applicable Windows Hello, macOS platform/provider and physical security-key flows manually                          |

Chromium's Windows [app-bound implementation](https://github.com/chromium/chromium/blob/0c75ec0efee23f664c9a3380217ae4650bed97e6/chrome/browser/os_crypt/app_bound_encryption_win.cc) checks conditions including system installation and the default data directory. Do not disable OS protection or copy authentication cookies to make a portable acceptance check pass. Record “unsupported in this package” separately from “failed” and “untested.”

No launcher or diagnostics should read the browser's cookie, password or token databases. Acceptance reports contain coarse results and origin/configuration information, never credentials, authentication bodies or token-bearing URLs. Native browser history is owned by the test profile; the experiment must not create an additional authentication log.

## Windows release plan

1. Assign Zacro-specific application, installer, service and profile identifiers; keep experimental and stable channels separate.
2. Build on a qualified native Windows worker with the pinned dependency/toolchain manifest. Retain security services and hardening; record effective build flags.
3. Produce an Authenticode-signed installer and signed executable/service payloads with timestamping. Validate installation/uninstallation, ordinary-user operation, default-browser registration, OS authentication and storage on a clean machine.
4. Operate a signed update manifest and authenticated artifact delivery. Verify hashes/signatures before staging, switch atomically only after a successful health check, and support staged rollout/rollback.
5. Validate the update/elevation-service model used by the chosen Chromium implementation. Copying updater source is not the same as running a secure release/update service.

## macOS release plan

1. Assign independent bundle identifiers, helper identities, Keychain/access-group identifiers and profile locations. Preserve native menu, window, input and accessibility integration.
2. Build arm64 and the retained Intel target independently. If a universal package is desired, combine only matching source/configuration versions and verify each architecture separately.
3. Sign all executable and helper components with the release identity and appropriate Hardened Runtime/entitlements. Notarize and staple the distributable; verify Gatekeeper acceptance on clean systems.
4. Package DMG/ZIP or another explicitly selected native distribution format and configure an independent signed update channel. Test updates, partial downloads, interruption and recovery.
5. Validate final-package native authentication, Keychain behavior, permissions, accessibility/IME, trackpad/window behavior and website sessions. Signing/notarization does not certify Google acceptance.

## Updates and rollback

Maintain a security-update owner and a small reviewed patch queue against upstream Chromium. Track dependency revisions, licenses, build environments and artifact provenance. Re-run browser-mechanics and provider acceptance when the engine, branding, relevant policies or native auth/storage configuration changes; record failed/untested results instead of carrying forward an old pass as permanent assurance.

Treat executable rollback and data rollback separately. Preserve the last known-good application artifact, but do not automatically run an old Chromium version against a newer profile schema. Use an upstream-supported downgrade mechanism or an explicit recovery plan with encrypted, access-controlled backups and user consent. Never merge or transplant cookies between test/reference/product profiles as a rollback technique.

Production gates remain: native builds for every claimed architecture; clean-machine distribution/update tests; applicable OS storage/passkey results; direct Google acceptance per platform; accessibility/input acceptance; and the feature-preservation requirements in [migration](MIGRATION.md). This document is a plan, not a claim that these services or packages have shipped.
