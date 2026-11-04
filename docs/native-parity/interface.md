# Native interface parity ledger

The Electron application is the behavioral and visual reference. A successful build is not evidence of parity. This ledger records the actual reference contracts and the native implementation/acceptance work. No row may be called complete solely because a control exists.

## Current evidence — 2026-11-04, app 70 and foreground blocker

The [verification record](verification.md) retains historical builds, exact failures and evidence. This summary supersedes older pending/current wording.

- App 70 packaged without warnings in 126.30 seconds, with valid plist/deep signatures and the validated 66 framework. Its genuine loopback media retry passed **10 checks**, extension host passed **28**, and engine/window-transfer/scoped AX passed **51/9/11**. All browsers exited normally; the owned TURN child also exited 0 without forced termination.
- Graphics/motion 68 passed **155 focused checks** and real Computer Use/raw-pixel review: the bright pane edge and idle 5pt rail stripe were absent, clip/shadow remained, and the shared no-overshoot animation curve used active-only display links. Those sources are unchanged in 70. Historical screenshots retain their original build identity.
- Full 69 failed only its RTC data/media check (897 reported, 896 true); mDNS resolution was observed, but TCC denial was not proven. The product's local-network purpose text grants no entitlement or permission. Full/media acceptance uses a separately supplied host coturn executable with owned loopback-only authentication, sockets and cleanup; no browser privacy policy is relaxed.
- Full 70 and its retry stopped at foreground readiness before feature fixtures. All apps/helpers have exited, and strict full acceptance remains open. Read-only metadata shows SecurityAgent frontmost; its dialog content/cause is unconfirmed, and the user cancellation request is unanswered. No security/password/grant automation occurred.
- Core/Services remains **321 passing tests**. Prior native extension, interface, Peek, history, split and AX passes keep their original build identities and do not certify every Chrome extension or production Keychain behavior. Physical trackpad/haptic/VoiceOver gates remain distinct.

Framework 66 remains SHA-256 `29f8ff0b9f38d9ac2ac89e2a9c8b05c0e3b28f1e12b32e5347262e651b71557d`, with 124 native inputs, 240 resource files and four symlinks. Both delivered `dist` apps remain build 40. Performance optimization remains deferred; no full-release or distribution certification is claimed.

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

## Implementation chronology — 2026-11-01

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

### Post-build17 source audit follow-up

Find now reserves the original 40px top row instead of covering page controls; the 32px bar stays at y=4, and closing restores the configured gutter. Popup windows follow the same Find reservation. Library opening focuses its search or section chooser, and closing restores a still-existing sidebar opener (falling back to Library), or asks the coordinator to focus the page when the sidebar is hidden. A newer dialog, palette, menu, or Find request prevents that restoration from stealing focus.

Palette Tab/Shift+Tab now consumes the event only for a real context transition; otherwise AppKit traverses controls. Marked-text composition is left to the input method. Home tabs remain searchable without appearing as invalid split candidates, unloaded pins are labelled as opening rather than already loaded, and asynchronous Peek failures reach the dismissible shell error strip. Editor Escape follows the close action, including atomic onboarding completion with an inline error if persistence fails.

Ordinary sidebar mutations now have source-timed 140ms insertion/reflow and 110ms selected-row feedback. These animations are suppressed during Space transitions and gesture/native-drag handling; they animate SwiftUI row presentation, never the browser document. Favorites show the 17px Peek logo at the tile's top-right, while ordinary tabs retain the 14px badge on their favicon. New Tab displays the actual customized shortcut on hover/focus. These changes passed integrated release18 typechecking and packaged acceptance. A rendered animation comparison and physical input acceptance remain separate gates.

The drag-retention audit found that switching an active `spacePage` to its preview branch removed the original SwiftUI drag source, and the balanced Favorite row hierarchy could reparent it during live reflow. The new `NativeSidebarDragController` moves native-session ownership to a retained AppKit source attached directly under the owning window. Row anchors identify the pressed tab; after a 4px threshold, the native session carries its exact text identifier and a backing-scale snapshot of that controlled sidebar row. SwiftUI continues to render live reorder placement independently. Mouse-down/click behavior is left intact, Reduce Motion suppresses the cancel return animation, and window-close/drag-end cleanup is exactly once. The AppKit source and seven attachment/reparent/cancel/drop/UTF8 acceptance helpers passed isolated typechecking and the packaged release18 application run. Actual pointer routing, button-tracker interaction and successful physical cross-Space/category drops remain explicit acceptance gates.

The error/loading audit found that a retained Chromium document alone omitted the source browser's failure UI. `NativePageErrorView` restores the themed failure card, retry/edit-address controls and scrollable small-window layout; Peek renders its corresponding card inside the existing tint panel. Root now supplies dedicated main-frame document errors and hides the failed native document without discarding history. A retained, non-key, mouse-pass-through child panel draws the original two-pixel, 32%-width, 1.6-second loading strip above each actually loading Chromium window, including Peek. Cancellation and close-preparation errors must not populate this UI. The integrated release18 run exercised actual failed-page and failed-Peek presentation, retry recovery and retained state. Root reported 61 application checks, 26 engine checks and the complete 203-case Core/Services suite passing at checkpoint `bee4e00`.

The palette also clears the previous profile's query, scope, context and Site Search draft when profiles change. Find leaves marked-text composition commands to AppKit. Home now scrolls at short window heights instead of clipping saved/recent controls. A further performance task is queued: render only the visible neighboring Space pages, with explicit per-Space scroll restoration, rather than rebuilding every offscreen Space tree during each gesture frame.


### Post-build18 bounded presentation follow-up

Space presentation now hosts only the visible pages and immediate neighbors, rather than all Space trees during every gesture frame. Trackpad feedback retains continuous offsets; selection dots animate one viewport over the original 220ms curve even for a distant target. An interrupted animation is replaced by a generation-checked transition, and profile changes remove old previews. Per-Space tab and Favorite scroll offsets survive unhosting and preview/active replacement. Only the active page writes to the cache, incomplete initial document layout cannot overwrite a saved offset, shortened content clamps, and deleted Spaces are pruned. Thirteen deterministic presentation/AppKit scroll checks passed in a non-presented standalone harness. They exercise bounded hosting with 1,000 Spaces, long travel, snapping, interruption, Reduce Motion, profile isolation and native scroll lifetime; they do not certify physical trackpad routing.

