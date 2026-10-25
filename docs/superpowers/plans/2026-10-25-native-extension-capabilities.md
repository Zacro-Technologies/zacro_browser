# Native extension capability completion

**Spec:** [Remaining extensions/sync design](../specs/2026-10-25-remaining-extensions-sync-design.md).
**Execution:** `superpowers:subagent-driven-development`, one fresh implementer
and reviewer per bounded task. The primary agent independently handles the
separate sync-control plan. No simultaneous editing of shared extension files.
**Goal:** Implement the user's remaining capabilities on the existing Electron
45 engine, using its actual native behavior where verified.
**Global constraints:** Preserve sandboxing, authenticated contexts, profiles,
private exclusion, permission review, immutable original package provenance and
generation revocation. No fake success or broader permissions as a workaround.
Read official pinned Electron sources where capability documentation differs.
Do not change other agents' files or run foreground native tests concurrently.

## Task 1: Native DevTools extensions

**Files:** `src/main/extensions/catalog.cjs`; `src/main/extensions/adapt.cjs`
only if necessary; new `test/e2e/extension-devtools.test.cjs`; existing catalog
tests when their asserted boundary changes. A focused new documentation file
`docs/EXTENSION-DEVTOOLS.md` records actual supported behavior and evidence.

**Interfaces:** Reviewed `devtools_page` is preserved in the derived manifest
and passed to the existing profile session extension loader. Electron's native
`chrome.devtools` remains native. The existing bridge may bootstrap ordinary
extension pages but must not grant page/main-world scripts extension identity.
Avoid changes to shared `api.cjs`, `host.cjs`, `bootstrap.js` unless a concrete
integration failure requires them; report that need first.

1. Add catalog/runtime tests that fail before enabling the feature: a sandboxed
   managed extension with a devtools page creates a genuine panel for its own
   profile's inspected HTTP page. Evaluate a marker in inspectedWindow and read
   the resulting native panel DOM to establish real integration.
2. Test isolation: a second profile/private session does not load the extension;
   disable/remove tears down its native context and obsolete bridge access.
   Invalid/foreign/path-traversing devtools resources fail installation/load.
3. Run the focused tests; record expected RED failures. Remove the overly broad
   catalog rejection only after resource validation and real runtime behavior
   are established. Preserve unrelated unsupported fields.
4. Run the focused native test plus catalog/manager tests and format/check.
   Expected: all pass without relaxed assertions or skipping platform behavior.
5. Self-review and commit only task-owned files. Report test evidence and exact
   changed files. The controller performs a fresh task review.

## Task 2: Native declarative network rules, offscreen contexts and alarms

**Files:** `src/main/extensions/catalog.cjs`, `manager.cjs`, `bridge.cjs`,
`adapt.cjs`; new focused lifecycle module(s) in that directory; new
`test/e2e/extension-native-services.test.cjs`, focused unit tests, and
`docs/EXTENSION-NATIVE-SERVICES.md`. Coordinate catalog/bridge edits after Task 1.
Root owns action API/bootstrap/host changes; request integration there instead
of concurrently editing them.

**Interfaces:** Preserve native Chromium DNR/offscreen/alarms where verified.
Introduce explicit initialization awaited by manager activation/restore before
advertising enabled. A trusted host-owned extension page can call native APIs;
never use ordinary web pages or main-world bridges. Native DNR must initialize
manifest-enabled static rulesets through updateEnabledRulesets, preserve users'
enabled/disabled choices and dynamic rules across restore/update, and remove
effective rules on disable/removal. Native session rules stay session-local.
Offscreen contexts must expose only native runtime, not fabricated storage/tabs
facades. Alarms must fire/wake real native backgrounds and have truthful restart
semantics. All contexts remain profile-scoped and sandboxed.

1. Write failing native tests through actual managed extension installation:
   static/dynamic DNR really block/redirect/modify an HTTP request, allowed
   requests succeed, another profile unaffected; native session/dynamic/static
   changes preserve documented lifetime through stop/restart/disable/update.
