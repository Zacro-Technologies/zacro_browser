# Extensions and device sync on Electron

Status: approved by the user on 2026-10-25, with explicit authorization to implement and verify on `extensions-and-sync`. This document describes requirements, not completed implementation.

Date: 2026-10-25. Branch: `extensions-and-sync`. Inspected baseline: `722404a` / Zacro 0.4.0.

## 利用者向けの要点

- 利用者が選択した方針は「Electronを維持し、①拡張機能・端末間同期を実装する」。Chromium本体への移行は行わない。
- 拡張機能の管理画面からChrome Web StoreのURLを指定して導入できるようにし、権限・互換性・更新を管理する。
- Zacroアカウントで端末を登録し、明示的に関連付けたプロファイル間で、拡張機能の導入・有効/無効・削除と対応設定を同期する。
- 新しい端末への拡張機能導入と追加権限は確認を必要とする。Zacroが管理するCookie、サイトのログイン状態、AI認証情報、PC内のパスを同期データへコピーしない。ただし、拡張機能自身が同期領域に保存する値には個人情報等が含まれ得るため、設定同期はその説明への同意後に有効にする。
- `chrome.storage.sync` は実際の同期に接続する。ローカル保存への置き換えだけで同期対応とは扱わない。
- 同期サーバーのソースと実行・検証方法も含める。本番ドメイン、ホスティング契約、公開デプロイは別途運用設定が必要であり、ローカル検証を本番サービス稼働とは表現しない。
- 以下のアカウント方式、保存方式、対応API、競合ルールは実装者からの提案であり、利用者が個別に指定した内容ではない。
- 初期アカウントはユーザー名・パスワードと復旧コードを使う案。サーバー保存時の暗号化を実装するが、サーバーも読めないエンドツーエンド暗号化とは異なる。
- 権限変更時には拡張機能の再読み込みが発生する場合がある。既にページ内で動いているスクリプトの停止にページ再読み込みが必要な場合は、未保存入力を確認し、利用者の判断を経て行う。

## Intent and scope

Deliver all six work areas previously grouped as item 1: broader extension compatibility, Web Store installation, Zacro accounts, device management, extension-library synchronization, and extension-setting synchronization. Preserve the existing browser and its Windows/macOS support.

Electron remains the runtime. This means an explicit, tested compatibility matrix, not a claim that every Chrome extension or Google service works. Unsupported requirements must be visible before activation; they must not become silent no-ops. Missing required contexts or API behavior prevent completion of the relevant deliverable.

Non-goals are the other product groups: password manager, independent browser windows, AI agents, arbitrary file navigation, general browsing-history/tab/bookmark sync, mobile support, and the application's own automatic updater. Extension package updates are in scope.

## Approaches and decision

1. **Keep Electron and build an explicit compatibility adapter plus a Zacro sync service.** Preserves current browser behavior; requires ownership of missing APIs, extension-context integration, packaging validation, and a bounded compatibility claim. **Chosen by the user.**
2. **Move to a browser built directly on Chromium.** Potentially wider native extension support, but requires migration of current application behavior and a substantially different build/maintenance pipeline. Not chosen.

Within the chosen approach, retain the existing MIT licensing model. Do not import GPL implementation code or add a dependency requiring a different distribution license without a separate decision. Prefer original adapters and narrowly scoped permissively licensed libraries. Dependency versions and licenses are pinned and recorded during implementation.

## Existing integration points

- `src/main/main.cjs`: `profileSession`, managed extension install/restore/toggle/remove, tab/native-view lifecycle, context menus, downloads, main IPC, application startup/shutdown.
- `src/core/store.cjs`: validated browser metadata, profile boundaries, atomic persistence, portable export, explicit deletion.
- `src/renderer/app.js` and `styles.css`: current Settings and Extensions panels. Extend the existing UI patterns rather than introducing a second frontend.
- `src/main/preload.cjs`: shell-only IPC. Its privileged bridge must remain unavailable to ordinary pages and extensions.
- `test/e2e/security.test.cjs`: real extension installation/profile isolation and rejection of unauthorized IPC. Extend this evidence with dedicated extension/sync fixtures.

Separate new modules under `src/main/extensions/`, `src/main/sync/`, and reusable protocol/model code under `src/core/sync/`. Put the independently runnable account/sync service under `services/sync/`, outside desktop packaging. Do not concentrate the new subsystem in `main.cjs`.

## 1. Extension acquisition, identity, and updates

### Sources and user flow

