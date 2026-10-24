# Browser security and maintenance

## Trust boundaries

The main process owns operating-system capabilities. The local application renderer receives a narrow IPC action bridge; every invocation must come from that renderer's main frame. Visited websites must never receive this bridge. Remote content uses sandboxed, context-isolated WebContentsViews with Node disabled and normal web security enabled. Navigation accepts HTTP and HTTPS only; internal new-tab pages are rendered by the shell. File, JavaScript and arbitrary external-protocol navigation is rejected. TLS errors are not bypassed.

Each profile has its own Chromium session partition. Private profiles use non-persistent partitions. Browser state filters private records before disk writes and portable exports. Downloads explicitly saved by users remain on disk even when initiated privately. Private browsing does not hide traffic from sites, network operators or the operating system.

Packaged Windows builds disable Electron's RunAsNode, NODE_OPTIONS and main-process CLI inspection fuses, enable OS cookie encryption and embedded ASAR integrity validation, and load application code only from ASAR. Development Electron binaries used by the test harness retain their normal debugging capabilities. HTTP/proxy authentication uses an expiring, single-use request tied to the requesting page and profile; credentials go directly to Chromium's authentication callback and never into browsing-state records.

Site permission decisions are scoped by profile and requesting origin; requests that cannot establish a trustworthy origin must be denied. Unpacked extensions are privileged third-party code: install only after reviewing their identity and requested permissions, do not load them into private profiles, and do not promise Chromium APIs the runtime does not implement.

AI connections are opt-in. Their keys must be encrypted using the OS credential mechanism and never included in renderer snapshots, portable exports or sync records. A local encrypted credential blob is not end-to-end account sync. Page context is untrusted evidence, not authority to execute instructions. This version must not submit purchases, messages or forms on behalf of a model.

PDF context is parsed locally in a disposable worker with input, page, text, time and JavaScript-heap limits. Only static text is shared after explicit selection. No raw PDF file, form annotations, or PDF JavaScript is sent to or executed for the provider.

Site icons are optional, memory-only presentation data. The host retrieves only same-origin raster candidates using the originating Chromium session, refuses redirects, and bounds requests to 128 KiB and four concurrent fetches. PNG dimensions and simple ICO structures are validated before image bytes reach the sandboxed shell. The shell never loads a website's favicon URL directly. SVG and unsupported or cross-origin icons fall back to a monogram; caches cannot cross session partitions.

When a command dialog covers a web page, the shell may receive a temporary local screenshot to preserve the visual background. Captures are bounded, never written to disk or sent to an AI provider, disabled in private profiles, and cleared when the dialog closes or its page/profile changes. Late capture responses must not restore an old profile's image. This is visual presentation, not permission to extract or share page content.

## Data recovery

Browser state is schema-validated on load, written to a flushed temporary file and renamed into place. The previous valid state is retained in `.bak`. Damaged input is preserved for recovery rather than silently destroyed. Explicit history, permission, archive and profile deletion also sanitizes the recovery copies, so a later recovery cannot resurrect cleared records. See [data recovery and deletion](DATA-RECOVERY.md) for the boundaries. Portable imports merge with fresh IDs; they cannot install extension paths, import credentials, grant permissions or replace current settings. Bookmark imports accept web URLs and text labels only.

## Maintenance policy before release

Pin Electron and development tooling in package-lock.json. Dependabot checks weekly, with security alerts reviewed daily by the designated release owner. Chromium/Electron critical fixes must trigger an emergency build and regression pass; the team must name an owner and response time before public release. Never retain a known-vulnerable runtime merely to preserve an extension behavior.

Check runtime advisories, run `npm audit`, review lockfile changes, run the full test suite, test the signed installer and stage updates before promotion. Installer signing, an update origin, signing-key custody and rollback procedures require operational provisioning; source code cannot supply these credentials.

For reports, use GitHub private vulnerability reporting if enabled for this repository. Do not post keys, personal browsing data or exploit details in public issues. Repository administrators must enable and staff a private reporting channel before a public release.

## Reference material

- [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security)
- [Electron process sandbox](https://www.electronjs.org/docs/latest/tutorial/sandbox)
- [Electron extension support](https://www.electronjs.org/docs/latest/api/extensions)
- [Electron releases](https://releases.electronjs.org/)
