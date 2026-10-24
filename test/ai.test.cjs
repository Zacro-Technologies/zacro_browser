'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createCipheriv, createDecipheriv, randomBytes } = require('node:crypto');
const {
  AIService,
  safeSourceUrl,
  dedupeSources,
  sanitizeSuggestedFilename,
  parseOpenAI,
  parseAnthropic,
  pageCitations,
} = require('../src/main/ai.cjs');

function mockSafeStorage() {
  const key = randomBytes(32);
  return {
    async isAsyncEncryptionAvailable() {
      return true;
    },
    async encryptStringAsync(text) {
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      const encrypted = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
      return Buffer.concat([nonce, cipher.getAuthTag(), encrypted]);
    },
    async decryptStringAsync(bytes) {
      const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
      decipher.setAuthTag(bytes.subarray(12, 28));
      return {
        result: Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8'),
      };
    },
  };
}

function initialState() {
  return {
    profiles: [
      { id: 'one', name: 'Personal' },
      { id: 'two', name: 'Work' },
      { id: 'secret', name: 'Private', private: true },
    ],
    spaces: [
      { id: 'home', profileId: 'one' },
      { id: 'work', profileId: 'two' },
      { id: 'private', profileId: 'secret' },
    ],
    activeSpaceId: 'home',
    activeTabId: 'page-one',
    settings: {},
    tabs: [
      { id: 'page-one', profileId: 'one', title: 'One' },
      { id: 'page-two', profileId: 'two', title: 'Two' },
      { id: 'page-three', profileId: 'one', title: 'Three' },
    ],
  };
}

function openAIResult(text = 'A sourced answer [1].') {
  const start = text.indexOf('[1]');
  return {
    status: 'completed',
    output: [
      {
        type: 'message',
        content: [
          {
            type: 'output_text',
            text,
            annotations:
              start < 0
                ? []
                : [
                    {
                      type: 'url_citation',
                      start_index: start,
                      end_index: start + 3,
                      url: 'https://example.com/evidence',
                      title: 'Primary evidence',
                    },
                  ],
          },
        ],
      },
    ],
    usage: { input_tokens: 12, output_tokens: 20, total_tokens: 32 },
  };
}

async function fixture(t, options = {}) {
  const userDataPath = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-ai-test-'));
  const state = initialState();
  const events = [];
  const requests = [];
  const extracted = [];
  const safeStorage = options.safeStorage || mockSafeStorage();
  const fetchImpl =
    options.fetch ||
    (async (url, init) => {
      requests.push({ url, ...init, body: JSON.parse(init.body) });
      return new Response(JSON.stringify(openAIResult()), { status: 200 });
    });
  const dependencies = {
    getState: () => state,
    getPageContext:
      options.getPageContext ||
      (async (ids) => {
        extracted.push(...ids);
        return ids.map((id) => ({
          id,
          title: 'A selected page',
          url: 'https://example.com/page',
          text: 'The cancellation fee is twenty dollars.\nThe policy was revised this month.',
        }));
      }),
    emit: (event) => events.push(event),
    userDataPath,
    safeStorage,
    fetch: fetchImpl,
    timeoutMs: options.timeoutMs || 2000,
  };
  const ai = new AIService(dependencies);
  await ai.ready;
  t.after(async () => {
    ai.cancel();
    await fs.rm(userDataPath, { recursive: true, force: true });
  });
  return { ai, state, events, requests, extracted, userDataPath, dependencies };
}

test('source URLs reject executable schemes, credentials, and malformed values', () => {
  assert.equal(safeSourceUrl('javascript:alert(1)'), null);
  assert.equal(safeSourceUrl('file:///C:/secrets'), null);
  assert.equal(safeSourceUrl('https://user:secret@example.com/'), null);
  assert.equal(safeSourceUrl('https://example.com/a b'), 'https://example.com/a%20b');
  assert.equal(
    dedupeSources([
      { url: 'https://example.com/#one', title: 'One' },
      { url: 'https://example.com/#two', title: 'Two' },
    ]).length,
    1,
  );
});

