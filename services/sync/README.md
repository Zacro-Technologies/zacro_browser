# Zacro account and extension sync service

This directory is an independently runnable Node.js 24 service. It is excluded
from desktop packaging. It uses built-in HTTP/TLS, crypto and SQLite modules;
there is no separate in-memory server implementation or required npm dependency.

The desktop and this service are separate processes. No production endpoint is
assumed, and running local tests does not deploy an account service. The account
model is a lowercase username, password and one-use recovery codes, without an
email ownership or email recovery claim.

## Local development

From the repository root, use dedicated directories outside the checkout:

```sh
node services/sync/cli.cjs generate-key --key-file "$HOME/.config/zacro-sync/master.key"
node services/sync/cli.cjs serve --data "$HOME/.local/share/zacro-sync" --key-file "$HOME/.config/zacro-sync/master.key" --dev-loopback --port 4040
```

Key generation refuses to overwrite a file and writes 32 random bytes with
private permissions. Never put a master key in the database/backup directory,
commit it, print it, or pass its contents on a command line. On Unix, the key
file must have mode 0600 or 0400. On Windows, restrict its ACL to the service
identity and the designated recovery operator.

The development flag allows HTTP on numeric loopback addresses only. It cannot
enable plaintext access on `0.0.0.0` or a LAN address. The listening event prints
the actual local URL. Stop with Ctrl+C or SIGTERM. `/health` and `/ready` report
service/schema status; startup fails before listening for a wrong/missing key,
missing key metadata/deletion ledger, or invalid encrypted persisted data.

## Production configuration

Run one instance with one dedicated local SQLite directory. The process owns
`.service.lock`; an additional instance refuses to start. SQLite uses WAL,
foreign keys and full synchronous transactions. Do not share the directory
between multiple replicas or put it on a network filesystem. A stale lock after
a crash requires inspection; `unlock --data PATH` only removes a lock when its
recorded process no longer exists. A live or unidentifiable owner is rejected.

Use direct TLS, supplying `--tls-key` and `--tls-cert`, or bind to loopback
behind a trusted local TLS proxy and specify `--trusted-proxy --public-url
https://sync.example.org`. The latter is an example operator-owned domain, not
a Zacro endpoint. Plaintext nonloopback binding is rejected even in proxy mode.
The service never trusts forwarding headers for authentication rate limits.
Do not expose its loopback listener through an untrusted forwarding service.

Named environment settings are in [.env.example](.env.example). The CLI does
not silently load an `.env` file. Node's explicit `--env-file` option or your
service manager may supply those settings. Keep the service user unprivileged,
restrict data/backup/ledger access, monitor disk use and configure a restart
policy. Persistent revision history and tombstones are retained for the dataset
lifetime, so operators must provision storage and monitor growth.

Passwords use versioned asynchronous scrypt (`N=131072, r=8, p=1`), with two
hash operations active and at most eight queued per process. Tokens and recovery
codes are random and stored only as hashes. Access tokens last 15 minutes;
refresh tokens rotate and expire after 30 days of inactivity. Refresh reuse
revokes that device, including its newest access token. Every authenticated
operation checks current database revocation state. Authentication is limited
by account and direct network peer; requests/bodies/headers/connections are
bounded. The process needs sufficient memory for concurrent scrypt operations
in addition to SQLite and requests; provision at least 1 GiB and monitor it.

Secret settings and dataset names use AES-256-GCM with authenticated ownership
metadata. Per-account data keys are wrapped by the external master key. Routing
indexes for arbitrary setting keys and operation fingerprints use keyed HMAC
under the account key, preventing unkeyed dictionary guesses of their contents.
The encrypted security ledger retains the latest password and recovery-code
hash state for safe restoration; it contains no plaintext credentials. Routing
IDs, usernames, device metadata, password/token hashes and revisions remain
queryable. **This is server-side encryption, not end-to-end encryption:** the
running service can decrypt extension settings. Extensions choose their own
setting values, which may contain personal information or credentials. Desktop
settings synchronization requires separate informed consent. Zacro's own
cookies, site sessions, AI credentials and local filesystem paths are not fields
in the library protocol.

