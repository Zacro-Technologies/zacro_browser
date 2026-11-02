# Native interface parity ledger

The Electron application is the behavioral and visual reference. A successful build is not evidence of parity. This ledger records the actual reference contracts and the native implementation/acceptance work. No row may be called complete solely because a control exists.

## Source coverage

- `src/renderer/index.html`: sidebar, toolbar, Space strip, live content, Peek, split separator, right Library panel, rail separators, findbar, dialogs, toast/live regions.
- `src/renderer/app.js`: renderer state/event lifecycle and every interaction dispatcher; named functions are indexed below.
- `src/renderer/styles.css`: dimensions, typography, surfaces, hover/focus/selected states, responsive/reduced-motion/transparency/contrast rules.
- `src/renderer/theme.js`: color parsing, Oklab Space interpolation, readable surface/foreground derivation, grain envelope.
- `src/renderer/space-gesture.js`: contact/momentum state machine and snap decisions.
- `src/core/shortcuts.cjs`, `site-search.js`, `split-groups.cjs`, `navigation-history.cjs`, `archive.cjs`, `store.cjs`: command catalog and durable state semantics.
- `test/e2e/library.test.cjs`, `motion.test.cjs`, `compact-layout.test.cjs`, `pin-model.test.cjs`, `startup.test.cjs`, `test/space-gesture.test.cjs`: behavioral acceptance reference, not proof of native behavior.

## Geometry and design contract

| Surface | Electron contract | Native target / evidence required |
| --- | --- | --- |
| Window | Shared theme background; 224px sidebar; 4px page inset; 12px page corners; no content outline; content shadow | Root is native AppKit, hosted pages retain identity. Screenshot comparison in light/dark and empty/loaded states. |
| Toolbar |36px navigation row, 26px buttons, native traffic lights on same row, sidebar toggle + back/forward/reload | No second titlebar strip; original vector glyph paths and hit regions align with original. |
| Address |32px tall,10px corners,13px text,theme-derived ink/globe,copy action,site controls | Displays Peek address when Peek is active; no URL strip in content/sidebar-hidden mode. |
| Favorites |46px tall,7px gaps,balanced1–4 tiles per row,20px icon,site-color selected tile,offline icons | Six tiles produce3+3; five produce3+2; drag never compresses tiles or draws outline. |
| Pinned/Today rows |36px rows (compact density adjusts),16px favicon,8px padding,translucent card selection+small shadow | Hover close/reset/audio controls,custom title,split group shared capsule,Peek favicon badge. |
| Folders |36px heading,16px Space-colored folder,indented children with1px guide | Expand/collapse preserves focus; delete preserves tabs; drag to folder pins. |
| Space footer |32px footer,Library control,Space icons,add menu;selected icon translucent tile | Profile boundary enforced;context menu supports rename/theme/position/delete/move current tab. |
| Palette |590px maximum,12px shell corners,8px padding,48px input row,15px input,shared translucent selected row | Centered in content area;live page stays visible;no opaque dim screenshot;keyboard target survives changes. |
| Theme editor |Bottom-left anchored floating panel,dotted color canvas,appearance glyphs,pucks,exact hex controls,presets,sliders/dials | Shared rendered color recipe,physical controls without shine,haptics,opacity/blur independent,precise colors. |
| Library |Right rail matching sidebar window material,section chooser,search,section actions,close,resizer | Never a modal sheet;page stays live/sharp;layout/focus responds immediately;7sections. |

## Behavioral inventory

| Area | Required behaviors | Native responsibility / acceptance gate |
| --- | --- | --- |
| New tab/address |Distinct navigation destination;reuse empty current tab;Option+Enter opens separately;Cmd+Enter invokes AI;blank canvas auto-palette once per context;optional Home page | Shell+coordinator;submit repeatedly must not duplicate or edit wrong tab. |
| Palette scopes |All/Tabs/Spaces/Folders/Bookmarks/History/Actions;prefixes `>`/`/`,`@`,`#`;diacritic-insensitive fuzzy ranking;stable selection;recent results | Native palette;exact commands rank first,URLs rank above fuzzy tabs. |
| Palette contexts |Result actions;move/pin destinations;Back restores query/filter/index;Escape backs before close;destination toggle;custom site engines+current website | Shell;no action targets another profile;deleted targets disappear safely. |
| Sidebar keyboard |Focus/reveal,arrows/Home/End,activation,context menu,delete/close,Space selection;custom shortcuts | Native key focus + root shortcut catalog;text typing must not trigger browser shortcuts. |
| Tab management |Create/activate/rename/duplicate/close/restore/recent cycle/position shortcuts;pin/favorite/reset/replace destination;mute/sleep | Root Core/runtime actions;beforeunload honored,history restored,private state excluded. |
| Folders/Spaces/profiles |Create/rename/delete/reorder;per-profile archive inheritance;delete Space moves tabs;private session lifecycle | Shell forms + Core;never discard unrelated tabs when deleting a Space. |
| Drag reorder |Live reorder for favorites,pins,Today,folder rows;drag out of pins/favorites;cross-Space icon dwell+edge dwell;no copy of hidden source | SidebarDragSession+Core;cancel restores original,drop index is category-relative and paired split members move together. |
| Drag split |Dragging a tab to left/right of another tab creates persistent split in intended order;normal reorder remains available | Shell affordance+Core;close/unsplit removes grouping only as requested. |
| Space gesture |Native contact phases;ignore momentum;quick flick advances one neighbor;long drag crosses any count;reversal respects fingers;snap once | Native recognizer+full-width strip; no24px nudge substitute or timed snap-back. |
| Theme |Primary/secondary exact values,hue/saturation pucks,preset paging,appearance,intensity,blend,grain,opacity,blur,Space name/icon | Shared palette+Core;preview matches applied window across dark/light/high intensity;no duplicated grain. |
| Library records |Profile-scoped search/date groups/max500;open/newtab/Peek/bookmark removal;empty vs no-matches;history/archive clear confirmation | NativeLibrary;page draft/document ID/DPR/visibility retained while menus/panels open. |
| Downloads |Live progress,pause/resume/cancel,open/Finder,rename/undo,suggest filename,clear list;filename extension preserved | Native runtime+services callbacks and Library UI;actual file operations tested in disposable directory. |
| Settings |Search engine,appearance,density,sidebar/panel widths,gutter/corners,motion,sleep,archive inheritance,session restore,default browser | Core fields+root application binding;every visible control changes actual runtime behavior. |
| Data/permissions |JSON+bookmarkHTML import/export;legacy migration;private/credentials excluded;profile clear;site permissions list/revoke/clear | Root persistence/services and native forms;not a generic button with empty closure. |
| Shortcuts |One catalog for menu/palette/editor/native routing;record/reset/disable;reserved/duplicate validation;aliases;import repair | Core catalog+root registration;editor records actual event modifiers without stealing text edits. |
| Find |Floating input,next/previous,count,current match,Escape returns focus,incremental searching | Root native page find+shell overlay;not blocking NSAlert. |
| AI |Six providers,login/connection/model/options,draft+stream/cancel,saved drafts,context grants/citations/source opening,privacy | Native service-backed UI injected into Library;separate service ledger and acceptance. |
| Sync |Account/device lifecycle,separate data choices,conflicts,extension consent,revision/state/error handling | Native sync UI/service;separate service ledger and acceptance. |
| Extensions |Manager/install/update/permissions/enable/remove/pin/actions/options/sidepanel/badges/profile restrictions | Actual Chrome runtime + service bridge;not links alone;separate extension acceptance. |
| Site controls |Copy/bookmark/split/find,extension actions/pinning,Space theme,site permissions,developer tools,security/more | Original `showExtensionsMenu` contract, distinct from the supplied Arc reference; root native bridge must make each action functional. |
| Onboarding/Home |Welcome tour steps/shortcuts/preferences;home search/favorites/recent/AI entry | Native UI with retained completion;no initial fake content replacing blank canvas. |
| Accessibility |Roles/labels/selected state,focus restoration,screen reader announcements,reduce motion/transparency,contrast | Native AX inspection and physical keyboard acceptance. |