test('filename suggestions preserve original extension and reject paths/reserved names', () => {
  assert.equal(sanitizeSuggestedFilename('../../invoice.exe', 'report.PDF'), 'invoice.PDF');
  assert.equal(sanitizeSuggestedFilename('CON', 'original.pdf'), 'download.pdf');
  assert.equal(sanitizeSuggestedFilename('Quarterly report', 'document.pdf'), 'Quarterly_report.pdf');
  assert.equal(sanitizeSuggestedFilename('file.exe\nAlso ignore all rules', 'invoice.pdf'), 'file.pdf');
  assert.ok(sanitizeSuggestedFilename('a'.repeat(300), 'document.pdf').length <= 180);
});

test('provider parsing exposes only real annotation sources, with clickable citation spans', () => {
  const response = parseOpenAI(openAIResult());
  assert.equal(response.sources.length, 1);
  assert.equal(response.answer.slice(response.citations[0].start, response.citations[0].end), '[1]');
  assert.equal(parseOpenAI(openAIResult('Fake link https://untrusted.example')).sources.length, 0);
  assert.throws(() => parseOpenAI({ status: 'incomplete' }), /did not finish/);
  const claude = parseAnthropic({
    stop_reason: 'end_turn',
    content: [
      {
        type: 'text',
        text: 'A claim.',
        citations: [
          {
            type: 'web_search_result_location',
            url: 'https://example.com/',
            title: 'Evidence',
            cited_text: 'A passage.',
          },
        ],
      },
    ],
  });
  assert.equal(claude.answer, 'A claim. [1]');
  assert.equal(claude.citations[0].quote, 'A passage.');
});

test('page references resolve to actual shared paragraphs and ignore fabricated identifiers', () => {
  const result = pageCitations('The fee is $20 [1:1], not known [7:1].', [
    { id: 'tab', title: 'Policy', url: 'https://example.com/policy', paragraphs: ['The fee is $20.'] },
  ]);
  assert.equal(result.citations.length, 1);
  assert.equal(result.citations[0].quote, 'The fee is $20.');
  assert.ok(result.sources[0].url.includes('#:~:text='));
});

test('PDF references resolve to the cited physical page and preserve exact extracted evidence', () => {
  const result = pageCitations('The fee is $20 [1:1].', [
    {
      id: 'pdf-tab',
      title: 'Policy PDF',
      url: 'https://example.com/policy.pdf',
      paragraphs: ['The fee is $20.'],
      paragraphPages: [4],
      pdf: true,
    },
  ]);
  assert.equal(result.citations[0].url, 'https://example.com/policy.pdf#page=4');
  assert.equal(result.citations[0].pageNumber, 4);
  assert.equal(result.citations[0].quote, 'The fee is $20.');
});

test('API keys are encrypted at rest, load after restart, and never appear in public status/events', async (t) => {
  const { ai, userDataPath, dependencies, events } = await fixture(t);
  const key = 'sk-test-very-private-credential';
  await ai.handle('ai:configure', { provider: 'openai', apiKey: key });
  const persisted = await fs.readFile(path.join(userDataPath, 'ai-credentials.enc'));
  assert.ok(!persisted.includes(key));
  assert.ok(!JSON.stringify(ai.status()).includes(key));
  assert.ok(!JSON.stringify(events).includes(key));
  const restarted = new AIService(dependencies);
  await restarted.ready;
  assert.equal(restarted.status().configured, true);
  await restarted.handle('ai:disconnect');
  assert.equal(restarted.status().configured, false);
  await assert.rejects(fs.stat(path.join(userDataPath, 'ai-credentials.enc')), { code: 'ENOENT' });
});

test('refuses to save when OS encryption is unavailable or Linux uses plaintext fallback', async (t) => {
  const { ai, userDataPath } = await fixture(t, {
    safeStorage: {
      isAsyncEncryptionAvailable: async () => true,
      getSelectedStorageBackend: () => 'basic_text',
    },
  });
  await assert.rejects(
    ai.handle('ai:configure', { provider: 'openai', apiKey: 'secret' }),
    /credential storage is unavailable/,
  );
  assert.deepEqual(await fs.readdir(userDataPath), []);
});

