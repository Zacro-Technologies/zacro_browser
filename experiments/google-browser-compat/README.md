# Direct Google website sign-in experiment

This is an isolated engine-compatibility experiment for **Windows x64 and macOS Apple silicon**. Its question is whether a normal, manually operated full browser can provide reliable Google website sessions while Zacro's workspace logic is developed beside it.

It does not replace the Electron application, install over another browser, or migrate an existing profile. **No Google sign-in result is established by downloading a browser or passing local fixtures.** See the separate [manual acceptance procedure](docs/MANUAL-ACCEPTANCE.md).

The [native Zacro source-build pipeline](build/NATIVE-BUILD.md) uses a separate Chromium **156.0.8078.48** pin for Windows x64, Mac arm64 and Mac x64. [Source/tooling CI passed on all three platforms](evidence/native-source-ci-b47b74e.json), including the nine-file branding patch. The separate [hosted Windows build failed](evidence/windows-hosted-build-failure.json) in its build step with exit code 1 after SDK setup, source/dependency preparation and branding/GN configuration succeeded. The step ended before its timeout; the underlying failure is unknown without the final diagnostic log. Browser tests and packaging were skipped, so this run produced no verified browser package or Google acceptance result. The [earlier milestones](evidence/windows-hosted-build-milestones.json) remain a dated progress snapshot, and the [local checkout receipt](evidence/windows-native-source.json) describes a different machine. The pipeline does not relabel the upstream binaries below.

## Upstream experiment deliverables

| Item                               | Purpose                                                                                                                                  | What it establishes                                                                                      |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Intact official Chromium snapshot  | Full-browser archive intended to retain native address, security, profile and authentication interfaces; Windows startup currently fails | A pinned artifact and a recorded execution failure; not a source-built Zacro fork                        |
| Optional Zacro workspace component | A small Manifest V3 integration spike using browser-owned tabs and storage                                                               | A bounded application-integration experiment; not the complete Zacro interface or an independent browser |
| Intact official Brave release      | A separate maintained-browser reference                                                                                                  | A baseline to test manually; its result does not certify Chromium or a future Zacro fork                 |

The Chromium snapshot is **159.0.8130.0**, position **1729109**, source `0c75ec0efee23f664c9a3380217ae4650bed97e6`. The Brave reference is **1.98.60 / Chromium 156.0.8078.48**. This version difference is a confound: differences in observed behavior cannot be attributed solely to browser architecture or Zacro's component. Exact upstream identities and archive verification metadata belong in `engines.lock.json`.

All direct Google, Gmail, Drive, account persistence, sign-out, isolation and passkey checks begin **untested** on each platform and configuration. Successful local navigation or cookie fixtures do not change those entries. Downloading a Mac archive on Windows is not a Mac execution result.

The user reported a visible Google password field in the **Windows Brave reference**, passing only that preliminary check; see the [manual reference matrix](evidence/manual-reference-results.json). Brave also passes [nine local mechanics checks](evidence/mechanics-brave-win32-x64-reference.json). Full login and the source-built Zacro candidate have separate untested checks.

**The Chromium 159 Windows snapshot fails startup before requesting the fixture document.** Its [failure report](evidence/mechanics-chromium-win32-x64-engine-only.json) records `fixture-document-did-not-start`, with both document request and script readiness false. This is a browser startup failure, not Google's unsupported-browser rejection. Do not count it as either a Google pass or a Google rejection. Mac execution has not been established by this Windows observation.

## Run the bounded experiment

Use Node.js 24 or later. Keep the experiment root outside this repository and use an absolute path without spaces. The examples use the CLI's default roots explicitly. The CLI does not perform a Chromium source checkout automatically.