Pinned extension layout now retains the installation's genuine-action capability while per-page action metadata refreshes. Changing documents temporarily disables an action until its current native state arrives, without removing every pinned tile and shifting the sidebar. Registry/profile changes invalidate that capability. Loading-strip panels observe actual parent movement and size changes, including Peek animation. A new bounded error panel can cover only Chromium's reported document rectangle while leaving a live extension side panel visible. It retains retry and keyboard focus ownership and follows native geometry; root integration and the real side-panel failure fixture remain pending.

A controlled non-presented NSHostingView inspection found that an icon-only custom Shape in a SwiftUI Menu becomes an empty native popup button (nil image and empty title). The affected footer, Library, profile, permissions, shortcut and extension menu labels now supply template NSImages from the exact original vector paths. A second structural inspection confirms native image attachment for both icon-only and combined Library labels. Cache-display renders omit native menu-button drawing, so this is structural evidence rather than a desktop visual claim. The palette field editor also uses theme ink for its insertion caret, matching CSS auto caret color; native text-selection behavior is unchanged. All changed UI source parses, the new presentation/scroll helpers typecheck, and the bounded error/loading controllers typecheck against the built Core module. Integrated release19 passed: root reported 74 packaged application checks, 26 engine checks and the complete 212-case Core/Services suite without failures or skips at checkpoint `443b7d8`. Updated desktop render/physical acceptance is still required.


### Post-build19 popup, focus and editor follow-up

The host now prepares `chrome.action.openPopup` through the original Chromium API continuation. It resolves the requested focused logical window, materializes only its selected real document (including a retained Peek), validates again after registration/catalog awaits, and supplies the native popup anchor. The root callback revalidates immediately before creating a real blank tab for an empty window. This path never synthesizes a toolbar click, activates an inactive window or grants activeTab. Native enforcement and the extension fixture remain separate custom-runtime acceptance gates.

Editor-to-editor/theme navigation now waits for the actual sheet dismissal event and checks its originating window/profile/Space instead of firing an unconditional 150ms timer. Automatic blank-page palette presentation also waits for sheet dismissal and checks that its owning window remains open. HTML bookmark import binds its original profile before the file dialog and retains that binding through the asynchronous operation.

Palette dismissal preserves an existing valid AppKit responder, can restore a still-valid captured responder, and otherwise rebinds a surviving sidebar key before falling back to Home search or the address control. It never uses generic page focus as that fallback, and a newer dialog, Library, Find or palette prevents restoration from taking over. The source theme preview's opaque chrome base and opacity-scaled tint/grain are now explicit; the preview itself does not add a separate blur surface. Dot texture and the selected puck outline use the Space's ink. A weak reference reported by the owned theme popover enables bounded NSView render evidence without desktop capture or broad window inspection. Integrated release20 passed: parent reported 87 packaged application checks, 26 engine checks and 213 Core/Services checks at checkpoint `e7f5b69`. Current desktop visual/physical acceptance remains separate.


### Post-build20 native color controls and window-owned confirmations

The owned theme-editor render showed apparently black rectangles around the native color pickers. Pixel inspection establishes that these are transparent holes in the cache-display output (RGBA `0,0,0,0`), not black paint. No black-background correction was inferred from that evidence. A separate source mismatch was confirmed: the original CSS specifies a 27×27px, radius6, borderless swatch, while the unrestricted SwiftUI ColorPicker rendered about50×27px with a white bezel. `NativeThemeColorWellControl` now draws the source swatch using a genuine NSColorWell. It retains native color-panel activation, color-pasteboard registration, keyboard focus, AXColorWell semantics, opaque color binding and haptic changes. AppKit's `isBordered` flag remains true internally because [that flag also controls click-to-open](https://developer.apple.com/documentation/AppKit/NSColorWell/isBordered); custom drawing removes only the visible bezel. Removal deactivates the well so an old color-panel selection cannot keep editing a discarded draft.

Five standalone native-control checks passed, covering control size/accessibility/drop registration, focus, quiet model refresh, native target/action updates and borderless rounded rendering on light/dark cards. Controlled reference images and metadata are under `macos/.build/verification/theme-color-well/`; they are non-presented owned-view evidence, not desktop screenshots or physical color-panel interaction acceptance. The control and helper checks subsequently passed the integrated release21 application run. That actual editor render suggested a 33-point native control frame despite its 27-point SwiftUI proposal; exact hosted-frame verification remains a follow-up rather than a visual-equivalence claim.

Library import/export/clear actions and sidebar/profile/Space deletion confirmations now await window-owned native sheets. A weak view anchor identifies the exact initiating window, including an existing editor sheet. A generation invalidates work on detach/reparent/cancellation; UI hosts also cancel on profile or logical-window closure and revalidate profile, owning window and destructive-action records after the await. Four standalone ownership checks passed. Root added explicit sheet cancellation on logical window closure because Chromium can order a shell out without issuing NSWindow.willClose. Four actual native-sheet cases and the nine color-well/dialog-ownership helper checks passed in the packaged release21 run. Parent reported 113 application checks and 218 Core/Services tests passing at checkpoint `bdaa149`. Physical color-panel/desktop appearance acceptance remains separate.


### Post-build21 logical-close and control follow-up

Accepted logical window closure now resets Find, palette, Library, theme drafts, local menus, editors, creation/rename forms, shortcut capture and deferred editor handoffs. The root close-attempt hook cancels only active drag/resize interactions, preserving editor/theme state if beforeunload vetoes the close. Native overlay presenters require an open logical owner and a visible parent. An explicit owning-window resize cancellation covers programmatic closure as well as the existing resign-key cancellation. The presentation-state diagnostic reports pending UI state to the application acceptance harness.

Because AppKit has no public dragging-session cancellation method, a close attempt revokes the current operation mask, suppresses its image/return animation and cancels model reflow/dwell immediately while retaining the native source until AppKit reports a terminal callback. An inert session cannot perform a delayed destination mutation. Nine standalone source-lifetime checks pass, including retained inert ownership and exactly-once rejection of a later move completion. These checks do not establish physical pointer/session acceptance.

The color-well representable now declares its exact 27-point fitting size and required size priorities. A simple hosted reproduction reports zero alignment insets and exact 27-point bounds, so no unproven inset correction was applied. The next real theme-editor run checks actual control bounds, converted bounds and fitting sizes before claiming resolution of the integrated render discrepancy. Theme puck reconstruction now uses explicit sRGB HSV, and hexadecimal output rounds and clamps bytes; three source-reference checks pass for saved-color round trips, keyboard/half-byte values and extended-gamut input.

