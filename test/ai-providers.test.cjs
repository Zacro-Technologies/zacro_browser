'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomBytes, createCipheriv, createDecipheriv } = require('node:crypto');
const { APIClient, normalizeBaseUrl, parseAnswer, MAX_RESPONSE } = require('../src/main/ai-providers.cjs');
const { CredentialVault, credentialId } = require('../src/main/ai-credentials.cjs');

function json(data, init = {}) {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: { 'content-type': 'application/json', ...init.headers },
  });
}
const request = {
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  key: 'fixture-api-secret',
  model: 'gpt-5-mini',
  instructions: 'Answer only',
  messages: [{ role: 'user', content: 'Question' }],
};
function encryption() {
  const key = randomBytes(32);
  return {
    isAsyncEncryptionAvailable: async () => true,
    encryptStringAsync: async (value) => {
      const nonce = randomBytes(12),
        cipher = createCipheriv('aes-256-gcm', key, nonce);
      const result = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
      return Buffer.concat([nonce, cipher.getAuthTag(), result]);
    },
    decryptStringAsync: async (value) => {
      const decipher = createDecipheriv('aes-256-gcm', key, value.subarray(0, 12));
      decipher.setAuthTag(value.subarray(12, 28));
      return {
        result: Buffer.concat([decipher.update(value.subarray(28)), decipher.final()]).toString(),
        shouldReEncrypt: false,
      };
    },
  };
}
async function vault(t, safeStorage, options = {}) {
  const userDataPath = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-keys-test-'));
  const store = new CredentialVault({ userDataPath, safeStorage, platform: 'win32', ...options });
  await store.ready;
  t.after(async () => {
    store.close();
    await fs.rm(userDataPath, { recursive: true, force: true });
  });
  return { store, userDataPath };
}

test('custom endpoints require HTTPS or literal loopback HTTP; official endpoints cannot be overridden', () => {
  for (const value of [
    'http://remote.example/v1',
    'https://user:secret@example.com/v1',
    'https://example.com/v1?token=x',
    'https://example.com/#x',
    'file:///tmp',
    'http://127.0.0.1.evil.test/v1',
    'https://host\\@evil.test',
    42,
  ])
    assert.throws(() => normalizeBaseUrl('compatible', value), { code: 'ENDPOINT' });
  assert.equal(normalizeBaseUrl('compatible', 'http://127.0.0.1:8080/v1/'), 'http://127.0.0.1:8080/v1');
  assert.equal(normalizeBaseUrl('compatible', 'http://[::1]:1234/v1'), 'http://[::1]:1234/v1');
  assert.equal(
    normalizeBaseUrl('compatible', 'https://api.example.com/custom/v1'),
    'https://api.example.com/custom/v1',
  );
  assert.throws(() => normalizeBaseUrl('openai', 'https://evil.test/v1'), { code: 'ENDPOINT' });
  assert.throws(() => normalizeBaseUrl('anthropic', 42), { code: 'ENDPOINT' });
});

test('API keys encrypt at rest, bind profile/provider/endpoint, and session choice removes old durable key', async (t) => {
  const safeStorage = encryption();
  const { store, userDataPath } = await vault(t, safeStorage);
  const id = credentialId('profile-one', 'openai', request.baseUrl);
  await store.set(id, 'fixture-api-secret', 'encrypted');
  assert.ok(!(await fs.readFile(store.file, 'utf8')).includes('fixture-api-secret'));
  const reopened = new CredentialVault({ userDataPath, safeStorage, platform: 'win32' });
  assert.equal(await reopened.get(id), 'fixture-api-secret');
  for (const other of [
    credentialId('profile-two', 'openai', request.baseUrl),
    credentialId('profile-one', 'anthropic', request.baseUrl),
    credentialId('profile-one', 'openai', 'https://evil.test/v1'),
  ])
    assert.equal(await reopened.get(other), '');
  await reopened.set(id, 'new-session-secret', 'session');
  assert.equal(reopened.status(id).credentialStorage, 'session');
  assert.equal(JSON.parse(await fs.readFile(store.file)).records[id], undefined);
  reopened.close();
  assert.equal(await reopened.get(id), '');
});

