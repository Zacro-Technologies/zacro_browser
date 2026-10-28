# Build the minimal native Zacro browser

This pipeline builds Chromium's full `//chrome` browser with the reviewed **Zacro Prototype** identity patch. Native tabs, address/security controls, profiles, permissions and authentication services remain in place. The Electron application is unchanged.

The source pin is **156.0.8078.48 / `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`**, matching the engine in the Brave reference. It is separate from the earlier Chromium 159 snapshot experiment. See [the native pin](native-build.lock.json) and [branding patch](../native-branding/README.md).

## Current evidence

- The [initial local Windows receipt](../evidence/windows-native-source.json) verifies a full Chromium checkout, pinned depot tools and all nine branding hashes. Its missing-toolchain and unsynchronized-dependency status belongs to that machine at the recorded time.
- [Hosted source/tooling CI](../evidence/native-source-ci-b47b74e.json) passed Windows x64, Mac arm64 and Mac x64. Each platform verified and patched all nine source files; these small checks did not compile or execute a browser.
- The [separate hosted Windows build](../evidence/windows-hosted-build-milestones.json) completed SDK installation, full toolchain preflight, exact source preparation, pinned dependency synchronization and branding/GN configuration, then started the four-job compiler. This dated milestone record does not establish successful compilation, an executable or native browser acceptance; the linked run and its build/package receipts provide subsequent results.
- Managed Python and VPython bootstrap completed without changing global Git settings.
- The Windows Brave reference passed [nine local mechanics checks](../evidence/mechanics-brave-win32-x64-reference.json). The user separately reported a visible Google password field there; that passes only the reference's [preliminary password-step check](../evidence/manual-reference-results.json).
- The Chromium 159 snapshot [failed local startup](../evidence/mechanics-chromium-win32-x64-engine-only.json) before requesting the fixture document. That is not a Google rejection: its Google checks remain untested.
- Branded Google checks remain untested. A finished, verified binary and separate manual observations are required before recording any pass. The hosted build does not provision the user's local machine, and Mac compilation remains a separate native-platform requirement.

## Prerequisites

Use Node 24+, Git and a dedicated external root without spaces. Initial preparation requires 100 GiB free; 200–300 GiB gives more working room. Compilation requires at least 40 GiB remaining before it starts, and long-running source/build commands monitor a 15 GiB reserve. On a reserve or interrupt stop, the launcher terminates its owned process tree and reports any cleanup failure. These are project guards, not proof that the build will fit. Existing files are retained.

Windows x64 requires VS 2026 18+ C++/ATL/MFC, SDK release 10.0.28000.2270 and x64 debugging tools 10.0.26100.3323+. The [provisioning tool](PROVISION-WINDOWS.md) verifies signed Microsoft installers and creates a separate Build Tools instance only with `-Install` from an elevated shell. It cannot approve OS elevation.

Mac builds require their native architecture, APFS and Xcode. The pinned source minimum SDK is 15; the upstream official SDK is 26.5 / 25F70. Deployment remains macOS 13. Intel Mac has a separate `darwin-x64` build/test gate.

## Build on Windows

Run from the Zacro repository after provisioning. `npm ci --ignore-scripts` installs the existing dependencies for the later local mechanics checks without running package installation scripts; the source tools themselves use Node built-ins and the pinned depot runtime.

```powershell
node experiments/google-browser-compat/build/native-build.cjs preflight --root C:\zacro-google-prototype --platform win32-x64
node experiments/google-browser-compat/build/native-source.cjs prepare --root C:\zacro-google-prototype --platform win32-x64
node experiments/google-browser-compat/build/native-source.cjs sync --root C:\zacro-google-prototype --platform win32-x64
node experiments/google-browser-compat/build/native-build.cjs configure --root C:\zacro-google-prototype --platform win32-x64
node experiments/google-browser-compat/build/native-build.cjs build --root C:\zacro-google-prototype --platform win32-x64 --jobs 8
node experiments/google-browser-compat/mechanics.cjs --root C:\zacro-google-prototype --engine zacro-native
node experiments/google-browser-compat/build/native-build.cjs package --root C:\zacro-google-prototype --platform win32-x64
```

