# Account and synchronization service implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver the real account/device/profile synchronization service and reproducible service tests.
**Architecture:** A single Node.js service uses SQLite transactions for accounts, revocable device credentials, datasets, idempotent mutations and a revision log. Secret payloads use authenticated encryption; browser credentials never enter sync schemas.
**Tech Stack:** Node.js 24 built-in HTTP, crypto and SQLite; CommonJS; node:test.
**Spec:** `docs/superpowers/specs/2026-10-25-extensions-and-sync-design.md`

## Global Constraints

- Work only on `extensions-and-sync`; service files are outside the packaged desktop app.
- Implement the approved username/password/recovery model and encryption without a plaintext fallback or embedded production secret.
- Keep account/dataset/extension namespaces separate; validate every operation against current device revocation state.
- Use a real SQLite-backed service in tests and a separate temporary database/key per test.
- No personal credentials, real email, cloud deployment, push, or production accounts.
- Do not change shared package.json or desktop files from the service task; report required script changes to the integrator.

## Review Focus

- Revoked and refresh-replayed credentials cannot authorize another request.
- Out-of-order retries and deleted generations cannot resurrect extensions/datasets.
- Pagination has a stable high-water mark, and multi-key mutations remain atomic under quotas.
- A restore cannot resurrect deleted accounts; incorrect keys fail without replacing existing secrets.
- Rate-limited authentication does not create unbounded hashing/memory work or trust arbitrary proxy headers.

### Task 1: Runnable account/device and sync service

**Files:** create `services/sync/{server,store,auth,crypto,protocol}.cjs`, `services/sync/README.md`, `services/sync/Dockerfile`, `services/sync/.env.example`; tests `test/sync-service.test.cjs`, `test/sync-reconciliation.test.cjs`.
**Interfaces:** `createSyncService({directory,masterKey,host='127.0.0.1',port=0,allowInsecureLoopback=false})` asynchronously returns `{url,close}` with a real HTTP server and SQLite storage. `masterKey` is a 32-byte Buffer. Production CLI reads explicit key/config and refuses unsafe configuration.

Protocol: JSON `/v1`, bearer access tokens, errors `{error:{code,message}}`. Registration/login accept `{username,password,deviceName,platform}` and return `{account:{id,username},device:{id,name,platform},accessToken,refreshToken,expiresAt,recoveryCodes?}`. Routes: POST `/accounts`, `/sessions`, `/sessions/refresh`, `/accounts/recover`; GET `/account`, `/devices`, `/datasets`; POST `/account/password`, `/account/recovery-codes`, `/devices`, `/datasets`; PATCH `/devices/:id`; DELETE `/sessions/current`, `/devices/:id`, `/account`, `/datasets/:id`; GET `/datasets/:id/snapshot`, `/datasets/:id/changes?after=&through=&limit=`; POST `/datasets/:id/operations`.

Dataset creation `{name}` returns `{id,name,epoch,revision}`. Snapshot returns `{dataset,extensions,settings,cursor}`. Changes return `{changes,cursor,through,hasMore}`. Operations body `{epoch,operations}`; each operation `{id,kind,extensionId,generation,baseRevision,payload}`. Library kind `extension` payload `{source:{kind:'web-store',id},state:'enabled'|'disabled'|'removed'}`. Settings kind `settings` payload `{set?,remove?,clear?}` with JSON values. Replies `{results:[{id,status:'applied'|'duplicate'|'conflict'|'quota',revision?,code?}],revision}`. Settings events include key changes with old/new values; removal/clear tombstones are retained. Each change includes revision/kind/extensionId/generation/payload. Endpoint refinements must be documented and sent to integrator before consumer work.

- [x] Write and run failing HTTP integration tests for registration/login/recovery/password change, device revocation and refresh reuse using actual persistence.
- [x] Implement versioned password hashing, bounded authentication, credential rotation and ownership-scoped account/device/dataset operations with encrypted persisted values.
- [x] Write/run failing convergence tests for duplicate requests, concurrent keys, removal precedence, stale reinstall, epochs, quota, stable paging and cross-account denial.
- [x] Implement transactional reconciliation and replay-safe change feeds, preserving actionable quota/conflict responses.
- [x] Add and test backup/restore/deletion ledger, wrong-key startup failure, process restart persistence, request limits and service readiness.
- [x] Run `node --test test/sync-service.test.cjs test/sync-reconciliation.test.cjs` and `npm test`. Expected: all focused and existing unit tests pass; disclose any unresolved protocol or runtime gap.
- [x] Document CLI, container/HTTPS deployment, key rotation, backup retention and production boundaries. Commit only owned files; report exact protocol and test evidence.
