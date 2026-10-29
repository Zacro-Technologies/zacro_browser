# Zacro Browser

**A familiar home for a more thoughtful way to browse.**

Zacro is an open-source, Arc-inspired browser by Zacro Technologies. Keep your everyday sites close, give each project its own Space, and follow your curiosity without losing your place.

![Zacro with Favorites, Spaces and vertical tabs beside a webpage](docs/screenshots/0.9/workspace.jpg)

## A place for everything

Your sidebar brings Favorites, folders and tabs together. Keep the sites you use every day in Favorites, pin useful pages to a Space, and let temporary tabs clear away with automatic archiving. Closing a Favorite or pin keeps its saved destination ready for next time.

Create **Spaces** for work, personal projects or whatever you're exploring. Give each one its own colors and icon. Use separate **profiles** when you want to keep accounts and browsing data apart.

## Follow a link without losing your place

**Peek** opens a link over the page you're reading. Shift-click to take a look, press Escape to return, or turn the preview into a full tab when you want to keep it. **Split view** puts two pages side by side for comparing, researching or following along.

| Peek | Make each Space yours |
| --- | --- |
| ![A link preview over the current page](docs/screenshots/0.9/peek.jpg) | ![Space colors and appearance controls](docs/screenshots/0.9/space-theme.jpg) |

Screenshots show version 0.9. See the [gallery and capture notes](docs/screenshots/README.md) for more.

## Move at the speed of a thought

Press **⌘T / Ctrl+T** to find a tab, open a site or search the web. The command bar also finds bookmarks, history, Spaces and browser actions. Shortcuts are yours to customize.

Hide the sidebar with **⌘S / Ctrl+S** when you want more room for the page. Your bookmarks, history and downloads are always within reach in Library.

## Bring your tools along

Install compatible extensions from the Chrome Web Store and manage them per profile. Optional account sync can share your extension library and, with separate consent, extension settings across linked desktop profiles. Sync currently requires a separately configured service; browsing works without an account. See [extension compatibility](docs/EXTENSIONS.md) and [sync setup](docs/SYNC.md).

Optional **Ask Zacro** brings questions, summaries and comparisons into your browsing workflow. Choose a connection, review the page or PDF text you want to share, and ask follow-up questions. Supported connections can research the web and let you open the answer's sources when you're ready. See [AI connections and current limits](docs/AI.md).

## Try Zacro

**0.10.0 is an early desktop preview for Windows and macOS.** It is still being refined before a signed public release. Some extensions are unsupported, direct Google sign-in is currently reported blocked, and live AI-provider acceptance remains in progress. Read the [release notes](docs/RELEASE-NOTES-0.10.md) and [website sign-in notes](docs/WEB-SIGN-IN.md) before relying on it as your everyday browser.

To run from source, install Node.js 24 or later:

```sh
npm ci
npm start
```

For more detail: [Mac guide](docs/MACOS.md) · [Roadmap](docs/ROADMAP.md) · [Validation](docs/VALIDATION.md) · [Security](docs/SECURITY.md).

## Help shape it

Share a browsing workflow you'd love to improve, report a bug, or contribute a change. Contributors can start with the [implementation guide](docs/IMPLEMENTATION-CONTRACT.md) and run `npm run verify` before submitting changes.

Zacro is an independent project, unaffiliated with The Browser Company. Original code is licensed under [MIT](LICENSE); third-party components retain their own licenses.
