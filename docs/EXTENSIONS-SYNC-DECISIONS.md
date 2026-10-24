# Implementation decisions and costs

These decisions refine the [approved Electron design](superpowers/specs/2026-10-25-extensions-and-sync-design.md). They do not grant broader
publication or production deployment authority. Native limitations and observed
validation are recorded in [Extensions](EXTENSIONS.md) and the [validation record](EXTENSIONS-SYNC-VALIDATION.md).

| Decision | Reason | Cost or consequence if unsuitable |
| --- | --- | --- |
| Reuse the requested `extensions-and-sync` branch and checkout. | The user explicitly chose this branch. | Shared checkout requires exclusive file ownership and a single native test lane. |
| Proceed through implementation after design approval. | The user authorized implementation and verification. | Further routine approval is omitted; genuinely destructive/external actions still need separate authority. |
| Run implementation agents sequentially, with independent read-only review. | Avoid competing source changes and native app focus. | Less parallel throughput. |
| Correct baseline Mac tests to use native primary modifiers and platform-neutral labels. | Existing tests sent Windows-only shortcuts on Mac. | A bad correction could hide a mapping regression; behavioral assertions and native mapping coverage remain. |
| Use a host-owned isolated MV2 broker and native-runtime facade. | Electron 45 MV2 backgrounds do not provide the required isolated preload context. | Extra transport/lifecycle complexity; no direct privileged global fallback is allowed. |
| Implement the independent account service while native transport work proceeds. | HTTP/SQLite/authentication have no native-context dependency. | Service work could precede an unusable desktop integration; final real-two-desktop acceptance remains mandatory. |
| Limit datasets to 100/account, active extensions to 100/dataset, lifetime extension IDs to 1000/dataset, JSON depth to 64. | Bound processing and queries. | Larger deployments require an explicit capacity/protocol change. |
| Preserve current encrypted credential state in the durable security ledger and revoke all restored device sessions. | Old backups must not revive old passwords, consumed recovery codes or deleted accounts. | Restored clients must sign in again; operators must retain the latest ledger. |
| Use OS-protected credentials and a distinct SQLite client store, with no plaintext fallback. | Keep account secrets outside browser snapshots. | Account access is unavailable when OS protection is unavailable. |
| Request `settings=0` when settings consent is off. | Consent must prevent downloads as well as uploads. | Client and service versions must support this transport contract. |
| Keep account-specific local archives and require explicit relinking after account changes. | Prevent settings/outboxes crossing accounts. | Retained unsynced values may require an explicit upload choice when relinking. |
| Rebuild effective native manifests for grant changes, allowing coordinated manager/catalog changes. | Adapter checks alone cannot revoke native access. | Reload can disconnect callbacks and require page reload for already injected scripts. |
| Reject required/optional `activeTab` that the pinned engine cannot enforce; implement MV2 lazy wake separately. | Native tests could not obtain a temporary one-tab grant, while genuine MV2 suspend/wake was feasible. | Some common extensions remain incompatible; broader host permissions are never substituted. Lazy wake is now verified. |
| Allocate an inert native guest for each browser tab, retaining its identity through New Tab. | Native messaging and scripting require stable genuine tab IDs. | Additional native objects for inactive tabs; unloaded URLs must remain unfetched and resource lifecycle is tested. |
| Pause remote library projection through the complete local operation and its queue commit; use link/account/intent guards across intentional runtime rebuilds. | Temporary local disablement must not trigger remote re-enable or stale operation completion. | Remote application is deferred during user operations; guards must distinguish intentional reload from account/profile changes. |
| Extend the current security ledger to dataset-only deletion and add local-profile purge distinct from unlink. | Explicit deletion must not restore or indefinitely retain live extension settings. | Added ledger record compatibility and recovery tests are required; ordinary unlink and unrelated data must remain intact. |
| Retire a deleting profile atomically with its settings purge, retaining the marker across interrupted teardown and clearing it only after durable browser deletion. | Live extensions and fresh links must not recreate deleted settings during asynchronous shutdown. | One extra completion transaction and browser metadata flush; failed teardown stays blocked with an explicit retry action. |

The repeated checkout decision in the desktop plan uses the same user authority
as the first row; its additional OS-vault/SQLite choice is listed separately.
