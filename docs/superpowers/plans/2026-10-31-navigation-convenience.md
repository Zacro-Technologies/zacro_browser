# Navigation convenience tasks

Recorded October 31, 2026 against `main` at `efa25fc`.

**Scope:** Track the requested clipboard-to-new-tab shortcut and a copy button immediately to the right of the address. This update records the plan; NAV-002 remains unimplemented.

## Task index

| ID | Feature | Status | Owner | Dependencies |
| --- | --- | --- | --- | --- |
| NAV-001 | Clipboard to a new tab | Implemented; source and existing tests inspected | No new implementation assignment | None |
| NAV-002 | Copy button to the right of the URL | Planned; not implemented | Unassigned; assign one developer before starting | Existing address row and clipboard support; no dependency on new NAV-001 work |

## NAV-001: Clipboard to a new tab — existing behavior

The existing `paste-search` action reads plain text only when invoked, trims it and creates a new tab without replacing the current page. The existing `normalizeAddress` resolver opens recognized addresses directly and searches other text with the selected search engine. Empty text does nothing; input over 8,000 characters is rejected. Images and files are not a new clipboard-search requirement.

Default shortcuts are **Control+Command+V on macOS** and **Ctrl+Alt+V on Windows**. They are editable through the shared shortcut catalog. Ordinary paste remains an editor action. Do not add a duplicate command or a second clipboard reader.

**Source evidence:**

- `src/core/shortcuts.cjs`: `paste-search` defaults and shortcut editor catalog.
- `src/main/main.cjs`: `runMacAction` handles `paste-search` for native shortcut dispatch.
- `src/core/store.cjs`: `tab:create` uses `normalizeAddress` and the selected search engine.
- `test/shortcuts.test.cjs`: exact modifier matching and ordinary paste separation.
- `test/e2e/command-workflow.test.cjs`: clipboard URL opens directly and increases the tab count to two.
- `docs/MACOS.md` and `docs/RELEASE-NOTES-0.10.md`: existing user-facing shortcut documentation.

These sources establish that a similar feature already exists, satisfying the request to avoid duplicate planned work. Tests were inspected, not rerun for this documentation update. The existing native clipboard case uses a URL; it is not fresh end-to-end proof of clipboard text search on every platform.

## NAV-002: Copy button to the right of the URL

**Goal:** Copy the current address in one click without opening Site controls.

**Likely files:**

- `src/renderer/app.js`: `renderToolbar` address row and action handling.
- `src/renderer/styles.css`: address-row spacing, focus and narrow layout.
- `test/e2e/command-workflow.test.cjs`: native button/clipboard regression.

**Reuse and behavior:**

- Place a copy icon button immediately after the address button and before Site controls. Keep URL editing and existing page/extension controls usable.
- Copy the full current URL represented by that address row, including path, query and fragment, even when the row displays only a hostname. In Split view or Peek, the copied destination must match the address represented by that row, rather than silently selecting another page's URL.
- Reuse the existing shell-only `clipboard:write-text` path, icon/button helpers and success toast. Inspect `ui:site-copy` and `copy-url` before editing; do not blindly reuse a handler that chooses a different page or closes an unrelated dialog. No new dependency, clipboard permission or renderer-to-web-page bridge is required.
- Disable the button when the row has no copyable page address, including the empty/new-tab state. Do not overwrite the clipboard in that state. Report success only after the write succeeds, and use the existing error-reporting path on failure.

**Acceptance criteria:**

- [ ] The URL has a dedicated copy button on its right; clicking copies the exact full represented URL without navigation, tab creation or a Site controls dialog.
- [ ] The button has an accessible name and tooltip, visible keyboard focus, and Enter/Space activation. It remains usable at the minimum sidebar/window sizes and in light/dark appearance; the empty/new-tab state is disabled.
- [ ] A focused native regression checks actual clipboard contents for a URL with path/query/fragment, the represented destination in Split/Peek, and the disabled state. Existing address editing, copy shortcut and Site controls flows continue to work.

**Verification when implemented:** Run the focused native case in `test/e2e/command-workflow.test.cjs`, then that file's affected existing flows, formatting and syntax checks. Inspect narrow, light/dark and keyboard-only layouts. Record the actual tested platform and revision; do not mark other platforms accepted by inference.

**Two-developer coordination:** Assign NAV-002 to one developer. Reserve the address-row/action sections of `app.js`, address styles and this test's fixtures while it is in progress. Coordinate with any browser-UI task touching those sections before merging; other extension/sync work can proceed in its own branch. If host changes in `src/main/main.cjs` prove necessary, agree on ownership first. On a shared Mac, run foreground native tests sequentially. Each developer should use a separate checkout/worktree and branch rather than editing one working directory concurrently.