test('unavailable or failed async encryption never saves plaintext and requires explicit session mode', async (t) => {
  const { store, userDataPath } = await vault(t, {
    ...encryption(),
    isAsyncEncryptionAvailable: async () => false,
  });
  await assert.rejects(store.set('id', 'secret-token', 'encrypted'), { code: 'AUTH_STORAGE' });
  assert.deepEqual(await fs.readdir(userDataPath), []);
  await store.set('id', 'secret-token', 'session');
  assert.equal(await store.get('id'), 'secret-token');
  assert.deepEqual(await fs.readdir(userDataPath), []);
  store.safeStorage = {
    ...encryption(),
    encryptStringAsync: async () => {
      throw new Error('raw-secret-error');
    },
  };
  await assert.rejects(
    store.set('id', 'secret-token', 'encrypted'),
    (error) => error.code === 'AUTH_STORAGE' && !error.message.includes('raw-secret'),
  );
  assert.deepEqual(await fs.readdir(userDataPath), []);
});

test('unreadable encrypted vault preserves existing file rather than overwriting credentials', async (t) => {
  const { userDataPath, store } = await vault(t, encryption());
  await fs.writeFile(store.file, 'broken-credential-file');
  const reopened = new CredentialVault({ userDataPath, safeStorage: encryption(), platform: 'win32' });
  await assert.rejects(reopened.set('id', 'new-secret', 'encrypted'), { code: 'AUTH_STORAGE' });
  assert.equal(await fs.readFile(store.file, 'utf8'), 'broken-credential-file');
});

test('profile deletion removes durable and session credentials across old endpoints, preserving other profiles', async (t) => {
  const { store } = await vault(t, encryption());
  const first = credentialId('one', 'compatible', 'https://first.example/v1');
  const second = credentialId('one', 'compatible', 'https://second.example/v1');
  const other = credentialId('two', 'openai', request.baseUrl);
  await store.set(first, 'first-secret', 'encrypted');
  await store.set(second, 'second-secret', 'session');
  await store.set(other, 'other-secret', 'encrypted');
  await store.forgetProfile('one');
  assert.equal(await store.get(first), '');
  assert.equal(await store.get(second), '');
  assert.equal(await store.get(other), 'other-secret');
  assert.deepEqual(Object.keys(JSON.parse(await fs.readFile(store.file)).records), [other]);
});

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test('startup, status, missing keys and session storage never access operating system encryption', async (t) => {
  let accessed = 0;
  const safeStorage = new Proxy(
    {},
    {
      get() {
        accessed++;
        throw new Error('OS store touched');
      },
    },
  );
  for (const platform of ['win32', 'darwin', 'linux']) {
    const { store } = await vault(t, safeStorage, { platform });
    assert.equal(store.status('id').storageAvailable, platform === 'linux' ? false : null);
    assert.equal(await store.get('missing'), '');
    await store.set('id', 'session-secret', 'session');
    assert.equal(await store.get('id'), 'session-secret');
    assert.equal(store.status('id').credentialStorage, 'session');
    await store.remove('id');
  }
  assert.equal(accessed, 0);
});

test('sync-only and Linux async fallback storage fail closed without invoking an OS provider', async (t) => {
  for (const platform of ['win32', 'linux']) {
    let probes = 0;
    const fake = {
      isEncryptionAvailable() {
        probes++;
        return true;
      },
      encryptString() {
        probes++;
        return Buffer.from('insecure');
      },
      getSelectedStorageBackend() {
        probes++;
        return 'gnome_libsecret';
      },
      ...(platform === 'linux' ? encryption() : {}),
    };
    const { store, userDataPath } = await vault(t, fake, { platform });
    await assert.rejects(store.set('id', 'secret-token', 'encrypted'), { code: 'AUTH_STORAGE' });
    assert.equal(store.status('id').storageAvailable, false);
    assert.deepEqual(await fs.readdir(userDataPath), []);
    assert.equal(probes, 0);
  }
});

test('async decryption uses the Electron result object and atomically rotates ciphertext', async (t) => {
  const fake = encryption();
  const { store } = await vault(t, fake);
  const id = credentialId('profile', 'openai', request.baseUrl);
  await store.set(id, 'rotation-secret', 'encrypted');
  const original = await fs.readFile(store.file, 'utf8');
  const decrypt = fake.decryptStringAsync;
  fake.decryptStringAsync = async (value) => ({ ...(await decrypt(value)), shouldReEncrypt: true });
  assert.equal(await store.get(id), 'rotation-secret');
  const rotated = await fs.readFile(store.file, 'utf8');
  assert.notEqual(rotated, original);
  assert.ok(!rotated.includes('rotation-secret'));
  const record = JSON.parse(rotated).records[id];
  assert.equal(JSON.parse((await decrypt(Buffer.from(record, 'base64'))).result).key, 'rotation-secret');
  const persist = store.persist;
  store.persist = async () => {
    throw new Error('fixture write failure');
  };
  await assert.rejects(store.get(id), { code: 'AUTH_STORAGE' });
  assert.equal(
    await fs.readFile(store.file, 'utf8'),
    rotated,
    'Failed rotation must preserve the old record',
  );
  store.persist = persist;
});

