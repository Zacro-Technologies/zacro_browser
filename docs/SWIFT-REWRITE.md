# Native macOS rewrite

The `swift-rewrite` branch is the separate development line for replacing Zacro's Electron application on macOS with a native Swift application. The target is the complete browsing experience, not a demonstration shell. The existing implementation remains the reference until the corresponding native workflows pass acceptance.

This document is a migration contract. An unchecked item is required work, not a claim that the feature works. Compilation and a successful launch do not establish parity.

## Architecture and engine decision

Swift owns browser state, native windows and controls, keyboard and trackpad input, page arrangement, and application services. Browser documents remain inside an isolated browser engine. Changing the interface language alone does not replace that engine or establish lower memory usage.

The user selected Chromium and requested Chrome-extension compatibility. Chromium is mandatory for this rewrite; WebKit is not a fallback. The alternatives considered were:

- **Chromium:** retain Chromium website behavior and pursue the current bounded Chrome-extension compatibility. A native CEF integration is one candidate. CEF exposes C/C++ APIs, supports native `NSView` hosting, and requires macOS helper application bundles, framework resources, process lifetime management, and main-loop integration. Existing Electron JavaScript APIs and Zacro's patched session ABI do not automatically become CEF APIs. The extension host must be ported and accepted separately. See the official [CEF general-usage guide](https://chromiumembedded.github.io/cef/general_usage.html) and [architecture](https://github.com/chromiumembedded/cef/blob/master/docs/architecture.md).
- **WebKit:** use Apple's system web-content framework and native page views. Apple provides [`WKWebExtensionController`](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller) for attaching extension contexts to web views on supported systems; this does not make Zacro's Electron adapter, Chrome Web Store installer, existing permissions, or extension synchronization automatically compatible. Those features need an explicit implementation and supported-API matrix.

The branch now vendors CefSwift with Zacro patches for isolated profile contexts and independently retained Chrome page windows. The pinned arm64 CEF archive has been downloaded and digest-verified locally. Native engine compilation and packaged acceptance are tracked separately; these are not proof of complete feature parity. The existing runtime pins and acceptance requirements are in [runtime/electron](../runtime/electron/README.md). Reusing that runtime through an Electron UI wrapper would not fulfill the native application rewrite target.

## Data and compatibility rules

- Keep native development data separate from the user's existing Electron profile directory. Import only through an explicit, reviewable migration operation. Never migrate by editing the original profile in place.
- Persist versioned state atomically, validate imported values, recover without silently overwriting an unreadable source, and retain a backup before migration.
- Keep cookies, credentials, site storage, permissions, cached icons and extensions profile-scoped. Private profiles must not enter persisted state, exports, icon caches, history, sync or AI context.
- Carry bookmarks, Spaces, folders, Favorites, pins, ordinary tabs, archive, split groups, saved Peek destinations, settings and navigation stacks where supported. Document items that cannot be imported, particularly engine-specific cookies/session databases and secrets.
- Google is the default search engine and page spacing defaults to 4px. Preserve explicit existing settings.
- Never advertise unsupported controls as working. Disabling an unavailable feature requires an accurate explanation and leaves its parity item open.

## Required parity and acceptance