2. Add offscreen DOM/runtime messaging create/has/close and denial of privileged
   adapter calls, including disable and private/profile isolation. Test genuine
   alarm delivery to suspended worker and alarm enumeration/clear/restart.
3. Inspect pinned Electron runtime behavior; add the smallest durable lifecycle
   initialization necessary. Do not claim success on absent native setters;
   report concrete blockers. No catalog enable until the fixture passes.
4. Run focused manager/catalog tests and native fixtures. Record RED/GREEN, exact
   method boundaries, self-review and commit only owned files. Root coordinates
   foreground tests and reviews the complete task diff.

## Task 3: Action popup, pixel icons and document menu callbacks

**Execution:** Root inline with TDD, independent of Task 2 files.
**Files:** `api.cjs`, `bootstrap.js`, `host.cjs`, a pure icon encoder if needed;
`test/extensions-api.test.cjs`, `test/e2e/extension-api.test.cjs` and owned
new native test file. Do not change Task 2 initialization concurrently.

**Interfaces:** action.openPopup accepts optional windowId, selects the existing
profile's active tab, and opens its declared sandboxed popup without granting a
user gesture/activeTab. Missing/disabled/foreign-window/hidden-profile cases
reject. Only one action popup per profile/window is retained. setIcon accepts
ImageData or size dictionaries; facade serializes bounded RGBA bytes, host
validates and encodes real PNG pixels. Paths continue to work. Menu onclick
functions remain in their owning document; facade routes onClicked events by
menu ID and removes/replaces callbacks after successful remove/update; MV3
workers must use onClicked as Chrome documents.

1. Add RED tests for openPopup, invalid windows/state/no gesture, pixel icons
   including malformed dimensions/bytes, and native callback/PROMISE behavior.
2. Implement under existing generation/permission guard. Image encoding is
   bounded, rejects malformed input, preserves alpha/colors and is never HTML.
   Verify actual shell icon pixels and isolated popup page. Inline callbacks
   work in a native MV2/document context and are not sent over IPC as functions.
3. Run focused unit/native tests, self-review and commit task-owned changes;
   request a fresh review after integration.

## Subsequent capability slices

The required builder check is probing DNR/offscreen/alarms and other APIs. Add
their exact implementation tasks after verified native behavior establishes
the appropriate mechanism. These items are OPEN, not omitted from the user's
request: action popups/ImageData, callbacks, alarms/fontSettings, DNR, offscreen,
sidePanel, userScripts, activeTab, nativeMessaging, identity, deployment and
release validation. They must not be marked complete by this DevTools task.

## Task 4: Native messaging host broker

**Files:** New `src/main/extensions/native-messaging.cjs`, focused
`test/extensions-native-messaging.test.cjs`, native fixture/e2e, and
`docs/EXTENSION-NATIVE-MESSAGING.md`. API/bootstrap/host/catalog integration is
coordinated with root after Task 3 completes; do not edit those concurrently.

**Interfaces:** A broker class accepts `resolveHost`, `approveHost`, `emit`, and
native process spawning dependencies for deterministic tests. Production host
resolution uses OS registration for the named host (macOS/Linux known Chrome
native-messaging locations; Windows documented HKCU/HKLM native-messaging
registry keys). Strict hostname grammar, manifest type=stdio, exact name and
allowed_origins must include the verified chrome-extension://ID/; reject URLs,
relative executables on Unix, shell commands, wildcard origins and malformed
or oversized manifests. Never search arbitrary executable paths or use a shell.

`connect(context, name, clientPortId)`, `post(context, clientPortId, value)`,
`disconnect(context, clientPortId)`, `send(context,name,value)`; context includes
profile/extension/generation and guard. Ports are scoped to that authenticated
context. Require nativeMessaging permission and a local review of the exact
registered host/executable; remember approval only for its unchanged manifest
and executable identity. Revoke processes/queues on context death, extension
disable/removal/profile shutdown. Native JSON length framing uses the machine's
byte order, validates UTF-8/JSON and size limits, handles fragmentation and
multiple messages, rejects truncated frames and bounds queue/process resources.
Do not print host payloads/stderr or include them in errors.