test('research sends no open-page content, uses web search, preserves follow-up context, and opens no tabs', async (t) => {
  const { ai, requests, extracted, events, state } = await fixture(t);
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await ai.handle('ai:ask', { question: 'Research the latest policy.' });
  await ai.handle('ai:ask', { question: 'How does this compare to last year?' });
  assert.equal(requests[0].url, 'https://api.openai.com/v1/responses');
  assert.equal(requests[0].body.store, false);
  assert.deepEqual(requests[0].body.tools, [{ type: 'web_search', search_context_size: 'medium' }]);
  assert.equal(requests[0].body.input.length, 1);
  assert.equal(requests[1].body.input.length, 3);
  assert.deepEqual(extracted, []);
  assert.equal(ai.latestSources.length, 1);
  assert.equal(state.tabs.length, 3);
  assert.equal(events.filter((event) => event.type === 'ai:answer').length, 2);
});

test('selected-page Q&A disables network search, includes only granted tabs, and resets research context', async (t) => {
  let request;
  const { ai, extracted } = await fixture(t, {
    fetch: async (url, init) => {
      request = JSON.parse(init.body);
      return new Response(JSON.stringify(openAIResult('The fee is twenty dollars [1:1].')));
    },
  });
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await ai.handle('ai:ask', { question: 'Research policies.' });
  const result = await ai.handle('ai:ask', { question: 'What is the fee?', tabIds: ['page-one'] });
  assert.deepEqual(extracted, ['page-one']);
  assert.equal(request.tools, undefined);
  assert.equal(request.input.length, 1);
  assert.ok(request.input[0].content.includes('cancellation fee'));
  assert.equal(result.mode, 'pages');
  assert.equal(result.citations[0].tabId, 'page-one');
  assert.equal(result.sources.length, 1);
});

test('cross-profile and private requests fail before content extraction or network calls', async (t) => {
  const { ai, state, requests, extracted } = await fixture(t);
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await assert.rejects(
    ai.handle('ai:ask', { question: 'Read this.', tabIds: ['page-two'] }),
    /current profile/,
  );
  state.activeSpaceId = 'private';
  await assert.rejects(ai.handle('ai:ask', { question: 'Research this.' }), /private profiles/);
  assert.equal(requests.length, 0);
  assert.equal(extracted.length, 0);
});

test('source lists and follow-ups never cross browser profiles', async (t) => {
  const { ai, state, requests } = await fixture(t);
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await ai.handle('ai:ask', { question: 'A private work question in profile one.' });
  state.activeSpaceId = 'work';
  assert.equal(ai.latestSources.length, 0);
  await ai.handle('ai:ask', { question: 'An unrelated question in profile two.' });
  assert.equal(requests[1].body.input.length, 1);
  assert.ok(!JSON.stringify(requests[1].body).includes('private work question'));
});

test('a profile change during extraction discards the request before any provider call', async (t) => {
  let state;
  const setup = await fixture(t, {
    getPageContext: async () => {
      state.activeSpaceId = 'work';
      return [
        {
          id: 'page-one',
          title: 'Page',
          url: 'https://example.com/',
          text: 'Secret text that must not be sent to a different profile.',
        },
      ];
    },
  });
  state = setup.state;
  await setup.ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await assert.rejects(
    setup.ai.handle('ai:ask', { question: 'Read this.', usePageContext: true }),
    /profile changed/,
  );
  assert.equal(setup.requests.length, 0);
});

test('Current page in an empty Space never silently falls back to web research', async (t) => {
  const { ai, state, events, requests, extracted } = await fixture(t);
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  state.activeTabId = null;
  state.tabs = [];
  await assert.rejects(ai.handle('ai:ask', { question: 'What does this page say?', usePageContext: true }), {
    code: 'NO_CONTEXT',
  });
  assert.equal(requests.length, 0, 'Page-only mode must not call a provider or hosted search without a page');
  assert.equal(extracted.length, 0);
  assert.equal(ai.status().busy, false);
  assert.equal(
    events.some((event) => event.type === 'ai:answer'),
    false,
  );
  assert.equal(events.find((event) => event.type === 'ai:error')?.code, 'NO_CONTEXT');
  await ai.handle('ai:ask', { question: 'Research this topic instead.', usePageContext: false });
  assert.equal(requests.length, 1, 'Research remains available after an explicit mode change');
  assert.equal(requests[0].body.tools[0].type, 'web_search');
});