The command palette now uses the existing profile-scoped favicon cache for URL-bearing History/Bookmark results, matching the renderer. Its native search field updates its accessible label for each nested/Site Search context and exposes the result count and selected result while preserving the typed query. Low-priority announcements are coalesced and require that exact field to remain visible, key and outside marked-text composition. Desktop VoiceOver/input behavior is not claimed from these source changes. The post21 batch has passed source parsing and bounded native-helper checks; integrated acceptance remains pending.


The continued post21 action audit corrected nested bookmark/history “Open page” to reuse the same existing-tab activation path as the top-level result; its accessibility label now says “Actions for …”. New Tab accepts the original drop-to-Today action above the first ordinary Today row. Reflow exit uses retained native whole-section bounds rather than child-row exit events, so replacing or moving rows does not cancel the projection. The source's synchronous drag-move callback checks the actual pointer (AppKit's reported drag point describes the image origin); leaving the whole section restores the current model order. New Tab and Today share one region, including their small gap. Eleven bounded AppKit drag/region checks pass, including child-row replacement and exact inside/outside section geometry. They do not establish physical event delivery or drop acceptance.

An exact non-presented ThemeEditor host also reports both native wells at 27×27 points with zero alignment insets; the baseline before explicit sizing reports the same. This does not reproduce the integrated cache-render discrepancy. The real editor's hosted geometry assertions and updated render remain necessary; neither an inset correction nor a desktop visual claim is inferred from the isolated host.


The integrated release22 hosted-control assertion reproduced and diagnosed the discrepancy: both visible, key theme-editor wells had 33×31-point bounds, with AppKit restoring alignment insets of 3 points horizontally and 2 vertically. The non-presented host did not exhibit this lazy native initialization, even after cacheDisplay. `NativeThemeColorWellControl` now explicitly returns zero alignment insets because its custom swatch has no native bezel; `isBordered` remains true for native activation. The correction awaits the actual presented-editor retry. A separate palette lifecycle fix moves the can-restore-focus guard before parent.makeKey, preventing a closing palette from taking key ownership back from a newly opened editor. An initial image-viewer fragment was incorrectly interpreted as missing theme content; pixel/hash verification disproved that interpretation, and it is not evidence for the lifecycle fix.


The release22 second assisted retry verified the correction in the actual presented editor after cache-display rendering: both wells have 27×27-point frame, bounds and fitting size, zero alignment insets, and correctly positioned root frames. The full packaged application run passed 133 checks and exited cleanly; engine22 independently passed 31 checks. Its actual palette accessibility and accepted-window-close presentation checks passed as well. Evidence is in `macos/.build/verification/application-22-assisted-retry2/`, including the measured hosted-control diagnostics and updated own-view render. This accepts the native sizing regression and exercised lifecycle cases; desktop material, physical trackpad/color-panel input and custom-runtime extension compatibility are still separate gates.


### Post-build22 split-Favorite drag and delayed Space navigation

The source renderer permits a Favorite that belongs to a split to remain a standalone draggable tile outside the split's own Space (`app.js` split/Favorite rendering and drag-space targeting). The native source previously rejected every split member, including those standalone tiles. It now accepts only actual registered standalone row anchors with a current profile and open owning window; the split capsule still has no drag anchor. Reflow can show the dragged member as an inert destination placeholder where the split capsule is absent. This placeholder has no native source anchor or duplicate accessible controls, and the original native drag source remains retained. A cross-Space commit moves the existing pair and preserves its ratio, while only the dragged member changes Favorite/pin/folder classification.

The 550ms Space-dwell work now carries a generation and the original drag's tab/profile/window authority. It rejects cancelled/replaced drags, owner closure/transfer, removed sources, changed profiles/starting Spaces and missing or foreign destinations immediately before selection. Edge dwell resolves neighbors from the current Space order on each firing and stops at the boundary. Successful navigation clears the old reflow; unrelated title/metadata changes do not cancel a valid drag. Drop commit revalidates the same authority. The pending callback releases its timer ownership even when validation rejects it.

Twenty-seven isolated checks passed (11 existing native source/region checks and 16 new reorder/dwell checks), using memory-only Core state and an injected scheduler that deliberately executes cancelled callbacks. Evidence: `macos/.build/verification/sidebar-drag-23/checks.log`. The new helpers compiled and linked against the built Core module; BrowserShell source parsing passed. These checks are wired into the existing application drag acceptance entry point for the next integrated build. They do not claim physical pointer/trackpad delivery or desktop visual equivalence.

The integrated release23 build passed without warnings. Its signed packaged application completed all149 checks and exited cleanly, including all27 combined native source/reorder/dwell checks. Root confirmed31 engine checks and244 Core/Services checks at checkpoint `809ff8c`. These results accept the exercised programmatic lifecycle/model behavior; physical pointer delivery and the still-building custom Chromium extension runtime remain separate gates.

### Post-build23 command and Site Controls follow-up

The final source audit identified missing query-specific Ask behavior, command search aliases, action availability and bounded Site Controls. The palette now offers `Ask Zacro: …` only for a nonempty, bounded question in the All scope with a configured public, idle AI context. Invocation revalidates the profile and availability; the root routes it to the same guarded submission path as the Library composer. The explicit Unsplit palette row replaces Split while a pair is visible, without disabling the split keyboard shortcut's toggle behavior. Stop requires an actually loading selected native document. Original renderer aliases such as “incognito”, “hotkeys”, “appearance” and “compare side by side” supplement command IDs and runtime categories.

Site Controls retains its compact natural height when content fits, but scrolls within the owning window's available height when many extensions or expanded actions are present. Its scroll indicators remain hidden and keyboard selection scrolls the actual focused control into view. Nine bounded own-view/policy checks passed, including a 60-extension NSHostingView with a 240-point viewport and programmatic access to its bottom controls. No desktop input was generated.

Browser shortcut capture and dispatch now share the renderer's physical-key contract for Command, Control and Option combinations, rather than recording a layout-translated character that could match a different command. Unmodified text retains its layout identity; the existing text composition and editable-field guards remain in place. The helper includes the original punctuation/digit mappings and F13–F24, while recording ignores repeat/dead/unknown events and Escape cancels capture. A shared menu equivalent helper supplies actual AppKit function/navigation characters so assigned named keys also appear in native menus. Chromium extension/native page input is unchanged. Two alias, six synthetic-event and two menu-equivalent checks extend the helper to 19 cases; these additions and the integrated application build are pending verification. Synthetic events are inspected as values and never dispatched as desktop input; hardware layout and trackpad acceptance remain separate.