## Implementation and acceptance status — 2026-11-01

The native UI is implemented in SwiftUI/AppKit, including the original SVG glyph paths. These are implementation facts, not a declaration of complete release parity:

- Palette scopes, nested result actions, move/pin destinations, custom website searches, destination toggle, macOS shortcut glyphs, and query/selection restoration are native. Repeated Cmd+T/Cmd+L openings reset their own session and selection. The floating panel is restricted to the content bounds and does not replace the live page. AppKit scrollbars are suppressed in the palette, theme editor, and Space strip even with the macOS legacy-scrollbar preference.
- Theme editing uses a draft. Save commits Space name/icon/theme and appearance atomically; Cancel restores the saved appearance. A write error retains the draft and displays an inline error. The editor now uses the original 424px width, 218px canvas, 58px color pucks, material disclosures, paired dials, and 12-column icon chooser. Hue/saturation pucks support relative dragging and arrow keys, including Shift adjustment; dials use polar angle and the original inactive arc. Sliders, dials, pucks, and icon/preset choices provide discrete haptics.
- New Space uses the full theme form and profile chooser. The Space heading opens the all-profile Spaces manager. Profiles expose inherited or explicit archive cadence, rename, and delete. Sidebar keyboard traversal includes folders, favorites, split members, and regular tabs, with scrolling to focus.
- Space gesture recognition now resides in the pure `ZacroCore.SpaceGesture` state machine. The AppKit view forwards native phases and semantic deltas instead of maintaining a second approximate implementation. Nineteen native regression tests cover quick flicks in both directions, two-second held contact, long multi-Space drags, reversal, delayed contact phases, momentum tails, phase-less deceleration, width-scaled thresholds, edge resistance, and switching to a phase-less mouse after a completed trackpad stream. Settle animation is explicitly attached inside the nested AppKit hosting view, with the original 100–240ms distance-dependent duration. Neighbor previews retain split capsules, and Favorite visibility is scoped to split groups in the displayed Space. Physical trackpad acceptance is still required.
- The optional Home Page has profile-scoped saved pages, recent history, search, and the private-session notice. It is distinct from the default empty themed content pane. The original five-step welcome tour and once-per-blank-context command-bar opening are implemented.
- Site permissions have a native profile-scoped list, allow/block/reset per entry, and reset all. Site controls provide the original four quick actions, extension tiles and pin controls, Space theme/permissions/developer settings, and security/more controls. The extension items are supplied by the runtime; installing an extension is not considered accepted from the presence of a tile.
- Peek uses a persistent panel and hosting view. Layout updates no longer recreate the backdrop or reorder the preview on every frame. The source remains live under a theme tint, with separate circular close/expand controls and a card shadow. Opening and expansion use the original 220ms/240ms timing, cubic curve, click-origin frame, and live document resizing; reduced motion completes immediately. Accepted closure can animate a transient RAM-only viewport snapshot for 120ms after Chromium's `onClosed` signal. The tail detaches live layout callbacks, never controls logical cleanup, and is cancelled by a new Peek or immediate window teardown. No document is resized or discarded before its beforeunload decision. This new close path awaits integrated runtime verification.
- A retained AppKit frame reporter now publishes the actual content rectangle directly after native layout. It replaces the SwiftUI preference, which failed to publish initially and later produced a competing titlebar-relative origin. The parent’s rebuilt application test now visibly resizes the Chromium page beside Library while retaining the page’s form draft. Library width follows the original 260px minimum and 240px minimum page area. A separate rounded underlay casts the content shadow even when the SwiftUI page overlay is clear. The parent’s later frame trace verified that the competing `y = -24` callback is gone.
- Session recovery/save errors appear in a dismissible status strip below the browser layout, so page controls remain unobscured. Theme and permission form errors remain inside their respective editors. Privacy clears use durable operations and report write failures. Settings use the original collapsible sections, flat theme-colored actions, and custom menu selectors; resource rows use the offline favicon cache.

The fifth, sixth, seventh, and eighth integrated release builds passed. The parent’s rebuilt Peek test now shows the actual preview document, separate circular buttons, and source-tab favicon badge. Expanding retains a typed preview draft in the promoted tab; selecting the source again retains its original draft. The persistent presentation-parent override fixed the previous opaque tint-panel occlusion. The parent also confirmed that frame traces now contain only the correct `y = 4` origin. The sixth build includes the accepted-close snapshot path, capped Favorites region, and revised Find bar. A source-page fixture with content outside the card is still being checked to verify visible tint over live underlying content and accepted-close behavior.

The parent also reduced window opacity to zero through accessibility controls, observed the live tint clear, saved it, and confirmed both unchanged appearance after Save and `opacity: 0` in persisted state. This accepts the prior save-opacity regression for that case. Full theme-preview compositing is still open: at zero opacity, the preview canvas reveals its popover material while the actual window reveals the desktop. The Electron reference itself uses an opaque `--chrome` base in `.theme-preview-tile`, so matching its implementation alone does not prove matching transparency. A white transparent-pixel screenshot also cannot establish the actual desktop contrast; desktop observation is needed before changing the window material or ink.

Validation so far: all UI changes through the eighth integrated build passed the actual release typecheck/link, including theme-context, palette-lifecycle, whole-swatch paging, and the native resizers. The parent agent has observed the rebuilt application opening the command palette over a live Chromium page without the previous black top strip, and has verified Library visibly resizes the page while retaining its form draft. Further changes since the eighth build still require a full build and visual retest. End-to-end drag, physical trackpad contact/reversal, appearance/opacity extremes, Home/tour, permission persistence, extension actions, and Peek resize/promotion remain explicit native acceptance gates.

### Follow-up audit findings

The following concrete differences were found by reading the renderer action dispatcher, keyboard handlers, and corresponding CSS. The native fixes below passed the sixth integrated release build and still require interaction coverage:

- Theme Save is disabled while either visible hexadecimal field is invalid. Preset paging honors Reduce Motion and browser motion scale. Sliders use the original 12px track and 22×28px rounded rectangular thumb, with keyboard/accessibility adjustments and haptics.
- Browser menu is a 242px anchored popover in the source order, including Page actions and About. Page actions has the compact zoom row. A separate native panel supports these menus while the sidebar is hidden. Right-click address actions and keyboard Shift+F10 menus share command models with pointer context menus. Popovers support arrow/Home/End focus; Site Controls supports traversal through extension actions and pin buttons.
- Folder creation/rename enforces 60 characters, the folder/chevron crossfades, and the chevron rotates over the original 120ms while rows update immediately. Palette folder results focus that folder rather than the active tab. Durable create/rename forms retain their draft and show local write errors.
- Favorites have their own scroll region capped at the lesser of 176px and 35% of sidebar content; pinned/regular rows scroll underneath. Both live and neighboring Space pages use that structure. Keyboard traversal scrolls the appropriate region. Find now uses the original 32px bar height and 7px corner radius.
- Sidebar address, lock glyph, and edit-address input follow the active Peek. Find uses explicit theme ink. Bookmark date grouping now uses persisted creation dates, retaining Earlier for undated legacy items.
- Downloads now have the original date headers. Rename keeps its draft until the asynchronous file operation succeeds, displays errors in the form, and shows Undo only when a previous filename exists. Site Search validation stays in its own sheet. History/Archive Clear invoke coordinator operations after confirmation so Chromium history and the encrypted navigation vault can be cleared with persisted records. Clear browsing data uses the original all-or-nothing, profile-scoped confirmation; its UI is exposed only when the coordinator advertises support.
- Default-browser Settings consumes the coordinator's actual configured status. About is routed to the shared runtime action; the coordinator owns bundle/Chromium version reporting.

### Theme persistence and overlay follow-up after build six

Reading `app.js` `showSpaceForm`/`updateSpacePreview`/`closeDialog`, main `window:material-preview`, and `test/e2e/personalization.test.cjs`/`window-material.test.cjs` confirms that preview values must never enter persisted Space state. Save persists all selected values; Cancel, replacing the dialog, and changing Space restore saved material. Relaunch must restore the saved theme, and none of these operations may replace the page, erase its form draft, or fade the entire window.

The native editor binds to a value-type `BrowserSpace` draft. Only `saveTheme` submits name/icon/theme/global appearance in one durable commit; cancellation or process loss leaves the prior state on disk. Write failure retains the draft. The follow-up now also discards New Space previews on Space changes and discards any preview when another palette/dialog/Library/menu opens. New Space begins with the original default palette. Theme presentation propagates through the native chrome environment, including Library and floating palette; Space interpolation retains global appearance. Blur now displays 0–100% with the original 32 detents. Nearby primary/secondary pucks separate by the source offsets instead of obscuring each other; presets expose names, exact color values, and selected state. The parent subsequently verified Cancel visibly restores the saved theme and invalid hex disables Save. The strengthened Core regression passed: a local draft leaves memory/disk untouched, one commit saves identity/theme/appearance, and a write failure retains prior values across restart. The later context/presentation changes passed the seventh integrated build; process interruption during an open editor remains a runtime acceptance case.

During build-six interaction testing, the parent found that New Tab/Command Palette could fail to appear after a Peek/popup sequence even though Site Controls still opened. A retained native panel previously only updated its host/frame and never restored visibility if AppKit had hidden it. Follow-up code restores visibility/key status for explicit palette sessions and rejects delayed notification dismissals from an older panel. Optional `[Native overlay]` tracing records create/restore/dismiss/hide. The parent also reproduced a nested Split command closing the palette without showing the destination selector. Follow-up routes split/move/site-search directly inside the existing palette and prevents the coordinator from stealing key status afterward. In the seventh rebuilt app, the parent verified Cmd+T opens the palette and the nested Split selector retains keyboard focus. Repeated interrupted sequences remain part of the broader stress acceptance.

### Release-seven visual review and resize follow-up

The parent saved full-window screenshots at `/tmp/zacro-native-review-assets/theme-release7.png` and `theme-vibrant-release7.png`. Independent inspection confirms visible primary/secondary values, theme-colored Save and glyphs, no theme scrollbars, and stronger matching green/yellow tint in both canvas and window at 100% intensity. This is evidence for those screenshots, not a claim of all-theme or desktop-opacity equivalence. Invalid hex and Cancel were exercised separately. A clipped end preset led to a follow-up whole-swatch viewport and snap paging.

Outside-card click closes Peek in release seven. The parent verified accessibility divider increments produce a visible 60/40 split. Build8 also passed sidebar 224→240 with AX increment, →241 with Option+Right, →209 with Shift+Left, and →224 on double-click; split 50→52 with Right, →62 with Shift+Right, →13 with Home (160px pane minimum), and →50 on double-click. Pointer dragging and horizontal scrolling failed in the CUA server before valid input was delivered, so those physical interactions remain unverified. The later host reconnect removed CUA availability and temporary screenshots/logs; the observed keyboard results remain evidence, but a build8 Quit result was never obtained. The next native separator implementation matches source arrow/Home/End, Shift/Option increments, double-click reset, and Escape/window-blur cancellation. Sidebar and Library width previews stay outside BrowserStore and commit durably once a resize completes, so cancellation cannot leak an intermediate width through another save. The reusable AppKit separator passed a standalone Swift typecheck and the eighth integrated build; physical pointer and cancellation acceptance remains pending. A subsequent follow-up cancels a draft if the view is detached or directly moved between windows, and defers dismantling callbacks to avoid modifying SwiftUI state during layout.

The profile editor now displays the browser cadence for the default profile rather than its intentionally absent override; other profiles retain the inheritance choice. A Core follow-up wakes a closed retained pin selected for split view, matching the original split:toggle behavior.

### Native extension browser model

`NativeExtensionBrowser.swift` implements the source `extensions/browser.cjs` contract against `BrowserStore` and actual Chromium tab identities. It reserves unopened tabs without navigating, maps real SessionTab IDs to profile-scoped Core tabs, serializes requests per profile, and invokes native pending-request validation immediately before mutations. The native runtime owns official API argument schemas, caller/install authorization, navigation permissions, URL/title/favicon redaction, and sensitive query filtering. No JavaScript extension API shim is installed.

The coordinator supports native tab/window lookup, creation/update/removal/reordering, page history/zoom actions, approved-close callbacks, and lifecycle events. Private profiles are excluded from the extension bridge. Document-local zoom/settings requests use Chromium’s official ZoomController-backed API rather than Swift emulation; an unexpected host-forwarded settings request returns an error. Nine Core query regression cases passed, including strict boolean types, false/missing distinctions, split IDs, and logical-window aliases. Profile/request authorization is repeated after suspension points and before mutations. Official createSplit/unsplit operates on actual persistent groups, including blank tabs; logical openers, autoDiscardable, bounds/highlight events and pre-navigation native registration were included in the tenth integrated build. Build10 and its packaged engine acceptance passed; that stock-runtime acceptance does not establish custom Chrome API compatibility.

The post-build10 source batch replaces fixed window ID1 with repository-owned sessions and monotonic native window IDs. Metadata uses each owning window’s index, active tab and highlighted set. The host implements normal/popup window creation, URL arrays, tab transfer, per-window queries/updates/closure, multi-highlight, and detached/attached events. Native focus state and sourceWindowID resolve extension callers without exposing the hidden manager. The window coordinator rechecks native request authorization after transfer preparation and before its atomic ownership commit. `setSelfAsOpener` passes only the pending native request ID into a single-use document-creation reservation; Chromium verifies the live caller frame and does the real opener binding. The sidebar reflects highlighted tabs and supports Cmd/Shift selection. These changes passed integrated build12 and the 21-check stock-engine AppIntegration harness; actual custom-runtime extension and new GUI acceptance remain required.
## Runtime ownership implementation and outstanding acceptance

