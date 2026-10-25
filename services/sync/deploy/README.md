# Single-host HTTPS deployment

These assets are ready for an operator-owned Linux Docker host with Compose v2
(or the standalone `docker-compose` equivalent). They do not deploy a service,
create an account, buy a domain, or establish a Zacro public endpoint. The local
acceptance uses disposable credentials and certificates, without contacting a
public certificate authority. A production operator must supply a host, an owned
DNS hostname, durable local storage and a backup/secret management policy.

The proxy owns the network namespace and publishes TCP 80/443. The service joins
it with `network_mode: service:proxy` and binds **127.0.0.1:4040**. There is no
published plaintext service port. Port 80 is for ACME and HTTPS redirection only.
Do not change the service to `0.0.0.0` behind a Docker bridge: the service rejects
that plaintext configuration. Caddy owns certificate renewal; it has no access
to the database or master-key volume. The sync container runs as UID/GID 1000,
with a read-only root filesystem, dropped capabilities, a 1 GiB limit, a bounded
log and a 30-second graceful stop. Provision at least 2 GiB RAM on the host,
plus sufficient local disk for lifetime revision history and seven days of
backups. Use one replica only, on local storage rather than NFS.

## Provision and start

Run from the repository root on the intended Docker host. Check out a reviewed
revision; record it with the resulting image digests. This builds the existing
service Dockerfile plus a Caddy image containing only the proxy configuration.
Caddy and Node versions are explicitly tagged; review security updates and
re-run acceptance before upgrading. An immutable registry digest may be used
when promoting a built image to another host.

Create `/etc/zacro-sync` with mode 0700 and administrative permissions as
needed. Before startup, point the owned domain's A/AAAA records at the host,
verify every published address and allow inbound TCP 80/443.

Copy [operator.env.example](operator.env.example) to an operator-only location
outside the checkout, fill `ZACRO_SYNC_DOMAIN` with an owned DNS hostname (no
scheme/path), then explicitly export it in the operator shell:

```sh
install -m 600 services/sync/deploy/operator.env.example /etc/zacro-sync/operator.env
# Edit /etc/zacro-sync/operator.env, particularly the mandatory hostname.
# Source only this trusted, operator-owned shell configuration.
set -a
. /etc/zacro-sync/operator.env
set +a
: "${ZACRO_SYNC_DOMAIN:?Configure an operator-owned DNS hostname first}"

sync_compose() { docker compose -f services/sync/deploy/compose.yaml "$@"; }
sync_compose config --quiet
sync_compose build

docker volume create "$ZACRO_SYNC_DATA_VOLUME"
docker volume create "$ZACRO_SYNC_KEYS_VOLUME"
docker volume create "$ZACRO_SYNC_BACKUPS_VOLUME"
# Set ownership of the NEW, EMPTY key and backup volumes once.
docker run --rm --network none --user 0 --entrypoint node \
  -v "$ZACRO_SYNC_KEYS_VOLUME:/keys" -v "$ZACRO_SYNC_BACKUPS_VOLUME:/backups" \
  "$ZACRO_SYNC_IMAGE" -e 'const fs=require("node:fs");for(const p of ["/keys","/backups"]){fs.chownSync(p,1000,1000);fs.chmodSync(p,0o700)}'
docker run --rm --network none -v "$ZACRO_SYNC_KEYS_VOLUME:/keys" \
  "$ZACRO_SYNC_IMAGE" generate-key --key-file /keys/master.key
sync_compose up -d --wait --wait-timeout 90
```

With standalone Compose, define `sync_compose()` using `docker-compose`
instead. On first use Docker initializes the empty data volume from the image's
node-owned `/data`; do not use `volume-nocopy` or mount a root-owned replacement
there. The generated master key is 32 raw bytes, mode 0600 and UID 1000, outside
the database and backups. Do not put its contents in environment variables,
Compose secrets with default mode 0444, image layers, command arguments or logs.
Never regenerate it for an existing database. Export/escrow the key through the
operator's protected secret management process; a volume is not a disaster
recovery plan. Do not expose Docker's API or give the service its socket.

Before starting, point the domain's A/AAAA records to the host, check that every
published address is correct, and allow inbound TCP 80/443. Caddy obtains a
publicly trusted certificate after DNS and network reachability are in place.
No domain or external certificate path is inferred by this repository.
Validate HTTPS and certificate trust from outside the host before connecting
real clients. Do not use `curl -k` or disable TLS verification.

