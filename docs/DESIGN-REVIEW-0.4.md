# Interface review: 0.4

## Reference study before implementation

Reviewed October 24, 2026. The 0.3 interface is compact in individual controls but still gives the page a conventional full-width browser toolbar. Arc's defining layout puts navigation and the address field inside the sidebar, so the page can reach the top inset. The next pass changes that hierarchy before polishing colors or animation.

The primary reference is the Arc illustration on [Arc's official website](https://arc.net/), specifically its `.window--arc` component rather than the separate Dia illustration. Its [published stylesheet](https://arc.net/_next/static/css/7627201d979738b0.css) supplies useful proportions: a 226.5px sidebar, 36px sidebar navigation row, 35px address field, 9.7px page inset, 8px page corners, 38px tab rows and 36px footer. These are website illustration measurements, not measurements of the native application's implementation.

Actual desktop images were also inspected: [a populated Arc sidebar](https://dannyspina.com/images/blog/arc_browser/sidebar.png) and [a compact light sidebar](https://assets.hongkiat.com/uploads/arc-browser-keyboard-shortcuts/tabs.jpg). They confirm the order: navigation, address, icon favorites, Space name, folders/pinned pages, a quiet divider, New Tab, regular tabs, and a bottom utility strip. Official descriptions explain [Favorites above Space titles](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space), [pinned tabs above the divider](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), and [Library at the bottom left](https://resources.arc.net/hc/en-us/articles/19230634389911-Library-A-home-for-your-downloads-archived-tabs-easels-and-more). Some help pages remain searchable but their direct URLs currently return 404. Pinterest references were searched; direct pin access returned 403, so unseen pins are not treated as visual evidence.

## Decisions

- Put the address and navigation controls in the sidebar. Remove the duplicated full-width address toolbar. Preserve native window controls and a dependable way to navigate when the sidebar is hidden; never cover clickable website content with caption controls.
- Let the page occupy the freed vertical space, with a thin 6–8px frame and restrained corners. Keep shell coordinates and native Chromium view bounds identical, including split views, panels and Peek.
- Keep Space identity below favorites. Replace the permanent New Tab/folder action strip with a quiet New Tab row and contextual creation actions. Use the footer for Library, small Space indicators and one creation menu.
- Aim for 30–32px tab rows and 12.5–13px text. Preserve readable titles, 16px favicons, and at least 24px actionable targets. Shrinking text below comfortable reading size is not a substitute for removing duplicate controls.
- Show close and secondary controls on hover **and keyboard focus**. Keep tooltips, accessible names, explicit private-session status, and visible focus rings. Settings, AI, bookmarks and split actions remain reachable through menus and commands.
- Use a soft Space tint for the sidebar and frame. Inactive rows are unboxed; the selected row is the main raised surface. Avoid repeated borders, badges, explanatory headings and duplicate destination lists.
- Keep local feedback around 100–140ms. State, native page geometry and dismissal remain immediate. Interrupted transitions must not move focus later; reduced motion preserves the same interaction behavior without decorative movement.

These changes preserve Zacro's own identity and implementation. Reference screenshots and Arc brand assets are not product assets. The hierarchy is the reference; existing browser features are not removed to make a screenshot look cleaner.

## Layout contract

The implementation uses a 224px default sidebar and preserves saved custom widths. Tab rows and the footer are 32px high. With the sidebar visible, the page begins 8px from the top on macOS; Windows reserves 36px for window controls. Full screen uses the 8px inset. Page content begins at 40px when the sidebar is hidden or Find is open. The shell and native Chromium views must use the same bounds, including split view and Peek. See the [validation record](VALIDATION.md#04-interface-revision) for current acceptance status.

## Acceptance

Review the actual running browser with a populated workspace and an empty Space, in light/dark appearance and a small window. Check address visibility, long titles, folder nesting, favorite icons, bottom Space navigation, hover/focus controls, hidden-sidebar recovery, Settings, Library, AI, split view and Peek. Switch Spaces sideways while a live page retains its draft and scroll position. Verify native Windows and Mac geometry separately. Capture final application screenshots only after interaction checks pass.