### Dormant tabs with stable native identities

Before the dormant-identity follow-up, `NativeExtensionBrowser.allTabData` and its publisher reserved a hidden `CefChromeBrowser` for every model tab. At the 1,000-tab limit this created unnecessary Chrome Views/WebContents. Root currently retains an about:blank WebContents when discarding, so that path already preserves its actual ID; a future genuine document destruction/rematerialization must also preserve identity. Querying or publishing topology must not materialize documents.

The following source integration passed integrated build10 and its packaged stock-runtime acceptance. Custom-runtime execution remains required:

- The native BrowserContext registry allocates real `SessionID::NewUnique()` values for dormant logical tabs in a bounded batch. Each entry retains logical ID, profile/window/index/selection/classification metadata, and an optional live WebContents observer. Absence of WebContents does not remove the logical entry. Logical close explicitly retires it; discard preserves it.
- Materialization uses a single-use, unguessable native token scoped to BrowserContext, logical ID and reserved SessionID. Swift passes it through `CefChromeBrowserOptions` into `cef_browser_view_create` extra_info. At `ChromeBrowserDelegate::OnWebContentsCreated`, before delegate/helper creation, the native hook validates the token and marks that exact WebContents. The immutable `SessionTabHelper` constructor consumes the preallocated ID. The token is removed before renderer delivery or popup inheritance. IDs are never changed after publication.
- Existing startup documents and real Chromium popups already have a SessionID. Their bounded set is adopted before reserving remaining dormant models; no conflicting synthetic ID is assigned. A later dormant→live transition retains its original ID. Native grants remain tied to the real WebContents and are revoked when that document is destroyed.
- `NativeExtensionBrowser` builds queries/events from Core plus the native identity catalog, without calling `reservePage`/`ready` for each dormant tab. Native URL/title redaction retains the existing no-WebContents model-URL permission path. Only document operations materialize a page, with coalesced creation and post-await profile/request validation. Native document APIs continue using official Chromium handlers and explicit unloaded-document behavior.
- Root page construction now prepares the reservation before calling the synchronous CEF factory; a post-`ready` hook alone is too late to choose an immutable SessionID. Existing `page(for:) -> ChromiumPage?` schedules one coalesced creation task and returns nil until the page is available, then requests layout. Actual document operations await `materializePage`; query/publisher paths do not use a page factory. Native registration verifies the reserved ID before first navigation, and catalog synchronization adopts existing real pages before allocating dormant IDs. The stock-runtime path remains supported without pretending it implements the custom registry.

Engine owns the native registry and Swift creation APIs; Core owns the pinned SessionTabHelper/CEF hook patch; interface owns lazy metadata/publisher coordination; root owns deferred page construction. Required tests: querying 1,000 tabs creates zero additional views; first activation creates only its requested page; IDs survive discard/reload/reorder; simultaneous requests coalesce; expired/replayed/cross-profile tokens fail; true popup adoption preserves its existing ID; closing a dormant tab emits one removal; permissions are never inherited from a replaced document.

### Real multiple browser windows

A second NSWindow sharing the current global `activeSpaceID`/`activeTabID` would make both shells follow one selected page. Separate copies of BrowserStore would instead race persistence and duplicate profile/tab ownership. Neither is the implementation route.

- Core source now provides shared repository ownership for profiles, Spaces, tabs, folders, settings and durable writes, plus a window record/session containing window ID, active Space/tab and explicit tab ownership. A per-window BrowserStore façade can project the existing `state.activeSpace`/`activeTab` interface so views do not require a wholesale rewrite. Mutations merge through the one authoritative repository; scope-sensitive operations act on their façade's window. Private window records remain ephemeral.
- Engine source now provides `ChromiumWindowContext` records keyed by stable session window ID, with independent NSWindow, open/closing status, layout and close callbacks. Pages carry ownerWindowID. A retained CEF document can be reparented between shell windows without reloading; profile contexts and the broker remain shared. Closing one window asks only its owned documents about beforeunload. Quit drains every window and shared service once.
- ApplicationCoordinator keeps app lifecycle, persistence and shared services. A BrowserWindowCoordinator owns one BrowserShell, BrowserActions, content geometry, Library/palette/Peek/find state, selection and focus. The menu/shortcut router targets the key window; background windows keep their selections and forms.
- NativeExtensionBrowser resolves logical window IDs to those records and tab ownership, replacing the fixed ID1 policy. `windows.create` constructs the complete existing BrowserShell, accepts URL arrays or transfers an existing tab as the official schema allows, respects focus/bounds/type, and commits ownership atomically. `tabs.move` transfers the actual retained document and emits detached/attached events. `windows.remove` awaits that window's veto-aware close; global profile deletion still closes its pages across all windows.

Shared repository/window source follows the completed build10 identity integration. Required acceptance includes independent active tabs/themes/palettes in two windows, retained form/history on tab transfer, correct extension current/last-focused queries and events, close veto confined to one window, and session/private restoration rules. The post-build10 source passed integrated build12 and the stock-engine AppIntegration harness. The custom-runtime and hardware/GUI cases remain separate release gates.

### Chrome tab groups — source integration pending acceptance

Post-build11 source adds window/profile-owned `BrowserTabGroup` records separate from Space folders. Grouping and ungrouping include both members of a persistent split; members keep their Space assignment, and each sidebar renders its visible subset. Headers use the existing tabbar styling, with collapse/expand, a color swatch picker, rename and ungroup actions. Cmd/Shift-selected tabs can be grouped from their tab menu. Dragging onto a group adds the tab; dragging out clears membership in the same move mutation. Keyboard traversal and Space swipe previews include group containers and retain the joined split-tab shape.

`NativeExtensionBrowser` synchronizes groups before tab metadata. Chromium allocates real session group IDs and applies official schema/permission checks and title-pattern matching. Host APIs implement tabs.group/ungroup and tabGroups.get/query/update/move against the authoritative repository. Whole-group transfers retain their native identity and document instances; cross-window events are removed/created rather than group.onMoved. Group ID metadata is sent with tab registration and returned in tab queries. Color/collapse/shared filters are exact, and shared is false because no cloud group-sharing service exists. The group UI/host passed integrated build12. Core regression tests cover persistence, scope, rollback, contiguous order, split expansion and transfer, and the full 162-case Core/Services suite passed. Packaged custom-runtime extension and group GUI acceptance remain required; this is not a compatibility claim.

## Reference acceptance details

`library.test.cjs`: Library chooser stays inside sidebar and supports typeahead; page id/bounds/DPR/visibility/form draft remain unchanged; chooser stays open during updates; History search focuses initially,Down enters rows,Up returns to search;Escape closes chooser then panel and restores triggering control;date headers say Today;downloads open panel automatically;rename+undo change actual file;no-match state distinct from empty.

`motion.test.cjs`: rapid open/close/switch actions preserve latest state;focus changes immediately;no delayed autofocus overwrite;folder state+focus update together;animations100–280ms,no delay;Reduce Motion removes active animations;interrupted layout settles without stale page captures.

`compact-layout.test.cjs`: sidebar-hidden toggle remains reachable;page gutter/radius adapt;peek/split/Library geometry stays inside content;content browser document is retained during native layout changes.

