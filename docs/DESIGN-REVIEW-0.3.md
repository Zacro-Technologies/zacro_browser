# Interface review: 0.3

## Reference study before implementation

Reviewed October 24, 2026. The previous interface repeated navigation and Space identity, put the first working tab roughly 320 pixels below the window edge, and treated a new tab like a promotional dashboard. The redesign prioritizes the page, fast navigation, and a stable working set.

Reference images and interaction descriptions:

- [Arc desktop screenshot on Pinterest](https://www.pinterest.com/pin/630644754085582898/): compact icon favorites, single-line tab titles, a quiet selected row, and a thin frame around the page.
- [Arc widget concept on Pinterest](https://www.pinterest.com/pin/616922848996402773/): one input and a recent destination. This is an inspiration concept, not an official Arc feature.
- [Arc: Find deep focus](https://start.arc.net/find-focus): intentional sidebar hiding and split view for reading and comparison.
- [Arc command-bar actions](https://start.arc.net/command-bar-actions): secondary operations belong in commands and menus instead of persistent instructional UI.
- [Zen compact mode](https://docs.zen-browser.app/user-manual/compact-mode): a visible route into focused browsing, without taking access to navigation away.

These references inform information hierarchy and interaction. Zacro retains its own icon, colors, implementation, and Windows controls. Reference images are not shipped as product assets.

## Daily flows

| Intent | Primary route | Design decision |
| --- | --- | --- |
| Open a destination | Address field or New tab | One command surface; a new tab immediately focuses it. No second sidebar search field. |
| Return to an open page | Pinned icons or tab list | Compact favorites, stable 34px tab rows, one active surface. Titles stay readable; URLs appear on hover and in the address bar. |
| Organize ongoing work | Folder button and tab context menu | Folders share the tab rhythm. Counts and actions stay secondary. No permanent section heading explaining tabs. |
| Change context | Space name or bottom Space shortcuts | Keep one Space name visible. Ordinary profile details live in the switcher; private status remains explicit. |
| Read without chrome | Sidebar toggle | A deliberate toggle, with a persistent way back. Avoid surprise edge-hover panels. |
| Follow a temporary lead | Peek | Title/origin, promote, close. Preserve the living page and the underlying reading position. |
| Compare pages | Split view | Keep pane positions stable and navigation attached to the focused pane. |
| Revisit saved material | Library | A compact library chooser with searchable lists. Remove duplicate home links to every library panel. |
| Configure the browser | Settings | Short labels and grouped controls. Keep data-sharing, billing, and destructive-action explanations where decisions are made. |

## Layout contract

- Toolbar: 44px high; controls use at least 28px hit targets. The host's native page coordinates must match the rendered shell.
- Sidebar: 230px default, with the existing width preference preserved. Compact Space header; icon-only favorites; 34px tab rows; one bottom utility strip. The first working tabs should appear within the upper fifth of a 900px window for a representative workspace.
- Page: 8px outer frame, 6px split gap, restrained 10px corners. Use available width for web content.
- Panels: maximum 360px, 48px header, 16px body padding. Use list rows rather than stacked decorative cards.
- New tab: search first, small saved destinations, up to three recent pages. Remove greeting, slogan, clock, ribbon, repeated Space picker, promotional empty state, and keyboard tutorials.
- Command palette: compact result rows, short action labels, minimal footer hints. Show URL/context only when it distinguishes a result.
- Color: warm neutral light surfaces and charcoal dark surfaces, with a subtle Space tint. Reserve emphasis for selection, focus, and meaningful actions.
- Motion: an 80–170ms target, with short local feedback and entrances. Dismissal, native geometry, and focus restoration happen immediately; closing a surface must never hold the page behind an exit animation. Reduced motion and forced colors remain supported.
- Icons: every icon-only action retains a tooltip, accessible name, and visible keyboard focus. Less visible text must not remove accessibility labels.

## Acceptance review

Review a representative workspace with eight or more tabs, folders, and pinned pages, alongside an empty Space. Check light and dark appearance, a 1000×700 window, panel opening, keyboard command selection, focus restoration, Peek promotion, and stable split panes. Capture real application screenshots after the interaction checks. Update README images only after reviewing the actual redesign.

The follow-up motion review uses repeated actions, not only screenshots: open and dismiss surfaces in quick succession, switch tabs and Spaces, expand folders, and toggle the sidebar while typing in a page. Look for delayed feedback, delayed dismissal, focus changes, and stale animation callbacks. The reduced-motion path must complete the same state and focus transitions immediately.