- Preserve local unpacked-folder installation for development, explicitly labeled local-only unless it has a supported portable source. Never upload a local directory or local path automatically.
- Add **Install from Chrome Web Store** in the Extensions panel. Accept a validated canonical store detail URL or a 32-character extension ID. Offer to use the current page only when it is a recognized store detail page. Open the store for browsing normally; never expose install privileges to its page scripts or pretend to implement Google's private store API.
- Fetch packages from the store distribution endpoint with bounded HTTPS-only redirects to enumerated Google distribution hosts. The implementation records the exact endpoint and host allowlist from validated responses. Reject other protocols, credential-bearing URLs, unbounded downloads, unsafe redirects, and TLS failures. This provider endpoint is an external dependency that can change; surface errors instead of falling back to an untrusted mirror.
- The confirmation shows the verified manifest's name/version, publisher/source provenance, requested host/API permissions, compatibility result, and target profile. Downloading metadata is not approval to install.

### Package validation

Verify CRX3 signatures and bind the expected extension ID to the developer public key and signed header. Web Store provenance additionally requires the production publisher proof following Chromium's verifier; never accept publisher test keys in production. Validate the complete archive before execution. Record the original package hash, public key, source, version, and verification result.

Extract into a new managed staging directory. Reject absolute/parent paths, symlinks, duplicate/case-colliding entries, reserved names, unsupported entry types, excessive depth, oversized files and decompression bombs. Initial limits: 100 MiB downloaded, 300 MiB expanded, 15,000 files, 32 path levels. No overwrite of the active version while staging. Preserve the extension ID across devices, restarts, and updates by preserving the verified public-key identity.

Check updates on startup when due and then at a jittered six-hour interval, with a manual check action and persisted backoff. Use the same source/identity/signature validation as installation. New permissions, broadened host access, or reduced compatibility pause the new version for review while the old version remains active. Accepted updates swap atomically and retain one rollback version; restart recovers interrupted staging. Uninstall cancels in-flight installation/update and wins over late completions.

## 2. Compatibility adapter and execution boundaries

The adapter knows the source profile, installed extension, granted permissions, and lifecycle generation. Derive these from native frame/service-worker identity and the owning Electron session; never trust a caller-supplied extension or profile ID.

### Supported surface to implement and test

- `action` / legacy `browserAction`: title, icon, popup, badge, enable/disable, clicked event; host-owned action menu and isolated popup.
- `runtime.openOptionsPage`: safely open an extension's declared options page. Preserve supported native runtime messaging and startup/installation events.
- `tabs`: get/current/query/create/update/remove/reload/duplicate/move and created/updated/activated/removed events, scoped to the extension's profile. Return only fields permitted by `tabs`, host permissions, or a valid `activeTab` grant. Active-tab grants originate in a user action and expire on navigation; synthetic extension requests cannot manufacture them.
- `windows`: current/get/getAll/update and focus events for Zacro's existing window. Independent-window creation remains unsupported and is reported explicitly.
- `contextMenus`: create/update/remove/removeAll and click dispatch for supported page/link/selection contexts, without replacing native browser entries.
- `commands`: manifest shortcuts with collision detection and user-visible assignment; do not steal reserved OS/browser shortcuts.
- `permissions`: contains/getAll/request/remove and change events. Required/optional permissions and host grants are checked consistently; optional requests require a user gesture and host confirmation. Unsupported permission capabilities cannot be granted.
- `storage.sync`: the complete scope defined below. Preserve native `storage.local`; do not alias local and sync namespaces.
- Integrate native supported `scripting`, `webRequest`, and runtime messaging without overriding them with incomplete adapters. Audit the existing `webRequest.onHeadersReceived` MIME observer so it does not silently suppress extension listeners. Unsupported engine APIs, including native messaging, identity services, or rules APIs not provided by the pinned runtime, are reported in the compatibility matrix.

**2026-10-25 pinned-runtime finding:** Native `activeTab` access remains denied after a real host action, including an execution marked as a user gesture. The implementation rejects required activeTab and disallows optional activeTab rather than granting broader native host access. This is an explicit Electron compatibility boundary under the unsupported-capability rule, not a claim that temporary native grants work. Raw MV2 lazy pages do suspend/wake. The initial compatibility Port prevented suspension; subsequent implementation added authenticated idle teardown and native event-triggered wake, verified after native background contexts reached zero. MV2 native `scripting` is absent; MV3 native scripting is tested.

### Extension contexts