### Custom-runtime private PDF correction

The actual custom24 runtime exposed a private PDF startup failure: its bundled viewer could not resolve the source tab through the logical catalog, while the public PDF case passed. The host now registers private documents through an in-memory component catalog before navigation, with actual incognito metadata. A dedicated private observer handles only the bundled PDF component's required tab lookup, document/zoom preparation, navigation/reload and new-window requests. Native Chromium separately verifies the exact installed component and its pending request; the Swift policy grants no extension permissions. New tabs/windows remain in the originating private profile, and requests to change privacy mode are rejected.

This route does not join NativeExtensionSync, cloud/extension storage, public registry events, recently closed sessions or third-party private extension participation. The manager retains only a private component transport; its exact observer identity is checked and reconnected after broker destruction during data clearing. Accepted private-profile retirement cancels queued work, erases logical identities/catalog/focus metadata and awaits transport closure before native context release. A terminal manager cannot recreate a retired transport merely to reply to an old request. Source changes and root pre-load/cleanup integration await the next coordinated build and actual private-PDF acceptance; the original failure is not yet marked resolved.

### Unicode command search reference follow-up

The source audit found that native palette search used locale-sensitive case/diacritic folding and grapheme offsets. The renderer's `fuzzyScore` (`src/renderer/app.js:4537–4573`) instead uses NFKD, removes only combining marks U+0300–036F, lowercases without a locale, iterates Unicode code points and calculates positions/lengths in UTF-16. `NativeCommandSearchMatching` now follows those rules, including the renderer's boundary/word whitespace set. Palette input trimming also follows JavaScript whitespace: it removes U+FEFF but preserves U+0085. This preserves compatibility-character matches and the reference's ranking of emoji and non-Latin titles without broadening diacritic removal.

`macos/scripts/check-command-search-reference.cjs` executes the actual renderer function to generate the native acceptance expectations. Its `--check` passed for 43 score cases and seven JavaScript trim cases, including full-width forms, ligatures, composed/decomposed accents, Hebrew/Devanagari marks, supplementary/ZWJ emoji, prefix/substring penalties and whitespace boundaries. All 50 checks are merged into the existing native command-interface acceptance entry point. No Swift compiler, app or desktop input was launched for this batch; native execution and integrated typechecking remain pending the next coordinated build. This is a concrete search-behavior correction, not new evidence of desktop visual or physical-input equivalence.

The root's first standalone Swift execution caught a real contextual-case mismatch at Greek final sigma despite the source review: Swift's default lowercasing produced a nonfinal sigma where the Electron function produced a final sigma. Explicit Foundation root-locale conversion fixes that discrepancy without depending on the user's locale. All **50 actual Swift reference checks now pass** (`macos/.build/verification/command-search-26-retry.log`); the original failing result remains in `command-search-26.log`. Packaged interface checks still await the next build.

### Native page-menu link actions and Peek origin

The page-menu audit confirmed that Copy Image, Save Image, spelling, editing and installed-extension entries remain genuine Chromium commands. It found a separate mismatch: native custom link entries appeared for every URL even though their dispatcher rejected non-web destinations. A shared presentation/dispatch policy now offers the original Open / Background / Peek / Copy entries only for credential-free HTTP(S) links. It leaves Chromium's decoded-image clipboard/download behavior intact.

Context-menu Peek now carries the invocation's original CEF point instead of sampling the pointer after a menu item is selected. Pinned Chromium first transforms nested renderer-frame coordinates to the root RenderWidgetHostView; CEF exposes those points without a CSS zoom conversion. The host adds the actual native document-slot offset, including a left extension panel, then converts through that exact browser window into the shell. Ten pure policy/geometry checks are authored and root wired them into application acceptance; integrated execution remains pending. The related source audit also identified missing Shift-XOR-Alt and saved-pin ordinary external-link Peek behavior; its separate implementation and evidence are recorded below.

### Trusted document-link Peek adapter

The native link adapter now mirrors `src/main/guest-preload.cjs`: a trusted primary-button Shift-XOR-Alt link opens Peek, while an ordinary external-host link from a saved pin uses bubble-phase handling so the site can retain its own cancelled-navigation or popup flow. Control/Command combinations, downloads, named targets and opener-excluding link relations keep the original behavior. The decision is checked again in Swift. DOM client points receive the actual Chromium zoom conversion once before the same native viewport-to-shell mapping used by the context menu.

The small DOM adapter runs only in a uniquely named isolated world. Its binding is attached to the actual main-frame execution context, never to the page's main world or to all contexts by name. A request is bound to a nonce, increasing sequence, unique context ID, frame/loader, committed address and the current native page/profile/window/visible-document snapshot. The host rechecks these after the frame-query await. Page navigation, document replacement, hiding, closure, transfer and Peek promotion revoke stale authority. The per-page coordinator drains the old adapter's exact native cleanup before arming a retained page under a new owner. Cleanup removes only this adapter's listener, binding and document-start script; it does not disable shared DevTools domains, and it visits bound main-frame contexts rather than every iframe world.

`macos/scripts/check-peek-link-bridge.cjs --check` executes the actual Electron adapter and the exact embedded native adapter against 38 event cases; all decisions and default-prevention/propagation effects match. Six further source-adapter cases verify inert subframes, unarmed/disposed listeners, removed bindings, changed documents and pagehide. The generated application acceptance helper contains those 38 policy expectations plus seven host visibility/source/coordinate guards. These are source and deterministic-policy evidence. Swift typechecking, actual isolated-world binding, trusted Chromium input and retained-page transfer/close behavior remain integrated runtime gates; physical trackpad input and desktop appearance remain separate.

`NativePeekLinkRuntimeAcceptance` authors ten additional gated loopback cases using Chromium's Input protocol in the disposable application harness: actual isolated-world arming, main-world binding isolation, synthetic-event rejection, trusted Shift/Alt input with retained source drafts, document reload/rearming, inactive split-source selection, external-host saved-pin behavior and close/revocation. The fixture creates and closes its own window and does not send macOS desktop input. These cases have not yet run; they are not acceptance evidence merely because the source exists.

