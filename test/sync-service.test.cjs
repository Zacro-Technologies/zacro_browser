'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { randomBytes } = require('node:crypto');
const { createSyncService } = require('../services/sync/server.cjs');

const password = 'A long synthetic password 123!';
async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-service-'));
  const options = { directory, masterKey: randomBytes(32), allowInsecureLoopback: true };
  let service = await createSyncService(options);
  t.after(async () => {
    await service.close();
    await fs.rm(directory, { recursive: true, force: true });
  });
  const request = async (route, { method = 'GET', body, token } = {}) => {
    const response = await fetch(`${service.url}/v1${route}`, {
      method,
      headers: {
        ...(body ? { 'content-type': 'application/json' } : {}),
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: response.status, data: await response.json() };
  };
  const register = async (username = 'account.one') => {
    const r = await request('/accounts', {
      method: 'POST',
      body: { username, password, deviceName: 'Test device', platform: 'test' },
    });
    assert.equal(r.status, 201, JSON.stringify(r.data));
    return r.data;
  };
  return {
    directory,
    options,
    request,
    register,
    restart: async () => {
      await service.close();
      service = await createSyncService(options);
    },
    get service() {
      return service;
    },
  };
}

test('real service registers, authenticates, persists and isolates accounts without storing credentials in plaintext', async (t) => {
  const f = await fixture(t);
  const first = await f.register();
  assert.equal(first.account.username, 'account.one');
  assert(first.recoveryCodes.length >= 8);
  assert.notEqual(first.accessToken, first.refreshToken);
  assert.equal((await f.request('/account', { token: first.accessToken })).data.account.id, first.account.id);
  assert.equal(
    (
      await f.request('/sessions', {
        method: 'POST',
        body: {
          username: 'account.one',
          password: 'Wrong password 123!',
          deviceName: 'Other',
          platform: 'test',
        },
      })
    ).status,
    401,
  );
  const login = await f.request('/sessions', {
    method: 'POST',
    body: { username: 'account.one', password, deviceName: 'Second', platform: 'test' },
  });
  assert.equal(login.status, 200);
  assert.notEqual(login.data.device.id, first.device.id);
  assert.equal((await f.request('/devices', { token: first.accessToken })).data.devices.length, 2);
  const other = await f.register('account.two');
  assert.equal(
    (await f.request(`/devices/${first.device.id}`, { method: 'DELETE', token: other.accessToken })).status,
    404,
  );
  await f.restart();
  assert.equal((await f.request('/account', { token: first.accessToken })).status, 200);
  const bytes = await fs.readFile(path.join(f.directory, 'sync.sqlite'));
  for (const secret of [password, first.accessToken, first.refreshToken, ...first.recoveryCodes]) {
    assert.equal(bytes.includes(Buffer.from(secret)), false);
  }
  await f.service.close();
  await assert.rejects(
    createSyncService({ ...f.options, masterKey: randomBytes(32) }),
    /key|decrypt|authenticat/i,
  );
});

test('rotated refresh replay revokes the entire device, including its newly issued access token', async (t) => {
  const f = await fixture(t);
  const a = await f.register();
  const rotated = await f.request('/sessions/refresh', {
    method: 'POST',
    body: { refreshToken: a.refreshToken },
  });
  assert.equal(rotated.status, 200);
  assert.notEqual(rotated.data.refreshToken, a.refreshToken);
  assert.equal((await f.request('/account', { token: a.accessToken })).status, 401);
  assert.equal((await f.request('/account', { token: rotated.data.accessToken })).status, 200);
  assert.equal(
    (await f.request('/sessions/refresh', { method: 'POST', body: { refreshToken: a.refreshToken } })).status,
    401,
  );
  assert.equal((await f.request('/account', { token: rotated.data.accessToken })).status, 401);
  assert.equal(
    (
      await f.request('/sessions/refresh', {
        method: 'POST',
        body: { refreshToken: rotated.data.refreshToken },
      })
    ).status,
    401,
  );
});

test('password changes revoke other devices and recovery is one-use and rotates all credentials', async (t) => {
  const f = await fixture(t);
  const a = await f.register();
  const b = await f.request('/sessions', {
    method: 'POST',
    body: { username: 'account.one', password, deviceName: 'Second', platform: 'test' },
  });
  const newPassword = 'New synthetic password 456!';
  assert.equal(
    (
      await f.request('/account/password', {
        method: 'POST',
        token: a.accessToken,
        body: { password, newPassword },
      })
    ).status,
    200,
  );
  assert.equal((await f.request('/account', { token: a.accessToken })).status, 200);
  assert.equal((await f.request('/account', { token: b.data.accessToken })).status, 401);
  const recovered = await f.request('/accounts/recover', {
    method: 'POST',
    body: {
      username: 'account.one',
      recoveryCode: a.recoveryCodes[0],
      newPassword: password,
      deviceName: 'Recovered',
      platform: 'test',
    },
  });
  assert.equal(recovered.status, 200);
  assert.notDeepEqual(recovered.data.recoveryCodes, a.recoveryCodes);
  assert.equal((await f.request('/account', { token: a.accessToken })).status, 401);
  assert.equal(
    (
      await f.request('/accounts/recover', {
        method: 'POST',
        body: {
          username: 'account.one',
          recoveryCode: a.recoveryCodes[0],
          newPassword,
          deviceName: 'Replay',
          platform: 'test',
        },
      })
    ).status,
    401,
  );
  assert.equal((await f.request('/account', { token: recovered.data.accessToken })).status, 200);
});

test('device names, revocation, logout and explicit password-verified account deletion are effective immediately', async (t) => {
  const f = await fixture(t);
  const a = await f.register();
  const b = await f.request('/devices', {
    method: 'POST',
    token: a.accessToken,
    body: { password, deviceName: 'Additional', platform: 'test' },
  });
  assert.equal(b.status, 201);
  assert.equal(
    (
      await f.request(`/devices/${b.data.device.id}`, {
        method: 'PATCH',
        token: a.accessToken,
        body: { name: 'Renamed device' },
      })
    ).status,
    200,
  );
  assert.equal(
    (await f.request('/devices', { token: a.accessToken })).data.devices.find(
      (d) => d.id === b.data.device.id,
    ).name,
    'Renamed device',
  );
  assert.equal(
    (await f.request(`/devices/${b.data.device.id}`, { method: 'DELETE', token: a.accessToken })).status,
    200,
  );
  assert.equal((await f.request('/account', { token: b.data.accessToken })).status, 401);
  assert.equal(
    (
      await f.request('/account', {
        method: 'DELETE',
        token: a.accessToken,
        body: { password, confirm: false },
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await f.request('/account', {
        method: 'DELETE',
        token: a.accessToken,
        body: { password: 'Wrong password 123!', confirm: true },
      })
    ).status,
    401,
  );
  assert.equal(
    (
      await f.request('/account', {
        method: 'DELETE',
        token: a.accessToken,
        body: { password, confirm: true },
      })
    ).status,
    200,
  );
  assert.equal((await f.request('/account', { token: a.accessToken })).status, 401);
  const c = await f.register('new.account');
  assert.equal(
    (await f.request('/sessions/current', { method: 'DELETE', token: c.accessToken })).status,
    200,
  );
  assert.equal((await f.request('/account', { token: c.accessToken })).status, 401);
});

test('service rejects unsafe configuration, malformed identities and bodies, and bounds authentication work', async (t) => {
  const f = await fixture(t);
  await assert.rejects(createSyncService({ ...f.options, host: '0.0.0.0' }), /HTTPS|loopback|proxy/i);
  await assert.rejects(createSyncService({ ...f.options, masterKey: Buffer.alloc(4) }), /key/i);
  for (const username of ['UPPER', '.leading', 'ab', 'name@example.com']) {
    assert.equal(
      (
        await f.request('/accounts', {
          method: 'POST',
          body: { username, password, deviceName: 'Test', platform: 'test' },
        })
      ).status,
      400,
    );
  }
  assert.equal(
    (
      await f.request('/accounts', {
        method: 'POST',
        body: { username: 'valid.name', password: 'short', deviceName: 'Test', platform: 'test' },
      })
    ).status,
    400,
  );
  const oversized = await f.request('/accounts', {
    method: 'POST',
    body: { extra: 'x'.repeat(2 * 1024 * 1024) },
  });
  assert.equal(oversized.status, 413);
  const failures = await Promise.all(
    Array.from({ length: 30 }, () =>
      f.request('/sessions', {
        method: 'POST',
        body: { username: 'nonexistent', password, deviceName: 'Test', platform: 'test' },
      }),
    ),
  );
  assert(failures.some((r) => r.status === 429));
  assert(failures.every((r) => [401, 429].includes(r.status)));
  assert.equal((await fetch(`${f.service.url}/ready`)).status, 200);
});