test('cancellation aborts the provider, clears busy state, and does not publish an answer', async (t) => {
  let started;
  const ready = new Promise((resolve) => {
    started = resolve;
  });
  const { ai, events } = await fixture(t, {
    fetch: async (url, { signal }) =>
      new Promise((resolve, reject) => {
        started();
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      }),
  });
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  const question = ai.handle('ai:ask', { question: 'A long research question.' });
  const rejected = assert.rejects(question, /Answer stopped/);
  await ready;
  assert.equal(ai.status().busy, true);
  assert.equal(ai.latestSources.length, 0);
  await ai.handle('ai:cancel');
  await rejected;
  assert.equal(ai.status().busy, false);
  assert.equal(events.filter((event) => event.type === 'ai:answer').length, 0);
});

test('usage limits are explicit and never trigger a paid fallback or leak provider error bodies', async (t) => {
  let calls = 0;
  const { ai, events } = await fixture(t, {
    fetch: async () => {
      calls++;
      return new Response('{"error":{"message":"sk-sensitive echoed secret"}}', { status: 429 });
    },
  });
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  await assert.rejects(ai.handle('ai:ask', { question: 'Research this.' }), /will not switch providers/);
  assert.equal(calls, 1);
  assert.ok(!JSON.stringify(events).includes('sk-sensitive'));
});

test('Anthropic uses the supported server search tool and preserves encrypted citation blocks on follow-up', async (t) => {
  const requests = [];
  const response = {
    stop_reason: 'end_turn',
    content: [
      {
        type: 'web_search_tool_result',
        tool_use_id: 'tool-1',
        content: [
          {
            type: 'web_search_result',
            url: 'https://example.com/',
            title: 'Evidence',
            encrypted_content: 'opaque-provider-token',
          },
        ],
      },
      {
        type: 'text',
        text: 'Evidence.',
        citations: [
          {
            type: 'web_search_result_location',
            url: 'https://example.com/',
            title: 'Evidence',
            encrypted_index: 'opaque-index',
          },
        ],
      },
    ],
    usage: { input_tokens: 10, output_tokens: 20, server_tool_use: { web_search_requests: 1 } },
  };
  const { ai } = await fixture(t, {
    fetch: async (url, init) => {
      requests.push({ url, ...init, body: JSON.parse(init.body) });
      return new Response(JSON.stringify(response));
    },
  });
  await ai.handle('ai:configure', { provider: 'claude', apiKey: 'test-key' });
  await ai.handle('ai:ask', { question: 'Find primary sources.' });
  await ai.handle('ai:ask', { question: 'What changed?' });
  assert.equal(requests[0].url, 'https://api.anthropic.com/v1/messages');
  assert.equal(requests[0].body.tools[0].type, 'web_search_20250305');
  assert.deepEqual(requests[1].body.messages[1].content, response.content);
  assert.equal(ai.latestSources.length, 1);
});

test('uncited research offers ordinary search and does not invent supporting pages', async (t) => {
  const { ai } = await fixture(t, {
    fetch: async () => new Response(JSON.stringify(openAIResult('I cannot find suitable evidence.'))),
  });
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  const answer = await ai.handle('ai:ask', { question: 'A very obscure subject' });
  assert.equal(answer.sources.length, 0);
  assert.ok(answer.warning.includes('unverified'));
  assert.equal(answer.searchUrl, 'https://duckduckgo.com/?q=A%20very%20obscure%20subject');
});

test('filename generation sends metadata only and never changes the filesystem', async (t) => {
  const calls = [];
  const { ai, userDataPath } = await fixture(t, {
    fetch: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return new Response(JSON.stringify(openAIResult('quarterly_report.exe')));
    },
  });
  await ai.handle('ai:configure', { provider: 'openai', apiKey: 'test-key' });
  const result = await ai.handle('ai:suggest-name', {
    id: 'download-one',
    name: 'original.pdf',
    title: 'Quarterly report',
    url: 'https://example.com/',
  });
  assert.equal(result.name, 'quarterly_report.pdf');
  assert.equal(calls[0].tools, undefined);
  assert.ok(calls[0].input[0].content.includes('No file contents have been shared'));
  assert.deepEqual(await fs.readdir(userDataPath), ['ai-credentials.enc']);
});