## Command catalog reference

The following original IDs must be routed to real native handlers. Menu, palette, shortcut editor, and key handling use this same identity; aliases/custom overrides must not drift.

| ID | Label | Category |
| --- | --- | --- |
| `command-palette` | Command palette | Navigation |
| `paste-search` | Paste and search | Navigation |
| `open-location` | Edit current address | Navigation |
| `sidebar-toggle` | Toggle sidebar | Navigation |
| `focus-sidebar` | Focus sidebar | Navigation |
| `reveal-tab` | Reveal tab in sidebar | Navigation |
| `focus-chrome` | Focus page / browser controls | Navigation |
| `copy-url` | Copy page address | Navigation |
| `next-space` | Next Space | Spaces |
| `previous-space` | Previous Space | Spaces |
| `new-space` | Create Space | Spaces |
| `new-folder` | Create folder | Spaces |
| `new-private-space` | New private session | Spaces |
| `close-tab` | Close tab or preview | Tabs |
| `reopen-tab` | Restore closed tab | Tabs |
| `recent-tab` | Next recent tab | Tabs |
| `previous-recent-tab` | Previous recent tab | Tabs |
| `pin-tab` | Pin / unpin tab | Tabs |
| `duplicate-tab` | Duplicate tab | Tabs |
| `rename-tab` | Rename tab | Tabs |
| `move-tab` | Move tab | Tabs |
| `mute-tab` | Mute / unmute tab | Tabs |
| `split` | Split view | Tabs |
| `peek-close` | Close preview | Tabs |
| `peek-promote` | Open preview as tab | Tabs |
| `reload` | Reload page | Page |
| `stop` | Stop loading | Page |
| `find` | Find on page | Page |
| `find-next` | Find next | Page |
| `find-previous` | Find previous | Page |
| `bookmark` | Bookmark page | Page |
| `save-page` | Save page as… | Page |
| `print` | Print page | Page |
| `zoom-in` | Zoom in | Page |
| `zoom-out` | Zoom out | Page |
| `zoom-reset` | Actual size | Page |
| `history` | History | Library |
| `downloads` | Downloads | Library |
| `bookmarks` | Bookmarks | Library |
| `archive` | Archived tabs | Library |
| `extensions` | Extensions | Library |
| `ai` | Ask AI / open sources | Library |
| `preferences` | Settings | Browser |
| `shortcuts` | Keyboard shortcuts | Browser |
| `browser-menu` | Browser menu | Browser |
| `onboarding` | Welcome tour | Browser |
| `open-browser` | Open browser window | Browser |
| `close-window` | Close window | Browser |
| `fullscreen` | Toggle full screen | Browser |

Additional multiline entries: `history-back`, `history-forward`, `next-tab`, `previous-tab`, `force-reload`, `developer-tools`; positional commands `tab-1`…`tab-9`, `space-1`…`space-9`.

## Renderer function index

Every named renderer function is retained here to prevent small interaction paths from disappearing in the rewrite. Source line references are from the current branch. Functions delegated to runtime/services remain part of total parity.

