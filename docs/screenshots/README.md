# Screenshot assets

## Current 0.5 captures

The five JPEGs in `0.5/` were captured from the packaged Zacro 0.5 Windows development application on October 25, 2026 using the Computer plugin for native interactions and window capture. They show an isolated local demo workspace, with locally served journal pages and demo favorites. They are unretouched native captures, preserved without recompression; any blue pointer highlight belongs to the capture tool.

- `0.5/workspace.jpg`: compact sidebar navigation, icon favorites, folders and tabs beside a live journal page.
- `0.5/palette.jpg`: the command palette with browser actions and an interactive sidebar.
- `0.5/shortcuts.jpg`: searchable, customizable keyboard bindings with Arc-style defaults.
- `0.5/ai-connections.jpg`: the OpenAI API configuration form within the six-provider Settings chooser.
- `0.5/blank-space.jpg`: a Space opening the command palette without creating a disposable blank tab.

The captures contain no real account credentials, private browsing history, live subscription sign-in, or AI answers. The AI connection image shows configuration choices; it does not establish authentication or inference acceptance. The [0.5 design and feature guide](../Zacro-0.5-Design-and-Feature-Guide.pdf) uses these five images; every page was rendered with Poppler and visually inspected. See the [validation record](../VALIDATION.md) for the separate test and review status.

## Historical 0.4 captures

The images below and the [0.4 feature guide](../Zacro-0.4-Design-and-Feature-Guide.pdf) predate the current empty-Space command palette, shortcut editor, provider selection and trackpad feedback. Use the current README and interaction guide for usage.

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
- `optional-ai.jpg`: the earlier unconnected Ask Zacro panel at the Connect Codex stage. That revision offered only the ChatGPT subscription connection; the current six-provider interface is shown in `0.5/ai-connections.jpg`.

The two macOS PNGs are unedited native desktop captures from the packaged 0.4 Apple silicon build on macOS 15.7.9 in disposable [CI](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40099796398) at commit `f3101841f04cda2e9441734c0b711f6e63c697e2`. They show the compact sidebar, native traffic lights, the application menu and Dock icon in light and dark appearance. Both images were visually reviewed. They supplement the native automated checks and do not establish physical-device acceptance.

## Scope and reproduction

Screenshots are still images. They do not demonstrate animation or certify keyboard shortcuts. The Computer tool's chord delivery on this host did not reliably deliver Control; native integration tests cover the Control shortcuts. See [design and interaction notes](../DESIGN.md) for motion, keyboard and accessibility behavior, the [validation record](../VALIDATION.md) for the exact checks, and [release status](../ROADMAP.md) for unfinished product requirements.

Reproduce the demo with `npm run test:interactive -- --packaged --showcase` after packaging. Visit the four favorites once to load their real PNG icons through Chromium, then return to the journal. Reference images used during the design study are linked in [the review](../DESIGN-REVIEW-0.4.md); they are not included in these application captures.