```sh
curl --fail --silent --show-error "https://$ZACRO_SYNC_DOMAIN/health"
curl --fail --silent --show-error "https://$ZACRO_SYNC_DOMAIN/ready"
sync_compose ps
```

Caddy access logging is disabled. Keep it disabled for authentication traffic;
never add request body logging. The service's logs contain fixed categories,
request IDs, status and duration, with no authentication bodies or settings.
Proxy operational/error logs can contain hostname/connection metadata; restrict
operator access to them. The provided configuration has no telemetry sink.

## Monitoring and restart

Use an operator-owned external HTTPS `/ready` probe and Docker's local health
status. Alert on unavailable or non-200 readiness, restart loops, unhealthy
containers, certificate expiry/renewal failure, backup age over the configured
interval, failed restore drills, and low disk space. Monitor memory/OOM events,
SQLite/WAL/ledger sizes and revision growth. Decide thresholds and a private
notification destination in the deployment environment. No monitoring account
or notification destination is provisioned by these assets.

```sh
sync_compose ps
sync_compose logs --tail 100 sync proxy
docker stats --no-stream
# Inspect disk use inside the live volume without exposing stored values:
docker run --rm --network none --entrypoint du \
  -v "$ZACRO_SYNC_DATA_VOLUME:/data:ro" "$ZACRO_SYNC_IMAGE" -sh /data
sync_compose restart sync
```

The `unless-stopped` restart policy handles process exits and daemon restarts;
Docker health status alone does **not** restart an unhealthy process. Inspect
readiness failures instead of repeatedly restarting or removing locks. A
normal stop releases `.service.lock`; the acceptance test verifies this. If
recreating the proxy, use `sync_compose up -d --force-recreate proxy sync` so the
service joins the new namespace; do not replace only the proxy container.

A crash/SIGKILL can leave a stale lock, intentionally failing closed. Stop both
containers, retain a protected copy of the data/ledger, and inspect the recorded
owner in the original PID namespace if available. CLI `unlock` refuses a live
or unidentifiable PID; a maintenance container has a different PID namespace
and cannot reliably establish that original owner's lifetime. Do not automate
lock deletion. Only after the operator establishes that no process/container
can access the volume, remove a demonstrably stale lock under a documented
incident procedure. A wrong/missing key or corrupt ledger requires recovery,
not lock deletion.

## Offline backups and deletion ledger

The following is an offline maintenance window. Stop writes before maintenance,
retain the current ledger, and restart even if backup fails. The snapshot path
is returned as JSON; use that exact path for restoration. Backup data includes
sensitive encrypted records and queryable metadata. Keep the backup volume
private and export snapshot/manifest pairs to the operator's durable encrypted
backup store. Apply storage lifecycle expiry of **at most seven days**, including
replicas/version history. The command prunes recognizable old files when it
runs; that does not replace external expiry enforcement.

```sh
sync_compose stop sync
(
  trap 'sync_compose start sync' EXIT
  docker run --rm --init --network none \
    -v "$ZACRO_SYNC_DATA_VOLUME:/data" -v "$ZACRO_SYNC_KEYS_VOLUME:/keys:ro" \
    -v "$ZACRO_SYNC_BACKUPS_VOLUME:/backups" "$ZACRO_SYNC_IMAGE" \
    backup --data /data --key-file /keys/master.key --backup-dir /backups
)
```

Schedule this command with the host's service manager at the operator's chosen
interval; check successful completion and the returned creation time. Never
restore an entire old live-volume snapshot. **The current `deletions.jsonl` is
authoritative and must survive outside the backup rollback domain.** It also
holds encrypted password/recovery continuity and dataset deletion records.
Keep the entire latest fsynced ledger on durable storage. A ledger copied at
backup time is insufficient after later account/dataset deletion or password
changes. When replicating it off-host, preserve every acknowledged update and
verify the replica before relying on disaster recovery. If the current ledger
is unavailable, do not restore using a convenient older copy. The service
fails closed when known ledger continuity is missing; external storage loss
and a false claim that an old ledger is current remain operator concerns.

## Restore drill and cutover

Use synthetic accounts for the first drill. Stop the service, retain the
original live volume containing the **current** ledger, and restore into a new
volume. Never replace that original with the old snapshot. New-volume staging
keeps the ledger outside the restored database's rollback operation.