These commands are for a repository checkout. If you downloaded a kit ZIP, follow [the standalone bootstrap](docs/MANUAL-ACCEPTANCE.md#start-from-a-downloaded-kit): extract it, enter the included `zacro-google-browser-compat` directory and use `node cli.cjs` / `node record.cjs`. Each kit contains one unchanged upstream browser ZIP plus the experiment tools; it is not a newly compiled Zacro application. The manual tools require only Node.js, without `npm ci`.

On Windows x64, from the repository root:

```powershell
node experiments/google-browser-compat/cli.cjs preflight --root C:\zacro-google-prototype
node experiments/google-browser-compat/cli.cjs fetch --engine brave --platform win32-x64 --root C:\zacro-google-prototype
node experiments/google-browser-compat/cli.cjs assemble --engine brave --platform win32-x64 --root C:\zacro-google-prototype
node experiments/google-browser-compat/cli.cjs launch --engine brave --platform win32-x64 --root C:\zacro-google-prototype --role regular-a
```

On an Apple silicon Mac, from the repository root:

```sh
node experiments/google-browser-compat/cli.cjs preflight --root "$HOME/zacro-google-prototype"
node experiments/google-browser-compat/cli.cjs fetch --engine brave --platform darwin-arm64 --root "$HOME/zacro-google-prototype"
node experiments/google-browser-compat/cli.cjs assemble --engine brave --platform darwin-arm64 --root "$HOME/zacro-google-prototype"
node experiments/google-browser-compat/cli.cjs launch --engine brave --platform darwin-arm64 --root "$HOME/zacro-google-prototype" --role regular-a
```

These examples start the maintained reference. Use the same commands with `--engine chromium` to reproduce or investigate the snapshot, retaining its known Windows startup failure in the results. Use `--role regular-b` for the second isolated regular profile and `--role private` for the private-session check. The CLI uses experiment-owned directories beneath the selected root; it must not point at an existing Zacro, Chrome, Chromium, Edge or Brave profile.

Profile directories are separated by engine, platform, configuration and role: `profiles/<engine>/<platform>/<engine-only|workspace|reference>/<role>`. Thus a bare Chromium baseline cannot inherit a workspace configuration's extension registration or preferences. The markers bind directories to their experiment purpose; they are not a migration path for real profiles.

Evaluate Chromium first without the workspace component and require its native address bar and page rendering to work before attempting account checks. Add `--workspace` to the Chromium launch command for the separate component configuration. The launcher loads the included extension; open **Zacro Workspace Lab** from the native Extensions menu/action to display its side panel. Browser identity and native security UI remain the upstream browser's. Do not describe this assembly as a newly compiled Zacro browser.

Workspace Lab operates on the current regular window's native tabs and groups: find or activate a tab, open a complete HTTP/HTTPS address, toggle native pinning, and create, edit, collapse or change native groups. It persists only its appearance preference; titles/addresses are read for the current view, and browser session data remains browser-owned. These native groups and pins are not yet Zacro's full Spaces, profile-wide Favorites or saved Space-pin model. Private windows use the native browser without the component, which is disabled for incognito.

Run local mechanics checks in their separate fixture profiles and record their results. Close every automated fixture browser and debugging connection before launching a fresh manual session through the ordinary CLI. **The human navigates to Google, enters credentials and completes MFA.** Do not attach Playwright, WebDriver, CDP, a browser-control agent or an authentication recorder during that session. Do not capture passwords, account identifiers, tokens, cookies or authentication request bodies in reports.

For automated browser mechanics from a repository checkout, install the existing dependencies with `npm ci --ignore-scripts`, then run:

```sh
node --test experiments/google-browser-compat/tests/*.test.cjs
node experiments/google-browser-compat/mechanics.cjs --root ROOT --engine chromium
node experiments/google-browser-compat/mechanics.cjs --root ROOT --engine chromium --workspace
node experiments/google-browser-compat/mechanics.cjs --root ROOT --engine brave
```

Replace `ROOT` with the same absolute experiment root used for fetching artifacts. In an extracted kit, install optional test dependencies with `npm ci --ignore-scripts`, run its experiment tests with `npm test`, and use `node mechanics.cjs` for that kit's engine. The kit includes the experiment tests, not the existing Electron application's complete suite. Mechanics results belong to `ROOT/results/`; failures or incomplete runs remain failures or incomplete runs, and never populate the human Google acceptance matrix. The prebuilt-kit workflow tests the bare Chromium, workspace and Brave configurations independently. It preserves a failed job even when diagnostic kits can still be assembled. The separate [native source workflow](../../.github/workflows/zacro-native.yml) runs small source/tooling checks on hosted runners and supports explicit compilation on a provisioned worker. A [bounded Windows workflow](../../.github/workflows/zacro-native-windows-build.yml) also attempts compilation after measuring and provisioning its hosted runner.

## Source-build path and current boundary

For the branded Chromium 156 build, use [NATIVE-BUILD.md](build/NATIVE-BUILD.md). When a CI build produces a package, follow [the native artifact import procedure](docs/NATIVE-ARTIFACT.md) to verify and manually launch it without a local Chromium checkout or compiler. The older `source-plan` command below describes the unmodified Chromium 159 snapshot's source and does not apply Zacro branding.

Print the native source-build plan with:

```powershell
node experiments/google-browser-compat/cli.cjs source-plan --platform win32-x64 --root C:\zacro-google-prototype
```

```sh
node experiments/google-browser-compat/cli.cjs source-plan --platform darwin-arm64 --root "$HOME/zacro-google-prototype"
```

The recommendation is a thin **full Chromium browser-layer fork**, retaining native browser services and initially the standard native chrome. A later Zacro interface should use native Views/WebUI and typed Mojo interfaces. A source plan, configuration or downloaded upstream artifact is not evidence that this fork has been compiled. Source builds and live account tests have their own gates.

The [initial local Windows preflight](evidence/windows-native-source.json) recorded 31.93 GiB RAM and 152.6 GiB free with missing tools; it is historical local evidence, not the hosted build's status. The [completed hosted source checks](evidence/native-source-ci-b47b74e.json) record each runner's actual resources: Mac arm64 had 42.46 GiB free and 7 GiB RAM, below this project's guards; Mac Intel had 107.29 GiB free and 14 GiB RAM, passing the minimum guards with limited headroom. A successful preflight or source-only check is not proof that a full build will fit or complete.

Existing Zacro also supports **Intel macOS**. The two-platform snapshot assembly does not silently remove that obligation: a separate native Intel build and acceptance gate remains in the migration plan. There is no Mac Intel artifact in this experiment's snapshot matrix.

## Decisions and evidence

- [Architecture comparison and decision](docs/ARCHITECTURE.md)
- [Primary sources, dates and pinned revisions](docs/SOURCES.md)
- [Staged migration and reusable application modules](docs/MIGRATION.md)
- [Platform distribution, storage, updates and rollback](docs/DISTRIBUTION.md)
- [Manual acceptance and platform-specific results](docs/MANUAL-ACCEPTANCE.md)
- [Verify and launch a native CI artifact](docs/NATIVE-ARTIFACT.md)
- [Saved execution evidence and limits](evidence/README.md)

Google website sessions, third-party OAuth callbacks, FedCM, Chrome Sync and Google API keys are separate concerns. External-browser fallback remains available in the existing application, but it does not authenticate Google websites inside Zacro. This experiment claims neither Google certification nor production readiness.
