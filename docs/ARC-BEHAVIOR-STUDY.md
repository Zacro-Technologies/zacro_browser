# Arc behavior study · October 2026

This review uses the eight Arc images supplied by the user, the Browser Company's published interaction documentation and release notes, and the actual Zacro code paths. It distinguishes documented behavior from visual interpretation. Some retired Help Center pages remain searchable but their direct URLs now return errors; no live Arc session is claimed.

## The three kinds of tab

| Kind | Scope and appearance | Navigation and lifetime |
| --- | --- | --- |
| Favorite | Icon tile above the Space title; shared by Spaces in the same profile | One live page, with a saved destination; persists when closed |
| Pinned | Named row, optionally in a folder, above the horizontal divider | Keeps its saved destination; no automatic archive; favicon resets it |
| Today | Named row below the divider | Temporary, archived after inactivity; restored through Archive |

Arc explicitly distinguishes [Favorites](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space), [pins](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around) and [profile-scoped settings](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing). Dragging across the boundaries changes the kind of tab, rather than copying the document. A profile boundary must never share a live session.

The user's `Screenshot-2022-12-07-at-2.45.05-PM.webp` shows a forward slash between the favicon and saved title on navigated pins. It is absent on pins at their saved destination. Arc's [October 6, 2021 release notes](https://resources.arc.net/hc/en-us/articles/20498463803799-Arc-for-macOS-2021-Release-Notes) describe the indicator and favicon reset. This means the displayed saved name, saved address, current address and live document are separate state. Hash/history navigation also needs to update the indicator without discarding the favicon.

Closing a navigated pin releases the current page after any unsaved-work decision, retains the pin at its saved address and clears the slash. Reopening loads that address. Close and Reset are distinct [command actions](https://start.arc.net/command-bar-actions); this review does not reinterpret Command-W as an immediate reload that keeps the old page active.

## Temporary tabs and inactivity

Arc's [Auto Archive documentation](https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go) specifies a **12-hour** default, reset when a tab is viewed or clicked, with profile-specific timing. The archive is recoverable. It does not document all sleep/restart edge cases. Arc's [2022 release notes](https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes) explicitly exclude playing media.

Zacro previously defaulted to 24 hours and excluded every loaded page. That made ordinary loaded tabs effectively permanent. The corrected policy permits clean background pages to expire, protects active and split pages, media, downloads, edited forms and authentication openers, and honors a silent beforeunload veto. A second eligibility check after asynchronous inspection prevents an intervening user selection from being archived. Persisted inactivity counts across restarts; the selected page is protected. Existing explicit timing choices survive migration. Zacro retains its optional Never setting, unlike Arc.

## Favorite sizing and visual hierarchy

The supplied Peek image shows six Favorites in two rows of three. The split-view reference shows four in one row, and the theming image shows three broad tiles. A fixed four-column grid is inconsistent with those references. The new layout balances one to four tiles in each row and fills the available width: five becomes three plus two, six becomes three plus three, and nine becomes three rows of three. The layout responds to sidebar resizing. This is a reference-informed algorithm, not a claim to know Arc's private layout code. Arc documents a maximum of twelve; Zacro preserves larger existing collections with bounded scrolling.

The divider communicates persistence without another explanatory heading. The New tab row opens the command palette, not a disposable blank page. Favorite activation returns to the existing live page; Reset remains an explicit action. Selected rows keep readable contrast in both appearances.

## Motion and chrome

Arc documents [two-finger Space switching](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas). A still image cannot establish a motion curve. The user's requested behavior is the acceptance target: the window's primary and secondary colors follow the actual sideways displacement, reverse when the finger reverses, and settle with the incoming Space. Color must not jump only after the selected Space changes. Edge resistance does not blend toward a nonexistent Space. Accessibility preferences remain authoritative.

The user's follow-up sets the palette treatment: a floating card and shadow, with no blur, tint or radius change to the page behind it. The Library shares the window material without a vertical border. Color swatches have equal dimensions; transparency and grain extend to stronger settings without fading text or web pages. Numeric controls provide the necessary feedback without an explanatory paragraph beneath the opacity slider.

Peek should enter and leave as a single surface. A short vertical lift, settling shadow and scrim provide depth while native content keeps its exact resolution. Interruptions, replacement, promotion and a canceled close must retain the same live document and reset animation state. Reduced motion removes travel. These are deliberate Zacro motion choices informed by the user's reference, not measured Arc timings.

## Acceptance scenarios

- Switch between two Spaces of one profile, then a different profile: Favorites share only within the first profile; pins and Today never leak between Spaces.
- Follow a pin to a subpage and a hash: show the slash, keep the saved title and icon, close with Command/Ctrl-W, and reopen at the saved address.
- Add one through twelve Favorites and resize the sidebar: fill every row without empty slots or undersized targets.
- Expire a clean loaded Today tab; preserve a recently selected tab, unsaved form, media page and login opener; restore the archived title and address.
- Partially swipe, reverse, cancel, commit and interrupt with a dialog: colors and tab positions must agree at every sampled stage.
- Open the palette over a real page: no filter or tint, unchanged page radius, visible card shadow.
- Open, dismiss, replace and promote Peek; veto a close with unsaved work; repeat with reduced motion.

Google account rejection is a separate engine compatibility issue. [Google's embedded-browser guidance](https://developers.googleblog.com/en/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/) requires a supported complete browser and truthful identity. UI polish, popup preservation and spoofing another browser are not evidence of successful sign-in. See [the current engine boundary](WEB-SIGN-IN.md).