| Area | Required native behavior | Acceptance evidence |
| --- | --- | --- |
| Windows and navigation | Native titlebar and sidebar controls; content-only mode; URL editing; back/forward, reload/stop, find, zoom, print, PDF viewing; normal link/new-window behavior; crash recovery | Local HTTP fixtures plus native keyboard and mouse coverage; restart/crash cases |
| Tabs and saved sites | Favorites, pins, ordinary tabs, folders, rename, close/restore, retained saved destinations, offline favicon cache, sleep/archive rules | Persistence and profile-isolation tests; offline restart; native drag review |
| Spaces and profiles | Separate cookie/storage contexts; Space switching and remembered tab; continuous direct-contact movement, short-flick one-page movement, no momentum; private browsing | Two-profile session fixture; physical Mac trackpad review, including slow/long and fast/short gestures |
| Dragging | Live reorder for Favorites/pins/ordinary tabs; drag between sections, into folders, across Space icons/edges; cancel restores layout | Native pointer tests with actual drag sessions; cancellation and ownership boundary tests |
| Split view | Combined tab presentation; persistent groups until unsplit; drag into left/right half; resizable divider; accessible keyboard resizing | Multiple groups across restart and Space changes; divider and drop tests |
| Peek | Link-origin animation; live tinted source content; source-tab site badge; outside click/Escape close; expansion animation; persistent destination and parked live document | Live document state, navigation, unsaved-work, focus, and restart tests |
| Materials and themes | Native transparent window and blur; accurate theme preview; clear color controls; subtle matte material; Space-tinted chrome; content shadow without outline; opaque themed empty pane; haptics | Light/dark/reduced-transparency captures; 0/50/100 opacity checks; physical haptic review |
| Command palette | Shared selected-tab design and curvature; tab/Space/bookmark/history/action results; editable shortcuts; Unsplit; paste-and-search; website search | Native keyboard, IME, selection and accessibility tests; safe URL handling |
| Library and downloads | Bookmarks/history/archive/settings; download start/progress/cancel/resume, reveal, rename/undo and collision handling | Fixture downloads, restart/error handling, native save dialogs |
| Site controls | Share/copy/other supported page actions; image context copy; page settings; real extension actions; adaptive pinned extension tiles | Real page/menu interactions; installed extension fixtures |
| Website permissions | Prompt and persist explicit per-origin/profile decisions; revoke safely; untrusted page cannot invoke privileged application actions | Camera/microphone/location fixtures; rejection, revocation, navigation race tests |
| Extensions | Verified acquisition and CRX checks where supported; unpacked review; profile boundaries; permission review; enable/remove; actions/options/context menus; updates/rollback; bounded compatibility matrix | Port relevant [extension tests](EXTENSIONS-SYNC-VALIDATION.md); real target-engine fixtures and packaged acceptance |
| AI | Existing six connections; explicit selected page/PDF context; review before transmission; sources; drafts/follow-ups; stop/reset/retry; provider and profile isolation; no silent billing fallback | Controlled transport/protocol tests plus separately authorized live connection acceptance; [AI contract](AI.md) |
| Account sync | Configured service; account/device/recovery workflows; linked profile scope; separate extension settings consent; offline outbox; revocation and credential isolation | Existing service against two native clients; restart/offline/revocation tests; [sync contract](SYNC.md) |
| Import/export | Validated collections/settings migration; no secrets/private data in export; no modification of original Electron data | Malformed fixtures, round-trip tests, backup/recovery verification |
| Accessibility and lifecycle | VoiceOver names/actions, focus order, reduced motion, fullscreen and multi-monitor placement, termination with unsaved pages | Native accessibility tree and manual review; lifecycle tests |
| Distribution | Reproducible release build, valid app bundle/resources, engine helper lifecycle if applicable, licenses, app identity, signing/notarization and update strategy | Install/launch on clean user profile; arm64/Intel support explicitly stated; hashes and signing logs |

## Completion gates

1. Map each reference workflow to its native implementation and test, including unsuccessful and cancelled paths. Reuse local fixtures and expected behavior rather than copying implementation-shaped assertions.
2. Build the actual release configuration and run native unit/integration suites. Re-run checks after any native engine or material change that affects their assumptions.
3. Exercise the packaged application using separate disposable profiles. A development launch does not validate packaged helpers, sandboxing, resources, permissions or credential storage.
4. Review the real UI on macOS with mouse, trackpad, keyboard and accessibility tools. Record performance under the same tabs, pages, window size and power state as the Electron baseline: cold start, idle CPU, total process memory, navigation latency, frame times during Space/Peek/split animations, and prolonged browsing.
5. Document every remaining unsupported feature and platform gate. The rewrite is complete only after required parity is implemented and accepted, or the user explicitly changes the feature scope. Do not infer that choosing an engine waives unrelated features.

## Audit references

