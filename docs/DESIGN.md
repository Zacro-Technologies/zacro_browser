# Zacro interface and motion

The 0.2 interface uses a quiet, Space-tinted frame around the web. The sidebar holds a search shortcut, compact favorites, folders, and everyday tabs; each active tab has a distinct raised surface. The main page has a consistent inset and rounded native corners. The home screen puts search first, followed by saved destinations and recent pages from the current profile.

The crossed-Z application icon and curved ribbon illustration are original vector assets. They remain crisp at display scale and do not require image-generation or remote asset services. The interface uses installed system fonts with their real weight variants. Light and dark palettes share the same layout and adapt to the Space color. Muted text remains readable instead of relying on very low opacity.

Windows High Contrast uses system colors, explicit selection/focus outlines, native checkboxes and named Space-color choices. Decorative artwork and blurred page backdrops are omitted in forced-colors mode so controls remain distinct.

## Motion rules

- Short transitions communicate opening, closing, focus, and reordering. Controls respond immediately; no animation blocks navigation or IPC completion.
- Tabs settle into position, Spaces change with a small directional movement, and panels/dialogs enter and leave with restrained translation and opacity.
- State updates reuse unchanged UI sections, preserving focus, search input, scroll position, and ongoing animations.
- Native web pages are laid out only when geometry or visibility actually changes. Ordinary title, history, download, or icon updates must not hide/show an already visible page. Inactive pages detach from the native window hierarchy while their live documents remain available, keeping hidden pages out of platform accessibility navigation without discarding drafts. Modal backdrop capture briefly retains its hidden native surface until capture completes or the 200 ms deadline expires; the command input receives focus immediately.
- `prefers-reduced-motion` disables decorative and transition motion. Switching the preference while a dialog or panel is moving completes its finite transition and focus cleanup. No essential information is communicated only by animation.

## Interaction requirements

The command field follows combobox/listbox keyboard behavior. IME composition must finish before Enter can navigate or send a question. Dialogs isolate background controls, trap Tab, and restore focus to a usable trigger when dismissed. Panel searches retain their input and selection during state updates. F6 moves between the web page and browser controls. Split-view toolbar actions target the focused pane without swapping page positions.

Manual tab names survive web-page title changes, reloads, and restarts. A page preview keeps its JavaScript state, input, and scroll position when promoted. User-written form state is protected by the existing beforeunload decisions.

## Reproducible review

`npm run test:interactive` launches the browser with a fresh disposable profile and a local journal fixture. Use `npm run test:interactive -- --packaged` after packaging to inspect the shipped executable. The fixture includes navigation, a second article, a page-local draft/counter, popup links, and a small download. Close the browser when finished; the launcher removes only its own temporary profile. A manually downloaded test file uses the browser's normal Downloads directory.

`npm run test:e2e` checks real Chromium interactions, focus restoration, sampled text contrast in light/dark themes, reduced motion, responsive layout, native page bounds, and profile boundaries. `npm run test:soak` repeats tab/Peek/split lifecycles, verifies that closed native pages are released and the original draft/reading position survives, and writes resource observations to `test-results/soak.json`. These checks supplement hands-on Windows review; they do not replace a full assistive-technology, real-site, or long-running performance evaluation.
