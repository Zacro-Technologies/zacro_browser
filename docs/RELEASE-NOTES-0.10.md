# Zacro 0.10 development preview

Version 0.10.0 incorporates the extensions and sync work merged into `main` in PR #4 (`d1e50c6`). It retains the 0.9 sidebar, tab lifecycle, command workflow and optional AI connections. This is a development version, not a signed public release.

## Extensions

- Verified Chrome Web Store acquisition and managed unpacked extensions, with profile-scoped installation, access review, enable/disable/remove controls, update review and rollback.
- Action popups, options pages and a bounded browser API adapter, including distinct `chrome.storage.sync`. Supported capabilities and runtime requirements are documented in the [extension guide](EXTENSIONS.md).
- Reload controls after permission reduction or removal preserve unsaved-page confirmation and warn while existing scripts may still be running.

## Accounts and synchronization

- A separately runnable HTTP/SQLite account service with recovery codes, device management, revocation and cloud-data deletion.
- Explicit links between browser profiles, with independent consent for extension-library and extension-setting synchronization, offline reconciliation and local permission review.
- OS-protected desktop credentials and HTTPS for packaged clients. Unpacked extension directories, AI credentials and subscription connections stay local.

Use the [desktop setup guide](SYNC.md) to try synchronization and the [service operator guide](../services/sync/README.md) for deployment requirements. No public service is configured or operated by this merge.

## Validation and limitations

The [merge validation record](EXTENSIONS-SYNC-VALIDATION.md) records 535 passing Node tests, native integration results and Apple silicon development-package acceptance after manual OS approval. These are results for the revisions named there, not fresh acceptance of every later build. The README's 0.9 screenshots retain their original provenance.

Stock Electron does not provide all Chrome extension APIs. Engine-dependent capabilities still require a separately built and validated Zacro Electron runtime. Current Windows and Intel Mac acceptance, full representative-provider coverage, public sync operations, direct Google sign-in support, signed/notarized distribution and automatic updates remain open. See the [release roadmap](ROADMAP.md).