The actual custom-runtime build27 exposed an initialization ordering failure: a URL-less WebContents had no renderer to answer Runtime/Page setup while navigation awaited that setup. An explicit blank-document experiment in build28 released the setup but broke the fresh-controller requirement for native history restoration. That experiment was removed. Native identity registration now precedes navigation, and adapter readiness is awaited after the actual initial/restored navigation. The immutable build29 retry passed all ten real trusted-link cases and the existing native history cases, including no extra Back entry (`application-29-retry/application.log`). The 45 generated Swift policy/host checks also passed. This establishes the exercised real Chromium input/binding behavior; it does not establish physical desktop input or guaranteed first-inline-script listener ordering.

An intermittent failed-Peek recovery in the first build29 run exposed a separate visibility-cache hazard: an opening animation could reach its rounded final frame while a page was hidden for an error, then mark the desired frame as visible without showing the recovered page. The retained Peek presenter now resynchronizes a newly supplied or hidden native preview independently of geometry changes. Root is correcting the corresponding actual-visible-frame cache. Hidden document adapters also retain their observed snapshot separately from their nil authorization, avoiding repeated native setup on every shell layout. These follow-up changes await the next integrated run; the successful immutable retry does not itself verify them.

The next source batch registers the adapter before navigation through an exact owned flattened session on the existing process-local browser broker. Pinned Chromium's PageHandler records a document-start script in browser-originating session state before falling through to its renderer; navigation therefore waits only for accepted native submission, while full binding/arming still completes after the actual document commits. Capability selection uses the engine's initialized broker rather than probing an unknown protocol method on a URL-less document. Stop immediately revokes dispatch and detaches only this adapter's child session, so cancellation before initial navigation can remove even a script whose opaque result identifier has not arrived. Existing bound contexts are disposed before detach. Stock diagnostic packages retain post-load root-session behavior and do not claim this first-document ordering.

Build30 compiled and packaged, but the strict first-inline fixture failed: the isolated world was created only by the later explicit create-world command, and the competing site's capture listener prevented Peek. Source inspection identified the missing prerequisite: InspectorPageAgent only registers its document-start instrumentation when Page.enable runs. The next batch submits Page.enable before addScript and allows navigation only after both native submissions, while still awaiting their replies after navigation. Acceptance diagnostics now record the bootstrap's original readyState/body presence and assert the site's interception counter immediately after input. These source changes await the next actual run; the fixture was not relaxed.

The focused packaged build31 run confirmed that ordering correction: the adapter first executed with readyState=loading and no body, the first-inline site listener was preempted, and the exact trusted binding request reached the host. The overall Peek check then failed because the host used a window-projected array index inside a canonical-state commit and wrote another window's tab. That application mutation is being corrected separately. The fixture now snapshots the other owner's destinations and fails immediately on any foreign-window Peek change, in addition to requiring the intended preview. Build31 therefore establishes document-start ordering, not an overall Peek acceptance pass.

Peek replacement now holds an exact source/window/profile/selection generation and the previous saved destination while asking the real old preview to close. A veto preserves its native identity, draft and saved metadata; concurrent replacements share the native close and only the latest still-valid destination can commit. Self-replacement permits the exact accepted old preview to have already detached its browser. Native callbacks retain the old destination until the durable replacement succeeds, and the page factory avoids recreating it during the close barrier. A gated owned-sheet fixture covers veto, concurrent latest intent, retained underlying draft and replacement from inside Peek. Those new checks are authored, not yet runtime acceptance evidence.

The focused packaged custom-runtime build32 Peek suite passed all **28 checks** and exited cleanly (`macos/.build/verification/peek-32/application.json` and `application.log`): six initial-document submission/cancellation/cleanup checks, fourteen real trusted-link checks, six replacement/owned-beforeunload-sheet checks and two setup checks. The actual initial parser-inline capture handler is now preempted; cancellation before the initial renderer leaves no future adapter script or extra history entry; a successor uses the same native browser identity and disposes only its own listener, binding and child session. The corrected canonical mutation opens the intended owner's Peek without changing the other window's destination. Replacement preserves the exact old draft on veto, coalesces concurrent close requests, commits only the latest still-valid intent, retains the source document and supports trusted self-replacement after old-browser teardown. These are real Chromium protocol input and exact owned-sheet acceptance results, not physical desktop input or material/animation visual equivalence. This focused suite does not establish full-application or all-extension compatibility.

The separate navigation32 suite timed out while waiting for a promotion fixture's beforeunload sheet after only its initial ownership assertion passed. The prior fixture sent input as soon as the document loaded without establishing that its Peek viewport had settled or that a trusted click produced sticky activation. The next fixture explicitly waits for the exact visible, active native preview and stable viewport, focuses that document, checks the actual click target, then asserts the delivered click's trusted/primary flags and `navigator.userActivation.hasBeenActive` before navigating. Each wait names its phase. This adds causal diagnostics and valid setup; it does not mark the original timeout resolved or bypass Chromium's beforeunload policy.

Navigation33's named phase confirmed a real focus problem: the displayed preview's viewport settled, but `document.hasFocus()` remained false after the application focus request. The application previously made CEF's generic Widget-root NSView the Cocoa first responder before requesting CEF WebView focus. Pinned Chromium's FocusManager returns early when that WebView is already its remembered focus, so a generic-root responder assignment can steal the document focus without invoking WebView.OnFocus again. The follow-up removes that assignment and retains native window activation plus CEF's own focus path; acceptance-only diagnostics identify actual key-window and responder classes. The packaged navigation34 suite subsequently passed all **33 checks** with clean exit, including actual preview focus, trusted sticky activation, pending-navigation veto, promotion with retained native identity/draft, and capture under the promoted identity. The stricter fixture was retained. This establishes the tested native input and focus path, not physical desktop input.

### Real tab-capture target and decoder acceptance

The capture33 fixture acquired its native stream but timed out waiting for `requestVideoFrameCallback` inside the extension's offscreen document. Pinned Chromium schedules that callback through window animation/presentation, so it is unsuitable as proof that a hidden consumer received no captured frames. The consumer now reads genuine `MediaStreamTrackProcessor` VideoFrames, decodes their center pixels through canvas, and requires at least two distinct frame timestamps, the expected target color and a live native track. Every frame is closed and all tracks/readers are cleaned up. Failure diagnostics report track/video state, dimensions, observed frames/colors, media events and the worker's actual native capture-status events; no screenshot or synthetic frame substitutes for the stream.

The immutable custom33 executable with that external fixture passed all **11 focused capture checks** and exited cleanly (`macos/.build/verification/capture-33-track-processor/application.json`): two setup checks and nine native grant/default/legacy/background/split/Peek/second-window/cleanup checks. The tested paths decoded real expected pixels and observed the native active/stopped events; a host permission without the real action grant remained denied. This establishes those specific Chrome capture behaviors, not all Chrome extension compatibility, a full-application pass or physical desktop input.