test('malformed async decrypt results and mismatched credential bindings are never accepted or rotated', async (t) => {
  const fake = encryption();
  const { store } = await vault(t, fake);
  const id = credentialId('profile', 'openai', request.baseUrl);
  await store.set(id, 'bound-secret', 'encrypted');
  const original = await fs.readFile(store.file, 'utf8');
  for (const result of [
    JSON.stringify({ id, key: 'bound-secret' }),
    { result: JSON.stringify({ id, key: 'bound-secret' }) },
    { result: JSON.stringify({ id: 'other', key: 'bound-secret' }), shouldReEncrypt: true },
  ]) {
    fake.decryptStringAsync = async () => result;
    await assert.rejects(store.get(id), { code: 'AUTH_STORAGE' });
    assert.equal(await fs.readFile(store.file, 'utf8'), original);
  }
});

test('a hanging OS availability prompt times out without late encryption or persistence', async (t) => {
  const pending = deferred();
  let encryptions = 0;
  const fake = {
    ...encryption(),
    isAsyncEncryptionAvailable: () => pending.promise,
    encryptStringAsync: async () => {
      encryptions++;
      return Buffer.from('unused');
    },
  };
  const { store, userDataPath } = await vault(t, fake, { storageTimeoutMs: 30 });
  await assert.rejects(store.set('id', 'timed-out-secret', 'encrypted'), /did not respond in time/);
  pending.resolve(true);
  await new Promise(setImmediate);
  assert.equal(encryptions, 0);
  assert.equal(store.status('id').storageAvailable, null);
  assert.equal(store.status('id').configured, false);
  assert.deepEqual(await fs.readdir(userDataPath), []);
});

test('late encryption cannot overwrite an explicit session choice after timeout', async (t) => {
  const pending = deferred();
  const fake = { ...encryption(), encryptStringAsync: () => pending.promise };
  const { store, userDataPath } = await vault(t, fake, { storageTimeoutMs: 30 });
  await assert.rejects(store.set('id', 'old-secret', 'encrypted'), /did not respond in time/);
  await store.set('id', 'current-secret', 'session');
  pending.resolve(Buffer.from('late-ciphertext'));
  await new Promise(setImmediate);
  assert.equal(await store.get('id'), 'current-secret');
  assert.deepEqual(await fs.readdir(userDataPath), []);
});

test('closing during encryption or decryption cancels promptly and ignores late completion', async (t) => {
  for (const mode of ['encrypt', 'decrypt']) {
    const fake = encryption();
    const { store, userDataPath } = await vault(t, fake);
    const id = credentialId('profile', 'openai', request.baseUrl);
    if (mode === 'decrypt') await store.set(id, 'saved-secret', 'encrypted');
    const before = mode === 'decrypt' ? await fs.readFile(store.file, 'utf8') : null;
    const pending = deferred(),
      entered = deferred();
    fake[`${mode}StringAsync`] = () => {
      entered.resolve();
      return pending.promise;
    };
    const operation = mode === 'encrypt' ? store.set(id, 'pending-secret', 'encrypted') : store.get(id);
    const rejected = assert.rejects(operation, { code: 'AUTH_STORAGE' });
    await entered.promise;
    store.close();
    await rejected;
    pending.resolve(
      mode === 'encrypt'
        ? Buffer.from('late-ciphertext')
        : {
            result: JSON.stringify({ id, key: 'saved-secret' }),
            shouldReEncrypt: true,
          },
    );
    await new Promise(setImmediate);
    if (before) assert.equal(await fs.readFile(store.file, 'utf8'), before);
    else assert.deepEqual(await fs.readdir(userDataPath), []);
    assert.equal(store.session.size, 0);
  }
});

test('superseded saves and deleted-profile decryptions cannot restore old keys', async (t) => {
  const fake = encryption();
  const { store } = await vault(t, fake);
  const id = credentialId('profile', 'openai', request.baseUrl);
  const encrypt = fake.encryptStringAsync;
  const pending = deferred(),
    entered = deferred();
  fake.encryptStringAsync = () => {
    entered.resolve();
    return pending.promise;
  };
  const older = store.set(id, 'old-secret', 'encrypted');
  const rejected = assert.rejects(older, { code: 'AUTH_STORAGE' });
  await entered.promise;
  fake.encryptStringAsync = encrypt;
  await store.set(id, 'new-secret', 'encrypted');
  pending.resolve(Buffer.from('old-ciphertext'));
  await rejected;
  assert.equal(await store.get(id), 'new-secret');

  const decryption = deferred(),
    decryptEntered = deferred();
  fake.decryptStringAsync = () => {
    decryptEntered.resolve();
    return decryption.promise;
  };
  const reading = store.get(id);
  const readRejected = assert.rejects(reading, { code: 'AUTH_STORAGE' });
  await decryptEntered.promise;
  await store.forgetProfile('profile');
  decryption.resolve({ result: JSON.stringify({ id, key: 'new-secret' }), shouldReEncrypt: true });
  await readRejected;
  assert.equal(await store.get(id), '');
  assert.equal(JSON.parse(await fs.readFile(store.file, 'utf8')).records[id], undefined);
});

