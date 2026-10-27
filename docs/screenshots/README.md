# Screenshot assets

## Current 0.7 captures

Eight unretouched captures document the 0.7 interface. The six Windows JPEGs were captured with native Computer interactions on October 28, 2026 (JST), using disposable showcase profiles and local demo pages. Original capture bytes are preserved; the blue pointer highlight comes from the capture tool. No account credentials, personal browsing data or simulated AI answers are present.

- `0.7/workspace.jpg`, `0.7/settings.jpg` and `0.7/onboarding.jpg` come from the packaged **`77669476468d53bb66f98d37faddae7c10bb99d8`** build, at a normal window size. They show the quiet chrome, browser-owned panels and editable tour.
- `0.7/compact.jpg`, `0.7/palette.jpg` and `0.7/spaces.jpg` come from the rebuilt **`7f8aba038f805a948e06ed6d90fcc846ae977196`** package, started with the minimum-size QA option. Their captured window is 565×424 pixels, including the native boundary and fractional-scale rounding. They show adaptive Settings, a fully reachable command palette and an inactive Space's context menu.
- `0.7/macos-light.png` and `0.7/macos-dark.png` are whole native desktop captures from the **`7766947`** Apple silicon package in successful [CI run 40579207712](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40579207712), artifact `12769696376`. Its ZIP was SHA-256 verified before extraction. Native controls, menus and the revised Dock icon are visible. The optional New Tab Page was opened explicitly during package acceptance.

All eight images were visually reviewed. The [six-page 0.7 guide](../Zacro-0.7-Design-and-Feature-Guide.pdf) embeds one intact Windows capture per page with explanatory text. Every page was rendered using Poppler and visually inspected; six pages, one embedded image per page and text extraction were verified. These stills do not prove motion quality, physical trackpad behavior or live Google/AI authentication. See [validation](../VALIDATION.md) for the separate tests and limitations.

## Historical 0.6 captures

The following four JPEGs were captured through native Computer interactions and window capture from the packaged Windows 0.6 development build at commit `1f130cb9719976e54981a63450263af33cbf3862` on October 26, 2026 (JST). They use an isolated showcase profile and locally served journal/demo pages. The images are unretouched originals, preserved without recompression; the blue pointer highlight belongs to the capture tool.

- `0.6/workspace.jpg`: compact navigation, icon favorites, folders and tabs beside a live journal page.
- `0.6/palette.jpg`: scoped command results over the page-only blurred backdrop, with the sidebar available.
- `0.6/space-theme.jpg`: Space icon, color and material controls with a live preview.
- `0.6/customization.jpg`: layout, motion and idle-favorite preferences.

The fifth image, `0.6/ai-workflow.jpg`, was captured through Computer from the rebuilt package at **`9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`** on the same date. It shows an unsent summary question, the explicitly selected local journal page, and the disconnected ChatGPT subscription choice. The question is fully visible after the composer-sizing correction.

All five images were visually reviewed. They contain no personal browsing data, account credentials, authenticated provider session or AI answers. The [five-page 0.6 feature guide](../Zacro-0.6-Design-and-Feature-Guide.pdf) preserves one intact image per page, with concise captions and embedded text. Every page was rendered with Poppler and visually inspected; page count and image presence were also checked. The PDF SHA-256 is `5C6717BA6D2BEB79F1FB400CF92F1385426E0B3B5497151F7A17C7127D2ED19F`.

`0.6/macos-light.png` and `0.6/macos-dark.png` are unedited native desktop captures from the final **`9bfcd1c104c5d9a7f9725fce93e32ac5fcd3ce17`** Apple silicon package on macOS 15.7.9 build 24G830, retrieved from successful [CI run 40222980054](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40222980054), artifact `12610675900` (`macos-arm64-validation`). Both were visually reviewed. They show the complete native window, traffic lights, application menu and Dock icon. The optional New Tab Page was opened explicitly for package acceptance; an empty Space normally opens the command palette. They supplement automated checks and do not establish physical-device acceptance. The 0.5 Mac captures below retain their historical provenance. See [the validation record](../VALIDATION.md#06-space-materials-motion-favorites-and-ai-workflows) for the tested revisions and remaining acceptance work.

## Historical 0.5 captures

The five JPEGs in `0.5/` were captured from the packaged Zacro 0.5 Windows development application on October 25, 2026 using the Computer plugin for native interactions and window capture. They show an isolated local demo workspace, with locally served journal pages and demo favorites. They are unretouched native captures, preserved without recompression; any blue pointer highlight belongs to the capture tool.

- `0.5/workspace.jpg`: compact sidebar navigation, icon favorites, folders and tabs beside a live journal page.
- `0.5/palette.jpg`: the command palette with browser actions and an interactive sidebar.
- `0.5/shortcuts.jpg`: searchable, customizable keyboard bindings with Arc-style defaults.
- `0.5/ai-connections.jpg`: the OpenAI API configuration form within the six-provider Settings chooser.
- `0.5/blank-space.jpg`: a Space opening the command palette without creating a disposable blank tab.

The captures contain no real account credentials, private browsing history, live subscription sign-in, or AI answers. The AI connection image shows configuration choices; it does not establish authentication or inference acceptance. The [0.5 design and feature guide](../Zacro-0.5-Design-and-Feature-Guide.pdf) uses these five images; every page was rendered with Poppler and visually inspected. See the [validation record](../VALIDATION.md) for the separate test and review status.

`0.5/macos-light.png` and `0.5/macos-dark.png` are unedited native desktop captures from the packaged Apple silicon build on macOS 15.7.9 in [CI run 40190619770](https://github.com/Zacro-Technologies/zacro_browser/actions/runs/40190619770), commit `4913177dfe5998608bdc2f1ab1d5f02115986167`. Both were visually reviewed. They show native traffic lights, the application menu, Dock icon and the optional New Tab Page opened explicitly during acceptance. Empty Spaces normally open the command palette. These disposable-profile captures supplement automated Mac checks and do not establish physical-device acceptance.

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
