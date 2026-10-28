# Staged migration without moving real browser profiles

This plan preserves the existing Electron engine while evaluating the [selected full-browser architecture](ARCHITECTURE.md). It does not authorize an in-place profile conversion, cookie transfer, installed-application replacement or wholesale UI rewrite.

## Reuse map

The current code is the implementation reference. Older design contracts describe intent and may lag the running application; do not use them to erase implemented behavior.

| Existing area                                         | Reuse or adaptation                                                                                                          | Browser-owned replacement                                                                    |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `src/renderer/theme.js`, CSS, icons and layout tokens | Reuse colors, interpolation, visual assets and design intent after separating DOM/native geometry assumptions                | Views/WebUI presentation with real native page geometry                                      |
| `src/core/archive.cjs`                                | Port/test the pure inactivity, profile inheritance and pin/Favorite exclusion policy                                         | Native tab lifecycle and safe-close checks remain authoritative                              |
| `src/core/site-search.js`                             | Reuse validated keyword/template behavior and tests in a browser-compatible module                                           | Native navigation/search destination opening                                                 |
| `src/core/shortcuts.cjs`                              | Reuse action identifiers, defaults, conflict rules and exported schema                                                       | Native accelerator/IME/menu routing per platform                                             |
| `src/core/store.cjs`                                  | Preserve schema meanings, limits and validation requirements; separate pure model changes from Node `fs`/events/crypto usage | Browser preferences/session storage plus a versioned workspace model                         |
| `src/core/import.cjs`                                 | Reuse validated bookmark/metadata concepts after a security review                                                           | Explicit future opt-in import into new profiles; no secret/session transfer                  |
| `src/renderer/app.js`                                 | Reuse independent command ranking and UI concepts selectively                                                                | Replace direct Electron IPC and assumptions about page-view composition                      |
| `src/main/main.cjs`, guest preload                    | Treat current behavior/tests as requirements, not code to transplant wholesale                                               | Native tab/navigation/profile/permission/authentication services and typed adapters          |
| AI provider services                                  | Preserve explicit sharing, context review, cancellation and credential boundaries only after browser integration is stable   | A separately reviewed local service interface; never an unrestricted browser/renderer bridge |
| Native regression fixtures                            | Reuse scenarios and expected outcomes                                                                                        | New engine adapters and process launchers; new platform evidence                             |

Tests should preserve behavior rather than require identical internal data structures. For example, a saved pin's original URL/title is workspace metadata, while its live native tab and navigation history belong to the browser.

## Stage 0 — establish the experiment boundary

- Keep browser executables, source checkouts, outputs and test profiles outside the application repository.
- Give every reference/candidate/configuration its own experiment-owned data root. Do not open real user profiles with another engine or version.
- Pin upstream versions, source commits, platform artifacts and tooling. Record the Chromium 159 versus 156 comparison confound.
- Separate automated loopback mechanics from human-operated account acceptance. Keep credentials and authentication traffic out of logs and exports.
- Leave the existing Zacro application and its user data intact.

Exit evidence: verified artifact manifests, native launch on each tested OS, local mechanics results and an explicit manual matrix. A downloaded Mac artifact is not a Mac launch result.

## Stage 1 — evaluate the full browser before changing its chrome

Run the intact Chromium candidate with its native address/connection UI, normal tabs, regular profiles, private windows, popups, permissions and authentication interfaces. Establish an official Brave baseline separately. Test direct Google account sign-in, Gmail/Drive, restart, sign-out, two-profile isolation, private cleanup and applicable authenticators on each required OS.

The workspace component is a separate configuration. Its early role is to exercise tab/workspace integration beside the native browser. Passing its local tests does not satisfy native Zacro UI, source-build, passkey or account-acceptance gates.

Exit evidence: platform-specific manual results and a comparison that identifies version/configuration differences. If the official reference fails, preserve the result and investigate environment/account factors before attributing failure to Zacro. If the reference passes but the candidate fails, retain both results and diagnose without spoofing, weakening security or moving cookies.

## Stage 2 — compile the smallest branded source candidate

After native toolchain/resource preflight passes, build the pinned full Chromium browser on Windows x64 and macOS arm64. Preserve browser subsystems and native chrome. Introduce only independent product/data identifiers and a clear experimental identity through upstream product/UA/client-hint generation. Do not relabel an upstream binary or replace its user agent with Chrome's.

Re-run local mechanics and manual acceptance for these actual binaries. Upstream snapshot results do not transfer automatically after branding, build flags, signing or product patches change. Add the existing product's Intel Mac source-build/acceptance lane before claiming a replacement for all supported architectures.

Exit evidence: reproducible native build logs and artifacts, exact patch set, actual browser identity and independent acceptance for each claimed platform. No UI migration should outrun this gate.

## Stage 3 — port workspace semantics behind explicit adapters

Preserve the following before replacing a daily-use engine:

| Feature                    | Required behavior                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Spaces                     | Ordering, active Space, icons/themes and scoped tabs; switching never shares another profile's session           |
| Favorites                  | One saved destination/live-document relationship shared only within a regular profile                            |
| Space pins                 | Saved address/title, navigated marker, reset/replace semantics and close-without-deleting behavior               |
| Today/archive              | Profile-specific inactivity rules, recovery and protection for active/media/download/authentication/edited pages |
| Peek                       | Native document/opener retention through promotion and dismissal; beforeunload and popup POST/callback behavior  |
| Split view                 | Same-profile ownership, native page identity, input focus and protected active-page lifecycle                    |
| Session recovery           | Validated metadata, atomic persistence, recoverable interruption and explicit private-session exclusions         |
| Downloads                  | Native download lifecycle, destination consent, interruption/restart behavior and OS file reveal                 |
| Permissions/authentication | Origin-scoped native decisions, authenticators and trust UI retained through custom chrome changes               |
| Keyboard/accessibility     | Native menus, editable shortcuts, IME, focus restoration, screen-reader semantics and reduced-motion support     |

Introduce one surface at a time. Native address/security/authentication controls remain visible while a new sidebar or command workflow is evaluated. Avoid copying browser-owned credentials, histories or cookie databases into the workspace layer to simulate integration.

## Stage 4 — future opt-in metadata migration

Design a versioned, validated export/import format for Spaces, themes, saved URLs, pin/Favorite metadata, bookmarks and supported preferences. Preview conflicts and unsupported fields, and leave the old data untouched. URL metadata can contain sensitive information; require explicit review and avoid diagnostic dumps.

Map regular profiles to newly created native profiles. Do not transplant cookies, local storage, passwords, authentication tokens, private-session state or Chromium database files. The human signs in again in each new profile. Do not run old and new engines against the same directory. Stage 4 is a plan, not an implemented migration in this experiment.

## Stage 5 — distribution and recovery

Complete [platform distribution and update gates](DISTRIBUTION.md), clean-machine acceptance, native accessibility/input checks and repeated human provider checks before selecting a replacement release. A previous executable can be retained for application rollback, but profile-format compatibility must be evaluated independently; never blindly open a newer profile with an older engine.

Keep an explicit decision record for any remaining gap. The existing Electron application remains the supported fallback until the replacement's required platform and feature gates are met. A supported external-browser action is useful but does not complete direct Google website sessions inside Zacro.
