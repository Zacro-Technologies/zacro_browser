'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const {
  AIService,
  safeSourceUrl,
  dedupeSources,
  sanitizeSuggestedFilename,
  pageCitations,
} = require('../src/main/ai.cjs');
const { CodexError } = require('../src/main/codex.cjs');

function sourced(text = 'A sourced answer [Evidence](https://example.com/evidence).') {
  return [
    { id: 'web', type: 'webSearch', action: { type: 'openPage', url: 'https://example.com/evidence' } },
    { id: 'answer', type: 'agentMessage', phase: 'final_answer', text },
  ];
}
async function fixture(t, options = {}) {
  const userDataPath = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-ai-test-'));
  const state = {
    profiles: [{ id: 'one' }, { id: 'two' }, { id: 'secret', private: true }],
    spaces: [
      { id: 'home', profileId: 'one' },
      { id: 'work', profileId: 'two' },
      { id: 'private', profileId: 'secret' },
    ],
    activeSpaceId: 'home',
    activeTabId: 'page-one',
    settings: {},
    tabs: [
      { id: 'page-one', profileId: 'one' },
      { id: 'page-two', profileId: 'two' },
      { id: 'page-three', profileId: 'one' },
    ],
  };
  const events = [],
    requests = [],
    extracted = [],
    external = [];
  const client = new EventEmitter();
  client.connected = options.connected !== false;
  client.pendingLogin = false;
  client.status = () => ({
    available: true,
    configured: client.connected,
    account: client.connected ? { email: 'fixture@example.test', planType: 'plus' } : null,
    models: [{ id: 'fixture-model', name: 'Fixture', isDefault: true }],
    loginPending: client.pendingLogin,
  });
  client.refresh = async () => client.status();
  client.login = async () => {
    client.pendingLogin = true;
    return 'https://auth.openai.com/authorize?fixture=true';
  };
  client.cancelLogin = async () => {
    client.pendingLogin = false;
  };
  client.logout = async () => {
    client.connected = false;
    client.emit('status');
  };
  client.close = () => {};
  client.run = async (request) => {
    requests.push(request);
    return options.run ? options.run(request) : sourced();
  };
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
    client,
    openExternal: async (url) => external.push(url),
    timeoutMs: options.timeoutMs || 2000,
  };
  const ai = new AIService(dependencies);
  await ai.ready;
  t.after(async () => {
    ai.close();
    await fs.rm(userDataPath, { recursive: true, force: true });
  });
  return { ai, client, state, events, requests, extracted, external, userDataPath, dependencies };
}