First implementation milestone proves the pinned Electron runtime can expose the adapter to extension pages, MV2 background pages where supported, MV3 classic/module service workers, and isolated content scripts, while exposing nothing to ordinary page worlds.

Use session-registered frame and service-worker preloads for extension origins, with a separate authenticated IPC endpoint. For content-script worlds that cannot receive those preloads, use an original, deterministic compatibility bootstrap in a derived managed copy of the verified package: prepend isolated content-script entries and wrap background entry points before original scripts run. The bootstrap uses the extension's native runtime messaging to its own authenticated background context; do not bridge through page DOM, `window.postMessage`, a public loopback server, or page-provided tokens. It validates native sender identity and origin/permissions. Ensure runtime messages cannot be confused with an extension's application messages.

Derived package rules: retain an immutable original archive/manifest/hash; version and hash the transformation; preserve the public key and extension ID; disclose adaptation in extension details; never state that the modified copy itself retains the original package signature. Keep original entry points and relative resolution intact. Static, registered dynamic, and programmatic isolated content-script injection must receive the same semantics. Main-world injections do not gain extension privileges. If these semantics cannot be implemented safely with supported Electron APIs and deterministic adaptation, report the failing contexts as a blocker; do not disable sandbox/context isolation, add permissive CSP, or declare the feature complete. A custom native Electron patch is a separate architecture decision, not a hidden fallback.

**2026-10-25 implementation clarification:** Native testing found that Electron 45's MV2 background executes the session preload without Electron context isolation, so `contextBridge` cannot expose the privileged adapter there. Do not install a direct privileged-global fallback. Test an original, host-owned hidden extension transport frame instead: it has explicit sandbox/context isolation, runs only the reserved host adapter, and main authenticates its exact native WebContents/frame and generation. The MV2 background and content scripts receive only native-runtime messaging facades and send directly to this receiver, which preserves native sender classification; they never receive IPC credentials or the privileged wrapper. Block navigation, alternate transport frames, forged sender metadata and stale generations. Do not duplicate original background execution or relax CSP. This is a supported-API transport candidate, not proof of MV2 support; both MV2 background forms, lifecycle and hostile-sender tests must pass before declaring that context supported. The Electron strategy, permission requirements and isolation of privileged code are unchanged.

Popup/options views retain their own profile and origin. A hidden or switched profile cannot obtain another profile's tabs, page context, grants, or credentials. Disabled/uninstalled extensions lose all adapter access immediately, including previously opened pages and late messages. Private profiles do not load extensions or participate in sync.

**Permission lifecycle decision (implementer proposal):** grant changes may unload, rebuild the effective manifest, and reload the extension. The effective manifest contains only approved native permissions/hosts and derived content-script declarations consistent with those grants. This must be tested against native `scripting`, network, content-script and optional-permission behavior; checking adapter calls alone is insufficient. If Electron cannot enforce a capability's narrowed grant, disable that capability or keep the extension disabled rather than announcing successful partial revocation. The adapter cannot make already injected JavaScript disappear: after unloading, identify affected open documents and request reload to finish removing their injected scripts. Honor beforeunload/unsaved-work choices. If reload is declined, keep the extension disabled and visibly mark the affected pages as requiring reload; do not claim immediate erasure of previously injected code. Never silently reload pages with unsaved work. The same boundary applies to uninstall and permission reduction during an update.

## 3. Zacro accounts and device management

Proposed first account model: unique normalized **username + password**, with recovery codes. This avoids implying email ownership verification or requiring an email provider before the service can run. Registration, login, password change, recovery, logout, account deletion, and rate-limited failed authentication are included. An email login/provider can be added later but is not silently substituted for an unverified address.

Passwords use asynchronous scrypt with independently random salts and versioned parameters (`N=131072`, `r=8`, `p=1`, bounded concurrency); accept 12–256 characters with a 1024-byte maximum, and never normalize the password. Usernames are 3–64 lowercase ASCII letters/digits with `_`, `-`, and `.`, beginning with a letter/digit. Recovery uses high-entropy one-use codes stored only as hashes; codes are shown once after explicit registration/regeneration and never logged. Password recovery invalidates prior sessions and rotates recovery codes.