1. Add failing real-child-process tests using a synthetic temporary native host,
   including fragmented response, multiple responses, denial by origin, malformed
   lengths/JSON/UTF-8, process exit, cancellation, profile/generation mismatch and
   withheld local approval. No real personal installed host is launched.
2. Implement broker/resolver with explicit limits and teardown. Cross-OS lookup
   tests inject registry/path discovery; real execution is tested on local OS.
3. Coordinate real native Port facade (onMessage/onDisconnect/lastError,
   synchronous connectNative return) and sendNativeMessage Promise/callback
   through authenticated IPC. Native nativeMessaging is blocked by Electron,
   so these methods must call the broker, not pretend native support.
4. Native acceptance: a disposable reviewed extension talks to the synthetic
   registered host and loses connection on disable. Unit + native checks pass;
   document exact host discovery, review and bounds, self-review, commit owned
   files and provide RED/GREEN report for fresh review.

## Review Focus

- Genuine DevTools context and inspected document behavior, not manifest loading.
- No cross-profile or private extension installation.
- Resource escape and generation revocation.
- Packaged original signature/provenance remains untouched.

## Task 5: Native extension side panels

**Files:** New `src/main/extensions/side-panel.cjs`; `src/main/main.cjs`,
`src/main/layout.cjs` only if needed; renderer `app.js`/CSS for real panel chrome;
new unit/native tests and `docs/EXTENSION-SIDE-PANEL.md`. Coordinate API/bootstrap/
host/catalog integration after native-messaging owner releases those files.

**Interfaces:** sidePanel.getOptions/setOptions, getPanelBehavior/setPanelBehavior,
open/close and getLayout. Maintain global default from manifest.side_panel and
per-native-tab overrides, scoped by profile/extension/generation. Open supports
the actual browser window/tab, requires a genuine host-recorded user gesture,
and rejects foreign/closed/private/disabled contexts. Action-click behavior can
open the configured panel; a visible browser control in Manage extensions opens
the configured panel too. Do not fabricate activeTab to open it.

Use one genuine sandboxed/context-isolated WebContentsView within the browser's
existing right-panel region, displaying a same-extension packaged page. Keep
the actual page WebContents and unsaved input intact; resize the page using the
normal layout path. Renderer shows title/close control and mutually selects
this panel versus Library/AI/Settings. Layout geometry comes only from trusted
shell IPC and is clamped to the window. Hide/detach the native view for shell
overlays so dialogs remain usable. Closing/replacing panel, switching profile,
disabling/removing extension or closing its scoped tab destroys obsolete access.
Global panels can remain open across same-profile tab switches. Offscreen/native
messaging concerns remain separate; never turn this into a standalone window.
Persist panel behavior/options under the managed profile directory if their
Chrome lifetime requires it; do not persist transient open/gesture state.

1. Add RED unit/native tests for options, tab/global selection and real attached
   view geometry, host gesture enforcement, cross-profile denial, native API
   use inside the panel, page input retention and teardown/overlay behavior.
2. Implement controller + shell/native layout + compatibility routes under the
   existing authorization guard. No page-driven install/panel control IPC.
3. Run targeted native/unit and existing layout/profile regression tests. Record
   exact supported methods and RED/GREEN, self-review, commit owned paths and
   return report for fresh review. Final combined suite is root-coordinated.

## Task 6: Extension identity web authentication

**Files:** New `src/main/extensions/identity.cjs`, focused unit/native tests and
`docs/EXTENSION-IDENTITY.md`; coordinate identity-only API/bootstrap/host/catalog
integration after Task5 releases those files.