test('source URLs reject executable schemes and credentials; duplicate fragments collapse', () => {
  assert.equal(safeSourceUrl('javascript:alert(1)'), null);
  assert.equal(safeSourceUrl('file:///C:/secrets'), null);
  assert.equal(safeSourceUrl('https://user:secret@example.com/'), null);
  assert.equal(safeSourceUrl('https://example.com/a b'), 'https://example.com/a%20b');
  assert.equal(
    dedupeSources([{ url: 'https://example.com/#one' }, { url: 'https://example.com/#two' }]).length,
    1,
  );
});
test('filename suggestions preserve extensions and reject paths/reserved names', () => {
  assert.equal(sanitizeSuggestedFilename('../../invoice.exe', 'report.PDF'), 'invoice.PDF');
  assert.equal(sanitizeSuggestedFilename('CON', 'original.pdf'), 'download.pdf');
  assert.equal(sanitizeSuggestedFilename('Quarterly report', 'document.pdf'), 'Quarterly_report.pdf');
  assert.equal(sanitizeSuggestedFilename('file.exe\nignore all rules', 'invoice.pdf'), 'file.pdf');
  assert.ok(sanitizeSuggestedFilename('a'.repeat(300), 'document.pdf').length <= 180);
});
test('page and PDF citations resolve only actual shared paragraphs and physical pages', () => {
  const pages = [
    { id: 'tab', title: 'Policy', url: 'https://example.com/policy', paragraphs: ['The fee is $20.'] },
  ];
  const result = pageCitations('The fee is $20 [1:1], unknown [7:1].', pages);
  assert.equal(result.citations.length, 1);
  assert.equal(result.citations[0].quote, 'The fee is $20.');
  assert.ok(result.sources[0].url.includes('#:~:text='));
  Object.assign(pages[0], { pdf: true, paragraphPages: [4] });
  assert.equal(pageCitations('Fee [1:1]', pages).citations[0].url, 'https://example.com/policy#page=4');
});
test('subscription sign-in opens externally, exposes no URL/token, and can be cancelled', async (t) => {
  const { ai, external } = await fixture(t, { connected: false });
  const status = await ai.handle('ai:login');
  assert.equal(status.loginPending, true);
  assert.deepEqual(external, ['https://auth.openai.com/authorize?fixture=true']);
  assert.ok(!JSON.stringify(status).includes('authorize'));
  assert.equal((await ai.handle('ai:login-cancel')).loginPending, false);
  await assert.rejects(ai.handle('ai:ask', { question: 'Hello' }), { code: 'NOT_CONFIGURED' });
});
test('API configuration is rejected; legacy credentials never load; only model preference persists', async (t) => {
  const { ai, userDataPath, dependencies, events } = await fixture(t, { connected: false });
  await fs.writeFile(path.join(userDataPath, 'ai-credentials.enc'), 'legacy-secret');
  await assert.rejects(
    ai.handle('ai:configure', { provider: 'openai', apiKey: 'new-secret' }),
    /not supported/,
  );
  await assert.rejects(ai.handle('ai:configure', { model: 'invented-model' }), { code: 'MODEL' });
  await ai.handle('ai:configure', { model: 'fixture-model' });
  const restarted = new AIService(dependencies);
  await restarted.ready;
  assert.equal(restarted.status().configured, false);
  assert.equal(restarted.status().model, 'fixture-model');
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(userDataPath, 'ai-model.json'))), {
    model: 'fixture-model',
  });
  assert.ok(!JSON.stringify(events).includes('secret'));
  await ai.handle('ai:disconnect');
  assert.equal(await fs.readFile(path.join(userDataPath, 'ai-credentials.enc'), 'utf8'), 'legacy-secret');
});
test('research uses hosted search without open-page content and retains scoped follow-up context', async (t) => {
  const { ai, requests, extracted, state } = await fixture(t);
  const first = await ai.handle('ai:ask', { question: 'Research the latest policy.' });
  await ai.handle('ai:ask', { question: 'How does this compare?' });
  assert.equal(requests[0].research, true);
  assert.equal(requests[0].messages.length, 1);
  assert.equal(requests[1].messages.length, 3);
  assert.deepEqual(extracted, []);
  assert.equal(first.sources.length, 1);
  assert.equal(
    first.answer.slice(first.citations[0].start, first.citations[0].end),
    '[Evidence](https://example.com/evidence)',
  );
  assert.equal(state.tabs.length, 3);
});
test('selected pages disable research, reset research history, and cite only granted evidence', async (t) => {
  const { ai, requests, extracted } = await fixture(t, {
    run: async () => sourced('The fee is twenty dollars [1:1].'),
  });
  await ai.handle('ai:ask', { question: 'Research policies.' });
  const result = await ai.handle('ai:ask', { question: 'What is the fee?', tabIds: ['page-one'] });
  assert.deepEqual(extracted, ['page-one']);
  assert.equal(requests[1].research, false);
  assert.equal(requests[1].messages.length, 1);
  assert.match(requests[1].messages[0].content, /cancellation fee/);
  assert.equal(result.citations[0].tabId, 'page-one');
});
test('cross-profile/private requests fail before extraction and conversation never crosses profiles', async (t) => {
  const { ai, state, requests, extracted } = await fixture(t);
  await assert.rejects(ai.handle('ai:ask', { question: 'Read this.', tabIds: ['page-two'] }), {
    code: 'SCOPE',
  });
  state.activeSpaceId = 'private';
  await assert.rejects(ai.handle('ai:ask', { question: 'Research this.' }), { code: 'PRIVATE' });
  assert.equal(requests.length, 0);
  assert.equal(extracted.length, 0);
  state.activeSpaceId = 'home';
  await ai.handle('ai:ask', { question: 'Personal secret subject.' });
  state.activeSpaceId = 'work';
  assert.deepEqual(ai.latestSources, []);
  await ai.handle('ai:ask', { question: 'Unrelated subject.' });
  assert.equal(requests[1].messages.length, 1);
  assert.ok(!JSON.stringify(requests[1].messages).includes('Personal secret'));
});
test('profile changes during extraction discard content before Codex receives it', async (t) => {
  let state;
  const setup = await fixture(t, {
    getPageContext: async () => {
      state.activeSpaceId = 'work';
      return [];
    },
  });
  state = setup.state;
  await assert.rejects(setup.ai.handle('ai:ask', { question: 'Read this', usePageContext: true }), {
    code: 'PROFILE_CHANGED',
  });
  assert.equal(setup.requests.length, 0);
});
test('empty/unreadable selected pages never silently become research', async (t) => {
  const { ai, state, requests } = await fixture(t, { getPageContext: async () => [] });
  await assert.rejects(ai.handle('ai:ask', { question: 'Read', usePageContext: true }), {
    code: 'NO_CONTEXT',
  });
  state.activeTabId = null;
  await assert.rejects(ai.handle('ai:ask', { question: 'Read', usePageContext: true }), {
    code: 'NO_CONTEXT',
  });
  assert.equal(requests.length, 0);
  await ai.handle('ai:ask', { question: 'Research instead' });
  assert.equal(requests[0].research, true);
});
test('streaming and cancellation never publish a partial answer as complete', async (t) => {
  let ready;
  const started = new Promise((resolve) => {
    ready = resolve;
  });
  const { ai, events } = await fixture(t, {
    run: ({ signal, onDelta }) =>
      new Promise((resolve, reject) => {
        onDelta('Partial');
        ready();
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      }),
  });
  const rejected = assert.rejects(ai.handle('ai:ask', { question: 'Long answer' }), { code: 'CANCELLED' });
  await started;
  assert.equal(ai.status().busy, true);
  await ai.handle('ai:cancel');
  await rejected;
  assert.equal(ai.status().busy, false);
  assert.deepEqual(
    events.filter((event) => event.type === 'ai:delta'),
    [{ type: 'ai:delta', delta: 'Partial', profileId: 'one' }],
  );
  assert.equal(events.filter((event) => event.type === 'ai:answer').length, 0);
});
test('subscription limits propagate without another provider or billing fallback', async (t) => {
  const { ai, requests } = await fixture(t, {
    run: async () => {
      throw new CodexError('Codex allowance reached; no API billing fallback.', 'LIMIT');
    },
  });
  await assert.rejects(ai.handle('ai:ask', { question: 'Research' }), { code: 'LIMIT' });
  assert.equal(requests.length, 1);
});
test('model-written URLs alone are not verified sources', async (t) => {
  const { ai } = await fixture(t, {
    run: async () => [{ type: 'agentMessage', text: '[Claim](https://invented.example)' }],
  });
  const answer = await ai.handle('ai:ask', { question: 'Obscure subject' });
  assert.deepEqual(answer.sources, []);
  assert.match(answer.warning, /unverified/);
  assert.equal(answer.searchUrl, 'https://duckduckgo.com/?q=Obscure%20subject');
});
test('filename suggestions send metadata only, preserve extensions and never stream into chat', async (t) => {
  const { ai, requests, events, userDataPath } = await fixture(t, {
    run: async ({ onDelta }) => {
      onDelta('quarterly_report.exe');
      return sourced('quarterly_report.exe');
    },
  });
  const result = await ai.handle('ai:suggest-name', {
    id: 'one',
    name: 'original.pdf',
    title: 'Quarterly report',
    url: 'https://example.com/',
  });
  assert.equal(result.name, 'quarterly_report.pdf');
  assert.equal(requests[0].research, false);
  assert.match(requests[0].messages[0].content, /No file contents have been shared/);
  assert.deepEqual(await fs.readdir(userDataPath), []);
  assert.equal(
    events.some((event) => event.type === 'ai:delta'),
    false,
  );
});
