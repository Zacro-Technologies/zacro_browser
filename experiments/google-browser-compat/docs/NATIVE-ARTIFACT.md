# Import and manually launch a CI-built prototype

This path verifies an existing native browser package. It does not download a browser, compile Chromium locally, install an application, or establish Google acceptance. Node 24 and the matching native OS/architecture are required; a source checkout, Visual Studio and Xcode are not required.

From one trusted GitHub Actions run, obtain these three files:

- The `Zacro-Prototype-….zip` archive from that run's prototype artifact.
- Its adjacent `….zip.json` package receipt.
- The full `build.json` from the same run's evidence artifact. The smaller `NATIVE-BUILD.json` inside a Windows ZIP is not a substitute.

The current receipts are unsigned and do not authenticate their CI origin. Select the trusted run and its files yourself. The supplied run URL is recorded as operator-provided provenance. Hash checks establish that the files agree with one another and the reviewed source/branding pins; they cannot turn arbitrary supplied receipts into trusted CI evidence.

From the repository, use explicit local paths. This Windows example does not open the browser:

```powershell
node experiments/google-browser-compat/build/native-artifact.cjs import --root C:\zacro-google-prototype --archive C:\Downloads\Zacro-Prototype.zip --package-receipt C:\Downloads\Zacro-Prototype.zip.json --build-receipt C:\Downloads\build.json --ci-run https://github.com/Zacro-Technologies/zacro_browser/actions/runs/123456/attempts/1
```

Replace the example paths and run URL with the actual files and run. Import verifies the package SHA-256, source and branding revisions, configuration binding, executable hash, and complete runtime inventory. Mac archives are extracted with native `ditto`, preserving the bundle's modes and contained symlinks. Windows archives use native `Expand-Archive`. Existing incomplete or modified imports are retained and rejected; use a fresh owned experiment root to recover.

The result includes a 64-character `artifactId`. Use it to verify or manually launch the imported runtime:

```powershell
node experiments/google-browser-compat/build/native-artifact.cjs verify --root C:\zacro-google-prototype --artifact ARTIFACT_SHA256
node experiments/google-browser-compat/build/native-artifact.cjs launch --root C:\zacro-google-prototype --artifact ARTIFACT_SHA256 --role regular-a --url about:blank
```

On Mac, use absolute Mac paths and the same commands. Choose `regular-a`, `regular-b`, or `private`; each role uses a separate profile under `profiles/zacro-native-import/<platform>/<runtime hash>/`. Existing browser profiles are never adopted. The launcher has no debugging, user-agent override, sandbox bypass, extension injection, or arbitrary flag option. Navigate to Google yourself and handle all account actions manually.

`IMPORT.json` records the archive, runtime, executable, package receipt and full build receipt hashes, the operator-supplied CI run URL, and `locallyCompiled: false`. Manual launch receipts under `launches/native-import-*.json` bind the artifact and runtime hashes to the profile role and record `automationAttached: false`.

The manual acceptance recorder supports imported artifacts. Initialize an untested report with the exact `artifactId` and native platform:

```powershell
node experiments/google-browser-compat/build/native-acceptance.cjs --root C:\zacro-google-prototype --init --platform win32-x64 --artifact ARTIFACT_SHA256
```

After a human has actually performed a check, record only that observed result. For example, use the following command only if entering the account identifier manually reached a password field:

```powershell
node experiments/google-browser-compat/build/native-acceptance.cjs --root C:\zacro-google-prototype --platform win32-x64 --artifact ARTIFACT_SHA256 --check google-password-step --result passed --reason completed --human-observed
```

Use `darwin-arm64` or `darwin-x64` with absolute Mac paths on the matching Mac. Run the recorder with `--help` to see the other checks and result codes. The password step does not establish authenticated sign-in, Gmail, Drive, or persistence; each remains untested until separately checked by a human.

Every invocation re-verifies the imported receipts and complete runtime. Reports under `acceptance/native-import-*.json` bind the archive, runtime and executable hashes to one platform and retain `locallyCompiled: false`. They do not copy account details, paths or the CI URL. Local source-build reports and unbuilt templates remain separate; another archive or runtime starts with an untested report. No local build receipt is created, and neither importing nor passing a human check authenticates the unsigned receipts' claimed CI origin.