Implement real `identity.launchWebAuthFlow` and synchronous `getRedirectURL`,
using an owned sandboxed, context-isolated BrowserWindow in the extension's
profile session. Require identity permission and validated context/generation;
never expose Node/preload/compatibility APIs to provider content. Validate HTTPS
provider URLs (no embedded credentials), extension-specific exact HTTPS host
`<extensionId>.chromiumapp.org`, bounded redirect results/options. Intercept
redirects before navigation, close window and return full redirect including
query/fragment. Never accept another extension's callback or leak tokens in logs.
The authorization window starts hidden; interactive mode shows after initial
load unless already completed; noninteractive defaults to abort after load, with
explicit abortOnLoadForNonInteractive=false and bounded timeout supporting JS
redirects. Abort/destroy pending work on caller/context/extension/profile death
and window close. Isolate concurrent flows and bound resources. Preserve normal
certificate validation and block unrelated popup/new-window escape.

`getProfileUserInfo` accurately returns empty Google account fields when Zacro
has no Chrome Google identity; never substitute a Zacro account. Google
`getAuthToken` requires genuine provider support; establish the pinned runtime
and official provider prerequisites rather than return fake tokens or silently
claim support. Keep a clear documented unsupported error if provider support
cannot be verified, recorded as an OPEN external requirement.

1. Add RED tests for same-ID HTTPS redirect, foreign/malformed URL rejection,
   query/fragment return, concurrency, timeout/cancel and revocation.
2. Implement and wire the facade with Promise/callback/lastError semantics.
3. Real Electron acceptance uses only a local synthetic HTTPS provider with
   fixture certificate handling restricted to that test's disposable session;
   no production TLS bypass or real user authentication. Verify real window
   isolation, redirects and lifecycle. Unit plus focused native regression,
   self-review and task-owned commit/report; root requests fresh review.

## Task 7: Approved native Electron hooks

User approved custom Electron on 2026-10-26. Pinned Electron45.0.0 commit
54f961b44b83e4ece81065ab60a182fd0c38c01e, Chromium156.0.8078.48.
Source clone `.tmp/electron-patch-source` is task-owned read/write; selected
Chromium originals in `.tmp/chromium-reference`. Root owns full build checkout
on external APFS image and build/install infrastructure. Do not run a full
gclient checkout yourself. Deliver Electron/Chromium patches in
`runtime/electron/patches` with exact base and application order manifest.

Implement privileged main-process session.extensions hooks with feature
negotiation version1. The extension JS/pages must not gain direct access.
Agree exact method names and return contract with root before adapter wiring.
- `getZacroCapabilities`: version plus implemented capability flags only.
- Real temporary activeTab grant to an actual WebContents in exact owning
  session, using Chromium ActiveTabPermissionGranter and native WebContents ID.
  Validate enabled extension, activeTab permission, HTTP(S) page and not private.
  Resolve only after network/renderer grant dispatch; revoke by native navigation,
  close, unload. Never add permanent manifest origins or grant other same-origin
  tabs. Native return must indicate genuine grant, with async cancellation safe.
- Update reviewed native permissions without replacing caller/extension object.
  PermissionsUpdater must update native permission data, networking, renderers
  and persistence before resolving. Root supplies already-reviewed exact
  permission/origin set. API is privileged, validate bounds/native parse and
  enabled same-session extension. Keep optional declaration metadata separate
  from grants, preventing direct native permissions.request bypass. Do not
  expose a native auto-grant route through retained optional manifest entries.
- userScripts enable/disable uses UserScriptManager::SetUserScriptPrefEnabled;
  add genuine SCRIPTS StateStore initialized before UserScriptManager. Ensure
  registered scripts persist across normal restart but disable/removal stops
  execution, separate USER_SCRIPT world with no extension credentials/Node.
- Native font preference hooks: real per-profile/script generic font maps and
  default/minimum sizes into Blink WebPreferences; update existing/new contents,
  preserve explicit CSS families. Get fonts via native OS enumeration. Root
  owns extension ownership/priority and persistence adapter. Native setter can
  replace validated override map; empty map restores unmodified native defaults.

Add native acceptance specs under Electron spec as part of patch: enabled grant
vs same-origin negative tab/cross-profile/navigation/unload, alive caller
permission continuation, user script isolation/persistence, font preference
effect. RED native tests can only run once custom build exists; clearly report
source-level checks vs compilation/run evidence. Source patch application on
pinned original must pass; do not claim complete based on patch alone.
Self-review, task-only commit, full report to task-7-report.md; no subagents.