The current behavior is defined across [implementation contract](IMPLEMENTATION-CONTRACT.md), [0.10 release notes](RELEASE-NOTES-0.10.md), [extension compatibility](EXTENSIONS.md), [AI connections](AI.md), [sync](SYNC.md), and [validation](VALIDATION.md). Existing partial support and release limitations remain limitations; the native rewrite must not claim greater compatibility without evidence.

## CefSwift dependency audit

The candidate [CefSwift](https://github.com/Rajaniraiyn/CefSwift) was inspected read-only at revision `b18cceef8afaf6686147e19a9239f31c2dd81541`. Its manifest pins CEF `156.0.14+g4fa4ab5+chromium-156.0.8078.48`; the arm64 minimal archive is listed as 134,887,274 bytes. CefKit with the initial profile and page-window patches compiled locally. The full app and packaged runtime need separate acceptance.

Source inspection identifies integration work beyond its advertised browser example:

- `CefChromeWindow` owns a CEF Chrome-style window and one browser. Native `parent_view` embedding uses Alloy; offscreen compositing also uses Alloy. The dependency's own configuration documentation says Alloy does not provide extensions. Do not use the embedded/Metal mode and claim Chrome-extension parity.
- `Examples/Sources/Browser/BrowserShell.swift` keeps several tab records but navigates one shared browser when selection changes. Zacro requires independently retained documents, back/forward stacks, splits and Peek; this example's tab model is insufficient.
- `CefChromeBrowser` privately owns one browser view and applies a one-child box layout. A full implementation needs multi-view lifecycle/arrangement and profile request contexts.
- `CefChromeWindow.setOverlay` currently installs a titlebar accessory. Its descriptive full-window-overlay comments are broader than that implementation; sidebar and Peek/palette layering need actual runtime validation.
- The package defaults to disabled Chromium sandboxing and can select a fixed mock cookie-encryption key for ad hoc builds. Those defaults must not silently apply to real browsing profiles. Zacro must choose explicit safe runtime policies and use disposable development profiles until the production configuration is accepted.
- Its global JavaScript bridge is callable by arbitrary hosted pages when handlers are registered. A native browser must not register privileged application handlers into that global page-facing bridge.

The dependency is vendored at the exact revision above, with its BSD license and CEF notices retained. Zacro owns patches for missing browser-host capabilities. Verify the resulting sandbox, session isolation, view lifecycle, extension support, and input behavior in the bundled application before treating the integration as complete. The existence of a Swift wrapper does not establish those properties.

CEF's current runtime header explicitly limits a Chrome-style window to one Chrome-style BrowserView. The initial multiple-views approach was rejected during source review before acceptance. The integration therefore uses retained Chrome child windows; split and Peek can retain separate live documents, but native overlays must account for child-window ordering and fullscreen transitions. This is an open UI acceptance area, not equivalent to a proven single-window compositor.

## Native engine acceptance evidence

On October 31, 2026, the bundled Apple silicon application passed its explicit
four-document engine acceptance fixture after adding request-context readiness
handling. CEF rejects creation of a Chrome BrowserView while a named disk
profile is still initializing; the integration now waits for
`on_request_context_initialized`, rather than leaving an empty window with no
browser. Context callback ownership does not retain the profile in a cycle.

The passing fixture checked four distinct native browser IDs, actual Chrome
runtime for every document, shared localStorage between two pages in the same
profile, isolation from a second persistent profile and a private profile,
correct persistent-context paths, no private cache path, and retained document
state across hide/show. Local evidence is in
`/tmp/zacro-engine-acceptance-ready.json` and its corresponding log. This is an
engine smoke test, not complete feature acceptance, restart durability, cookie
migration, extension compatibility, or a performance benchmark.

The fixture uses a deliberately selected mock cookie key only in a fresh,
empty `zacro-native-acceptance-*` directory directly under the system temporary
directory, with a loopback HTTP fixture. The Chromium sandbox remains enabled.
Normal launches keep real Keychain protection: the development bundle showed a
Chromium Safe Storage password prompt, which was not granted. Production
credential access/signing acceptance remains pending. The test mode is never
selected as a fallback after Keychain failure.
