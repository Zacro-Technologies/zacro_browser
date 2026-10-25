# Screenshot assets

These images and the linked 0.4 feature PDF are historical captures, made before the current empty-Space command palette, shortcut editor and trackpad feedback changes. Fresh captures are pending; use the current README and interaction guide for usage.

The nine JPEG images were captured from the packaged Zacro 0.4 Windows development application on October 24, 2026 using the Computer plugin for both the final interactions and native window captures. They show the implemented compact sidebar interface with a prepared demo profile and locally served journal pages. The Mail, Calendar, Notes and Studio favorites are local demo destinations with original PNG icons. The captures contain no real account credentials, private browsing history, or simulated AI answers.

The captures are JPEG images, preserved without recompression. The blue pointer highlight belongs to the Computer capture tool and is preserved in the images. The filenames describe the visible feature:

- `home-dark.jpg`: minimal dark launchpad, bookmarks and recent pages.
- `appearance-light.jpg`: light appearance with compact Settings open.
- `workspace.jpg`: navigation and address inside the sidebar, with icon favorites, folders and tabs beside a live page.
- `peek.jpg`: the native link preview.
- `split-view.jpg`: two native pages side by side.
- `command-palette.jpg`: tab search over the temporary page backdrop.
- `bookmarks.jpg`: the searchable Bookmarks panel and Library switcher.
- `focus-mode.jpg`: the live page with the sidebar hidden.
- `optional-ai.jpg`: unconnected Ask Zacro at the Connect Codex stage. This opens Settings, where Sign in with ChatGPT connects a Codex subscription; there is no API-key field or separate API-billing fallback.

The two macOS PNGs are unedited native desktop captures from the packaged 0.4 Apple silicon build on macOS 15.7.9 in disposable [CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40099796398) at commit `f3101841f04cda2e9441734c0b711f6e63c697e2`. They show the compact sidebar, native traffic lights, the application menu and Dock icon in light and dark appearance. Both images were visually reviewed. They supplement the native automated checks and do not establish physical-device acceptance.

Screenshots are still images. They do not demonstrate animation or certify keyboard shortcuts. The Computer tool's chord delivery on this host did not reliably deliver Control; native integration tests cover the Control shortcuts. See [design and interaction notes](../DESIGN.md) for motion, keyboard and accessibility behavior, the [validation record](../VALIDATION.md) for the exact checks, and [release status](../ROADMAP.md) for unfinished product requirements.

Reproduce the demo with `npm run test:interactive -- --packaged --showcase` after packaging. Visit the four favorites once to load their real PNG icons through Chromium, then return to the journal. Reference images used during the design study are linked in [the review](../DESIGN-REVIEW-0.4.md); they are not included in these application captures.