test('concurrent independent encrypted saves preserve both provider records', async (t) => {
  const { store } = await vault(t, encryption());
  const first = credentialId('one', 'openai', request.baseUrl);
  const second = credentialId('two', 'openai', request.baseUrl);
  await Promise.all([
    store.set(first, 'first-secret', 'encrypted'),
    store.set(second, 'second-secret', 'encrypted'),
  ]);
  assert.equal(await store.get(first), 'first-secret');
  assert.equal(await store.get(second), 'second-secret');
  assert.equal(Object.keys(JSON.parse(await fs.readFile(store.file, 'utf8')).records).length, 2);
});

test('closing during a queued commit prevents saved/session state from being repopulated', async (t) => {
  const { store } = await vault(t, encryption());
  const pending = deferred(),
    entered = deferred();
  store.persist = async () => {
    entered.resolve();
    await pending.promise;
  };
  const saving = store.set('id', 'pending-secret', 'encrypted');
  const rejected = assert.rejects(saving, { code: 'AUTH_STORAGE' });
  await entered.promise;
  store.close();
  pending.resolve();
  await rejected;
  assert.equal(store.status('id').configured, false);
  assert.equal(store.session.size, 0);
});

test('OpenAI Responses sends only authorized tools, no storage, and preserves provider citation offsets', async () => {
  let sent;
  const client = new APIClient({
    fetch: async (url, options) => {
      sent = { url, options };
      return json({
        status: 'completed',
        output: [
          {
            type: 'message',
            content: [
              {
                type: 'output_text',
                text: 'Fact [1]',
                annotations: [
                  {
                    type: 'url_citation',
                    url: 'https://example.com/source',
                    title: 'Evidence',
                    start_index: 5,
                    end_index: 8,
                  },
                ],
              },
            ],
          },
        ],
        usage: { input_tokens: 10, output_tokens: 3 },
      });
    },
  });
  const result = await client.run({ ...request, research: true });
  assert.equal(sent.url, 'https://api.openai.com/v1/responses');
  assert.equal(sent.options.redirect, 'error');
  assert.equal(sent.options.credentials, 'omit');
  const body = JSON.parse(sent.options.body);
  assert.deepEqual(body.tools, [{ type: 'web_search' }]);
  assert.equal(body.store, false);
  assert.equal(result.answer.slice(result.citations[0].start, result.citations[0].end), '[1]');
  assert.equal(result.usage.input_tokens, 10);
  await client.run({ ...request, research: false });
  assert.equal(JSON.parse(sent.options.body).tools, undefined);
});

