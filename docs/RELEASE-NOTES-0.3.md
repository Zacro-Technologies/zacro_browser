# Zacro 0.3 — compact interface

The interface has been redesigned after reviewing Arc, Pinterest browser references, and Zen's compact browsing flow. The [design review](DESIGN-REVIEW-0.3.md) records the decisions made before implementation.

- Compact 44px toolbar, 230px default sidebar, and 34px tab rows.
- Icon favorites, one Space heading, and a single bottom utility strip.
- A minimal new-tab page: search, saved pages, and recent destinations.
- Library chooser with quick switching between bookmarks, history, downloads, and archived tabs.
- Smaller panels and command results; expandable Settings groups.
- Ctrl/Command + Shift + B hides or shows the sidebar while keeping live pages intact.
- Horizontal scrolling over the sidebar switches Spaces within the current profile. Shift + mouse wheel works too. One switch per gesture, edge stops, directional motion, and remembered tab-list positions keep navigation predictable.
- Refined light/dark colors, quick 100–160ms interface feedback, immediate dismissal, named icon controls, keyboard focus, reduced motion, and forced-color support.
- Sidebar shortcuts preserve focus in page fields; Library returns focus to its opener; Settings preserves expanded groups and drafts.
- Optional AI now uses ChatGPT sign-in and the user's Codex allowance through a bundled, isolated app-server. API-key and Claude connections have been removed; requests never fall back to separate API billing.
- Codex credentials use an isolated OS keyring entry. Research can use hosted web search; explicitly shared page/PDF context uses search-disabled requests with no execution environments.

Existing sidebar-width preferences are preserved. The default applies to new profiles.

This remains a development build. Real subscription sign-in and inference require the user to complete authentication and remain an acceptance step. The [commercial release requirements](ROADMAP.md) and [AI boundaries](AI.md) still apply.