### Favorite action accessibility follow-up

Electron names its image-only Favorite activation buttons with the saved display label and Closed/Loaded/Sleeping status. The native favorite Button previously had only an icon while its ancestor supplied a tooltip. The actual activation Button now has an explicit accessible name and a stable action identifier, preserving its existing click and selection behavior. A new gated owned-shell fixture checks that exact AXButton across sleeping, real page materialization, retained closure and rename, then closes its fixture window. The fixture starts at the owning shell content view and excludes foreign views and Chromium child windows; it uses neither desktop AX automation nor synthesized macOS input. Source changes and five checks await the next integrated run, so assistive interaction is not yet accepted from this patch alone.

The packaged custom33 focused sidebar run passed all seven checks (the five owned-shell AX checks plus two setup checks) and the driver confirmed clean exit zero. `macos/.build/verification/sidebar-33/application.json` records the actual action's Sleeping/Loaded/Closed naming and rename updates. This accepts those native accessibility-tree properties and fixture cleanup; desktop VoiceOver or physical keyboard interaction is still a separate gate.

### Home and toolbar source alignment queued for build35

The Home saved-page strip had one stretching horizontal row, unlike the reference's fixed 72px wrapping tiles (`app.js` `renderHome`; `styles.css` `.home-links`/`.home-link`). It now wraps and centers each row independently, uses the source spacing and responsive padding, and preserves each tile's icon/text dimensions. The Home search surface now has its ordinary line border and accent focus/3px halo, distinct from the deliberately outline-free content pane. Its search field and submit button share the focus-within treatment. Toolbar controls now use the reference 17px sidebar and 15px navigation paths, theme-derived hover fill, 0.97 press transform, 100/140ms timings, and Reduce Motion behavior. No desktop contrast or hover interaction has been inferred from these source changes.

`NativeHomePageRenderEvidence` captures the actual Home SwiftUI tree with six saved pages at wide and narrow widths in light/dark, using only hidden owned hosting views and a memory-only store. The helper is gated by the existing render-evidence flag, never opens a native page or makes a window key, and awaits build35 integration; no new render or runtime pass is claimed yet.

The source follow-up for build36 replaces the oversized Private Home hero with the reference's compact inline 16px shield and 14px heading, plus full-width 11px detail. Recent pages now use the source header/row spacing, reserved favicon/arrow sizes, theme hover and 0.985 press feedback; the arrow remains hidden until its row is hovered or focused. Owned render fixtures now include recent rows and private variants at both widths in light/dark, still using only memory-only state and hidden hosting windows. Integrated typechecking and the new render comparison remain pending; physical hover/keyboard and desktop material are not inferred from the source change.

A separate `extension-services` acceptance suite is authored for build36 so native bookmark migration, download resume/rename, side-panel retention/parking and management consent checks can run independently of the unresolved programmatic-popup gate. It reuses the actual install/icon/worker setup. The existing full/extension suite order and strict popup assertion remain unchanged; the partial suite reports both full-application and complete-extension-fixture acceptance as false. The focused36 run passed real bookmark migration and eight download checks, then failed while waiting for the native side-panel document; it exited cleanly. Source tracing identifies SidePanelCoordinator::Show rejecting the hosted CEF TYPE_POPUP before creating a panel, while the public API resolves successfully. The native hosted-only correction is owned by the engine batch; no side-panel acceptance is claimed yet.

The new native auxiliary acceptance fixture is also integrated for build35 after the existing identity checks, while the worker remains alive. It uses genuine native auth windows from two distinct profile contexts and exact loopback tokens, trusted sticky activation, and the exact owned beforeunload sheet. Ten intended assertions cover Stay retaining document/window/draft/pending worker, Leave completing native window teardown, and the other profile remaining unaffected and completing its real callback. Its explicitly requested 90-second bounded fixture hold preserves the existing 20-second default. Actual runtime results are pending; this does not claim full-app Quit veto or physical input.

### Theme and sidebar controls prepared for build37

Puck selection now leaves the chosen color unchanged until movement, matching Electron pointerdown. Actual dragging uses the source's 0…359° canvas while keyboard movement retains its full 360° wrap. Hex colors slightly above 359° remain positioned by the unclamped source formula; a drag that returns to its origin recomputes that origin rather than retaining the previous offset. Cancellation releases the cached drag origin. Six new semantic cases cover stationary black, both endpoints, black's movement brightness fallback, returning to origin and near-red hex positioning; they are authored but not yet executed in the integrated application.

Compact folder headings now use the source's 28px row height, and outgoing/incoming Space previews retain folder guides. Folder, New Tab and pinned-home reset controls use the existing theme hover fill and source press behavior; audio, close and reset glyphs use actual 14/13/15px shape dimensions. Retained drag anchors, grouping and drop authority are unchanged. Reduce Transparency keeps requested opacity and blur editable while rendering an opaque sidebar and suppressing grain in the window/theme preview, as the reference's accessibility media rule does. The normal gradient remains available outside that sidebar, and the system material override stays active. These are source changes, not desktop material or physical hover/drag evidence.

The side-panel worker fixture now records actual onClicked receipt, requested mode/tab, native open completion, genuine SIDE_PANEL contexts and the last messaging failure in its bounded failure report. It preserves Chromium's action/user-gesture/permission path and never treats a resolved open promise as proof of a presented panel.

`NativeDownloadRetirementAcceptance` is integrated in the explicitly partial `download-retirement` suite and late in the full custom application path. It creates real worker transfers in two disposable public profiles: A deliberately retains its inspector after durable Core deletion to observe the actual cancellation fence and a late item; B detaches its witness then exercises ordinary Application Delete Profile. The original profile's native documents must survive. The packaged custom37 focused run passed all **16 checks** (14 retirement cases plus two setup checks) and exited cleanly; `macos/.build/verification/download-retirement-37/application.json` records actual running/paused cancellation, late-item cancellation despite the API callback race, another profile's real byte resumption, exact transport cleanup and unchanged unrelated documents. It does not cover private last-owner cleanup or claim physical database erasure before Chromium shutdown/replay. Focused reports continue to reject full-app/complete-extension acceptance claims.

### Sidebar focus and context actions prepared for build38

