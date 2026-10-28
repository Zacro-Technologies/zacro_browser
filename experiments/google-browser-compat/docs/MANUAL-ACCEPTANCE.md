# Human-operated Google website acceptance

These checks establish observations for one operating system, binary revision and configuration. They are not Google certification. Local automated fixtures, an OAuth callback, FedCM or Chrome Sync cannot fill these rows.

## Three separate configurations

1. **`brave-reference`**: intact Brave 1.98.60, a maintained full-browser reference. Its engine is Chromium 156.0.8078.48.
2. **`chromium-engine`**: intact upstream Chromium snapshot 1729109, version 159.0.8130.0, without the workspace component.
3. **`chromium-workspace`**: the same Chromium snapshot with the bounded Zacro workspace extension. Native address, connection-security, tab, permission and authentication interfaces remain in control.

The Chromium and Brave versions differ. A different result cannot be attributed solely to the embedder, identity, extension, signing or engine version. The workspace is an integration spike, not a source-built or rebranded Zacro browser. Existing Electron Zacro remains separate.

The separate [source-built Zacro procedure](../build/NATIVE-BUILD.md) uses Chromium 156 and its own compiled-receipt-bound acceptance recorder. No branded binary has been compiled or tested yet.

**Known execution blocker:** the [Windows Chromium 159 report](../evidence/mechanics-chromium-win32-x64-engine-only.json) fails at `native-fixture-document-ready`, before the fixture page is requested. This is a startup failure, not evidence that Google rejected that browser. Leave its Google rows untested until a usable native window and page navigation are available. The [Windows Brave matrix](../evidence/manual-reference-results.json) records only the human-observed password-entry step as passed; full login and Mac checks remain separate.

Run each configuration in its own owned test directories. The launcher separates configuration, platform and regular/private roles. Do not point it at an existing Chrome, Brave, Chromium or Zacro profile. Do not import browsing data, credentials or cookies. Installed applications and default-browser settings should stay as they are.

## Before credentials

- Use the native operating system: Windows x64 for `win32-x64`, Apple silicon macOS for `darwin-arm64`. Existing Mac Intel support is a separate gated lane; this snapshot kit does not supply its binary.
- Read the kit's `bundle.json` and `engines.lock.json`, or the repository fetch receipt, then confirm the pinned version in the browser's **About** page after launch. Keep the native address bar visible. Navigate with that bar, not a browser-automation connection. A launch receipt records a spawned process, not a completed browser or Google check.
- Use a dedicated account you are comfortable testing. The human enters passwords, completes MFA, chooses accounts and handles authenticators. Never send these values to an agent or put them in the matrix.
- Close automated fixture browsers. The manual launcher does not expose CDP, WebDriver, remote debugging, page scripts, request interception or UA overrides. Do not attach Playwright, DevTools automation or another debugging client during these checks.
- The workspace reads tab metadata through the normal extension API. It has no content scripts, host permissions, cookie access, page-scripting or debugger permission. A browser extension can still affect provider acceptance; test the engine-only configuration independently.
- Do not disable browser security, certificate checks, Gatekeeper or antivirus. Do not remove quarantine or re-sign the upstream application to make a check pass. If the OS blocks a candidate, record that execution blocker; a signed reference remains a different configuration.
- Do not enable Chrome Sync or register OAuth/API credentials for this test. Native browser-account and Sync prompts are separate from website sign-in. Skip import/default-browser offers.

## Start from a downloaded kit

Install **Node.js 24 or later for your native architecture**. Manual launch and result recording use built-in Node modules and do not require `npm ci`, Playwright, a source checkout or a compiler. A kit is an unchanged upstream browser archive accompanied by experiment source and instructions; it is not a source-built Zacro fork.

Extract the outer kit ZIP to a new directory outside the repository and outside your experiment data root. Each kit has one top-level directory named **`zacro-google-browser-compat`** containing `cli.cjs`, `record.cjs`, `bundle.json`, `engines.lock.json`, `docs/`, and `payload/`. Keep that directory intact. Do not extract the kit directly into `ROOT`: a nonempty directory without an experiment owner marker is deliberately rejected.

The following examples start with the maintained Brave reference and assume its kit is in your Downloads directory; adjust only the archive's location if needed. On Windows x64, use PowerShell:

