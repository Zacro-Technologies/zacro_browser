# Zacro 0.2

This Windows development release refines the everyday browsing experience with a new interface and substantial native-page reliability work. It is not a signed commercial release.

## Design and interaction

- Space colors now tint the sidebar and browser chrome. The page sits in an inset, rounded canvas, with matching Peek and library panels.
- Favorites use compact tiles and real site icons. The home screen brings search, saved destinations and recent browsing together.
- Tabs, Spaces, dialogs and panels use coordinated motion. Reduced-motion preferences suppress those effects.
- Light and dark palettes, responsive panels, stronger keyboard focus and an original Zacro icon form a consistent visual system.
- Windows High Contrast uses system colors, visible control states and named theme choices.

## Browsing reliability

- Split panes retain their positions as focus changes; the address bar and page controls follow the focused pane.
- Peek promotion preserves the actual page, including drafts and scroll position, and adds its current destination to History.
- The command palette retains page context with a bounded, temporary backdrop. Private profiles do not generate these captures.
- F6 moves between page and browser controls. Dialog focus, IME composition, Find feedback and focus restoration receive regression coverage.
- Tab names chosen by the user survive subsequent document-title updates and session restoration.
- Window placement and maximized state restore without size drift or off-screen placement after monitor changes.
- Late asynchronous results cannot replace a newer dialog or panel.
- Inactive native pages detach from the window hierarchy while retaining their documents and drafts.

## Data and security

- Favicon requests are isolated by profile, restricted to same-origin raster formats and bounded by size, time and concurrency. Icons remain in memory.
- Explicit history, permission, archive and profile deletion also sanitizes state-recovery copies.
- Current-page AI questions in an empty Space fail clearly without silently switching to paid web research.
- A site permission prompt cannot grant or save access after the originating page becomes inactive or its profile changes.
- The release command verifies Authenticode signatures on the executable and installer when organization signing credentials are supplied.

## Validation and availability

See the [validation record](VALIDATION.md) for the exact automated checks, Computer acceptance workflows and release limitations. `npm run test:interactive` opens a disposable profile and a local site for hands-on testing. `npm run test:soak` exercises repeated real Chromium page lifecycles.

The Windows test installer is `dist/Zacro-0.2.0-x64-Setup.exe`. Account/extension sync, broader extension APIs, subscription AI authentication, scoped browser agents and signed automatic distribution remain release work in the [roadmap](ROADMAP.md). macOS and Linux have not been validated.