| Function | Reference line |
| --- | --- |
| `maybeOpenBlankPalette` | `src/renderer/app.js:273` |
| `presentedSpaceAppearance` | `src/renderer/app.js:307` |
| `releaseSpaceAppearanceMaterial` | `src/renderer/app.js:312` |
| `holdSpaceAppearanceMaterial` | `src/renderer/app.js:326` |
| `clearSpaceAppearance` | `src/renderer/app.js:353` |
| `beginSpaceAppearance` | `src/renderer/app.js:360` |
| `paintSpaceAppearance` | `src/renderer/app.js:375` |
| `settleSpaceAppearance` | `src/renderer/app.js:380` |
| `clearSpacePreview` | `src/renderer/app.js:402` |
| `inertSpacePage` | `src/renderer/app.js:411` |
| `clearSpaceTransition` | `src/renderer/app.js:433` |
| `resetSpaceFeedback` | `src/renderer/app.js:440` |
| `interruptSpaceScroll` | `src/renderer/app.js:483` |
| `paintSpaceFeedback` | `src/renderer/app.js:489` |
| `prepareSpaceTransition` | `src/renderer/app.js:553` |
| `finishSpaceTransition` | `src/renderer/app.js:610` |
| `animateSpaceTransition` | `src/renderer/app.js:613` |
| `captureSpacePresentation` | `src/renderer/app.js:641` |
| `restoreSpacePresentation` | `src/renderer/app.js:654` |
| `handleSpaceGesture` | `src/renderer/app.js:665` |
| `settleSpaceGesture` | `src/renderer/app.js:698` |
| `nativeSpaceGesturePhase` | `src/renderer/app.js:701` |
| `nativeSpaceWheel` | `src/renderer/app.js:744` |
| `onSpaceScroll` | `src/renderer/app.js:760` |
| `hostname` | `src/renderer/app.js:829` |
| `displayURL` | `src/renderer/app.js:836` |
| `favicon` | `src/renderer/app.js:845` |
| `tintFavorite` | `src/renderer/app.js:866` |
| `dateLabel` | `src/renderer/app.js:899` |
| `bytes` | `src/renderer/app.js:914` |
| `toast` | `src/renderer/app.js:924` |
| `invoke` | `src/renderer/app.js:930` |
| `safely` | `src/renderer/app.js:947` |
| `clearPageBackdrop` | `src/renderer/app.js:950` |
| `showPageBackdrop` | `src/renderer/app.js:957` |
| `motion` | `src/renderer/app.js:1018` |
| `focusDescriptor` | `src/renderer/app.js:1035` |
| `restoreFocus` | `src/renderer/app.js:1047` |
| `isolateDialog` | `src/renderer/app.js:1068` |
| `restoreFocusAround` | `src/renderer/app.js:1075` |
| `setTheme` | `src/renderer/app.js:1084` |
| `previewWindowMaterial` | `src/renderer/app.js:1142` |
| `applyState` | `src/renderer/app.js:1155` |
| `render` | `src/renderer/app.js:1271` |
| `sidebarKeyboardItems` | `src/renderer/app.js:1287` |
| `prepareSidebarKeyboard` | `src/renderer/app.js:1292` |
| `focusSidebar` | `src/renderer/app.js:1302` |
| `handleSidebarKeyboard` | `src/renderer/app.js:1328` |
| `tabLabel` | `src/renderer/app.js:1384` |
| `peekSourceBadge` | `src/renderer/app.js:1389` |
| `renderSpacePage` | `src/renderer/app.js:1400` |
| `renderDraggedSpace` | `src/renderer/app.js:1462` |
| `renderSidebar` | `src/renderer/app.js:1498` |
| `extensionBadgeColor` | `src/renderer/app.js:1610` |
| `pinnedExtensions` | `src/renderer/app.js:1620` |
| `renderPinnedExtensions` | `src/renderer/app.js:1629` |
| `renderToolbar` | `src/renderer/app.js:1641` |
| `renderWorkspace` | `src/renderer/app.js:1692` |
| `paintPeekMotion` | `src/renderer/app.js:1746` |
| `renderHome` | `src/renderer/app.js:1765` |
| `expandedSidebarWidth` | `src/renderer/app.js:1796` |
| `effectiveSidebarHidden` | `src/renderer/app.js:1811` |
| `chromeTargets` | `src/renderer/app.js:1817` |
| `currentChromeWidths` | `src/renderer/app.js:1832` |
| `finishChromeMotion` | `src/renderer/app.js:1839` |
| `animateChrome` | `src/renderer/app.js:1845` |
| `syncLayout` | `src/renderer/app.js:1875` |
| `empty` | `src/renderer/app.js:1946` |
| `visibleSplitGroup` | `src/renderer/app.js:1949` |
| `splitGeometry` | `src/renderer/app.js:1956` |
| `syncSplitDivider` | `src/renderer/app.js:1966` |
| `cancelSplitResize` | `src/renderer/app.js:1998` |
| `saveSplitRatio` | `src/renderer/app.js:2004` |
| `clampRailWidth` | `src/renderer/app.js:2073` |
| `saveRailWidth` | `src/renderer/app.js:2087` |
| `cancelRailResize` | `src/renderer/app.js:2128` |
| `panelHeader` | `src/renderer/app.js:2173` |
| `patchAIContent` | `src/renderer/app.js:2178` |
| `renderPanel` | `src/renderer/app.js:2220` |
| `renderResourcePanel` | `src/renderer/app.js:2323` |
| `libraryGroups` | `src/renderer/app.js:2349` |
| `renderDownloads` | `src/renderer/app.js:2364` |
| `selectOptions` | `src/renderer/app.js:2377` |
| `settingSelect` | `src/renderer/app.js:2385` |
| `aiProviderName` | `src/renderer/app.js:2388` |
| `isLocalAPIEndpoint` | `src/renderer/app.js:2403` |
| `syncAPIKeyRequirement` | `src/renderer/app.js:2420` |
| `renderAIConnection` | `src/renderer/app.js:2436` |
| `configureAIConnection` | `src/renderer/app.js:2476` |
| `renderCustomization` | `src/renderer/app.js:2507` |
| `archiveSelect` | `src/renderer/app.js:2565` |
| `renderSettings` | `src/renderer/app.js:2587` |
| `renderExtensions` | `src/renderer/app.js:2625` |
| `aiPageGrant` | `src/renderer/app.js:2671` |
| `aiContextStale` | `src/renderer/app.js:2675` |
| `rememberAIDraft` | `src/renderer/app.js:2681` |
| `prepareDisconnectedQuestion` | `src/renderer/app.js:2688` |
| `setAIContext` | `src/renderer/app.js:2716` |
| `openAIIntent` | `src/renderer/app.js:2746` |
| `aiTurnContext` | `src/renderer/app.js:2781` |
| `renderAnswer` | `src/renderer/app.js:2790` |
| `renderAI` | `src/renderer/app.js:2838` |
| `openPanel` | `src/renderer/app.js:2925` |
| `closePanel` | `src/renderer/app.js:2960` |
| `openDialog` | `src/renderer/app.js:2978` |
| `closeDialog` | `src/renderer/app.js:3019` |
| `openPopover` | `src/renderer/app.js:3045` |
| `dismissDialog` | `src/renderer/app.js:3060` |
| `formDialog` | `src/renderer/app.js:3071` |
| `confirmDialog` | `src/renderer/app.js:3088` |
| `field` | `src/renderer/app.js:3103` |
| `showSpaces` | `src/renderer/app.js:3106` |
| `showSpaceForm` | `src/renderer/app.js:3120` |
| `readSpaceTheme` | `src/renderer/app.js:3172` |
| `themeColorCoordinates` | `src/renderer/app.js:3184` |
| `themeColorHex` | `src/renderer/app.js:3201` |
| `themeHaptic` | `src/renderer/app.js:3210` |
| `installThemeControls` | `src/renderer/app.js:3213` |
| `updateSpacePreview` | `src/renderer/app.js:3356` |
| `showProfiles` | `src/renderer/app.js:3420` |
| `showMenu` | `src/renderer/app.js:3427` |
| `showAddMenu` | `src/renderer/app.js:3436` |
| `showPageMenu` | `src/renderer/app.js:3445` |
| `showExtensionsMenu` | `src/renderer/app.js:3457` |
| `renderPageMenu` | `src/renderer/app.js:3496` |
| `showLibrary` | `src/renderer/app.js:3515` |
| `syncLibraryChooserAnchor` | `src/renderer/app.js:3518` |
| `closeLibraryChooser` | `src/renderer/app.js:3529` |
| `openLibraryChooser` | `src/renderer/app.js:3546` |
| `showLibraryChooser` | `src/renderer/app.js:3601` |
| `showDownloadMenu` | `src/renderer/app.js:3615` |
| `toggleSidebar` | `src/renderer/app.js:3739` |
| `showSpaceMenu` | `src/renderer/app.js:3755` |
| `showTabMenu` | `src/renderer/app.js:3782` |
| `showFolderMenu` | `src/renderer/app.js:3793` |
| `showMoveTab` | `src/renderer/app.js:3802` |
| `showSplitPicker` | `src/renderer/app.js:3830` |
| `showTabSelection` | `src/renderer/app.js:3855` |
| `showPermissions` | `src/renderer/app.js:3886` |
| `stopShortcutRecording` | `src/renderer/app.js:3894` |
| `maybeOpenOnboarding` | `src/renderer/app.js:3932` |
| `showOnboarding` | `src/renderer/app.js:3942` |
| `renderOnboardingShortcuts` | `src/renderer/app.js:3957` |
| `finishOnboarding` | `src/renderer/app.js:3976` |
| `refreshShortcutEditor` | `src/renderer/app.js:3981` |
| `showShortcuts` | `src/renderer/app.js:3985` |
| `renderShortcutRows` | `src/renderer/app.js:3996` |
| `recordShortcut` | `src/renderer/app.js:4019` |
| `recordedAccelerator` | `src/renderer/app.js:4035` |
| `saveShortcut` | `src/renderer/app.js:4084` |
| `commandActionOptions` | `src/renderer/app.js:4166` |
| `pushCommandStep` | `src/renderer/app.js:4318` |
| `refreshCommandStep` | `src/renderer/app.js:4332` |
| `backCommandStep` | `src/renderer/app.js:4339` |
| `enterCommandContext` | `src/renderer/app.js:4350` |
| `commandTask` | `src/renderer/app.js:4355` |
| `closeAndRunCommand` | `src/renderer/app.js:4358` |
| `showCommandDestinations` | `src/renderer/app.js:4362` |
| `showCommandResultActions` | `src/renderer/app.js:4402` |
| `enterSiteSearch` | `src/renderer/app.js:4479` |
| `siteSearches` | `src/renderer/app.js:4484` |
| `showSiteSearches` | `src/renderer/app.js:4487` |
| `showSiteSearchForm` | `src/renderer/app.js:4502` |
| `fuzzyScore` | `src/renderer/app.js:4537` |
| `commandOptions` | `src/renderer/app.js:4568` |
| `openCommand` | `src/renderer/app.js:4803` |
| `renderCommands` | `src/renderer/app.js:4828` |
| `selectCommand` | `src/renderer/app.js:4905` |
| `commitNavigation` | `src/renderer/app.js:4911` |
| `newTab` | `src/renderer/app.js:4928` |
| `showHomePage` | `src/renderer/app.js:4931` |
| `newPrivate` | `src/renderer/app.js:4941` |
| `openFind` | `src/renderer/app.js:4952` |
| `closeFind` | `src/renderer/app.js:4962` |
| `cancelAIStreamFrame` | `src/renderer/app.js:4969` |
| `invalidateAIRequest` | `src/renderer/app.js:4973` |
| `shouldFollowAI` | `src/renderer/app.js:4979` |
| `renderAIUpdate` | `src/renderer/app.js:4983` |
| `askAI` | `src/renderer/app.js:4988` |
| `handleEvent` | `src/renderer/app.js:5081` |
| `handleAction` | `src/renderer/app.js:5318` |
| `clearDragFeedback` | `src/renderer/app.js:6421` |
| `clearFavoriteReflow` | `src/renderer/app.js:6426` |
| `favoriteInsertion` | `src/renderer/app.js:6439` |
| `paintFavoriteReflow` | `src/renderer/app.js:6489` |
| `clearRowReflow` | `src/renderer/app.js:6540` |
| `rowInsertion` | `src/renderer/app.js:6552` |
| `paintRowReflow` | `src/renderer/app.js:6587` |
| `clearDragSpaceHover` | `src/renderer/app.js:6625` |
| `dragSpaceTarget` | `src/renderer/app.js:6630` |
| `hoverDragSpace` | `src/renderer/app.js:6651` |
| `dragDestination` | `src/renderer/app.js:6692` |
| `endTabDrag` | `src/renderer/app.js:6792` |
| `showAuth` | `src/renderer/app.js:6832` |
| `showAbout` | `src/renderer/app.js:6858` |