```powershell
Expand-Archive -LiteralPath "$env:USERPROFILE\Downloads\zacro-google-browser-compat-brave-1.98.60-win32-x64.zip" -DestinationPath C:\zacro-google-kits\brave
Set-Location C:\zacro-google-kits\brave\zacro-google-browser-compat
node cli.cjs preflight --platform win32-x64 --root C:\zacro-google-prototype
node cli.cjs fetch --engine brave --platform win32-x64 --root C:\zacro-google-prototype
node record.cjs --root C:\zacro-google-prototype --init
node cli.cjs launch --engine brave --platform win32-x64 --role regular-a --root C:\zacro-google-prototype
```

On an Apple silicon Mac, use Terminal:

```sh
mkdir -p "$HOME/zacro-google-kits/brave"
ditto -x -k "$HOME/Downloads/zacro-google-browser-compat-brave-1.98.60-darwin-arm64.zip" "$HOME/zacro-google-kits/brave"
cd "$HOME/zacro-google-kits/brave/zacro-google-browser-compat"
node cli.cjs preflight --platform darwin-arm64 --root "$HOME/zacro-google-prototype"
node cli.cjs fetch --engine brave --platform darwin-arm64 --root "$HOME/zacro-google-prototype"
node record.cjs --root "$HOME/zacro-google-prototype" --init
node cli.cjs launch --engine brave --platform darwin-arm64 --role regular-a --root "$HOME/zacro-google-prototype"
```

`preflight` reports source-compilation requirements as well as native execution availability. Missing Visual Studio, Xcode or source-build disk capacity does not by itself block an upstream binary kit. A source-ready value or a spawned process is not a passed browser check. `fetch` verifies and copies the included matching payload into the owned cache; `launch` extracts it using the native OS tool, verifies the runtime and creates a separate manual test profile.

For the Chromium snapshot, extract `zacro-google-browser-compat-chromium-159.0.8130.0-PLATFORM.zip` into a separate kit directory and use `--engine chromium`, retaining its known Windows startup blocker. Each kit carries only its named engine/platform payload. Requesting another engine or platform can download its pinned archive; it does not create native execution on the wrong OS. The separate kits may use the same experiment data root because the launcher isolates engine, platform, configuration and role. Keep extracted kit files in place while using its workspace configuration.

The optional automated fixture harness has a separate dependency setup: inside the extracted kit run `npm ci --ignore-scripts`, run the included experiment tests with `npm test`, then use `node mechanics.cjs --root ROOT --engine chromium --workspace` or `--engine brave` as appropriate. It uses dedicated loopback fixture profiles and must be completely closed before manual account testing. No npm setup or fixture automation belongs in the live account session. The kit includes the experiment's tests; the existing Electron application's full suite remains in the repository.

## Launch from the repository

The kit requires Node.js 24 or later. In these examples, `ROOT` means an absolute directory outside the application repository, such as `C:\zacro-google-prototype` or `/Users/yourname/zacro-google-prototype`. Replace `PLATFORM` with the native platform value.

```sh
node experiments/google-browser-compat/cli.cjs preflight --root ROOT
node experiments/google-browser-compat/cli.cjs fetch --engine brave --platform PLATFORM --root ROOT
node experiments/google-browser-compat/cli.cjs fetch --engine chromium --platform PLATFORM --root ROOT

# Maintained reference, separate regular profile A
node experiments/google-browser-compat/cli.cjs launch --engine brave --platform PLATFORM --role regular-a --root ROOT

# Bare Chromium engine, a different profile
node experiments/google-browser-compat/cli.cjs launch --engine chromium --platform PLATFORM --role regular-a --root ROOT

# Workspace configuration, another different profile
node experiments/google-browser-compat/cli.cjs launch --engine chromium --platform PLATFORM --role regular-a --workspace --root ROOT
```

From an extracted kit's `zacro-google-browser-compat` directory, use `node cli.cjs` instead of the repository-prefixed path above. Launch without a URL and manually navigate to `https://accounts.google.com/`, `https://mail.google.com/` and `https://drive.google.com/`. The agent does not drive those pages. Add `--workspace` only for the Chromium workspace configuration; the launcher loads the component, and **Zacro Workspace Lab** in the native Extensions menu/action opens its side panel. The browser continues to display address and security information.

For a second regular profile use `--role regular-b`. For a private session use `--role private`; it launches the native incognito mode in a dedicated test root. Keep the same engine and `--workspace` choice as the configuration being evaluated, including for its private-session row. The component itself is disabled in incognito. Close **all** incognito windows before checking cleanup; windows in one incognito session normally share its temporary state.

Do not run two launcher instances for the same role at once. Close that browser normally before a restart. Test profiles persist for further human inspection; the kit never deletes them on exit. Do not include their directories in artifacts or share them.

## Acceptance matrix