## Task 8: Consume the custom native runtime in Zacro

Root builds Electron; Task7 owns native patch. Agreed v1 session.extensions
contract: getZacroCapabilities() => {version:1,activeTab:true,
reviewedPermissions:true,userScripts:true,fontSettings:true};
grantZacroActiveTab(extensionId,webContentsId) => Promise<void> after native
network/render dispatch; setZacroReviewedPermissions(extensionId, fullSet) =>
Promise<void> with exact full reviewed permissions/origins;
setZacroUserScriptsEnabled(extensionId,bool) => void;
loadExtension(path,{zacroReviewedPermissions:fullSet}) validates/applies exact
initial active/granted set BEFORE registration/worker/content scripts. Native
permissions.request direct IPC is denied. Original required+optional manifest
declarations must be retained for native validation. Native code enforces
required access, exact session and enabled identity, no private profiles.

Own new engine capability module, manager/permissions/catalog integration,
activeTab API.gesture hookup, explicit userScripts local toggle UI/controller,
focused tests/native custom-runtime acceptance/docs. Task7 owns native source;
root owns build/artifact scripts and fontSettings adapter (coordinate shared
api/bootstrap/host/renderer exact hunks).

Requirements: negotiate hooks/version/method existence from actual session,
fail closed on stock Electron; keep stock acceptance truthful and allow engine
capabilities only on patched runtime. Manifest parsing must stay pure/testable
with explicit capability inputs. Preserve verified original package/hashes;
derive a new managed manifest for native mode retaining optional declarations
while all grants are applied through privileged initial load option. Handle
previous derived versions safely, never broaden access in migration/downgrade.

Permission request/remove changes native permissions in-place and preserves
original living caller/context/generation. No native unload/reload, no losing
unsaved page data. After native completion current metadata/persistence and
events reflect grants; cancellation/disable/profile transition at any async
boundary must revoke/stay fail-closed. Required permissions never removed;
no callback before native completion. Preserve current stock fallback.

activeTab grants actual native tab after genuine host action/command/menu
gesture only, never via API openPopup or extension fake gestures. Update adapter
temporary visibility only once native grant resolves and revalidate context.
Same-origin other tab negative; navigation/disable native revocation.

userScripts permission availability requires runtime; provide trusted Manage
extensions local enable/disable toggle (separate consent), persist it by managed
profile/extension, apply before/background initialization and on restart.
Extensions cannot toggle their own host setting. Existing script worlds remain
native; do not implement scripting with unsafe evaluate/Node.

RED unit tests cover runtime mismatch/stock denial, live permissions preserved
through awaits and cancellation, migration, user consent. Native custom fixture
must FAIL when demanded without custom runtime; regular stock suite can record
explicit unsupported behavior rather than skip all assertions. Native execution
awaits root built binary; report exact unrun boundaries, no mock-only completion.
Record report task-8-report.md, task-owned commits; no subagents.

## Task 9: Native fontSettings adapter

Task7 custom hooks on session.extensions:
getZacroFontPreferences() => native effective {fonts:[{script,genericFamily,
fontId}],defaultFontSize,defaultFixedFontSize,minimumFontSize};
setZacroFontPreferences(same shape,fonts required/sizes optional) replaces
native overrides; empty fonts and absent sizes restores native defaults.
getZacroFontList() => Promise<{fontId,displayName}[]> native OS enumeration.
Task8 engine-capabilities.cjs negotiates actual v1 and all font hooks.

Own new font-settings.cjs, focused unit/native tests/docs and fontSettings-only
API/bootstrap/host integration; coordinate Task8 shared files. Implement Chrome
fontSettings get/set/clear Font, DefaultFontSize, DefaultFixedFontSize and
MinimumFontSize, getFontList and four onChanged events with accurate per-receiver
levelOfControl. Validate generic families, script tags, sizes/font names and
argument shapes with bounded state. Native getter supplies defaults; do not
hardcode default fonts/sizes or substitute CSS. Require fontSettings permission,
trusted enabled same-profile/generation context and genuine negotiated runtime.