The browser creates a device enrollment after password authentication. Device records expose a user-editable name, platform, creation/last-seen timestamps, and revocation status. Long-lived device credentials are opaque random tokens, stored server-side only as hashes and client-side in a separate OS-protected vault. No plaintext credential fallback, browser-state export, or renderer snapshot may contain them. Short access credentials expire after 15 minutes; refresh credentials rotate, expire after 30 days of inactivity, and detect reuse. Password changes revoke other device sessions. Rate-limit authentication by account and network origin, bound hashing concurrency, and distrust forwarding headers unless an operator explicitly configures a proxy.

Every operation checks account/device authorization against current database state so revocation also invalidates previously issued access credentials. Revoked clients stop uploads/downloads, discard credentials, and show a reconnect-required state. Local browsing and locally installed extensions remain usable. Removing a device cannot remotely erase files already downloaded to it, and the UI must not claim otherwise.

Account endpoint selection is an advanced service setting. A packaged build may supply a configured HTTPS service URL; an unconfigured build says that service setup is required instead of contacting an invented endpoint. Endpoint changes sign out and separate local sync state, preventing credentials or queued changes from crossing services. Explicit development mode permits loopback HTTP only; release clients require HTTPS.

## 4. Profile linking and extension-library sync

Synchronization is off until the user signs in and links a normal local profile to a named remote dataset owned by the same account. Creating and joining a dataset are explicit operations; matching local profile names never automatically link them. One local profile has at most one dataset link. Linking displays the local and remote extension changes for review before applying them. Unlinking retains local installations/settings and stops network activity; deleting a remote dataset requires a separate confirmation and recent authentication.

An extension-library record contains `extensionId`, portable verified source, intended state (`enabled`, `disabled`, `removed`), a server revision and an installation generation. Its schema contains no absolute paths, cookies, login state, browsing data, AI credentials, or local-only extension files. Unpacked/local-only sources stay visibly local-only. Versions are observations rather than a command to downgrade; each device chooses the latest compatible verified package from the registered source. The exclusion is about Zacro-owned records, not a promise to recognize secrets hidden inside extension-supplied setting values.

New devices download supported sources but leave them pending local permission approval. A declined installation does not delete the other device's installation. Separate remote intent from local status: pending approval, incompatible, unavailable source, download failed, enabled, or disabled. A locally disabled compatible extension can be enabled by an authenticated remote intent only within permissions already approved on that device. Broadened permissions always require review.

Persist local changes in a transactional outbox before acknowledging them. Operations have unique IDs, authenticated device ownership, dataset epoch, base revision and installation generation. The service serializes operations transactionally and deduplicates retries. Pull changes before pushing the outbox. Independent extension operations merge. For the same generation, removal wins over conflicting enable/disable operations; stale installs cannot resurrect a tombstone. An explicit reinstall must observe the removal revision and create a new generation. Persist tombstones until the dataset is deleted; do not prune them by elapsed time.

Metadata conflicts between non-removal states resolve by server acceptance order, never client clocks. The client communicates rejected stale operations and reconciles them without endlessly re-enqueuing them. Dataset deletion changes its epoch, rejects old outboxes, and prevents disconnected clients from recreating it. Account switching isolates outboxes and local extension-setting namespaces; no automatic merge between accounts.

Use bounded HTTPS batches with an incremental revision cursor, cancellation, timeouts and exponential backoff with jitter (initial 5 seconds, maximum 5 minutes). Push after a short debounce and poll at 30 seconds while connected, immediately on explicit Sync now/resume. Server pagination returns a stable high-water revision so concurrent mutations do not skip records. Persist acknowledgements, cursor, and resulting state atomically. Retain revisions for the dataset lifetime initially; introduce compaction only with an explicit resnapshot protocol.

## 5. Real extension-settings synchronization

Implement `get`, `getKeys`, `getBytesInUse`, `set`, `remove`, `clear`, `setAccessLevel`, `storage.onChanged`, and area-specific change listeners as applicable to the pinned API contract. Support both callback and Promise forms with native-style errors. A write atomically validates all keys before committing. Change events include old/new values and the `sync` area, including accepted remote changes; identical assignments do not emit changes.

Namespaces are bound to service/account, linked dataset, extension ID and installation generation. Without a linked account, `storage.sync` remains a distinct local namespace; it is not `storage.local`. Linking presents whether to upload local settings or use the dataset's settings; unlinking creates an independent local copy and cannot keep pushing to the former account.

Library synchronization and extension-setting synchronization have separate profile-level switches. Settings sync is initially off and requires explicit consent explaining that extensions choose their setting contents and may include personal information or credentials. Zacro does not copy its own credentials into the payload, but cannot reliably detect arbitrary encoded secrets stored by an extension. Do not market these values as guaranteed credential-free. Turning settings sync off stops uploads/downloads, retains the local copy, and leaves cloud deletion as a separate action. Re-enabling displays the local/remote choice again; no automatic cross-account merge.

