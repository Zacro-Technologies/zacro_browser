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
    isEncryptionAvailable: () => true,
    getSelectedStorageBackend: () => 'test-encrypted',
    encryptString: (value) => {
      const nonce = randomBytes(12),
        cipher = createCipheriv('aes-256-gcm', key, nonce);
      const result = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
      return Buffer.concat([nonce, cipher.getAuthTag(), result]);
    },
    decryptString: (value) => {
      const decipher = createDecipheriv('aes-256-gcm', key, value.subarray(0, 12));
      decipher.setAuthTag(value.subarray(12, 28));
      return Buffer.concat([decipher.update(value.subarray(28)), decipher.final()]).toString();
    },
  };
}
async function vault(t, safeStorage) {
  const userDataPath = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-keys-test-'));
  const store = new CredentialVault({ userDataPath, safeStorage });
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
  const reopened = new CredentialVault({ userDataPath, safeStorage });
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

test('missing/keychain basic_text/encryption failure never saves plaintext and requires explicit session mode', async (t) => {
  const { store, userDataPath } = await vault(t, {
    isEncryptionAvailable: () => true,
    getSelectedStorageBackend: () => 'basic_text',
  });
  await assert.rejects(store.set('id', 'secret-token', 'encrypted'), { code: 'AUTH_STORAGE' });
  assert.deepEqual(await fs.readdir(userDataPath), []);
  await store.set('id', 'secret-token', 'session');
  assert.equal(await store.get('id'), 'secret-token');
  assert.deepEqual(await fs.readdir(userDataPath), []);
  store.safeStorage = {
    isEncryptionAvailable: () => true,
    encryptString: () => {
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
  const reopened = new CredentialVault({ userDataPath, safeStorage: encryption() });
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