test('Anthropic uses official key/version headers, bounded hosted search and exact opaque history blocks', async () => {
  let sent;
  const content = [
    {
      type: 'text',
      text: 'Fact.',
      citations: [
        {
          type: 'web_search_result_location',
          url: 'https://example.com/evidence',
          title: 'Evidence',
          encrypted_index: 'opaque-index',
        },
      ],
    },
    {
      type: 'web_search_tool_result',
      content: [
        { url: 'https://example.com/evidence', title: 'Evidence', encrypted_content: 'opaque-search' },
      ],
    },
  ];
  const client = new APIClient({
    fetch: async (url, options) => {
      sent = { url, options };
      return json({ content, stop_reason: 'end_turn' });
    },
  });
  const result = await client.run({
    ...request,
    provider: 'anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-sonnet-4-6',
    research: true,
  });
  assert.equal(sent.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(sent.options.headers['x-api-key'], request.key);
  assert.equal(sent.options.headers.authorization, undefined);
  assert.equal(sent.options.headers['anthropic-version'], '2023-06-01');
  assert.equal(JSON.parse(sent.options.body).tools[0].max_uses, 5);
  assert.deepEqual(result.historyContent, content);
  assert.equal(result.answer.slice(result.citations[0].start, result.citations[0].end), '[1]');
});

test('OpenRouter disables provider fallback and exposes only verified search annotations; compatible sends no search tools', async () => {
  const calls = [];
  const client = new APIClient({
    fetch: async (url, options) => {
      calls.push({ url, options });
      return json({
        choices: [
          {
            message: {
              content: 'Answer [1]',
              annotations: [
                {
                  type: 'url_citation',
                  url_citation: {
                    url: 'https://example.com',
                    title: 'Evidence',
                    start_index: 7,
                    end_index: 10,
                  },
                },
              ],
            },
          },
        ],
      });
    },
  });
  const router = await client.run({
    ...request,
    provider: 'openrouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'openai/gpt-5-mini',
    research: true,
  });
  assert.equal(JSON.parse(calls[0].options.body).provider.allow_fallbacks, false);
  assert.equal(JSON.parse(calls[0].options.body).plugins[0].id, 'web');
  assert.equal(router.sources.length, 1);
  const compatible = await client.run({
    ...request,
    provider: 'compatible',
    baseUrl: 'http://localhost:11434/v1',
    key: '',
    model: 'local/model',
    research: false,
  });
  assert.equal(calls[1].options.headers.authorization, undefined);
  assert.equal(JSON.parse(calls[1].options.body).plugins, undefined);
  assert.equal(compatible.sources.length, 0);
});

test('HTTP errors and redirects are sanitized, bodies cancelled, and never retried', async () => {
  for (const [status, code] of [
    [302, 'REDIRECT'],
    [401, 'AUTH'],
    [429, 'LIMIT'],
    [500, 'PROVIDER'],
  ]) {
    let calls = 0,
      cancelled = false;
    const client = new APIClient({
      fetch: async () => {
        calls++;
        return new Response(
          new ReadableStream({
            cancel() {
              cancelled = true;
            },
          }),
          { status, headers: { 'content-type': 'application/json', location: 'https://evil.test' } },
        );
      },
    });
    await assert.rejects(client.run(request), { code });
    assert.equal(calls, 1);
    assert.equal(cancelled, true);
  }
});

test('oversized declared and chunked bodies cancel their streams; non-JSON responses fail closed', async () => {
  for (const declared of [true, false]) {
    let cancelled = false;
    const client = new APIClient({
      fetch: async () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new Uint8Array(MAX_RESPONSE + 1));
            },
            cancel() {
              cancelled = true;
            },
          }),
          {
            headers: {
              'content-type': 'application/json',
              ...(declared ? { 'content-length': String(MAX_RESPONSE + 1) } : {}),
            },
          },
        ),
    });
    await assert.rejects(client.run(request), { code: 'RESPONSE_SIZE' });
    assert.equal(cancelled, true);
  }
  await assert.rejects(
    new APIClient({ fetch: async () => new Response('<html>secret</html>') }).run(request),
    { code: 'PROTOCOL' },
  );
});

test('cancellation terminates stalled body reads and pre-aborted requests do not call transport', async () => {
  const controller = new AbortController();
  let cancelled = false;
  const client = new APIClient({
    fetch: async () =>
      new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
        { headers: { 'content-type': 'application/json' } },
      ),
  });
  const pending = client.run({ ...request, signal: controller.signal });
  await new Promise((resolve) => setImmediate(resolve));
  controller.abort(Object.assign(new Error('Stopped'), { code: 'CANCELLED' }));
  await assert.rejects(pending, { code: 'CANCELLED' });
  assert.equal(cancelled, true);
  await assert.rejects(
    new APIClient({
      fetch: () => {
        assert.fail('No transport after cancellation');
      },
    }).run({ ...request, signal: controller.signal }),
    { code: 'CANCELLED' },
  );
});

test('incomplete responses, local tool requests and fabricated URLs never become completed sourced answers', () => {
  assert.throws(() => parseAnswer('openai', { status: 'incomplete', output: [] }), { code: 'INCOMPLETE' });
  assert.throws(() => parseAnswer('anthropic', { stop_reason: 'pause_turn', content: [] }), {
    code: 'INCOMPLETE',
  });
  assert.throws(
    () => parseAnswer('compatible', { choices: [{ message: { content: 'Done', tool_calls: [{}] } }] }),
    { code: 'TOOL_POLICY' },
  );
  const result = parseAnswer('openai', {
    output: [
      {
        type: 'message',
        content: [
          {
            type: 'output_text',
            text: '[invented](https://example.com)',
            annotations: [{ type: 'url_citation', url: 'javascript:alert(1)', start_index: 0, end_index: 5 }],
          },
        ],
      },
    ],
  });
  assert.deepEqual(result.sources, []);
});