```sh
sync_compose stop sync
export ZACRO_SYNC_RECOVERY_VOLUME=zacro-sync-recovery-YYYYMMDD
# Select the exact /backups/...sqlite path emitted by the successful backup.
export ZACRO_SYNC_SELECTED_BACKUP=/backups/SELECTED.sqlite
: "${ZACRO_SYNC_SELECTED_BACKUP:?Select the snapshot path}"
docker volume create "$ZACRO_SYNC_RECOVERY_VOLUME"
docker run --rm --network none --user 0 --entrypoint node \
  -v "$ZACRO_SYNC_RECOVERY_VOLUME:/restore" "$ZACRO_SYNC_IMAGE" \
  -e 'const fs=require("node:fs");fs.chownSync("/restore",1000,1000);fs.chmodSync("/restore",0o700)'
docker run --rm --init --network none \
  -v "$ZACRO_SYNC_DATA_VOLUME:/live:ro" -v "$ZACRO_SYNC_KEYS_VOLUME:/keys:ro" \
  -v "$ZACRO_SYNC_BACKUPS_VOLUME:/backups:ro" -v "$ZACRO_SYNC_RECOVERY_VOLUME:/restore" \
  "$ZACRO_SYNC_IMAGE" restore --data /restore/recovered \
  --key-file /keys/master.key --backup "$ZACRO_SYNC_SELECTED_BACKUP" \
  --ledger /live/deletions.jsonl
```

Restore authenticates/checks the snapshot and applies the current ledger before
validation. It refuses an existing destination and expired snapshots. Device
sessions are revoked; users must log in again. For a production cutover, create
an operator-owned Compose override:

```yaml
services:
  sync:
    environment:
      ZACRO_SYNC_DATA: /data/recovered
    volumes:
      - recovery:/data
volumes:
  recovery:
    external: true
    name: ${ZACRO_SYNC_RECOVERY_VOLUME:?Set the verified new volume}
```

Save that override outside the checkout and include it on **every subsequent**
Compose command, including backups and maintenance with the matching
`/data/recovered` path. Define `sync_compose()` accordingly. Start the recovered
service using `up -d --wait`; verify external HTTPS readiness, fresh login,
retained settings and absence of deleted datasets/accounts. Do not run the old
and recovered stores concurrently. Keep the previous live volume protected
until cutover verification and ledger continuity are established. Thereafter
the recovered service's ledger is authoritative: rolling back to the old live
volume without its newer ledger can resurrect deleted data. Stop and transfer
the current complete ledger before any rollback; revalidate before readiness.

Old backups need the key that authenticated them. For rotation, generate
`/keys/next.key` with the same CLI, stop the service, run `rotate-key` with
`--key-file /keys/master.key --new-key-file /keys/next.key`, then update the
service key-file configuration before starting. Keep required old keys securely
for the backup retention window. Consult the parent [README](../README.md) for
credential continuity, rotation and recovery limitations.

## Reproduce container acceptance

From the repository root, with Node.js 24+, OpenSSL and a running Docker Engine:

```sh
node --test test/container/sync-container.test.cjs
```

The test chooses `docker compose` or standalone `docker-compose`, builds both
actual images and starts the checked-in Compose stack. It uses uniquely named
volumes, synthetic keys/accounts and a one-day self-signed certificate trusted
only by the test client. HTTPS publishes only on a random host loopback port;
it never requests a public certificate. Tests cover health/readiness, rejected
unauthenticated access, two authenticated clients, library/settings roundtrip,
encrypted persisted values, graceful restart, singleton refusal, wrong/absent
key failure, offline backup/restore, revoked sessions and post-backup account
and dataset deletion. Test output omits credentials and bodies. Cleanup removes
only its uniquely named containers/volumes/images; failure diagnostics contain
fixed steps/status rather than raw response bodies. No VM or global Docker
context is created or changed. Set `DOCKER_HOST` explicitly for a remote engine;
no host bind sharing is needed. The separate
[sync-container workflow](../../../.github/workflows/sync-container.yml) runs
this acceptance on Linux Docker. It does not certify production DNS, ACME,
storage durability, monitoring delivery, or native desktop binaries.

Reference semantics: Docker documents
[service network namespaces](https://docs.docker.com/reference/compose-file/services/#network_mode)
and [Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/);
Caddy documents [automatic HTTPS](https://caddyserver.com/docs/automatic-https)
and [reverse proxy configuration](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).
