# Accounts, profiles and extension synchronization

Implementation and acceptance are in progress on `extensions-and-sync`. The
account service and desktop client have passed real HTTP/SQLite tests, and the
native account screen and two complete Electron browsers have passed genuine
extension-API synchronization, offline restart and device-revocation flows.
Native background suspend/wake also passes. Independent whole-branch review
and remaining platform acceptance are tracked in
[the validation record](EXTENSIONS-SYNC-VALIDATION.md).

## Start a development service

Use Node.js 24. The service is a separate process and is not included in the
packaged browser. No public Zacro service address is assumed.

From the checkout, run:

```sh
mkdir -p .tmp/sync-demo
node services/sync/cli.cjs generate-key --key-file .tmp/sync-demo/master.key
node services/sync/cli.cjs serve --data .tmp/sync-demo/data --key-file .tmp/sync-demo/master.key --dev-loopback --port 4040
```

Keep this terminal running. Key generation refuses to replace an existing key;
reuse the existing key when restarting the same database. The key must remain
outside the database directory. For HTTPS deployment, backups, restoration,
retention and key rotation, follow the [operator guide](../services/sync/README.md).
A local test does not deploy a production service.

Start two development browser instances with separate disposable profiles. On
macOS/Linux, use one terminal for each command:

```sh
ZACRO_USER_DATA="$PWD/.tmp/sync-client-a" ZACRO_SYNC_DEV_LOOPBACK=1 npm start
ZACRO_USER_DATA="$PWD/.tmp/sync-client-b" ZACRO_SYNC_DEV_LOOPBACK=1 npm start
```

On Windows PowerShell, use separate terminals, changing `sync-client-a` to
`sync-client-b` in the second:

```powershell
$env:ZACRO_USER_DATA = Join-Path $PWD '.tmp/sync-client-a'
$env:ZACRO_SYNC_DEV_LOOPBACK = '1'
npm start
```

Development HTTP is limited to numeric loopback addresses and must be explicitly
enabled. Packaged clients require HTTPS. The browser refuses account sign-in if
OS credential protection is unavailable; it does not save plaintext tokens as a
fallback.

## Connect an account

Open **Library → Settings → Account & sync → Configure service** and enter
`http://127.0.0.1:4040` for the development service above. For a deployed service,
use its actual HTTPS origin without a path or embedded credentials.

Create an account on the first device and sign into that account on the second.
Usernames contain 3–64 lowercase ASCII letters/digits, `_`, `-` or `.`, beginning
with a letter/digit. Passwords contain 12–256 characters, with a maximum of 1024
UTF-8 bytes. Passwords are not normalized. No email ownership or email recovery
is implied.

Save the ten recovery codes shown after registration. Each is usable once; they
are not included in browser snapshots or exports. Account recovery changes the
password, invalidates old device sessions and replaces all recovery codes.
Changing a password while signed in revokes the other devices. Regenerating
recovery codes invalidates the previous set.

**Devices** shows enrolled devices, their names and revocation status. Revoking
a device prevents further synchronization and requires it to sign in again.
It cannot erase files or settings already downloaded to that computer.

## Link browser profiles deliberately

Sign-in alone does not link profiles. Choose **Link profile**, create a named
sync profile or select an existing one, and review the changes. Matching browser
profile names do not create a link. Each local profile can have one link; a sync
profile cannot be attached twice within the same browser installation.

Extension-library and extension-setting synchronization are separate choices.
The library contains portable extension source IDs and enabled/disabled/removed
intent. Local unpacked folders stay local; no local directory is uploaded.
Versions are observations, not commands to downgrade another device.

Settings synchronization starts **off**. Enabling it requires consent and a
choice between using the remote settings or uploading the local settings.
Extensions choose their own values; these may include personal information or
credentials. Zacro does not copy its own cookies, site sessions, AI credentials
or local paths into synchronization records. The service encrypts stored
settings, but the running service can read them: this is **not end-to-end
encryption**.

Turning settings synchronization off keeps a local copy and stops setting
uploads/downloads. Library synchronization continues. Cloud deletion is a
separate action. Requests waiting for token refresh or a retry recheck the
originating link and consent before sending. Re-enabling presents the
local/remote choice again.

Unlinking keeps local extensions and a separate local settings copy. Signing
out or changing the service stops the old links. Settings from different
accounts remain separate; signing into a different account does not replay the
previous account's queued changes. Relinking requires review. Explicitly
deleting a local browser profile also deletes its extension settings from the
local sync database, including archived copies for other signed-in accounts.
Other local profiles and cloud datasets remain intact.

## Pending, offline and conflicting changes

Local changes are saved before the extension receives success. The client pulls
remote changes before sending its persistent queue, polls while connected and
backs off after network failures. **Sync now** requests an immediate attempt.
Local success, server acceptance and permission approval on another device are
separate states.

New extensions on another device require that device's permission approval.
Declining local permission does not delete the extension from other devices.
Extra permissions after an update require review. Removing an installation wins
over stale changes from that installation; reinstalling creates a new generation.

Independent setting keys merge. Conflicting values follow the service's
acceptance order, not device clocks. A stale clear preserves newer keys it had
not seen. Settings use the supported Chrome sync limits: 102400 total bytes,
8192 bytes per item, 512 items, 120 writes/minute and 1800 writes/hour.

If merged offline changes exceed the service quota, the rejected local change
remains visible as unsynced. **Export** saves it explicitly, **Retry** submits a
new attempt after resolving the conflict, and **Discard** uses the accepted
remote state. Other accepted changes continue. A removed installation requires
an explicit reinstall rather than retrying an obsolete generation.

Deleting a cloud profile or account requires the current password and explicit
confirmation. It does not delete local browser installations. The operator's
current durable security ledger prevents deleted cloud profiles and accounts
from reappearing when a permitted older backup is restored. Historical encrypted
backup expiry (at most seven days) and ledger durability remain operator
responsibilities.