`prepare` fetches exact commits. `sync` uses pinned VPython and records successful synchronization plus actual dependency revisions. `configure` verifies those records, applies branding and runs upstream hooks/GN. It refuses unrelated source edits, changed arguments and dependency drift. `build` writes a compiled receipt only after the real `chrome` target succeeds and the runtime inventory is verified.

Windows uses a development component build to reduce linking memory. The archive includes GN's complete runtime dependency closure, including DLLs/resources and the reordered final `chrome.exe`. The internal filename stays `chrome.exe`; product and registration identity are Zacro Prototype.

## Build on Apple silicon

```sh
node experiments/google-browser-compat/build/native-build.cjs preflight --root "$HOME/zacro-google-prototype" --platform darwin-arm64
node experiments/google-browser-compat/build/native-source.cjs prepare --root "$HOME/zacro-google-prototype" --platform darwin-arm64
node experiments/google-browser-compat/build/native-source.cjs sync --root "$HOME/zacro-google-prototype" --platform darwin-arm64
node experiments/google-browser-compat/build/native-build.cjs configure --root "$HOME/zacro-google-prototype" --platform darwin-arm64
node experiments/google-browser-compat/build/native-build.cjs build --root "$HOME/zacro-google-prototype" --platform darwin-arm64 --jobs 8
node experiments/google-browser-compat/mechanics.cjs --root "$HOME/zacro-google-prototype" --engine zacro-native
node experiments/google-browser-compat/build/native-build.cjs package --root "$HOME/zacro-google-prototype" --platform darwin-arm64
```

On an Intel Mac select `darwin-x64`. Mac configurations produce a noncomponent `Zacro Prototype.app` containing its framework. Native `ditto` packaging preserves links and permissions, which are included in runtime integrity checks. Development artifacts are not notarized distribution releases. No quarantine or signing bypass is provided.

## Check Google manually

For a package produced by CI, use [native artifact import and manual launch](../docs/NATIVE-ARTIFACT.md). That route verifies the archive, package receipt and full build receipt without requiring a local source checkout or toolchain. The commands below launch from a completed local source build.

Close local fixtures first. This launcher opens a separate manual profile without debugging or automation flags:

```powershell
node experiments/google-browser-compat/build/native-build.cjs launch --root C:\zacro-google-prototype --platform win32-x64 --role regular-a --url https://accounts.google.com
```

Use the Mac root/platform on Mac. `regular-b` and `private` use separate owned directories. Profiles are also separated by the full runtime hash, including DLLs/resources. Upstream startup flags skip first-run onboarding; native browser security and authentication prompts are retained.

The human enters the identifier. A visible password field passes only `google-password-step`; actual login, Gmail, Drive, persistence, sign-out, isolation, private cleanup and authenticators are separate checks. Record no identifiers or credentials.

After that specific human observation:

```powershell
node experiments/google-browser-compat/build/native-acceptance.cjs --root C:\zacro-google-prototype --platform win32-x64 --check google-password-step --result passed --reason completed --human-observed
```

The recorder requires a matching compiled receipt and binds results to the executable and full runtime hashes. It cannot populate another platform's results. `--init` without `--platform` creates only an untested template.

## Outputs and CI

Source/dependencies stay in `ROOT/native-source/156.0.8078.48/<platform>/`; build receipts go to `ROOT/native-builds/156.0.8078.48/<platform>/`; archives go to `ROOT/native-output/`. Local mechanics reports are in `ROOT/results/`; manual evidence is in `ROOT/acceptance/`.

The [Zacro native browser source workflow](../../../.github/workflows/zacro-native.yml) has two different jobs:

