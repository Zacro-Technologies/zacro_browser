# 0.8 interaction and design review

## References and decisions

Arc's [Pinned Tabs](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), [Favorites](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space), [command actions](https://start.arc.net/command-bar-actions), [multitasking workflow](https://start.arc.net/master-multitasking) and [Site Search](https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website) informed the changes. These are interaction references, not claims of complete Arc equivalence.

The working hierarchy is navigation → address → profile Favorites → Space identity → folders and Space pins → ordinary tabs. Favorites are icons; pins are named rows. Both preserve a saved destination independently of the current page. Dragging between these three regions changes the appropriate kind without duplicating the live page. Favoriting does not silently impose a cap or discard imported data.

Library begins with a named destination menu. An open panel has a single title chooser instead of a dense navigation strip. Flat rows, date groups, persistent search and contextual download actions reduce competing controls. Its material is the same continuous window material as the sidebar, with no separate webpage card styling.

The resizable sidebar and Library edges move native page bounds continuously. Keyboard users can focus each separator and use arrows, Shift for larger increments, Alt for single pixels, Home/End and double-click reset. Compact widths preserve a usable page and retain saved preferences.

Commands now support result actions and destination drilling, folder reveal, reset/replace pin actions, Space pin reset and editable site-search keywords. Tab enters the next step, Escape returns to the previous one, and Page Up/Down traverses results. Dark selection adds a clear fill, outline and accent edge. Filters use a text underline instead of pill controls.

Space appearance offers 38 searchable icons. Window tint opacity controls the native desktop-blurred material on supported platforms while preserving sharp text and opaque webpages. Blur strength follows the operating system; an arbitrary pixel slider would misrepresent what native APIs support. Opaque fallback respects accessibility preferences.

## Scope and evidence

Shift-click Peek, profile-wide live Favorites, saved pin destinations, canceled unsaved-work navigation and the Library's live-page retention have native regression coverage. Hands-on Windows review and current capture provenance are recorded separately. Physical Mac trackpad behavior and macOS material quality require review on a Mac.

Google rejects direct account login in the current reported environment. Popup/session mechanics and FedCM are separate from that provider rejection. The 0.8 interface work does not claim to solve it; see [website sign-in and engine work](WEB-SIGN-IN.md).

A polished interface does not close the remaining signed-release, update, security, accessibility, real-provider or engine compatibility gates in the [roadmap](ROADMAP.md).
