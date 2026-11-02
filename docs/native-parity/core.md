# Native state and persistence parity

The reference is the Electron implementation, especially `src/core/store.cjs`, `navigation-history.cjs`, `split-groups.cjs`, `archive.cjs`, `shortcuts.cjs`, `site-search.js`, and `import.cjs`. This ledger describes implemented state contracts and deterministic evidence; it does not certify engine behavior or visual parity.

| Contract | Swift implementation | Evidence |
| --- | --- | --- |
| Google default, empty location produces blank draft, safe web/search addresses | `ZacroCore/Models.swift` | BrowserStoreTests address matrix; explicit extension URLs use a separate trusted API |
| Profile-wide favorites retain identity across Spaces; ordinary pins/folders are Space-local | `BrowserStore.selectTab/selectSpace/moveTab/toggleFavorite/togglePin` | Remembered favorites, cross-profile rejection, pin destination capture, unpin reopen, explicit drag classification |
| Splits persist until unsplit/closed; move both members across Spaces; shared favorites may visit another Space without destroying group | `BrowserStore` split repair and move operations | Inactive-member move keeps active partner and selection; only dragged member changes pin/favorite classification; choosing a closed retained pin/favorite as the second member wakes it atomically |
| Sidebar keyboard order | `sidebarTabs(spaceID:)` | Favorites, folders, loose pins, split pairs, ordinary tabs; hidden implicit blank drafts excluded |
| Peek persists with parent; promotion preserves original if tab limit prevents opening | `SavedPeek`, `setPeek`, `promotePeek` | 1,000-tab limit test preserves Peek and archived entries; closing parent discards Peek |
| Archive cadence, inheritance and Never | `archiveHours`, `archiveStale`, settings/profile fields | Never and per-profile cadence survive restart; pins/folders/splits/Peek excluded; runtime can supply live-page exclusions through archiveCandidates(now:excludeIDs:) |
| Back/forward restoration | `repairTab`, `NavigationEntry` | Unsafe entries removed while selected index retained; up to 100 entries around current page, no serialized opaque page state |
| Restart/session setting | `BrowserStore.init` | Restore-off retains pins/splits/Peek, archives ordinary tabs; unfinished downloads become interrupted |
| Portable data | `Collections.swift`, `LegacyImport.swift` | Version checks; IDs remapped; destination settings/selection retained; private data/history/permissions/download paths excluded from portable export; explicit legacy migration preserves safe navigation/history |
| HTML bookmarks | `Collections.swift` | UTF-8/16MB/20,000-entry bounds, entity decoding, profile-scoped deduplication, HTTP(S) only |
| Shortcut catalog | `Shortcuts.swift` | 73 original macOS identities; aliases, collisions, reserved keys, overrides/reset/swap tests |
| Website search | `SiteSearch.swift` | Keyword/placeholder/endpoint validation; encodeURIComponent-compatible query encoding; same-origin matching normalizes case/default ports |
| Settings/window geometry | `BrowserSettings`, `BrowserWindowBounds`, repair | Original field defaults/bounds and numeric rounding; geometry model stores content/window size kind and maximized state |
| Space gestures | `SpaceGesture.swift` | Original contact phases, reversal, 80ms velocity window, continuous multi-Space movement, edge resistance, one-neighbor quick flicks and ignored momentum |
| Native extension tab metadata | Optional `autoDiscardable`, logical `openerTabID` | Defaults remain automatically discardable; opener identities survive portable ID remapping and are cleared for self, closed, removed or cross-profile references |
| Native extension tab queries | `NativeExtensionQuery.swift` | Strict Boolean/integer fields, exact false and missing-field semantics, current/last-focused window filters and aliases; URL/title matching remains inside Chromium after permission checks |

## Durable state

`SessionPersistence` serializes snapshots on one utility queue. App callers opt in with `enableDebouncedPersistence()`; saves coalesce at 250ms with a one-second maximum deferral. `flush()` cancels deferred work and synchronously writes the latest snapshot behind all older queued writes. The application must call it before termination.

`commit` normalizes a separate candidate, writes it synchronously, and only publishes the candidate after success. Theme/onboarding/import dialogs can keep the draft open on disk failure instead of claiming a successful save. Collection and HTML imports use this path and cannot publish a partial import.

Files use exclusive 0600 temporary files, fsync, atomic rename, and directory fsync. A valid prior file becomes the backup. A corrupt primary is preserved under a generated unreadable filename and a valid backup is recovered. Explicit history/archive/permission/profile clears use throwing durable transactions. They sanitize the backup and managed unreadable recovery files before committing the primary, and publish memory only after success. A blocked recovery write preserves the previous primary and in-memory state; unrelated files are untouched. Private profiles and their dependent collections are removed from all persisted snapshots.

`BrowserStoreTests` and `ElectronParityTests` cover 51 cases as of 2026-11-01. Tests include queued-write ordering, flush, privacy clearing after an outstanding write, backup recovery, failed editor commits, failed collection imports, private profile destruction with an unwritable public store, and shortcut/site-search editor rollback. `SpaceGestureTests` adds 19 clock-injected scenarios, including the 18 Electron cases. They verify quick flicks select exactly one neighbor, held contacts never time out, long drags can span the strip, reversal discards old velocity, and momentum cannot contribute distance or cause a second commit. An additional device-switch regression verifies a completed trackpad stream cannot lock out a subsequently used mouse. `NativeExtensionQueryTests` adds nine query validation and matching cases, including strict splitViewId matching, for 79 Core cases. These are state-level tests. Native engine back/forward, actual drag hit testing, physical trackpad feel, AX, and screenshots belong to the runtime acceptance suite.

## Integration contracts

- Call `sidebarTabs()` for keyboard tab ordering instead of independently sorting categories.
- Use atomic `moveTab(..., pinned:, favorite:, clearFolder:)` for drag classification. Omitted folder means preserve it; `clearFolder: true` means remove it.
- User address entry uses `BrowserAddress.resolve`. Only a verified extension action should call `createExtensionTab`/`setExtensionPage`.
- Theme/onboarding edits use `try commit`. Profile/folder creation uses `createProfileDurably`/`createFolderDurably`; shortcut and site-search edits throw on persistence failure. Privacy controls use `clearHistoryDurably`, `clearArchiveDurably`, `clearPermissionsDurably`, `removePermissionDurably`, and `deleteProfileDurably`; legacy wrappers expose failures through `lastError`.
- `discardPrivateProfile(id:)` destroys the private profile and dependent in-memory records without a public disk write; use it when its last private window closes.
- Automatic memory sleep must honor `autoDiscardable != false` and revalidate after asynchronous checks. Explicit sleep/close and the separately chosen archive cadence remain user actions.
- Window bounds require Application capture/restore; the model alone does not reposition windows.
- `archiveCandidates(now:excludeIDs:)` is a pure query for runtime safety checks. Requery after asynchronous page checks before closing; `recordVisibleTabActivity(now:)` updates both visible split members, and departure/unsplit/close refresh their idle dates.
- `SpaceGesture.Input` uses seconds and semantic direction (negate native wheel deltas). Pass native contact phases and profile ID; preserve unknown momentum as `nil` for phase-less devices. Only `didRelease` selects a Space; `progress` drives continuous signed strip displacement. Native contacts own their release deadline, so a fallback timer must not finish an active contact.
- A release build still needs actual engine/UI acceptance and signed distribution validation. Passing these tests is not a release certification.
