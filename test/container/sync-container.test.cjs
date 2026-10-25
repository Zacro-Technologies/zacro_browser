'use strict';
// Explicit integration command; intentionally outside the default host unit-test glob.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const composeFile = path.join(root, 'services/sync/deploy/compose.yaml');

async function execute(
  program,
  args,
  { input, env = process.env, allowFailure = false, timeout = 180000 } = {},
) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { cwd: root, env, timeout, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '',
      stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.once('error', () => reject(new Error(`Cannot execute ${program}`)));
    child.once('close', (code) => {
      const result = { code, stdout, stderr };
      // Do not print command output: HTTP bodies and operator secrets must stay private.
      if (code !== 0 && !allowFailure) reject(new Error(`${program} command failed (exit ${code})`));
      else resolve(result);
    });
    child.stdin.end(input);
  });
}
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test(
  'actual deployment image provides TLS sync, durable restarts and deletion-aware offline restore',
  { timeout: 900000 },
  async (t) => {
    const id = `zacro-sync-test-${randomUUID()}`;
    const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-container-'));
    const volumes = ['data', 'keys', 'backups', 'restored', 'certs'].map((name) => `${id}-${name}`);
    const [data, keys, backups, restored, certs] = volumes;
    const images = [`${id}-service`, `${id}-proxy`];
    const env = {
      ...process.env,
      ZACRO_SYNC_DOMAIN: 'sync.test',
      ZACRO_SYNC_IMAGE: images[0],
      ZACRO_SYNC_PROXY_IMAGE: images[1],
      ZACRO_SYNC_DATA_VOLUME: data,
      ZACRO_SYNC_KEYS_VOLUME: keys,
      ZACRO_SYNC_CADDY_DATA_VOLUME: `${id}-caddy-data`,
      ZACRO_SYNC_CADDY_CONFIG_VOLUME: `${id}-caddy-config`,
      ZACRO_SYNC_HTTP_BIND: '127.0.0.1::80',
      ZACRO_SYNC_HTTPS_BIND: '127.0.0.1::443',
    };
    let composeProgram = 'docker',
      composePrefix = ['compose'];
    if ((await execute('docker', ['compose', 'version'], { allowFailure: true })).code !== 0) {
      composeProgram = 'docker-compose';
      composePrefix = [];
    }
    const override = path.join(temporary, 'fixture.yaml');
    const compose = (args, options = {}) =>
      execute(composeProgram, [...composePrefix, '-p', id, '-f', composeFile, '-f', override, ...args], {
        env,
        ...options,
      });
    const docker = (args, options) => execute('docker', args, options);
    const serviceRun = (args, { volume = data, key = '/keys/master.key', allowFailure = false } = {}) =>
      docker(
        [
          'run',
          '--rm',
          '--network',
          'none',
          '-v',
          `${volume}:/data`,
          '-v',
          `${keys}:/keys:ro`,
          '-v',
          `${backups}:/backups`,
          images[0],
          ...args,
          '--key-file',
          key,
        ],
        { allowFailure },
      );
    t.after(async () => {
      await compose(['down', '--volumes', '--remove-orphans'], { allowFailure: true }).catch(() => {});
      for (const name of volumes) await docker(['volume', 'rm', name], { allowFailure: true });
      for (const name of images) await docker(['image', 'rm', name], { allowFailure: true });
      await fs.rm(temporary, { recursive: true, force: true });
    });
    await fs.writeFile(
      override,
      `services:\n  proxy:\n    environment:\n      ZACRO_SYNC_TLS_DIRECTIVE: tls /fixtures/cert.pem /fixtures/key.pem\n    volumes:\n      - fixtures:/fixtures:ro\nvolumes:\n  fixtures:\n    external: true\n    name: ${certs}\n`,
    );
    await compose(['config', '--quiet']);
    await compose(['build'], { timeout: 600000 });
    t.diagnostic('actual service and TLS proxy Dockerfiles built');
    for (const name of volumes) await docker(['volume', 'create', name]);
    // No host bind mounts: works with remote Docker daemons and VM mount sharing disabled.
    await docker([
      'run',
      '--rm',
      '--network',
      'none',
      '--user',
      '0',
      '--entrypoint',
      'node',
      '-v',
      `${keys}:/keys`,
      '-v',
      `${backups}:/backups`,
      '-v',
      `${restored}:/restored`,
      images[0],
      '-e',
      `const fs=require('node:fs');const crypto=require('node:crypto');for(const p of ['/keys','/backups','/restored']){fs.chownSync(p,1000,1000);fs.chmodSync(p,0o700)}for(const n of ['master','wrong']){const p='/keys/'+n+'.key';fs.writeFileSync(p,crypto.randomBytes(32),{mode:0o600});fs.chownSync(p,1000,1000)}`,
    ]);
    await execute('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-keyout',
      path.join(temporary, 'key.pem'),
      '-out',
      path.join(temporary, 'cert.pem'),
      '-subj',
      '/CN=sync.test',
      '-addext',
      'subjectAltName=DNS:sync.test',
    ]);
    const ca = await fs.readFile(path.join(temporary, 'cert.pem'));
    for (const name of ['key.pem', 'cert.pem']) {
      await docker(
        [
          'run',
          '--rm',
          '-i',
          '--network',
          'none',
          '--user',
          '0',
          '--entrypoint',
          'node',
          '-v',
          `${certs}:/fixtures`,
          images[0],
          '-e',
          `const fs=require('node:fs');fs.writeFileSync('/fixtures/${name}',fs.readFileSync(0),{mode:0o600})`,
        ],
        { input: await fs.readFile(path.join(temporary, name)) },
      );
    }
    await compose(['up', '-d', '--wait', '--wait-timeout', '90']);
    const serviceID = (await compose(['ps', '-q', 'sync'])).stdout.trim();
    const proxyID = (await compose(['ps', '-q', 'proxy'])).stdout.trim();
    const proxyInspect = JSON.parse((await docker(['inspect', proxyID])).stdout)[0];
    const serviceInspect = JSON.parse((await docker(['inspect', serviceID])).stdout)[0];
    assert.equal(serviceInspect.Config.User, 'node');
    assert.equal(serviceInspect.HostConfig.NetworkMode, `container:${proxyID}`);
    assert.equal(Object.keys(serviceInspect.HostConfig.PortBindings || {}).length, 0);
    assert.equal(Object.keys(proxyInspect.HostConfig.PortBindings).sort().join(','), '443/tcp,80/tcp');
    const port = Number(proxyInspect.NetworkSettings.Ports['443/tcp'][0].HostPort);
    const request = (route, { body, token, method = body ? 'POST' : 'GET' } = {}) =>
      new Promise((resolve, reject) => {
        const req = https.request(
          {
            hostname: '127.0.0.1',
            port,
            servername: 'sync.test',
            ca,
            path: route,
            method,
            timeout: 15000,
            headers: {
              host: 'sync.test',
              ...(body
                ? {
                    'content-type': 'application/json',
                    'content-length': Buffer.byteLength(JSON.stringify(body)),
                  }
                : {}),
              ...(token ? { authorization: `Bearer ${token}` } : {}),
            },
          },
          (res) => {
            let text = '';
            res.on('data', (chunk) => {
              text += chunk;
            });
            res.on('end', () => {
              try {
                resolve({ status: res.statusCode, data: JSON.parse(text) });
              } catch {
                reject(new Error('Expected a JSON service response'));
              }
            });
          },
        );
        req.on('timeout', () => req.destroy(new Error('TLS request timeout')));
        req.on('error', (error) => reject(new Error(`TLS request failed (${error.code || 'unknown'})`)));
        req.end(body ? JSON.stringify(body) : undefined);
      });
    const ready = async () => {
      let last;
      for (let attempt = 0; attempt < 60; attempt++) {
        last = await request('/ready').catch((error) => ({ error: error.message }));
        if (last.status === 200) return;
        await pause(500);
      }
      throw new Error(`TLS readiness did not recover (${last.error || last.status})`);
    };
    await ready();
    assert.equal((await request('/health')).status, 200);
    assert.equal((await request('/v1/account')).status, 401);
    const password = 'Disposable container acceptance password 123!';
    const credentials = {
      username: 'container.acceptance',
      password,
      deviceName: 'Disposable A',
      platform: 'test',
    };
    const registration = await request('/v1/accounts', { body: credentials });
    assert.equal(registration.status, 201);
    const token = registration.data.accessToken;
    const login = await request('/v1/sessions', { body: { ...credentials, deviceName: 'Disposable B' } });
    assert.equal(login.status, 200);
    const secondToken = login.data.accessToken;
    const dataset = (await request('/v1/datasets', { token, body: { name: 'Synthetic encrypted dataset' } }))
      .data;
    const deleted = (await request('/v1/datasets', { token, body: { name: 'Delete after snapshot' } })).data;
    const deletedAccount = await request('/v1/accounts', {
      body: { ...credentials, username: 'delete.acceptance' },
    });
    assert.equal(deletedAccount.status, 201);
    const extensionId = 'a'.repeat(32);
    const mutate = await request(`/v1/datasets/${dataset.id}/operations`, {
      token,
      body: {
        epoch: dataset.epoch,
        operations: [
          {
            id: randomUUID(),
            kind: 'extension',
            extensionId,
            generation: 'container-generation',
            baseRevision: 0,
            payload: { source: { kind: 'web-store', id: extensionId }, state: 'enabled' },
          },
          {
            id: randomUUID(),
            kind: 'settings',
            extensionId,
            generation: 'container-generation',
            baseRevision: 0,
            payload: { set: { fixtureSecret: 'synthetic-value-encrypted-at-rest' } },
          },
        ],
      },
    });
    assert.equal(mutate.status, 200);
    assert.ok(
      mutate.data.results.every((result) => result.status === 'applied'),
      'sync operations apply',
    );
    const verifySnapshot = async (accessToken) => {
      const snapshot = await request(`/v1/datasets/${dataset.id}/snapshot`, { token: accessToken });
      assert.equal(snapshot.status, 200);
      assert.equal(snapshot.data.extensions.length, 1);
      assert.ok(
        snapshot.data.settings[0].values.fixtureSecret === 'synthetic-value-encrypted-at-rest',
        'settings roundtrip',
      );
    };
    await verifySnapshot(secondToken);
    await compose(['restart', 'sync']);
    await ready();
    await verifySnapshot(token);
    const lock = await serviceRun(['migrate', '--data', '/data'], { allowFailure: true });
    assert.notEqual(lock.code, 0, 'maintenance cannot share a live dataset');
    assert.ok(/already in use|locked/i.test(lock.stderr), 'live singleton refusal is explicit');
    await compose(['stop', 'sync']);
    const diskCheck = await docker([
      'run',
      '--rm',
      '--network',
      'none',
      '--entrypoint',
      'node',
      '-v',
      `${data}:/data:ro`,
      images[0],
      '-e',
      `const fs=require('node:fs');if(fs.existsSync('/data/.service.lock'))process.exit(1);const b=fs.readFileSync('/data/sync.sqlite');for(const s of ['Synthetic encrypted dataset','synthetic-value-encrypted-at-rest'])if(b.includes(Buffer.from(s)))process.exit(2)`,
    ]);
    assert.equal(diskCheck.code, 0);
    const backupResult = await serviceRun(['backup', '--data', '/data', '--backup-dir', '/backups']);
    const backupPath = JSON.parse(backupResult.stdout.trim()).path;
    assert.ok(backupPath.startsWith('/backups/zacro-sync-'));
    for (const [key, reason] of [
      ['/keys/wrong.key', /decrypt|authenticat|master key/i],
      ['/keys/absent.key', /ENOENT/],
    ]) {
      const failure = await serviceRun(['serve', '--data', '/data', '--dev-loopback'], {
        key,
        allowFailure: true,
      });
      assert.notEqual(failure.code, 0, 'invalid keys fail closed');
      assert.ok(reason.test(failure.stderr), 'startup reports the expected key failure');
    }
    const unsafeBind = await serviceRun(
      [
        'serve',
        '--data',
        '/data',
        '--host',
        '0.0.0.0',
        '--trusted-proxy',
        '--public-url',
        'https://sync.test',
      ],
      { allowFailure: true },
    );
    assert.notEqual(unsafeBind.code, 0, 'plaintext nonloopback binding is refused inside the image');
    assert.ok(/TLS|loopback/i.test(unsafeBind.stderr), 'network boundary refusal is explicit');
    await compose(['start', 'sync']);
    await ready();
    assert.equal(
      (
        await request(`/v1/datasets/${deleted.id}`, {
          token,
          method: 'DELETE',
          body: { password, confirm: true },
        })
      ).status,
      200,
    );
    assert.equal(
      (
        await request('/v1/account', {
          token: deletedAccount.data.accessToken,
          method: 'DELETE',
          body: { password, confirm: true },
        })
      ).status,
      200,
    );
    await compose(['stop', 'sync']);
    await docker([
      'run',
      '--rm',
      '--network',
      'none',
      '-v',
      `${data}:/live:ro`,
      '-v',
      `${keys}:/keys:ro`,
      '-v',
      `${backups}:/backups:ro`,
      '-v',
      `${restored}:/restore`,
      images[0],
      'restore',
      '--data',
      '/restore/recovered',
      '--key-file',
      '/keys/master.key',
      '--backup',
      backupPath,
      '--ledger',
      '/live/deletions.jsonl',
    ]);
    // Replace only the test service's mount; the authoritative live ledger is retained separately.
    const restoreOverride = path.join(temporary, 'restore.yaml');
    await fs.writeFile(
      restoreOverride,
      `services:\n  sync:\n    environment:\n      ZACRO_SYNC_DATA: /data/recovered\n    volumes:\n      - recovery:/data\nvolumes:\n  recovery:\n    external: true\n    name: ${restored}\n`,
    );
    await execute(
      composeProgram,
      [
        ...composePrefix,
        '-p',
        id,
        '-f',
        composeFile,
        '-f',
        override,
        '-f',
        restoreOverride,
        'up',
        '-d',
        '--wait',
        '--wait-timeout',
        '90',
        'sync',
      ],
      { env },
    );
    await ready();
    assert.equal((await request('/v1/account', { token })).status, 401, 'restore revokes sessions');
    const restoredLogin = await request('/v1/sessions', { body: credentials });
    assert.equal(restoredLogin.status, 200);
    const restoredToken = restoredLogin.data.accessToken;
    await verifySnapshot(restoredToken);
    assert.equal(
      (await request(`/v1/datasets/${deleted.id}/snapshot`, { token: restoredToken })).status,
      404,
      'current ledger preserves dataset deletion',
    );
    assert.equal(
      (await request('/v1/sessions', { body: { ...credentials, username: 'delete.acceptance' } })).status,
      401,
      'current ledger preserves account deletion',
    );
    const logs = (await compose(['logs', '--no-color'])).stdout;
    for (const secret of [
      password,
      token,
      secondToken,
      ...registration.data.recoveryCodes,
      'synthetic-value-encrypted-at-rest',
    ])
      assert.ok(!logs.includes(secret), 'container logs omit credentials and settings');
    t.diagnostic(
      'TLS trust, health/auth, two-client sync, encrypted disk, graceful restart, singleton lock, wrong/missing key, offline backup/restore, revocation and current deletion ledger passed',
    );
  },
);
