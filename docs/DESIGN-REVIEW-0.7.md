# 0.7 interaction and compact-window review

The design keeps the web page as the central reading surface. Browser controls belong to the surrounding Space-colored window, including Library, Settings and the assistant. A browser panel should be recognizable as application chrome without adding explanatory labels to every control.

## Decisions

- **Small windows:** lower the native minimum and adapt the shell instead of shrinking text. Temporarily make room for a panel when the saved sidebar width and the page cannot coexist; preserve the user's normal sidebar preference when the window grows again. Dialog bodies scroll within the viewport and keep their controls reachable.
- **One motion language:** sidebar and panel width changes use a short monotonic ease. Interrupting an animation starts from its current position. Reduced motion still takes precedence. Space swipes remain a separate, direct-manipulation gesture.
- **Live Library:** the former Library popover hid the native page and substituted a JPEG capped at 1024 pixels. Opening a Library section should retain the real page and its current rendering scale. Browser panels use the window palette and a divider, rather than duplicating the content page's rounded card.
- **Space swipes:** show the actual next Space's favorites, folders and tabs alongside the outgoing Space. The two surfaces move together, reverse together, and settle on release. Preview controls are inert and cannot accidentally activate or duplicate a tab. There is no floating Space-name badge.
- **Quiet chrome:** remove the top-left application logo, visible sidebar toggle and favorite status markers. Keep useful labels in tooltips and accessibility names. The menu, palette and onboarding retain discoverability of the sidebar shortcut.
- **Onboarding:** introduce a few practical workflows, with each displayed shortcut directly editable using the same conflict checks as Settings. A keyboard user must be able to complete, skip and reopen the tour.
- **Application icon:** replace the crossed, shadowed mark with a simple continuous Z and a restrained berry gradient. Generate Windows icons at native 16–256px sizes, including fractional-scale sizes, alongside the macOS icon set.

## Keyboard workflow

Arc's [multitasking guide](https://start.arc.net/master-multitasking) uses Command-T as the entry point for destinations, existing tabs and actions; Control-Tab returns to recent work; and shortcuts can be customized. Its [command list](https://start.arc.net/command-bar-actions) also exposes organization, navigation, Library and settings through search. These patterns inform the defaults and command coverage rather than requiring a memorized shortcut for every control.

Zacro's existing platform-aware catalog remains the source for native menus, command results, tooltips and editable bindings. The new tour uses that same catalog. Sidebar and footer navigation also need ordinary arrows, Home/End, Enter/Space and a keyboard context-menu route. Page editing, IME input and operating-system shortcuts keep their normal meanings.

## Verification

The implementation must be checked at compact and normal window sizes, with keyboard-only input and reduced motion. Native tests should verify that Library does not capture or detach the live page, resizing preserves page state, and a Space preview contains the neighboring Space's real items. Computer review and the final validation record establish which checks have completed; this document records the design decisions, not a release certification.
