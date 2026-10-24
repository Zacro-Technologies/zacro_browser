# Zacro interface and motion

The 0.4 interface follows an [Arc reference and workflow review](DESIGN-REVIEW-0.4.md). Navigation and the address field live inside the sidebar, leaving the page free of a permanent full-width toolbar. The sidebar order is navigation, address, icon favorites, Space identity, folders, a quiet New Tab row, and ordinary tabs. Its footer contains Library, small Space indicators and a creation menu. Page actions and secondary tools live in compact menus. Library groups bookmarks, history, downloads, and archived tabs; Settings uses expandable groups.

The default sidebar is 224px wide; existing saved custom widths remain intact. Tab rows and the footer are 32px high. A raised selected row and hover/focus controls keep other tabs visually quiet, with 16px favicons and readable 12.5-13px text. The native page begins at an 8px top inset on macOS, or 36px on Windows to preserve the native caption controls. Full screen uses 8px. Hiding the sidebar or opening Find moves the page's top to 40px. Shell geometry and native Chromium bounds must match for normal pages, split view, panels and Peek.

The new-tab page contains search, saved destinations, and recent pages. Pinned pages are omitted from home shortcuts while the sidebar is visible. Greetings, slogans, clocks, decorative artwork, repeated Space labels, and permanent keyboard tutorials have been removed. The crossed-Z icon remains an original vector asset. Warm gray and charcoal surfaces carry a restrained Space tint; system fonts use real weight variants.

Ctrl/Command + Shift + B toggles the sidebar. A compact navigation row appears above the page when the sidebar is hidden, preserving the address and sidebar toggle. Native pages reclaim the available width without reloading. There is no surprise edge-hover panel. Ordinary profile details live in the Space switcher; private browsing remains explicitly identified.

Scroll horizontally over the sidebar to move between Spaces in the current profile, or hold Shift while using a vertical mouse wheel. A gesture moves one Space in the scroll direction and stops at either end. A 64px threshold, horizontal-axis preference, and an idle reset after momentum prevent accidental switches during tab-list scrolling. Webpage scrolling is unaffected. Each Space remembers its tab-list position; the active Space shortcut stays in view. Dialogs, tab dragging, pinch/zoom, and window resizing interrupt the gesture.

Windows High Contrast uses system colors, explicit selection/focus outlines, native checkboxes and named Space-color choices. Decorative artwork and blurred page backdrops are omitted in forced-colors mode so controls remain distinct.

macOS uses native traffic lights and a native menu bar. The title area reserves the controls' space with the sidebar shown or hidden; full screen removes that reservation until the controls return. The interface uses familiar ⌃⌥⇧⌘ labels, system typography, inactive-window treatment, Finder wording, and system contrast/transparency preferences. ⌘Tab and ⌘H retain their operating-system actions; ⌃Tab cycles browser tabs. Close Window and Quit are distinct, with Dock reopening and private-session cleanup. See [the Mac guide](MACOS.md) for the full behavior and verification boundary.

## Motion rules

- Motion has an 80–170ms target. The current entrance transitions take 140–160ms; microfeedback takes 100–120ms. Controls respond immediately; no animation delays navigation, input focus, or IPC completion.
- Tab creation, selection, reordering, and folder disclosure use short local movement. Space changes keep their direction. Panels and dialogs enter with restrained opacity and translation; Peek's controls fade in over 120ms. Native page geometry and sidebar width change immediately.
- Dismissal releases panels and modal surfaces immediately, restoring the live page and focus without waiting for an exit animation. Avoid long fades, large travel distances, repeated animation on metadata updates, and transitions that animate the contents of a live web page.
- State updates reuse unchanged UI sections, preserving focus, search input, scroll position, and ongoing animations.
- Native web pages are laid out only when geometry or visibility actually changes. Ordinary title, history, download, or icon updates must not hide/show an already visible page. Inactive pages detach from the native window hierarchy while their live documents remain available, keeping hidden pages out of platform accessibility navigation without discarding drafts. Modal backdrop capture briefly retains its hidden native surface until capture completes or the 200 ms deadline expires; the command input receives focus immediately.
- `prefers-reduced-motion` disables decorative and transition motion. Switching the preference while a dialog or panel is moving completes its finite transition and focus cleanup. No essential information is communicated only by animation.

## Interaction requirements

The command field follows combobox/listbox keyboard behavior. IME composition must finish before Enter can navigate or send a question. Dialogs isolate background controls, trap Tab, and restore focus to a usable trigger when dismissed. Panel searches retain their input and selection during state updates. F6 moves between the web page and browser controls. Split-view navigation and page actions target the focused pane without swapping page positions. Compact menus preserve tooltips, accessible names and keyboard access; secondary tab controls appear on keyboard focus as well as hover.

The sidebar shortcut keeps focus in the active web-page field when invoked there. A toolbar click keeps focus on the toggle so its next action is predictable. Library panels return to the Library opener, and switching Library sections does not lose that return target. Settings disclosures retain their expanded state and input drafts through asynchronous updates.

Manual tab names survive web-page title changes, reloads, and restarts. A page preview keeps its JavaScript state, input, and scroll position when promoted. User-written form state is protected by the existing beforeunload decisions.

## Reproducible review

`npm run test:interactive` launches the browser with a fresh disposable profile and a local journal fixture. Add `-- --showcase` for a populated design-review workspace, or `-- --packaged --showcase` to inspect the packaged executable. The showcase uses prepared demo tabs and bookmarks; only the local active page loads initially. Its Mail, Calendar, Notes and Studio favorites open local demo pages with original PNG icons; visit each once to load those icons through Chromium. The fixture includes navigation, a second article, a page-local draft/counter, popup links, and a small download. Close the browser when finished; the launcher removes only its own temporary profile. A manually downloaded test file uses the browser's normal Downloads directory.

`npm run test:e2e` checks real Chromium interactions, focus restoration, sampled text contrast in light/dark themes, reduced motion, responsive layout, native page bounds, and profile boundaries. `npm run test:soak` repeats tab/Peek/split lifecycles, verifies that closed native pages are released and the original draft/reading position survives, and writes resource observations to `test-results/soak.json`. These checks supplement hands-on Windows review; they do not replace a full assistive-technology, real-site, or long-running performance evaluation.

The [validation record](VALIDATION.md) distinguishes completed checks from pending acceptance for the current revision. Screenshots capture still interface states; they do not demonstrate motion or establish commercial readiness.