Focus Sidebar now resolves the selected tab among the rendered keyboard items, otherwise the first visible item, otherwise the actual Space picker. This matches `app.js` `focusSidebar` and fixes an unattached focus target for ordinary blank tabs and members hidden by collapsed native groups. The Space picker and group-heading Buttons have stable accessibility identifiers. Five authored owned-shell checks inspect actual focused AX state, preserve the selected document/group collapse, and close the exact fixture window; they are wired into focused sidebar and full acceptance but have not run yet.

The tab context menu's Open in split view now directly pairs the clicked eligible row with the current page, matching `split:toggle({id})`. It no longer selects that row before opening a picker. The existing Core reducer retains persistent pairs and wakes a closed retained pin in the same mutation. Six authored memory-only reducer checks cover explicit target, fallback, selected source, retained pin, invalid blank/other-Space contexts and existing pair/ratio preservation; separate keyboard/palette Split behavior is unchanged. Typechecking and runtime acceptance remain pending.

The focused `extension-services-37-ready` run passed the real panel's logical browser-window assertion after the worker waited for its actual message listener. It then failed `failedDocumentKeepsNativeSidePanelVisible`; this remains unresolved. Build38 adds bounded, acceptance-gated component diagnostics for native error/bounds/panel/window/overlay state, exact model/page/browser addresses and read-only native history, while retaining the original strict predicate. The observed error-page retries match Chromium's native1/5/30/60-second auto-reloader. No speculative geometry change or weakened assertion is included.

### Navigation capture and close-review follow-up

The new native state acknowledgement requires application capture requests to remain serialized until their actual protocol result arrives. Cancelling a debounce no longer abandons an in-flight renderer flush. Close and discard wait for that operation and then request a fresh snapshot; profile reset, document replacement, movement and cancellation invalidate stale publication. Background capture remains nonmodal.

An actual capture failure at close presents an owned Keep Open / Close Without Page State sheet. Explicit fallback first durably saves current back/forward addresses and removes only the failed document's previous encrypted snapshot, preventing silent restoration of stale form contents. Consent binds the exact page, browser, profile, window, address and navigation history; changed state requires recapture, and a newer successful snapshot cannot be removed by old consent. I/O failure keeps the document open. Window and termination close attempts now have individual identities so an older tab preparation rejection cannot cancel or revive a newer close operation.

The custom-runtime25/Swift26 diagnostic now passes actual oversized live form state, concurrent capture, Keep Open, stale consent, overlapping tab/window close, explicit fallback and reopening without old form contents. The overall application run remains failed later at its unpacked-extension setup; it is not a release acceptance pass. The subsequent bounded-history addition and outer termination generation guards require the next integrated executable. A separate fixture compiles and executes five exact production termination methods with deterministic scheduling; all 14 lifetime checks pass, including stale preparation, deferred completion and reentrant Quit.


### Custom browser chrome and pane contour prepared for build 40

The user's explicit custom-chrome requirement exposed remaining system-rendered controls outside the main sidebar: AI and Sync used SF Symbols directly, the shared glyph resolver could fall back to system images, and settings/extension forms retained native switches, pickers and rounded text fields. These browser-owned surfaces now use the original path catalog (including renderer `icon()`'s globe fallback), custom 31×19 switches with 13px thumbs/12px travel, custom checkbox/disclosure/selection controls and source primary/secondary button treatment. The selector keeps a genuine native menu for keyboard/typeahead behavior; OS file, permission and security dialogs are unchanged. Toggle accessibility representations explicitly use a semantic-only native proxy to preserve state/actions without recursive custom styles. No visible operating-system switch or default picker remains in the App Swift source scan.

`NativePaneShape` now supplies one continuous contour to the SwiftUI page clip, page underlay/shadow and window-material cutout, matching the hosted page's existing continuous CALayer contour at the same configured `pageRadius` (reference default 12). This fixes the prior circular/continuous mismatch without adding a content outline or guessing a private OS window radius. Root owns live window-resize/native-page layout validation and the remaining content-overlay call site. Four authored `NativeChromeControlRenderEvidence` images will render the actual shared controls in light/dark at 340/560pt using hidden owned hosting windows; cache-display native-menu drawing, desktop composition, integrated typechecking and actual control interaction remain unverified for this source batch. No compiler or application was launched by this UI task.

The focused sidebar39 fixture retained all five Favorite AX naming passes and its ordinary-blank row-suppression check, then timed out waiting for actual focused AX state on the visible fallback row. It exited cleanly; the focus behavior is not accepted. Core's build 40 bounded diagnostics retain that assertion and record exact owned focus/model/key-window state. The unified sidebar-toggle follow-up was subsequently integrated as described below; that does not resolve the independent row-focus runtime gate by itself.

### UI completion follow-up — 2026-11-03

The shared selector no longer routes its visible label through SwiftUI `Menu`, which had converted the custom layout into an Aqua cell with a leading arrow. Its 34pt trigger is now drawn by an AppKit button using the same 7pt card contour, theme ink, text sizing and original trailing vector path as the other browser controls. The actual native menu retains keyboard/typeahead behavior and a pop-up accessibility role, label and selected value. Open menus are invalidated by semantic option changes, selection changes, disablement, removal or a window/profile/Space change; identical human-readable labels cannot authorize an action against replacement values. The actual selector, shared chrome controls and complete glyph source passed a narrow warning-free Swift5/AppKit typecheck. New owned light/dark renders and physical menu interaction still require the integrated app.

Sidebar toggles now share one operation for toolbar, floating reveal, menu, palette and admitted document-key origins. A compact Library closes without reversing the explicit sidebar preference. The exact owned palette, menu, theme panel and editor are dismissed before focus is handed to the selected document or address control; unrelated/nested security sheets are never dismissed. Window/profile/Space/selection changes, deactivation, foreign focus and later user input cancel obsolete focus handoffs. Resize, drag and Space-gesture drafts are cancelled before the layout changes. `macos/scripts/check-sidebar-toggle.py` executes 26 extracted production decision/lifetime cases under Swift6 checking, including the real root-dispatch early return. Those cases pass and are wired into native CI. The separate actual runtime helper retains seven strict focus/document checks; no runtime pass is inferred from the extracted fixture.

The native content-frame reporter and the coordinator's coalesced layout pass now schedule through the main run loop's common modes. Dispatch-queue callbacks could remain deferred during AppKit's nested border-tracking loop, leaving the Chromium content at its old dimensions until a drag ended. This preserves deferred/coalesced publication while making it available during tracking. The actual resize acceptance already includes an observation inside `.eventTracking`, in addition to the settled grow/shrink, split, Find and empty-pane cases. The new tracking case awaits the next joint build and runtime run.