Settings persist locally per profile and extension, are not sync credentials.
Use stable extension install order (manager record.installedAt, deterministic
ID tie-breaker) for competing owners; latest installed enabled extension wins,
so an older extension write cannot steal a newer extension's selection. Clear
removes only own override; disable/remove or permission revoke recomputes and
restores next owner/native default. Disabled extension's retained preferences
can reactivate on explicit enable; uninstall removes them. No private/global
profile bleed. Emit only meaningful effective/control transitions, bounded
data, to enabled authorized receivers through bridge. Handle native set failure
without committing a false successful persisted state.

TDD: native-mock units for ownership/precedence, restart, cancellation, invalid
args, stock denial, per-profile events/disable/revoke/native failure rollback.
Real native fixture asserts computed generic selection/size changes, explicit
CSS unaffected, other profile negative, restoration. Custom acceptance must
fail when demanded without runtime; run actual after root build ready. No
mock-only feature claim. Self-review and task-owned commit/report task-9-report.md;
no subagents, no broad suites.

## Task 10: Reproducible sync deployment and container acceptance

User has no hosting account/domain; complete local deploy/operations assets
without purchasing/publishing or inventing a public endpoint. Existing
services/sync Node24 service/CLI/Dockerfile already implement real auth, TLS,
SQLite encrypted persistence/externalkey, backup/restore/deletion-ledger/key
rotation and health/ready. Preserve their security boundaries and account model.

Own services/sync/deploy (or equivalent focused directory), deploy docs, focused
container acceptance script/test and .github/workflows sync-container job as
separate workflow. Root owns native runtime workflow and all native app files.
Provide concrete HTTPS deployment with durable SQLite data, separate masterkey,
restart/health/monitoring and backup/restore operational commands. A proxy must
share loopback network namespace; current service rejects nonloopback plainHTTP.
Never relax service network validation merely to accommodate Docker networking.
Use mandatory operator-owned domain and external secrets; do not generate
production keys inrepo or emit key/tokens/log payloads. No telemetry destination.
Graceful stop and singleton lock remain reliable across container restart.

Container acceptance must build actual Dockerfile/image and use disposable
volumes/keys/accounts only. Test health/readiness, signup/auth/sync roundtrip,
restart persistent state, wrongkey/absentkey failure, backup/restore behavior and
HTTPS path where feasible using fixture-only certificates. No real accounts or
public endpoint. Cleanup only testnamed containers/volumes; keep diagnostics
with no secretbody/token output. Add reproducible CI LinuxDocker job for this
acceptance; actual Windows/mac builds remain separate.

Root installed colima0.10.3/lima2.2.1/docker29.9.2/compose5.6.1. Dedicated VM is
starting exec63184: COLIMA_HOME=/Volumes/ZacroElectronBuild/colima, profile
zacro-sync-test, activate=false, sshconfig=false, sshagent=false, mountnone,
disk12GiB/root10GiB/cpu2/memory2, VZ. Logs container-setup.log. It is downloading
diskimage. Do not change global Docker context; set DOCKER_HOST to this VM socket
whenready (discover exact path via colima status/config). Docker Compose is
standalone docker-compose because global plugin config was not modified.
Root is also syncing Chromium externally; avoid memorypressure during compile,
coordinate stop of VM once container acceptance finishes.

Use official docs/currentpinned images where needed. TDD behavior for new
helpers, realDocker acceptance, self-review/task-ownedcommit and report
task-10-report.md. No subagents; no deployments/pushes/accountcreation.

## Task 11: Pinned native build and artifact integrity tooling (root)

Provide explicit resumable source/toolchain/patch/build/native-test phases for
the three supported targets, exact source/depot pins and ordered patch hashes.
Never reset existing source changes. Build locally on the dedicated APFS volume
authorized by the user. Prepare manual self-hosted CI; do not claim unprovisioned
Windows/Intel runners ran. Keep source checks, compilation, native tests and
signed release gates distinct.