CLI request logs contain request IDs, fixed categories, status and duration.
They omit request URLs/queries, bodies, passwords, credentials, recovery codes
and settings. Do not add a proxy/access logger that records authentication
bodies. Server errors do not echo stored values.

## Backups, restore and keys

Stop the service before CLI maintenance. `migrate` opens and validates the
database and applies supported schema migrations. It refuses a newer schema.

```sh
node services/sync/cli.cjs backup --data /srv/zacro-sync/data --key-file /run/secrets/zacro-sync-master --backup-dir /srv/zacro-sync/backups
node services/sync/cli.cjs restore --data /srv/zacro-sync/restored --key-file /run/secrets/zacro-sync-master --backup /srv/zacro-sync/backups/SELECTED.sqlite --ledger /srv/zacro-sync/data/deletions.jsonl
```

Use the actual backup path returned by `backup`; `SELECTED.sqlite` above is a
placeholder. A backup is a consistent `VACUUM INTO` SQLite snapshot plus a JSON
manifest authenticated with the master key. Restore verifies its authentication
and checksum, refuses snapshots older than seven days, stages into a new
directory, applies the **current durable security ledger**, and validates
encrypted data before the directory can become ready. It never overwrites an
existing destination. Keep the authoritative ledger on durable storage outside
the backup rollback domain; an older copy is not a valid restore ledger.
The file is named `deletions.jsonl` and also contains encrypted credential
continuity records. Keep the entire current file, including those records.
Restoration always revokes every device and requires a fresh login. Applying
the current ledger preserves password changes and consumed recovery codes made
after the snapshot, even if the master key was rotated in the meantime.

Account deletion fsyncs its ledger record before removing account-owned live
data and sessions. Restoring an earlier database with the current ledger cannot
recreate the deleted account. Deletion cannot erase copies already downloaded
by disconnected clients. Historical encrypted backups are not instantly erased.

**Configure backup storage expiry to at most seven days.** The backup command
also prunes recognizable expired snapshots when it runs, and restore rejects
expired snapshots, but a stopped process cannot enforce storage deletion.
Production retention and ledger durability are operator obligations; the local
tests do not certify those external systems. Keep backups and manifests together
and test restoration using synthetic accounts before production operation.

For master-key rotation, generate a second private key file, stop the service,
and run:

```sh
node services/sync/cli.cjs rotate-key --data /srv/zacro-sync/data --key-file /run/secrets/zacro-sync-master --new-key-file /run/secrets/zacro-sync-master-next
```

Update the service configuration to the new key before restarting. The operation
rewraps account keys transactionally; it does not rewrite settings plaintext.
Old backups require their original master key. Retain each old key securely only
as long as its permitted backups require it, then retire it under the operator's
key management policy. Missing keys cannot be recovered by generating replacements.

## HTTP contract

JSON endpoints are under `/v1`. Protected endpoints use `Authorization: Bearer
ACCESS_TOKEN`. Errors are `{error:{code,message}}`. Request bodies are limited
to 1 MiB. Browser-origin requests are rejected; the desktop main process is the
client. Recovery codes appear only in explicit registration/recovery/regeneration
responses and must never become routine browser snapshots or logs.

Each account supports at most 100 active datasets and 100 active devices. A
dataset supports 100 installed extension identities and 1,000 identities across
its lifetime, including removals. These bounds keep snapshots finite; a full
library returns `quota` with `library_limit`. JSON nesting is limited to 64
levels. Settings reads ignore retained tombstones, and change pages contain at
most 200 revisions. History still requires monitored disk capacity.