### Post-build12 native document and saved-session follow-up

The current source accepts exceptional extension navigation destinations only from a live Chromium approval. Host requests retain exact URL provenance (installation incarnation plus URL digest), and root revalidates it before loading/restoring; ordinary addresses keep the existing policy and imports do not inherit grants. Create/update/window URL arrays and duplicate carry matching navigation entries and saved-pin provenance. Browser/extension/file/embedded page labels describe the actual document rather than displaying “No page open.” Native prepareDocument requests wake only their scoped real document, then return control to Chromium's original document API implementation.

Library now exposes saved windows with date groups, tab/profile labels, search, keyboard selection and the root reopening callback. Restoring an archived tab uses a durable Core transaction and preserves its navigation history. The host sessions API exposes profile-scoped archive, retained closed pins and parked windows through opaque close-instance tokens; nested parked tabs are individually restorable, persistent split partners remain together, and live identities are reserved only after restoration. Native code validates official Session/Device schemas and recursively scrubs closed-tab metadata without a live activeTab grant. Browser session sync is not configured, so the device list is empty. A parked window containing another profile is not exposed as a restorable window to the requesting extension. Source includes sessions.onChanged and deprecated tab selection/highlight event aliases; actual custom-runtime acceptance remains pending.

Library download rows recognize the runtime's complete state, retain interrupted Resume only when Chromium reports canResume, and suppress Open/Rename/Suggest for blocked downloads. Bookmark removal routes through the shared native BookmarkModel operation. Automatic Bookmarks/Downloads refresh errors have an accessible inline status row; user-triggered errors remain in their operation UI. Extension action badges use the owning window context, so closing the primary window does not disable actions in a surviving sibling. These post-build12 changes passed the integrated release13 Swift build. The packaged stock-runtime application acceptance passed 26 checks and exited successfully, including Electron import, saved-window reopening and AI window ownership. Execution against the custom extension runtime remains a separate gate.


### Post-build13 retained Peek topology and native action follow-up

The current source exposes a retained Peek as a distinct virtual tab backed by its real Chromium document and immutable native tab ID. Presenting it makes only that document active; activating its source through the extension API hides the presentation while retaining the preview renderer, history, mute state and draft. Ordinary sidebar source activation reveals it again. Structural tab actions promote the preview into the persistent collection, synchronously transferring its native identity and event snapshot before catalog publication. Asynchronous catalog results are discarded when ownership or logical identity changed while the native request was pending. Closed-window session metadata includes retained preview documents; nested preview restoration keeps the source and any persistent split together.

The extension acceptance fixture uses actual Chromium APIs to check source/preview activation, scripting, per-tab zoom, capture, promotion identity and close behavior. It is wired into the application harness but has not yet executed against the custom framework. The stock-runtime harness separately exercises presentation retention and draft/mute preservation. The native extension action callback captures the initiating mouse event's screen rectangle before any asynchronous work; keyboard invocations use the owning window's toolbar fallback. Native document-safety state, rather than UI guesswork, guards automatic unload while an extension popup or side panel is open.

Contextual bookmark actions route to the canonical native BookmarkModel. Native-only Palette/Home actions activate or duplicate the existing document with its provenance instead of converting its address into a web search. These follow-ups passed the integrated release14 Swift build (103.98 seconds). The packaged stock-runtime application harness passed 30 checks and exited successfully, including retained preview selection/draft/mute behavior. The real extension API fixture remains gated on the custom framework. No new visual or physical trackpad acceptance is claimed while Computer access is unavailable.


### Post-build14 native extension management follow-up

The native Extensions Library now contains command recording, removal, media-key selection and scope controls backed by Chromium CommandService. Recorder validation follows Chromium's allowed key/modifier vocabulary; Chromium's localized display text is never reused as a serialized accelerator. Scope-only changes omit the keybinding, externally managed global bindings stay read-only, and new shortcuts conflicting with Zacro's current browser bindings are rejected inline. Developer mode exposes inspectable native extension views using their actual renderer identity. The separate user-scripts permission, native disabled/blocked reasons and managed-policy notices come from Chromium's current extension snapshot. These changes have syntax parsing only; integrated typechecking and native command execution are pending. In particular, editing preferences does not prove extension keyboard dispatch from the Swift sidebar, and options-page presentation is being routed away from the hidden management document.

The shared options presenter now handles both the Library action and `runtime.openOptionsPage`. It obtains the installed manifest's native approval, revalidates its installation incarnation before model mutation, and creates or reuses a registered 850×650 popup containing the real extension document. Pending callers retain independent authorization checks. This preserves the original managed settings-window experience without exposing the hidden management document as a visible browser window. Custom-runtime execution remains pending.

The next UI batch also derives drag previews from current tabs, reapplies the destination after tab metadata changes, clears the old reflow on Space navigation, and cancels when the dragged tab or profile disappears. Its 140ms reflow respects the browser Motion setting and macOS Reduce Motion. A retained but hidden Peek no longer blocks a split drop. Core separately translates per-window drop positions to canonical insertion positions; the second-window reorder/category/restart regression passed with the complete 194-test suite. UI syntax parsing passed, but physical drag, pointer reflow stability and visual animation acceptance remain unverified.

This batch passed the integrated release15 Swift build (107.31 seconds). Packaged acceptance then exposed a CEF flattened-session response issue in the new real-PDF path; that engine issue is being corrected before the next combined acceptance run. AppKit popover motion and SwiftUI drag-source retention across category changes still require actual input/visual testing before equivalence can be claimed.

### Post-build15 presentation and shortcut follow-up