Repeat this table for each configuration on each platform. All entries start **untested**. Unsupported or unavailable authenticator hardware is not a pass.

The preliminary `google-password-step` check succeeds when the human enters an account identifier, chooses **Next**, and sees Google's password-entry field in the same browser. Stop there when only this step is being evaluated; entering a password is unnecessary. This establishes only that the identifier-to-password step was reached. It does not establish authenticated website sign-in, Gmail or Drive access, MFA/passkey completion, or persistence after restart. Keep all those rows untested until separately observed. Do not record the identifier or capture the account screen.

| Check code                  | Human procedure                                                                                                               | Pass observation                                                                                                                 |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `google-password-step`      | Navigate to Google Accounts manually, enter the account identifier yourself and choose Next. Stop before entering a password. | Google's password-entry field appears without the unsupported-browser rejection at this step. This is a preliminary result only. |
| `direct-google-login`       | Enter the direct Google Accounts address in the native omnibox and complete sign-in/MFA yourself.                             | Google finishes website sign-in inside that browser without the unsupported-browser error.                                       |
| `gmail`                     | Open Gmail inside the same browser/profile.                                                                                   | The intended account's mailbox is accessible. No account name or message contents are recorded.                                  |
| `drive`                     | Open Drive inside the same browser/profile.                                                                                   | The intended account's Drive is accessible. No file names or contents are recorded.                                              |
| `restart-persistence`       | Close the browser normally, relaunch the same configuration/regular role and visit Gmail/Drive manually.                      | The website session remains authenticated, subject to normal Google policy.                                                      |
| `regular-profile-isolation` | While profile A is signed in, open role `regular-b` of the same configuration.                                                | B does not inherit A's website account. If testing a second account, it does not alter A.                                        |
| `private-session-cleanup`   | Open role `private`, sign in yourself, close every private window, relaunch that role and visit Google again.                 | The previous private website account is absent. User-saved downloads are outside this cleanup guarantee.                         |
| `sign-out`                  | Sign out through Google's own website UI, revisit Gmail/Drive, then restart normally and revisit again.                       | The signed-out profile does not silently restore the former website session.                                                     |
| `platform-passkey`          | If applicable, manually select the platform authenticator during Google sign-in.                                              | Native platform UI completes the intended flow with human presence. Record unavailable hardware separately.                      |
| `security-key`              | If available, manually complete a supported external security-key flow.                                                       | Native authentication UI completes the flow with the human's key interaction.                                                    |

Use only outcome codes. Do not capture passwords, account identifiers, tokens, cookies, authentication request bodies, recovery codes or screenshots of signed-in pages. The native browser necessarily owns its ordinary session data; diagnostic files must not copy it.

## Record results without sensitive data

The schema and template are under `acceptance/`. Initialize the external record:

```sh
node experiments/google-browser-compat/record.cjs --root ROOT --init
```

Inside an extracted kit's `zacro-google-browser-compat` directory, use `node record.cjs` in the recorder commands. `--init` preserves existing observations in the same experiment root; it does not reset completed rows. The recorder upgrades a validated older 81-row matrix to 90 rows by adding one untested `google-password-step` row for each platform/configuration pair. Existing evidence remains unchanged.

Only after the human has observed the stated result, record one check. For example:

```sh
node experiments/google-browser-compat/record.cjs --root ROOT --platform win32-x64 --configuration chromium-engine --check direct-google-login --result passed --reason completed --human-observed
```

When the human has reported reaching only the password field, record the preliminary check instead:

```sh
node experiments/google-browser-compat/record.cjs --root ROOT --platform win32-x64 --configuration chromium-engine --check google-password-step --result passed --reason completed --human-observed
```

That command changes only the preliminary row for the selected platform/configuration. It never marks `direct-google-login`, `gmail`, `drive` or `restart-persistence` as passed.

The same command accepts `failed` with a reason such as `browser-rejected`, `persistence-failed`, `isolation-failed`, `cleanup-failed`, `flow-unavailable` or `other-failure`. Use `not-applicable` with `hardware-unavailable` for missing authenticator hardware. Use `untested` with `awaiting-human` or `platform-unavailable` when no observation exists. The recorder rejects arbitrary notes/URLs/account fields and never reads browser profiles. It writes only `ROOT/acceptance/manual-results.json` and records exact engine pins plus outcome/timestamp. Keep each platform's evidence separate; a Windows pass does not populate a Mac row.

Third-party Google callbacks and FedCM are follow-up checks outside this direct-website matrix. A later custom Zacro-identity source build needs a new acceptance run even if every upstream-browser check passes.