Record every regular file/relative internal symlink in a target/source/patch
receipt. Reject tampered files, extra files, wrong target/source and escaping
links. Stage/verify installs, preserve previous npm runtime backup, and recheck
receipt at packaging. Receipt is local integrity, not publisher authentication
or compilation proof. Use targeted adversarial tests and actual pinned-source
build/native/package acceptance once available. Root self-review followed by
fresh scoped review of task-owned scripts/docs/workflow.

## Task 12: Native ruleset resource paths found in verified packages

Production verification of uBlock Origin Lite2026.1021.1354 (ID
ddkjiahejlhfcafbddmgiahcphecmpfh, CRX SHA256
0887559eb9e6864e91b52e4a0c660995ade47c084dcc7150ed9ae743c9475a76)
found valid ruleset paths such as `/rulesets/main/easylist.json` rejected by
catalog validation. Pinned Chromium156 `Extension::GetResource(string_view)`
removes exactly one leading slash; DNR manifest handling uses this method.

Own the DNR path check in catalog.cjs, focused native-services unit/native
fixtures and relevant compatibility documentation. Accept a single
extension-root slash while retaining rejection of traversal, double-leading
slashes, empty path components, foreign URLs, encoded/control characters and
backslashes. Preserve original package bytes and the native resource path;
never interpret it as a host filesystem absolute path. Existing acquisition
and copied-package symlink boundaries remain unchanged.

Add a failing catalog case and a real managed native ruleset fixture using the
root-relative path. Prove actual blocking and cleanup, not catalog success
alone. Update the previously overbroad negative `/rules.json` expectation while
retaining its meaningful adversarial cases. No new permissions or native API
facades. Run focused tests, record RED/GREEN and exact behavior, commit owned
files and request fresh review. Do not run foreground tests while root's full
stock verification owns that lane. No subagents.

## Task 13: Native paint assertion precision (root inline)

Current stock verification passes106/107 native cases; the native startup paint
case fails on background channel30 versus expected31. A separate unmodified
Electron45 BrowserWindow, loading none of Zacro, reproduces background BGRA
`[93,121,30,255]` and marker `[88,56,222,255]` on three captures while DOM CSS
remains `rgb(31,121,93)` and `rgb(222,55,88)`. This is a one-channel-level native
capture conversion difference, not a hidden or unpainted page.

Keep all visibility, animation-frame, actual capture, marker placement, draft
retention and nine-transition assertions. Compare each sorted color channel
within one integer level, with useful per-transition diagnostics; do not force
rendering/color switches or replace image evidence with DOM-only checks. The
existing real startup test supplies RED/GREEN. This low-impact test assertion
change needs no new implementation-mirroring unit suite. Record the minimal
baseline and focused actual result, commit this test only, and obtain a fresh
scoped review.

## Task 14: Version-pinned representative provider acceptance

Own a separate opt-in test/provider representative acceptance fixture and
compatibility evidence documentation. Keep normal unit/E2E suites offline and
all user profiles/accounts untouched. Existing JSON Formatter acceptance stays.
Use production HTTPS acquisition and CRX developer/publisher verification,
original hashes and real managed installation. Fail closed if the provider
changes the explicitly pinned version/hash. Locally cached task-owned original
CRXs are available for investigation only; do not substitute unverified bytes
or a mocked compatibility capability for final provider acceptance.

Verified current samples:
- Dark Reader4.9.133, eimadpbcbfnmbkopoojfekhnkhdbieeh,
  ee38f20d1d50789f4b482c9a1a5dadab599b8682fd2a7dfb7de21fae8561b918.
- React Developer Tools8.0.0, fmkadmapgofadopljbjfkapdkoienihi,
  d92e1122a16362cc5510927068a5b1a8d50b43e1f3be25c3117f7c005807b302.
- uBlock Origin Lite2026.1021.1354, ddkjiahejlhfcafbddmgiahcphecmpfh,
  0887559eb9e6864e91b52e4a0c660995ade47c084dcc7150ed9ae743c9475a76.
- Bitwarden2026.10.0, nngceckbapebfimnlniiiahkandclblb,
  f2feb7fc46d2550bef9b69af1cc358aea26b90a947645f9de16ec14d9296ef69.