- **Hosted source/tooling verification:** Windows x64 (`windows-latest`), Mac arm64 (`macos-15`) and Mac x64 (`macos-15-intel`) run native Node 24, Git, PowerShell and OS archive tools. The job installs no npm dependencies or compiler, downloads only the nine pinned original source files, tests rejection of edited files, and applies the actual patch to an external sparse copy. Its preflight JSON may correctly report missing build tools, SDK differences or insufficient memory/disk. A successful verification job does not mean Chromium was compiled or a browser ran. The patch result is copied to a nonhidden JSON artifact path so the upload action retains it.
- **Explicit native compilation:** dispatch with `compile=true`, the target platform and an absolute root without spaces. An empty root fails validation. This job requires an already provisioned self-hosted worker with `self-hosted`, `zacro-chromium`, the exact platform (`win32-x64`, `darwin-arm64` or `darwin-x64`), matching OS (`Windows` or `macOS`) and architecture (`X64` or `ARM64`) labels. Node architecture and toolchain preflight are checked before source preparation. Windows also needs Git Bash for the workflow shell. The worker needs a logged-in desktop session for headful local browser fixtures; a background service without an interactive desktop is not an equivalent fixture environment.

GitHub's published 14 GB storage figure is not a ceiling on observed free space. The [completed source run's preflights](../evidence/native-source-ci-b47b74e.json) measured **146.98 GiB free and 15.99 GiB RAM** on its Windows volume, with VS 18.11 present and SDK 28000 missing. Mac arm64 measured **42.46 GiB free and 7 GiB RAM**, below this project's disk and RAM guards; Mac Intel measured **107.29 GiB free and 14 GiB RAM**, passing minimum guards with warnings about limited headroom. Both Macs used Xcode 16.4 and SDK 15.5, which meets the pinned minimum but differs from upstream's official SDK 26.5. These source-check measurements do not describe every hosted volume or the separately provisioned Windows build. Measure each actual runner before a large checkout. Preflight is recorded before network-dependent reference fetching. Runner labels and tools are documented in [GitHub's runner catalog](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [Mac arm64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

Reference fetching uses the manifest's pinned GitHub raw URL with bounded, `Retry-After`-aware retries. If that origin continues to return a transient HTTP failure, it tries canonical Chromium Gitiles at the identical commit and file path, decodes its `format=TEXT` response and requires the same SHA-256. HTTP errors and exhausted retries fail the job; a hash mismatch never triggers a fallback. The three verification lanes run sequentially to avoid simultaneous bursts against those upstream origins.

The self-hosted job has a 23-hour timeout, leaving room before the workflow token's 24-hour lifetime; hosted jobs instead have a six-hour execution limit. Both are subject to [GitHub execution limits](https://docs.github.com/en/actions/reference/limits). Preparation, synchronization, compilation, local fixture failure and package failure keep the job failed. Packaging runs only after those earlier steps succeed. Artifacts use the exact package path returned by that run, with run-specific evidence, so an old archive in a persistent build root cannot be presented as a fresh success. This workflow does not install a compiler, approve elevation, automate Google accounts, upload profiles, sign a release or notarize it.

The completed [source run at `b47b74e`](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40742047074) passed all three platforms: Windows **121 tests / 116 passed / five platform skips**; each Mac **121 tests / 114 passed / seven Windows-only skips**, with zero failures. All three passed nine-file forward application, reverse checks and output hashes. The [saved observation](../evidence/native-source-ci-b47b74e.json) records the exact revision, job URLs and resources. This run also validates the bounded retry/fallback path's integration; it does not turn prior failed runs into passes. Its compile job was skipped, and no browser was built or launched by these source checks.

The full interface migration starts after an actual branded binary passes platform-specific acceptance. Release hardening, signing, notarization, installers, updates and complete feature migration remain later work.

### Bounded hosted Windows build

The separate [Windows prototype build workflow](../../../.github/workflows/zacro-native-windows-build.yml) attempts actual compilation on `windows-latest`. It first measures available storage and memory, verifies an existing VS 18+ C++/ATL/MFC installation, and installs only the pinned SDK with the runner's existing administrator token. It does not change local Windows installations or request paid runner capacity.

The job has a 350-minute limit, uses four local compiler jobs, preserves the 15 GiB disk reserve, and leaves time for local fixtures, packaging and uploads. It runs when its own workflow file changes on this branch or through an explicit dispatch. A timeout or build error stays a failure; only successful compilation, runtime checks and packaging produce a browser artifact. Hosted Apple silicon remains below the source-build resource guards, so the available native Mac still needs a connection for compilation.
