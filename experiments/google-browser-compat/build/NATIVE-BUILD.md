# Build the minimal native Zacro browser

This pipeline builds Chromium's full `//chrome` browser with the reviewed **Zacro Prototype** identity patch. Native tabs, address/security controls, profiles, permissions and authentication services remain in place. The Electron application is unchanged.

The source pin is **156.0.8078.48 / `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`**, matching the engine in the Brave reference. It is separate from the earlier Chromium 159 snapshot experiment. See [the native pin](native-build.lock.json) and [branding patch](../native-branding/README.md).

## Current evidence

- The pinned Chromium source and depot tools were checked out on Windows outside the application repository. This is the actual source repository, but its DEPS synchronization has not run.
- All nine branding changes were applied to that checkout and verified against reviewed hashes; see the [source and toolchain receipt](../evidence/windows-native-source.json).
- Managed Python and VPython bootstrap completed without changing global Git settings.
- The Windows Brave reference passed [nine local mechanics checks](../evidence/mechanics-brave-win32-x64-reference.json). The user separately reported a visible Google password field there; that passes only the reference's [preliminary password-step check](../evidence/manual-reference-results.json).
- The Chromium 159 snapshot [failed local startup](../evidence/mechanics-chromium-win32-x64-engine-only.json) before requesting the fixture document. That is not a Google rejection: its Google checks remain untested.
- **The branded browser is not yet compiled or launched.** Windows compilation awaits administrator approval for its toolchain. Mac compilation awaits access to the available Apple silicon machine. Branded Google checks remain untested.

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

Standard hosted runners have approximately 14 GB of writable storage, enough for the small verification job but below the source-build guard. Their runner labels, available PowerShell and architecture are documented in [GitHub's runner catalog](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [Mac arm64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md). Do not move full compilation onto those runners merely because the source checks pass.

The self-hosted job has a 23-hour timeout, leaving room before the workflow token's 24-hour lifetime; it remains subject to [GitHub execution limits](https://docs.github.com/en/actions/reference/limits). Preparation, synchronization, compilation, local fixture failure and package failure keep the job failed. Packaging runs only after those earlier steps succeed. Artifacts use the exact package path returned by that run, with run-specific evidence, so an old archive in a persistent build root cannot be presented as a fresh success. CI does not install a compiler, approve elevation, automate Google accounts, upload profiles, sign a release or notarize it. Neither workflow has been validated by an actual remote run merely because its files exist.

The full interface migration starts after an actual branded binary passes platform-specific acceptance. Release hardening, signing, notarization, installers, updates and complete feature migration remain later work.