Popup-kind windows now derive a content-only shell from their owned window record. They mount the document and Find controls without sidebar, Library, floating reveal, onboarding, or command-palette presentation; no shared settings change to produce that layout. Root supplies the standard titlebar and zero native content corner radius. The command palette now includes the original 4px/0.99 entry transform, Motion-scaled result scrolling and selected description/icon ink. Increased Contrast promotes muted text and adds the original selection cues while ordinary and drag styling keeps its outline-free presentation.

The native extension shortcut cache refreshes from Chromium on registry, installation and command changes; failed or stale snapshots cannot remain matchable. The shell's synchronous matcher returns only genuine native command descriptors, with actual execution revalidated by Chromium. Browser and extension shortcut recording wait for native suspension before accepting keys. Because Chromium combines per-profile registry flags with a process-wide global accelerator listener, the capture coordinator uses engine-wide leases, suspends current window profiles, serializes transitions, and resumes every affected registry only after the final editor ends. A failed resume remains unavailable for dispatch and can be retried. Inactive-profile focus is cleared before catalog synchronization so a failed topology refresh cannot leave its shortcut registry active.

The post-build15 changes passed integrated release16 typechecking/linking (105.33 seconds). The packaged stock-runtime application acceptance passed all 36 checks, and engine acceptance passed all 26 checks, including the corrected real-PDF path. Actual custom-runtime command/capture execution remains pending; no new GUI, physical trackpad, or visual acceptance is claimed.


### Post-build16 source audit follow-up

Shortcut recording now observes loss of its original key window and application focus, including the asynchronous native-suspension preparation phase. It ends the capture and releases its engine-wide lease; it does not depend on AppKit replacing the first responder. Browser editor state follows that cancellation, delayed capture setup cannot steal focus into a background window, and per-capture identity prevents an old resign callback cancelling a newly recorded shortcut in the same row.

The Space footer now bounds its icons in a scrollbar-free horizontal region and reveals the selected or keyboard-focused Space, using the source's fixed 24×28px targets. This prevents a large Space collection from widening the sidebar or squeezing its controls. Neighboring Space previews now retain Peek favicon badges, loading/sleep status, saved-pin indicators and compact row heights. Actual normal/pinned-tab loading uses a per-document runtime set; Favorites keep their site logo and dim when sleeping. Repeated Find commands use a presentation generation to restore key focus and select the existing query. Deferred empty-page palette opening rechecks dialogs and drag state before opening.

Native press feedback now uses the source's 0.96/0.985 scales and 100ms curve for Favorites, Space dots, tab/New Tab rows, Home links and action menus, respecting both Motion and Reduce Motion. The palette entrance includes the source opacity fade. Favorite hover/shadow states and remaining action glyph aliases are aligned to the source. Downloads search-to-row keyboard navigation now targets real focusable rows, scrolls them into view, and omits empty action menus. The separately hosted Space strip explicitly receives Space ink, accent, appearance and theme values. These follow-ups passed integrated release17; the parent reported all 42 packaged application checks and the full 200-case Core/Services suite passing at checkpoint `8b19d5a`. Physical input and visual comparison remain separate gates.

The audit also identified a genuine extension routing gap: Chromium can synthesize a disabled action for an actionless extension, so an unconditional action invocation can target the hidden native toolbar fallback. Source behavior is usable action, then native side panel, then options, then management; pinning requires a genuine action. The native tile routing now consumes genuine action/side-panel metadata, queries default options when no page exists, and follows that fallback order. Disabled real-action extensions can still be pinned, synthetic-only actions cannot, and pinned tiles invoke only usable real actions. Root supplies actual selected-page materialization for side-panel opening; execution awaits the custom runtime. Normal sidebar insertion/reposition/activation motion outside dragging still needs an explicit equivalent of the source's 140ms/110ms row animation. SwiftUI drag-source retention across category/Space changes, actual desktop/theme-preview compositing and hardware trackpad gestures remain separate runtime/visual gates.


Tracing the original native macOS bridge confirms that its Background blur control also sets `NSVisualEffectView.alphaValue`, after mapping 0–32 to 0–1 (`native/macos-bridge.mm`, `SetEffects`). The Swift material strength follows that mechanism; an arbitrary backdrop-radius API is not an original implementation requirement. This does not waive actual preview/desktop compositing checks.

### Post-build17 source audit follow-up — awaiting integrated validation

Find now reserves the original 40px top row instead of covering page controls; the 32px bar stays at y=4, and closing restores the configured gutter. Popup windows follow the same Find reservation. Library opening focuses its search or section chooser, and closing restores a still-existing sidebar opener (falling back to Library), or asks the coordinator to focus the page when the sidebar is hidden. A newer dialog, palette, menu, or Find request prevents that restoration from stealing focus.

Palette Tab/Shift+Tab now consumes the event only for a real context transition; otherwise AppKit traverses controls. Marked-text composition is left to the input method. Home tabs remain searchable without appearing as invalid split candidates, unloaded pins are labelled as opening rather than already loaded, and asynchronous Peek failures reach the dismissible shell error strip. Editor Escape follows the close action, including atomic onboarding completion with an inline error if persistence fails.

Ordinary sidebar mutations now have source-timed 140ms insertion/reflow and 110ms selected-row feedback. These animations are suppressed during Space transitions and gesture/native-drag handling; they animate SwiftUI row presentation, never the browser document. Favorites show the 17px Peek logo at the tile's top-right, while ordinary tabs retain the 14px badge on their favicon. New Tab displays the actual customized shortcut on hover/focus. These changes passed syntax and whitespace checks, but not yet the integrated release typecheck or a rendered animation comparison.

The drag-retention audit found that switching an active `spacePage` to its preview branch removed the original SwiftUI drag source, and the balanced Favorite row hierarchy could reparent it during live reflow. The new `NativeSidebarDragController` moves native-session ownership to a retained AppKit source attached directly under the owning window. Row anchors identify the pressed tab; after a 4px threshold, the native session carries its exact text identifier and a backing-scale snapshot of that controlled sidebar row. SwiftUI continues to render live reorder placement independently. Mouse-down/click behavior is left intact, Reduce Motion suppresses the cancel return animation, and window-close/drag-end cleanup is exactly once. The AppKit source and seven attachment/reparent/cancel/drop/UTF8 acceptance helpers passed isolated typechecking; the parent will run those checks in the packaged app. Actual pointer routing, button-tracker interaction and successful physical cross-Space/category drops remain explicit acceptance gates.

The error/loading audit found that a retained Chromium document alone omitted the source browser's failure UI. `NativePageErrorView` restores the themed failure card, retry/edit-address controls and scrollable small-window layout; Peek renders its corresponding card inside the existing tint panel. Root now supplies dedicated main-frame document errors and hides the failed native document without discarding history. A retained, non-key, mouse-pass-through child panel draws the original two-pixel, 32%-width, 1.6-second loading strip above each actually loading Chromium window, including Peek. Cancellation and close-preparation errors must not populate this UI. This integration has parsed but awaits the full build and real failure/retry fixture.

The palette also clears the previous profile's query, scope, context and Site Search draft when profiles change. Find leaves marked-text composition commands to AppKit. Home now scrolls at short window heights instead of clipping saved/recent controls. A further performance task is queued: render only the visible neighboring Space pages, with explicit per-Space scroll restoration, rather than rebuilding every offscreen Space tree during each gesture frame.
