# Extension native messaging

Zacro retains Electron and routes `chrome.runtime.connectNative` and
`chrome.runtime.sendNativeMessage` to a main-process host broker. Electron's
native delegate remains denied; only the authenticated compatibility transport
may ask this broker to launch a reviewed, registered host.

The protocol and registration rules follow the primary
[Chrome native messaging documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

## Registration discovery

A host name contains only lowercase ASCII letters, digits, underscores and
single dots between nonempty components; Zacro limits names to 255 characters.
Zacro never searches `$PATH`, accepts an executable URL, or invokes a shell.
The host's JSON file must declare the exact requested `name`, a string
`description`, `type: "stdio"`, an executable `path`, and an `allowed_origins`
array of exact `chrome-extension://<32-character-extension-id>/` origins.
Wildcards and malformed origins are rejected, even if another listed origin
would match.

Zacro checks Google Chrome registrations in this order:

| OS | User registration | Machine registration |
| --- | --- | --- |
| macOS | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/<name>.json` | `/Library/Google/Chrome/NativeMessagingHosts/<name>.json` |
| Linux | `~/.config/google-chrome/NativeMessagingHosts/<name>.json` | `/etc/opt/chrome/native-messaging-hosts/<name>.json` |
| Windows | `HKCU\Software\Google\Chrome\NativeMessagingHosts\<name>` | `HKLM\Software\Google\Chrome\NativeMessagingHosts\<name>` |

On Windows the registry key's default `REG_SZ` value supplies the absolute
manifest path. Zacro queries HKCU then HKLM in the 32-bit view, followed by
HKCU then HKLM in the 64-bit view, stopping at the first registration. It uses
`reg.exe` directly with fixed arguments. Windows executable paths may be
relative to the manifest directory; macOS and Linux executable paths must be
absolute. A malformed existing registration is denied instead of falling
through to a different host. Chromium, Chrome for Testing, other browsers,
custom profile directories and arbitrary executable directories are not searched.

## Local review and authority

The calling extension must hold `nativeMessaging` and run in a verified
extension document, background page or service worker. Content scripts cannot
call these methods directly. Renderer-supplied host names, port IDs and
payloads never confer a profile, extension, generation or document identity.
Native ports belong to one authenticated context; a port ID from another
profile, generation or document has no authority.

The main process presents a local review before starting an unapproved host.
Review identity binds the profile and extension to the registered manifest
path, canonical manifest path, exact manifest SHA-256, registered and canonical
executable paths, executable SHA-256 and filesystem identity. Approval is
remembered only in the running broker, for an unchanged identity, with a
256-entry cache. It is never synced. The resolver verifies the entire identity
again after review and immediately before launch; changing the registration or
executable requires a new review. Symlink target changes also change identity.

Native hosts run as external applications under the user's OS account. They
have the account's normal filesystem and network authority. Extension pages
and workers retain their Electron sandbox, context isolation and lack of Node
access. Local host approval is the boundary for starting an external program;
it does not place that external program into Electron's renderer sandbox.
As with other path-based native launchers, an OS process with write access to
the host files can race the final verification and `spawn`; protect installed
host directories using normal OS permissions.

## Protocol and bounds

Frames contain a four-byte unsigned length in the machine's native byte order,
then strict UTF-8 JSON. Lengths count bytes. The parser supports fragmented
headers, fragmented bodies and several frames in one pipe read. It rejects
zero or oversized lengths, malformed UTF-8, malformed JSON and incomplete frames
at EOF. Payloads and host stderr are never logged or included in errors; the
host's stderr descriptor is discarded.

| Resource | Zacro limit |
| --- | --- |
| Registration manifest | 64 KiB |
| Executable inspected for approval | 256 MiB |
| Incoming host message | 1 MiB (Chrome limit) |
| Outgoing JSON body | 4 MiB (stricter than Chrome's 64 MiB) |
| Pending output per port, including frame headers | 4 MiB |
| Live or pending ports in one broker | 16 |
| Ports in one authenticated context | 8 |
| Incoming frames per port per second | 1024 |
| Single request, including approval and startup | 30 seconds |
| Port inactivity, including pending review | 5 minutes |
| Grace after termination before forced kill | 500 milliseconds |

`connectNative` creates a new external process for its port. `sendNativeMessage`
creates a separate process for each call, returns its first response, ignores
later responses and closes that process. Native hosts receive the extension
origin as their first argument and start with their executable directory as
working directory. Windows hosts additionally receive `--parent-window=0`.

Disconnect, navigation/context death, generation revocation, extension disable
or removal, profile shutdown and broker disposal discard pending frames and
close the child. Revocation interrupts pending approval without waiting for the
reviewer to finish. A pipe failure or malformed message produces one disconnect
with a generic `runtime.lastError`; deliberate local disconnect is clean.

## Verification

`node --test test/extensions-native-messaging.test.cjs` uses copies of
`test/fixtures/native-messaging/host.cjs` and temporary manifests. At the
test-only subprocess launch boundary, the installed Node runtime executes this
JavaScript fixture explicitly, including on Windows where shebang scripts are
not native executables. The Electron fixture uses development Electron's Node
mode. The real broker still verifies the registered script, obtains approval,
passes origin/parent arguments and exercises framed pipes, failures and child
termination. These tests never start a personal installed native host.

Injected discovery and registry reads cover registration boundaries for all
supported OSes. Passing these protocol fixtures does not establish discovery
and launch of an actual installed Windows host; that remains a native Windows
acceptance check. Windows and Linux execution results must come from those
platforms, separately from local macOS results.