| Method and path                                   | Request / result                                                                                                  |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `POST /accounts`                                  | `{username,password,deviceName,platform}`; returns account/device, token pair, expiry and one-time recovery codes |
| `POST /sessions`                                  | Same login fields; returns a newly enrolled device and token pair                                                 |
| `POST /sessions/refresh`                          | `{refreshToken}`; rotates the pair                                                                                |
| `POST /accounts/recover`                          | `{username,recoveryCode,newPassword,deviceName,platform}`; rotates recovery codes and revokes old sessions        |
| `GET /account`, `GET /devices`                    | Safe account/current-device or owned device list                                                                  |
| `POST /account/password`                          | `{password,newPassword}`; revokes other devices                                                                   |
| `POST /account/recovery-codes`                    | `{password}`; replaces all recovery codes                                                                         |
| `POST /devices`                                   | `{password,deviceName,platform}`; enrolls a device                                                                |
| `PATCH /devices/:id`                              | `{name}`                                                                                                          |
| `DELETE /devices/:id`, `DELETE /sessions/current` | Immediate session/device revocation                                                                               |
| `DELETE /account`                                 | `{password,confirm:true}`                                                                                         |
| `GET /datasets`, `POST /datasets`                 | Owned list / create with `{name}`                                                                                 |
| `DELETE /datasets/:id`                            | `{password,confirm:true}`; rejects later stale operations                                                         |
| `GET /datasets/:id/snapshot`                      | `{dataset,extensions,settings,cursor}`                                                                            |
| `GET /datasets/:id/changes`                       | `after`, optional stable `through`, and `limit` (1–200); returns `{changes,cursor,through,hasMore}`               |
| `POST /datasets/:id/operations`                   | `{epoch,operations}`; at most 100 operations                                                                      |

A dataset is `{id,name,epoch,revision}`. Each operation contains
`{id,kind,extensionId,generation,baseRevision,payload}`. IDs are unique to a
device/dataset; changing a retry's body or its device is rejected. Library
payloads are exactly `{source:{kind:'web-store',id},state}` with
`enabled`, `disabled` or `removed`. The verified portable extension ID is the
only source accepted; local paths and arbitrary URLs are rejected.

Settings payloads contain `set`, `remove` and/or `clear`. The server serializes
mutations, preserves unseen keys during stale `clear`, enforces per-extension
generation limits (102400 total bytes, 8192 per item and 512 items), and rejects
an overflowing multi-key mutation atomically. Independent operations continue.
Snapshot settings entries contain `{extensionId,generation,values,revisions}`;
settings change events contain `payload.changes` with old/new values.

Replies contain results with `applied`, `duplicate`, `conflict` or `quota` and
the current revision. A rejected operation remains rejected on identical replay;
an explicit retry after reconciliation needs a **new operation ID**. Removal
wins over stale enable/settings writes. Reinstallation needs a fresh generation
and a base revision that observes the tombstone. Client clocks never determine
conflict order. Clients must persist cursor, acknowledgement and resulting state
atomically, pull before pushing, and request local permission approval before
activating a remotely requested installation.

## Validation and container

```sh
node --test test/sync-service.test.cjs test/sync-reconciliation.test.cjs test/sync-operations.test.cjs
```

The tests use actual HTTP servers, temporary SQLite databases, protected-file
CLI operations and synthetic credentials. They cover lifecycle, replay,
ownership, convergence, quotas, paging, encrypted persistence, tampering,
deletion-aware restore and key rotation. They do not establish deployed-service
availability or the final two-Electron-client acceptance by themselves.

The [Dockerfile](Dockerfile) is provided for an operator build. Container builds
and public TLS deployment must be validated in the target environment; they
are not implied by Node test success. Mount persistent data and an external
private master-key file readable by the unprivileged `node` user. Use direct TLS
for a published container port, or a loopback listener with a TLS proxy sharing
its network namespace. Do not publish plaintext on all interfaces.