Limits follow the supported Chrome sync contract: 102400 bytes total, 8192 bytes per item, 512 items, 120 write operations/minute and 1800/hour per local namespace. Count the documented UTF-8 serialized value/key sizes, with boundary tests against representative Chrome behavior. Reject unsupported serialization and protect special object keys. `setAccessLevel` defaults to trusted and untrusted extension contexts; trusted-only excludes content scripts. Validate permission and access level on every operation, not only on initial connection.

Store key changes/tombstones in the same outbox protocol, with server revisions per key. Independent key changes merge; competing values of one key follow server acceptance order. A stale `clear` only deletes keys visible at its base revision, preserving later unseen additions. Server quota checks are transactional. If merged offline changes would exceed quota, reject the conflicting mutation, keep it visibly unsynced, and offer retry/export/discard rather than silently deleting local data. A deliberate discard emits the resulting change event. Other accepted changes continue to synchronize.

The same genuine API calls must pass in popup/options pages, background contexts and content scripts, on two separate installations through an actual running service. Testing a storage helper in Node alone is insufficient.

## 6. Account/sync service and protection of stored data

Proposed service stack: Node.js 24 and SQLite, using one service instance and transactional schema migrations, WAL, foreign keys and bounded queries. This is an explicit single-instance deployment; horizontal scaling is not claimed. Desktop and service communicate through versioned `/v1` JSON endpoints. Tests run the actual service/database, not a separate in-memory implementation. Include development configuration, a production configuration example, a container build, health/readiness endpoints, migration/backup/restore commands, and operator instructions.

Store secret/sync payload fields encrypted at rest with AES-256-GCM, fresh nonces and authenticated ownership/context metadata; use versioned per-account data keys wrapped by an operator-supplied master key outside the database. Passwords/tokens use non-reversible hashes instead. Non-secret routing metadata remains queryable. Key absence or decryption failure fails startup/readiness rather than generating a new key over existing data. Document that this is server-side encryption, not end-to-end encryption: the service can decrypt synchronized settings. TLS is terminated by the configured HTTPS server or trusted reverse proxy.

Do not log passwords, recovery codes, tokens or extension-setting values. Log structured operation outcomes, request IDs, sanitized failures and aggregate health; enforce request/body/batch/rate limits and graceful shutdown. Enforce account ownership in every query and mutation, including pagination, profile joins, device changes, and deletion. Provide deterministic fixtures for tampered ciphertext, revoked sessions, malformed cursors, replay and cross-account access.

Account deletion requires recent password/recovery authentication and explicit confirmation. Delete live account/profile/device/sync data and revoke all sessions in one transactional workflow. Backup retention is at most seven days in the proposed operational policy; record deletion identifiers in a durable deletion ledger and apply them before any restored service becomes ready. Document that historical backups are not instantly erased and that deletion cannot erase copies on disconnected devices. Include a restore test proving deleted accounts cannot be resurrected. Production deployment must configure backup retention and ledger durability; local tests alone do not establish this operational guarantee.

## 7. User interface

Extend Settings with Account & sync: service connection/setup status, registration/login, recovery codes, device name/list/revoke, profile linking/unlinking, Sync now, last successful sync, offline/blocked/conflict status, password change and account/cloud-data deletion. Credentials remain in main-process storage; password inputs clear after submission and errors do not echo them.

Extend Extensions with store installation, source/version/compatibility details, granted permissions, action/options access, update/check/approve/rollback, and per-device sync status. Keep the existing compact sidebar and Library conventions. Use clear user language such as "Needs permission on this device" or "Only on this device"; do not expose protocol counters or internal paths in normal flows.

Existing browser controls continue to work while network operations run. Closing a panel does not accidentally approve an install or abandon a committed sync operation. Profile/account changes invalidate obsolete dialogs and responses. UI must distinguish local success, queued sync, server acceptance and remote installation; none implies the next.

## 8. Acceptance and completion criteria