Failed authorization-window cleanup during Quit now has a separately owned AppKit recovery controller. The root injects freshly read native capabilities; the controller's UUID identifies only a UI episode and grants no native authority. It uses an eligible browser shell when available, otherwise an owned temporary AppKit window without close/minimize affordances or a Core/browser-model creation. Replacement waits for the exact old sheet Task to finish. Cancellation, owner disappearance and runtime changes dismiss only this controller's presentation; they never imply that the user pressed Cancel Quit. A failed native cancellation retains the failure and re-presents fresh Retry/Cancel controls with its error. A fresh final-cleanup capability removes Cancel Quit. Unrelated sheets/application modals and a hidden application are left alone.

The CEF-free owned AppKit runner passed all **12 actual NSAlert/window checks**, exited 0 and compiled without warnings (`macos/.build/verification/auxiliary-recovery-ui-41-final`). It verifies fallback creation/nonclosability, Retry, cancellation-release failure/recovery, generation replacement, unrelated-sheet isolation, actual foreign application-modal waiting, owner `orderOut` fallback, final-cleanup capability changes and cleanup. Its first run retained eight passing cases before exposing that an already occluded owner's `orderOut` may produce no occlusion-change notification. A presentation-scoped visibility timer, removed with the exact sheet, covers that missing notification; the final run accepts the corrected UI case. A subsequent exact-window lifetime check replaces closed-owner object-address bookkeeping with weak window references scoped to the current failure episode. The same closed and intentionally reopened NSWindow remains excluded during that episode, then becomes eligible for a new failure episode. All **13 actual checks** pass after this hardening, warning-free with exit 0 (`auxiliary-recovery-ui-41-weak-owner`). These results exercise actual owned AppKit sheets through model operations, without desktop input or Chromium/native admission execution. Integrated root/runtime Quit behavior remains a separate acceptance gate.

The palette follow-up preserves the renderer's CSS-only hover behavior: pointer hover changes its surface without moving keyboard selection or triggering a scroll. Only selection changes request the nearest necessary scroll. Title and detail now share the reference inline baseline and 9pt gap rather than becoming two stacked lines; result rows retain 40pt minimum height with 2pt spacing and a matching height calculation. The selected title uses medium weight, unselected vector results use Space accent, and scope chips use 11pt type, 8pt horizontal padding, 7pt corners and the reference selected fill. At compact widths the scopes scroll horizontally without wrapping, matching the reference overflow rule. The input vector is explicitly 18pt, and the palette uses the shared continuous 12pt pane contour per the user's curvature preference. The actual palette, theme, glyph and chrome-control files passed a warning-free narrow Swift5 typecheck against the actual Core module with ephemeral action bindings (`palette-style-41/typecheck-final.json`). This is not yet a packaged interaction or desktop-composition pass.

All direct `NativeGlyph(...).font(...)` sizing sites were reviewed because a font modifier does not resize these original vector Shapes. Eight sites now specify their actual size directly: 13pt address identity, 15pt site controls, 14pt footer Space icons, 24pt Library empty state, 18pt download document and the existing intended 16pt folder/New Tab and 17pt appearance icons. Parent text fonts are preserved; the Sync preview's Label font remains because its icon was already explicitly 14pt. The audit found no root/engine-owned glyph/font call sites needing a patch. Evidence: `glyph-size-41/audit.json`; integrated rendering remains pending.


The local legacy-history migration now durably assigns opaque per-visit deletion-boundary receipts before submitting native import batches. Exact visit versions retain their original lease across title changes and retries; a newer coalesced visit receives separate authority. Native results must attest the assigned lease, and Core removes that exact mapping in the same durable transaction as binding/removal and its import acknowledgement receipt. Portable imports/exports cannot author those receipts, and recovery copies are purged at authority changes. The updated standalone live Core suite passed **227 tests**, including eight boundary cases, seventeen legacy import cases and the SPA Library distinction, with no failures/skips or compiler warnings (`history-core-tests-41/tests-boundary.json`).

`NativeHistoryMirrorRuntimeAcceptance` is authored for the next custom-runtime execution. Its isolated lane owns a fresh native profile absent from the canonical collection, seeds its Core state before creating Chromium's context, and loads its own minimal history-permission worker. Twenty-five checks use actual native SQL identities and Chrome history operations for lost replies/acknowledgements, source-version changes, pre-submission URL/range/delete-all scopes, disk-write failure, profile isolation, explicit Electron JSON reimport and scheduled aging beyond ninety days. The additional exact-time reimport case keeps a deleted highest-VisitID binding unverified while creating a fresh Core UUID at the same native URL/time; the actual pinned AUTOINCREMENT identity must keep the new intent distinct, then verification must remove only the old binding. The aging counter must advance after the import journal was acknowledged, so a pending journal cannot stand in for durable bound retention. A separate fourteen-check lane uses an owned modeled document and the existing suspend/barrier/resume boundary to inspect actual pushState/replaceState/back/forward events without a concurrent drainer acknowledging them first. The actual transport, production drain and both helper entries passed a warning-free narrow Swift5 typecheck against the current Core module; only imported-manager construction and application/owner bindings were ephemeral (`history-runtime-authoring-41/typecheck-final.json`). Native SQL execution, scheduled expiry, real renderer SPA events and integrated shutdown remain pending; these are authored acceptance cases, not runtime passes.


`NativeExtensionHostNavigationAcceptance` now creates an owned temporary MV3 extension with real action-popup and side-panel documents. It attaches to their actual Chrome targets/unique execution contexts and dispatches one genuine Chromium mouse pair per producer, recording trusted/primary/active DOM receipts without a Runtime userGesture override. Authored checks cover ordinary and Meta background links, named `window.open` reuse with the same native WebContents and WindowProxy, actual opener callbacks, a real POST form and exact loopback response body, profile/process admission fences and source-RFH ownership while another profile is focused. Child history is checked against the actual native event identity rather than matching a Core tab ID to a Library row. The fixture uninstalls its own extension and normally closes only its created tabs/window. Both new history/host helpers passed the final warning-free narrow Swift5 typecheck against current production transport/drain/Core source modules and the actual admission wrapper (`extension-host-navigation-41/typecheck-final.json`); application/owner bindings and the imported-manager/admission factory boundaries were ephemeral. The helper is wired by the root for integrated execution; actual popup/panel DOM production and C++ broker behavior remain pending.
