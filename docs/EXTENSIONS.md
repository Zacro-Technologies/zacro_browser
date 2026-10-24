# Extensions on Electron

The `extensions-and-sync` branch adds verified Chrome Web Store acquisition,
profile-scoped extension controls, and a Zacro compatibility adapter. Development
acceptance is still in progress; the [validation record](EXTENSIONS-SYNC-VALIDATION.md)
distinguishes working checks from open lifecycle and platform gates. This is a
bounded compatibility layer, not Chrome-wide extension support.

## Install and manage

Open **Library → Settings → Extensions → Manage extensions**. Choose **Install
from Chrome Web Store**, paste a canonical detail URL or extension ID, and review
the downloaded extension's name, version, source, target profile and access. If
the current tab is a recognized store detail page, the field starts with that
address. Web pages cannot invoke installation themselves.

Packages come from Google's HTTPS distribution endpoint. Zacro verifies CRX3
developer identity and the production publisher proof, bounds downloads and
archive expansion, and rejects unsafe archive paths. It retains the immutable
original and runs a separately hashed managed compatibility copy. The derived
copy is not represented as retaining the original package's signature.

**Load unpacked extension** copies a selected local folder into managed storage.
Local sources are labeled **Only on this device** and are not uploaded. Install
only trusted extensions: their approved access can allow reading and changing
web pages. Private profiles never load extensions.

Each extension card exposes its state, granted permissions, compatibility
limitations, action and options pages, update review, and rollback where a
previous version exists. Updates are checked when due at startup and on a
jittered six-hour schedule. **Check for updates** requests an immediate check.
Additional permissions pause an update for review. A failed replacement retains
the preceding usable version where restoration is possible. Rollback rebuilds
the retained original with the reviewed required permissions; optional access
is not restored from an older native copy and must be granted again.

Disabling or removing revokes native and adapter access immediately. Scripts
already running inside pages may require a page reload. Zacro offers to reload;
unsaved pages retain their normal leave confirmation. A reduction that still
has affected documents remains disabled with **Reload pages to finish**. A page
warning and **Reload page** control remain in the toolbar and Extensions panel
after local or synchronized removal, even though the extension is no longer
installed. Choosing Stay preserves both the draft and warning. Navigating,
reloading, or closing the affected document clears its warning.

## Supported boundaries

The adapter supplies action/browserAction state and host-opened popup views;
declared options pages; profile-scoped tab operations and events; the existing
single browser window; page/link/selection context menus; manifest commands;
reviewed optional permission changes; and distinct `chrome.storage.sync`.
The exact tested method/context matrix is in the validation record. Undeclared
uses of additional APIs can still fail even when manifest inspection passes.

The adapter surface is deliberately bounded:

| API | Implemented surface | Boundary |
| --- | --- | --- |
| `storage.sync` | `get`, `getKeys`, `getBytesInUse`, `set`, `remove`, `clear`, `setAccessLevel`, change listeners | Strict JSON values and documented quotas; consent controls network synchronization. |
| `tabs` | `get`, `getCurrent`, `query`, `create`, `update`, `reload`, `duplicate`, `remove`, `move`; created/updated/activated/removed events | Current extension profile only; browser guest IDs exclude shell, broker and separate options/action windows. |
| `windows` | `get`, `getCurrent`, `getAll`, `update`, focus-change event | Existing single browser window; no window creation/removal API. |
| `action` / `browserAction` | Title, popup, badge text/colors, packaged icon, enable/disable, click listener | Browser controls open the popup; ImageData and extension-invoked `openPopup` reject. |
| `runtime` | `openOptionsPage` | Declared own-extension page only; other runtime messaging stays native. |
| `contextMenus` | `create`, `update`, `remove`, `removeAll`, click event | Supported contexts/patterns and checkbox/radio groups; use `onClicked`, not an inline `onclick` function. |
| `commands` | `getAll`, command event, declared shortcut dispatch | Browser/system shortcuts keep priority; conflicts and unassigned commands are visible. |
| `permissions` | `getAll`, `contains`, `request`, `remove`, added/removed events | Reviewed optional supported rights only; native manifest rebuild can disconnect the original caller. |

These are implemented method boundaries, not proof of all Chrome overloads or
all third-party extensions. The validation record identifies actual native
flows and intentionally negative engine probes. Unsupported method/property
combinations return errors instead of reporting a successful no-op.

Native runtime messaging and `storage.local` remain native. MV3 native isolated
programmatic and registered scripting receive the compatibility bootstrap.
Main-world scripts receive no privileged adapter. Native `webRequest` is not
replaced by the browser's PDF detection; page content type is read on demand.

Electron 45 cannot supply a native one-tab temporary `activeTab` grant through
the host's extension action. Required `activeTab` is rejected before activation;
optional `activeTab` cannot be granted. Zacro does not replace it with broad host
permissions. MV2 native `scripting` is also unavailable. Native messaging,
identity services, DNR/offscreen/userScripts and other absent engine features
remain unsupported. `action.setIcon` currently accepts packaged image paths,
not ImageData; extension-invoked `action.openPopup` is not implemented.

Persistent MV2 script/HTML backgrounds, MV2 lazy event pages, and MV3
classic/module workers pass real API tests. Tests stop genuine native workers
or wait for an event page to suspend, then verify host events wake the original
background and reach its listeners. Pending notifications have bounded queues
and readiness deadlines; process crashes do not have an exactly-once delivery
guarantee. Ordinary HTTP subframes work, while opaque sandboxed origins fail
closed. Existing derived copies retain their recorded adapter until reinstalled
or updated.

## Synchronization

Follow [Account & sync](SYNC.md) to run or connect to a service and explicitly
link profiles. The library contains portable source IDs and enabled/disabled/
removed intent. A new device shows **Needs installation on this device** and
requires its own permission review. Declining does not remove other devices'
installations. Local execution, cloud intent, and remote approval are separate.

Settings synchronization starts off and requires separate consent. Extensions
choose what they write to `chrome.storage.sync`; those values can include
personal information or credentials. `storage.local` remains local. The service
encrypts data at rest but can decrypt it; this is not end-to-end encryption.
Without a linked account, sync storage is a distinct local namespace. Cookies,
site sessions, browser passwords and AI authentication are not copied into it.

## Reproduce acceptance

Run `npm run verify` for offline unit and Electron integration tests. The
two-desktop fixtures run the actual account service, desktop UI and extension
APIs, substituting only the externally verified download boundary with a signed
synthetic package. They do not mock synchronization or extension API execution.

`npm run test:provider` is a separate, explicit online check that downloads and
executes version-pinned JSON Formatter in a disposable browser profile. It uses
the production package verifier and real provider. Provider changes are surfaced
as failures; no mirror or publisher-test key is accepted in production.