1. Re-run the existing baseline suite before functional changes; preserve browser navigation, profile isolation, Peek/split, AI isolation, native Mac behavior, packaged security and session recovery.
2. Prove the extension-context adapter before building the full feature set. Negative tests cover ordinary pages/frames/workers, forged IDs, wrong profile/account, disabled extensions, permission removal, destroyed contexts and stale callbacks. Verify effective native grants after reload and explicit pending-reload behavior for injected scripts, including cancellation with unsaved page input.
3. Test real MV2/MV3 fixture extensions for action/options, supported tab/events, content scripts, runtime messaging and actual sync storage. Include classic/module workers, worker restart, dynamic/programmatic injection, callbacks/Promises, quota boundaries and access-level changes.
4. Validate CRX3 signatures/IDs/publisher proofs and hostile archives; test update permission escalation, cancellation, interrupted replacement, downgrade rejection and rollback.
5. Test account lifecycle, recovery, token rotation/reuse, device revocation, profile ownership, endpoint switching, encrypted persistence and migrations through the real service. Assert no Zacro-managed cookies, credentials or paths enter outgoing schemas, while consented extension-supplied values follow the explicit settings-sync policy.
6. Run two isolated Electron clients and one real service. Install/enable/disable/remove an extension; change settings through its API; verify convergence after reconnect/restart. Exercise concurrent edits, stale offline reinstall, local rejection of remote permissions, account/profile switches, server restart, paging, replay, quota conflicts and cloud deletion.
7. Publish an explicit compatibility matrix. Use reproducible fixtures for all claimed APIs plus version-pinned real extension samples representing productivity, developer tools, a content blocker, and a password manager. Record supported/partial/unsupported results; a family whose engine APIs are missing is a visible compatibility limitation, not a successful test. External downloads are separate opt-in acceptance, not hidden network dependencies of unit tests.
8. Run Windows and native Apple silicon/Intel CI and packaged acceptance. CI credentials are synthetic; do not use personal browsing data or sign into real accounts automatically. Include the compatibility adapter assets and server-independent desktop behavior in package checks.
9. Review permission boundaries, authentication, cryptography usage, archive processing and deletion independently. Document exact passing results and unresolved provider/platform/operations limitations. Do not mark all of item 1 complete if actual Web Store acquisition, both-client API synchronization, or required execution contexts remain unverified.

## Proposed work sequence

This is one product feature spanning three dependent subsystems, implemented in order: extension host/acquisition; account service and sync protocol; desktop sync and UI integration. Each gets a separate implementation plan and testable milestones after this design is approved. No phase substitutes a mock for the final cross-device acceptance.

1. Establish the baseline and extension-context feasibility tests.
2. Build verified package acquisition/lifecycle and the compatibility adapter.
3. Build account/device service, protected persistence and protocol tests.
4. Implement library and settings reconciliation, then wire the genuine extension API.
5. Integrate account/profile/device UI and remote permission review.
6. Run two-client, real-extension, platform and packaged acceptance; update source-backed documentation.

The implementer may choose module names, UI spacing consistent with the existing system, permissively licensed parser dependencies, and test-fixture details. Changes to account identity/recovery, encryption promises, permission requirements, synchronization scope, or the Electron strategy require a visible design revision rather than an undocumented shortcut.

## Builder-check record

A fresh read-only reviewer checked this design on 2026-10-25. Two consequential ambiguities were resolved as implementer proposals in this revision: permission changes may require extension/page reload with explicit pending-reload status; and the exclusion of browser credentials applies to Zacro-managed data, while opaque extension settings require separate informed opt-in. These are now covered by acceptance items 2 and 5. The runtime feasibility milestone remains required; this review does not establish that the adapter already works.

## Sources checked for this design

- Repository: `README.md`, `docs/ROADMAP.md`, `docs/SECURITY.md`, `docs/VALIDATION.md`, `docs/MACOS.md`, `src/main/main.cjs`, `src/core/store.cjs`, `src/renderer/app.js`, `test/e2e/security.test.cjs` at the baseline above.
- Electron extension support: https://www.electronjs.org/docs/latest/api/extensions
- Electron session/preload registration: https://www.electronjs.org/docs/latest/api/session
- Electron service-worker IPC and lifecycle: https://www.electronjs.org/docs/latest/api/ipc-main-service-worker and https://www.electronjs.org/docs/latest/api/service-workers
- Chrome extension storage contract: https://developer.chrome.com/docs/extensions/reference/api/storage
- Chromium storage API schema/quotas: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/extensions/common/api/storage.json
- Chromium CRX3 verifier: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/crx_file/crx_verifier.cc

Online documentation can move ahead of the pinned Electron 45.0.0 runtime. Implementation validates capabilities against that exact runtime and records any deliberate version update; documentation alone does not prove runtime support.