Exercise actual core behavior on disposable local pages: Dark Reader changes
page appearance; React DevTools creates real component tools for a genuine
React page; uBOL's original enabled rules block a local fixture request and
disable removes the block. Select a real original ruleset condition that can
match loopback fixture traffic, or a test-process-only hostname map to loopback;
do not contact ad endpoints or replace the extension's rules. React18.3.1 and
ReactDOM18.3.1 official npm archives are in the task-owned react-fixture cache;
use bounded integrity-pinned acquisition for any reusable fixture dependency,
not an invented React hook. Do not add production dependencies.

On stock runtime, assert the actual documented engine-required denial for
Dark Reader/fontSettings and uBOL/activeTab/userScripts. On negotiated custom
runtime, execute their real positive core behavior; demanded custom acceptance
must fail if native hooks are absent. Bitwarden currently has other required
unsupported APIs/file access/sandbox; prove visible incompatible state and no
native activation, and document it as unsupported, never a positive password
manager result. React's optional clipboardWrite is a visible partial boundary.
Do not broaden the approved API scope merely to make these samples install.

Coordinate the single native foreground lane. Root's stock suite has finished;
Task12 owns its focused run until released. Root will supply the actual custom
runtime when compiled; custom positive checks remain unrun until then. Record
exact versions, behaviors, negative limits, commands/results and source/runtime
identity in task-14-report.md. Fresh task review follows the narrow commit.
No subagents, personal account login, source package modification or publication.

Task14 implementation ruling: the verified uBOL archive also uses native-valid
`background.service_worker: "/js/background.js"`. The adapter previously rejected
this before presenting incompatibility. The Task14 implementer owns the minimal
worker-path fix in adapt.cjs and focused classic/module native fixtures: remove
one root slash for filesystem/bootstrap-relative calculations only, retain the
original native manifest path/bytes, and reject traversal, double slash, encoded,
control, foreign and backslash paths. Genuine imported worker code and relative
dependencies must run after adaptation. This does not expand API permissions.

## Task 15: Windows sync backup and CLI acceptance portability

Read-only inspection of the existing baseline CI run40206850043 (head1da83e3,
not the current branch revision) found Windows backup fsync failures and a
CLI shutdown assertion failure. Job121209518324 shows EPERM at maintenance.cjs
backup fsync and null exitCode vs0 after child.kill('SIGTERM'). These paths are
unchanged in current source. Windows FlushFileBuffers requires GENERIC_WRITE;
the backup snapshot is currently reopened read-only. Node24 documents that
Windows child.kill SIGTERM terminates the process rather than delivering POSIX
signal handlers. Actual Windows re-verification remains pending current CI.

Own services/sync/maintenance.cjs and focused sync operations tests/fixtures.
Open the freshly-created snapshot with the access required for a real durable
flush, without truncating it or swallowing flush failures. Reproduce the
read-only regular-file fsync failure through a narrow platform-contract seam
over real filesystem/SQLite backup and restore; retain mandatory failure on
genuine write/flush errors and existing authenticated metadata/deletion rules.

Test the real CLI's registered graceful handler portably. On POSIX preserve real
signal coverage. A test-only preload over the child's authenticated parent IPC
may emit the handler event on Windows; exercise that transport locally too.
Keep it outside all production/package files and never add a product shutdown
network endpoint. Require a clean exit, stopped event, released ownership and
successful offline backup/restore; never accept forced termination as graceful
success. Bound test cleanup and keep passwords/keys out of logs.

Use the existing failing CI as platform evidence, add covering focused
regressions before the production change, and run only the affected Node tests.
No native foreground test, live runtime source edits or public CI rerun/push.
Document the precise remaining Windows execution gate. Report exact commands,
RED/GREEN and self-review in task-15-report.md and commit only owned files;
fresh review required. No subagents.

Primary references:
- https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers
- pinned Node24.22.0 doc/api/child_process.md in the source checkout, or
  https://github.com/nodejs/node/blob/v24.22.0/doc/api/child_process.md
- https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40206850043
