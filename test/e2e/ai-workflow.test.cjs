'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

async function bounded(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), 8000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function fixture(t, { configured = true } = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-ai-workflow-'));
  const requests = [],
    errors = [];
  let failedOnce = false;
  const server = http.createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    if (request.url.startsWith('/page-')) {
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      const name = request.url.slice(1);
      response.end(
        `<!doctype html><title>${name}</title><h1>${name}</h1><p>Evidence belonging only to ${name}.</p><p>The documented price is twenty dollars.</p><input type="password" value="fixture-password-must-not-be-shared">`,
      );
      return;
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/v1/models') {
      response.end(JSON.stringify({ data: [{ id: 'fixture' }] }));
      return;
    }
    if (request.url !== '/v1/chat/completions') {
      response.writeHead(404);
      response.end('{}');
      return;
    }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    requests.push(body);
    const question = body.messages.at(-1).content;
    if (question.startsWith('hold answer')) return;
    if (question.startsWith('fail once') && !failedOnce) {
      failedOnce = true;
      response.writeHead(503);
      response.end(JSON.stringify({ error: { message: 'Fixture temporarily unavailable' } }));
      return;
    }
    response.end(
      JSON.stringify({
        choices: [
          {
            message: {
              role: 'assistant',
              content: '**Summary**\nThe documented price is twenty dollars. [1:1]',
            },
            finish_reason: 'stop',
          },
        ],
        usage: { prompt_tokens: 20, completion_tokens: 12 },
      }),
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const env = { ...process.env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  let app;
  t.after(async () => {
    if (app)
      await bounded(app.close(), 'Application close').catch(async () => {
        const child = app.process();
        if (child.exitCode === null && child.signalCode === null) {
          const exited = new Promise((resolve) => child.once('exit', resolve));
          child.kill();
          await bounded(exited, 'Owned process exit');
        }
      });
    server.closeAllConnections();
    await bounded(new Promise((resolve) => server.close(resolve)), 'Fixture close');
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith('zacro-ai-workflow-'));
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    assert.deepEqual(errors, []);
  });
  app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
  const shell = await app.firstWindow();
  shell.setDefaultTimeout(10000);
  shell.on('pageerror', (error) => errors.push(error.message));
  const invoke = (action, payload = {}) =>
    shell.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
  await expect(shell.locator('#command-input')).toBeFocused();
  await shell.keyboard.press('Escape');
  await invoke('navigate', { url: `${base}/page-one` });
  await expect
    .poll(async () => {
      const state = await invoke('state:get');
      return state.tabs.find((tab) => tab.id === state.activeTabId)?.title;
    })
    .toBe('page-one');
  const first = (await invoke('state:get')).activeTabId;
  const second = await invoke('tab:create', { url: `${base}/page-two`, active: false });
  if (configured)
    await invoke('ai:configure', { provider: 'compatible', baseUrl: `${base}/v1`, model: 'fixture' });
  const open = async (section) => {
    await shell.getByRole('button', { name: 'Library', exact: true }).click();
    await shell.locator(`#library-menu [data-key="panel-${section}"]`).click();
    await expect(shell.locator('#panel-title')).toHaveText(section === 'ai' ? 'Ask Zacro' : 'Settings');
  };
  await open('ai');
  await expect(shell.locator('#ai-question')).toBeVisible();
  await shell.evaluate(() => {
    window.aiWorkflowEvents = [];
    window.zacro.onEvent((event) => {
      if (event.type.startsWith('ai:')) window.aiWorkflowEvents.push(event);
    });
  });
  return { app, shell, invoke, open, base, requests, first, second: second.id };
}

test(
  'Unconnected AI starters and palette questions retain editable drafts through connection settings without reading or sending',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t, { configured: false }),
      { shell } = b;
    await b.app.evaluate(({ webContents }, url) => {
      const guest = webContents.getAllWebContents().find((contents) => contents.getURL() === url);
      if (!guest) throw new Error('Fixture page is missing');
      global.aiWorkflowContextReads = { mime: 0, text: 0 };
      const original = guest.executeJavaScriptInIsolatedWorld.bind(guest);
      guest.executeJavaScriptInIsolatedWorld = (worldId, ...args) => {
        if (worldId === 1001) {
          const kind = args[0]?.[0]?.code === 'document.contentType' ? 'mime' : 'text';
          global.aiWorkflowContextReads[kind]++;
        }
        return original(worldId, ...args);
      };
    }, `${b.base}/page-one`);
    const prepareFromPalette = async (question, { keptInPalette = false } = {}) => {
      await b.invoke('shortcut:run', { id: 'command-palette' });
      await shell.locator('#command-input').fill(question);
      await b.app.evaluate(({ BrowserWindow }) => {
        const contents = BrowserWindow.getAllWindows()[0].webContents;
        contents.focus();
        const modifiers = [process.platform === 'darwin' ? 'meta' : 'control'];
        contents.sendInputEvent({ type: 'keyDown', keyCode: 'Enter', modifiers });
        contents.sendInputEvent({ type: 'keyUp', keyCode: 'Enter', modifiers });
      });
      await expect(shell.locator('#panel-title')).toHaveText('Ask Zacro');
      if (keptInPalette) await expect(shell.locator('#command-input')).toHaveValue(question);
      else await expect(shell.locator('#command-input')).toHaveCount(0);
    };
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    const firstQuestion = 'Explain how this browser keeps my tabs separate';
    await prepareFromPalette(firstQuestion);
    await expect(shell.locator('#ai-question')).toHaveValue(firstQuestion);
    await expect(shell.locator('#ai-submit')).toBeDisabled();
    const otherQuestion = 'Compare the two approaches to organizing research';
    await prepareFromPalette(otherQuestion);
    await expect(shell.locator('#ai-question')).toHaveValue(firstQuestion);
    await expect(shell.locator('.ai-saved-questions summary')).toHaveText('Saved questions (1)');
    const newestQuestion = 'Retain this third question without replacing either existing draft';
    await prepareFromPalette(newestQuestion, { keptInPalette: true });
    await expect(shell.locator('#ai-question')).toHaveValue(firstQuestion);
    await expect(shell.locator('.ai-saved-question')).toHaveCount(1);
    await shell.locator('#command-input').press('Escape');
    await shell.locator('.ai-saved-questions summary').click();
    await expect(shell.locator('.ai-saved-question .message-content')).toHaveText(otherQuestion);
    await shell.getByRole('button', { name: 'Review saved question', exact: true }).click();
    await expect(shell.locator('#ai-question')).toHaveValue(otherQuestion);
    await expect(shell.locator('.ai-saved-question .message-content')).toHaveText(firstQuestion);
    await shell.getByRole('button', { name: 'Review saved question', exact: true }).click();
    await expect(shell.locator('#ai-question')).toHaveValue(firstQuestion);
    await shell.getByRole('button', { name: 'Discard saved question', exact: true }).click();
    await expect(shell.locator('.ai-saved-questions')).toHaveCount(0);
    await shell.locator('#ai-question').fill('');
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    await b.invoke('shortcut:run', { id: 'command-palette' });
    await shell.locator('#command-input').fill('/summarize');
    await shell.getByRole('option').filter({ hasText: 'Summarize this page' }).click();
    await expect(shell.locator('#ai-question')).toBeVisible();
    await expect(shell.locator('#ai-question')).toBeEditable();
    await expect(shell.locator('#ai-question')).toHaveValue(/Summarize this page/);
    await expect(shell.locator('.ai-context-chip')).toContainText('page-one');
    await expect(shell.locator('.ai-context-chip')).toHaveAttribute('title', `${b.base}/page-one`);
    await expect(shell.locator('#ai-submit')).toBeDisabled();
    assert(await shell.evaluate(() => CSS.supports('field-sizing', 'content')));
    const composerSize = () =>
      shell.locator('#ai-question').evaluate((element) => ({
        height: element.getBoundingClientRect().height,
        visible: element.clientHeight,
        content: element.scrollHeight,
        top: element.scrollTop,
      }));
    await expect
      .poll(async () => {
        const size = await composerSize();
        return size.height > 53 && size.height <= 160 && size.content <= size.visible + 1 && size.top === 0;
      })
      .toBe(true);
    const longDraft = Array.from(
      { length: 30 },
      (_, index) => `Line ${index + 1}: keep this entire long draft editable.`,
    ).join('\n');
    await shell.locator('#ai-question').fill(longDraft);
    await expect
      .poll(async () => {
        const size = await composerSize();
        return size.height <= 160 && size.content > size.visible;
      })
      .toBe(true);
    await expect(shell.locator('#ai-question')).toHaveValue(longDraft);
    await shell.locator('#ai-question').fill('Short question');
    await expect.poll(async () => (await composerSize()).height).toBe(53);
    const draft = 'Keep my prepared question before connecting';
    await shell.locator('#ai-question').fill(draft);
    await shell.locator('#ai-question').press('Enter');
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await expect(shell.locator('.message')).toHaveCount(0);
    await shell.getByRole('button', { name: 'Connect AI', exact: true }).click();
    await expect(shell.locator('#panel-title')).toHaveText('Settings');
    await expect(shell.locator('#ai-settings')).toHaveAttribute('open', '');
    await b.open('ai');
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await expect(shell.locator('.ai-context-chip')).toHaveAttribute('title', `${b.base}/page-one`);
    await expect(shell.locator('#ai-submit')).toBeDisabled();
    await shell.getByRole('button', { name: 'Connect AI', exact: true }).click();
    await shell.locator('#ai-provider').selectOption('compatible');
    await expect(shell.locator('#api-provider-form')).toHaveAttribute('data-provider', 'compatible');
    await shell.locator('#ai-base-url').fill(`${b.base}/v1`);
    await shell.locator('#ai-api-model').fill('fixture');
    const redrawConnectionForm = async (name) => {
      await b.invoke('space:update', { id: (await b.invoke('state:get')).activeSpaceId, name });
      await expect(shell.locator('.space-title')).toHaveText(name);
    };
    await expect(shell.locator('#ai-api-key')).toHaveJSProperty('required', false);
    await redrawConnectionForm('Retained local endpoint');
    await expect(shell.locator('#ai-base-url')).toHaveValue(`${b.base}/v1`);
    await expect(shell.locator('#ai-api-model')).toHaveValue('fixture');
    await expect(shell.locator('#ai-api-key')).toHaveJSProperty('required', false);
    await expect(shell.locator('#ai-api-key')).toHaveAttribute('placeholder', 'Optional for localhost');
    await shell.locator('#ai-base-url').fill('https://api.example.com/v1');
    await redrawConnectionForm('Retained remote endpoint');
    await expect(shell.locator('#ai-base-url')).toHaveValue('https://api.example.com/v1');
    await expect(shell.locator('#ai-api-key')).toHaveJSProperty('required', true);
    await expect(shell.locator('#ai-api-key')).toHaveAttribute(
      'placeholder',
      'New key required for this endpoint',
    );
    await shell.locator('#ai-base-url').fill(`${b.base}/v1`);
    await redrawConnectionForm('Ready local endpoint');
    await expect(shell.locator('#ai-api-key')).toHaveJSProperty('required', false);
    await shell.locator('#api-provider-form button[type="submit"]').click();
    await expect(shell.locator('#ai-connection-status')).toContainText('Local API ready');
    await b.open('ai');
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await expect(shell.locator('.ai-context-chip')).toHaveAttribute('title', `${b.base}/page-one`);
    await expect(shell.locator('#ai-submit')).toBeEnabled();
    assert.equal(b.requests.length, 0, 'Preparation and connection must not send an AI request');
    assert.deepEqual(
      await b.app.evaluate(() => global.aiWorkflowContextReads),
      { mime: 0, text: 0 },
      'Preparation and connection must not extract page text',
    );
    await shell.locator('#ai-submit').click();
    await expect(shell.locator('.message.assistant .message-content')).toContainText('twenty dollars');
    assert.equal(b.requests.length, 1);
    assert.deepEqual(await b.app.evaluate(() => global.aiWorkflowContextReads), { mime: 1, text: 1 });
  },
);

test(
  'AI starters prepare explicit context, preserve drafts and never silently share a newly active page',
  { timeout: 60000 },
  async (t) => {
    const b = await fixture(t),
      { shell } = b;
    await shell.locator('[data-action="ui:ai-intent"][data-intent="summarize"]').click();
    await expect(shell.locator('#ai-question')).toHaveValue(/Summarize this page/);
    await expect(shell.locator('.ai-context-chip')).toContainText('page-one');
    assert.equal(b.requests.length, 0, 'Choosing a starter must not send a request');
    const draft = 'My question\nwith a second line';
    await shell.locator('#ai-question').fill('My question');
    await shell.locator('#ai-question').press('End');
    await shell.locator('#ai-question').press('Shift+Enter');
    await shell.locator('#ai-question').pressSequentially('with a second line');
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await shell.locator('#ai-question').dispatchEvent('keydown', { key: 'Enter', isComposing: true });
    assert.equal(b.requests.length, 0);
    await b.open('settings');
    await b.open('ai');
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await shell.locator('[data-action="ui:ai-intent"][data-intent="explain"]').click();
    await expect(shell.locator('#ai-question')).toHaveValue(draft);
    await shell.locator('#ai-question').press('Enter');
    await expect(shell.locator('.message.assistant .message-content')).toContainText('twenty dollars');
    await expect(shell.locator('.message.assistant strong')).toHaveText('Summary');
    await expect(shell.locator('.message-citation')).toHaveCount(1);
    assert.equal(b.requests.length, 1);
    assert(JSON.stringify(b.requests[0]).includes('/page-one'));
    assert(!JSON.stringify(b.requests[0]).includes('fixture-password-must-not-be-shared'));
    await shell.getByRole('button', { name: 'Copy answer', exact: true }).click();
    const copied = await b.app.evaluate(({ clipboard }) => clipboard.readText());
    assert(copied.includes('twenty dollars') && copied.includes(`${b.base}/page-one`));

    await b.invoke('tab:activate', { id: b.second });
    await expect
      .poll(async () => {
        const state = await b.invoke('state:get');
        return state.tabs.find((tab) => tab.id === state.activeTabId)?.title;
      })
      .toBe('page-two');
    await expect(shell.locator('.ai-context-chip')).toContainText('page-one');
    await shell.locator('#ai-question').fill('Follow up on the selected document');
    await b.app.evaluate(({ BrowserWindow }) => {
      const contents = BrowserWindow.getAllWindows()[0].webContents;
      contents.focus();
      const modifiers = [process.platform === 'darwin' ? 'meta' : 'control'];
      contents.sendInputEvent({ type: 'keyDown', keyCode: 'Enter', modifiers });
      contents.sendInputEvent({ type: 'keyUp', keyCode: 'Enter', modifiers });
    });
    await expect.poll(() => b.requests.length).toBe(2);
    await expect(shell.locator('.message.assistant')).toHaveCount(2);
    assert(JSON.stringify(b.requests[1].messages.at(-1)).includes('/page-one'));
    assert(!JSON.stringify(b.requests[1].messages).includes('/page-two'));

    await shell.locator('#ai-context').selectOption('page');
    await expect(shell.locator('.message')).toHaveCount(0);
    await expect(shell.locator('.ai-context-chip')).toContainText('page-two');
    await shell.locator('#ai-question').fill('Read the reviewed document');
    await b.invoke('navigate', { url: `${b.base}/page-three` });
    await expect(shell.locator('.ai-context-chip')).toHaveClass(/stale/);
    await expect(shell.locator('#ai-submit')).toBeDisabled();
    await expect(shell.locator('#ai-question')).toHaveValue('Read the reviewed document');
    await shell.getByRole('button', { name: 'Review pages again', exact: true }).click();
    await expect(shell.locator('#ai-submit')).toBeEnabled();
    await shell.locator('#ai-question').press('Enter');
    await expect.poll(() => b.requests.length).toBe(3);
    await expect(shell.locator('.message.assistant')).toHaveCount(1);
    assert.equal(b.requests[2].messages.filter((message) => message.role !== 'system').length, 1);
    assert(JSON.stringify(b.requests[2]).includes('/page-three'));
    assert(!JSON.stringify(b.requests[2]).includes('/page-one'));

    await shell.getByRole('button', { name: 'Clear shared context and conversation', exact: true }).click();
    await expect(shell.locator('.ai-context-chip')).toHaveCount(0);
    await expect(shell.locator('.message')).toHaveCount(0);
    await shell.locator('[data-action="ui:ai-intent"][data-intent="compare"]').click();
    const selector = shell.getByRole('dialog', { name: 'Ask selected tabs', exact: true });
    await selector.locator(`input[value="${b.first}"]`).check();
    await selector.locator(`input[value="${b.second}"]`).check();
    await selector.getByRole('button', { name: 'Use selected tabs', exact: true }).click();
    await expect(shell.locator('.ai-context-chip')).toHaveCount(2);
    await expect(shell.locator('#ai-question')).toHaveValue(/Compare these pages/);
    assert.equal(b.requests.length, 3, 'Choosing comparison pages is not permission to send yet');
    await shell.locator('#ai-question').press('Enter');
    await expect.poll(() => b.requests.length).toBe(4);
    await expect(shell.locator('.message.assistant')).toHaveCount(1);
    assert(
      JSON.stringify(b.requests[3]).includes('/page-one') &&
        JSON.stringify(b.requests[3]).includes('/page-three'),
    );
  },
);

test(
  'AI retry, edit and stop keep unfinished drafts and reject late answers after reset',
  { timeout: 45000 },
  async (t) => {
    const b = await fixture(t),
      { shell } = b;
    await shell.locator('#ai-question').fill('fail once then answer');
    await shell.locator('#ai-question').press('Enter');
    await expect(shell.getByRole('button', { name: 'Retry question', exact: true })).toBeVisible();
    await shell.locator('#ai-question').fill('Keep my unfinished follow-up');
    await shell.getByRole('button', { name: 'Retry question', exact: true }).click();
    await expect.poll(() => b.requests.length).toBe(2);
    await expect(shell.locator('.message.assistant').last()).toContainText('twenty dollars');
    await expect(shell.locator('#ai-question')).toHaveValue('Keep my unfinished follow-up');
    await shell.getByRole('button', { name: 'Edit question', exact: true }).last().click();
    await expect(shell.locator('#ai-question')).toHaveValue('Keep my unfinished follow-up');
    await shell.locator('#ai-question').fill('');
    await shell.getByRole('button', { name: 'Edit question', exact: true }).last().click();
    await expect(shell.locator('#ai-question')).toHaveValue('fail once then answer');
    await expect(shell.locator('.message')).toHaveCount(0);

    await shell.locator('#ai-question').fill('hold answer until stopped');
    await shell.locator('#ai-question').press('Enter');
    await expect.poll(() => b.requests.length).toBe(3);
    const requestId = await shell.evaluate(
      () => window.aiWorkflowEvents.findLast((event) => event.type === 'ai:progress').requestId,
    );
    await shell.locator('#ai-question').fill('Keep typing while waiting');
    await shell.getByRole('button', { name: 'Stop response', exact: true }).click();
    await expect(shell.getByRole('button', { name: 'Retry question', exact: true })).toBeVisible();
    await expect(shell.locator('#ai-question')).toHaveValue('Keep typing while waiting');
    await shell.getByRole('button', { name: 'New conversation', exact: true }).click();
    await expect(shell.locator('.message')).toHaveCount(0);
    await b.app.evaluate(({ BrowserWindow }, requestId) => {
      BrowserWindow.getAllWindows()[0].webContents.send('zacro:event', {
        type: 'ai:answer',
        requestId,
        answer: 'Late cancelled answer must not reappear',
      });
    }, requestId);
    await expect(shell.locator('.message')).toHaveCount(0);
    await expect(shell.locator('#ai-question')).toHaveValue('Keep typing while waiting');
    assert.equal(b.requests.length, 3);

    // A closed panel retains DOM nodes. A palette intent in another profile
    // must not capture the old hidden textarea before re-rendering its panel.
    await shell.getByRole('button', { name: 'Close panel', exact: true }).click();
    await b.invoke('profile:create', { name: 'Separate AI profile' });
    await b.invoke('ai:configure', { provider: 'compatible', baseUrl: `${b.base}/v1`, model: 'fixture' });
    await b.invoke('navigate', { url: `${b.base}/page-other-profile` });
    await expect
      .poll(async () => {
        const state = await b.invoke('state:get');
        return state.tabs.find((tab) => tab.id === state.activeTabId)?.title;
      })
      .toBe('page-other-profile');
    await b.invoke('shortcut:run', { id: 'command-palette' });
    await shell.locator('#command-input').fill('/summarize');
    await shell.getByRole('option').filter({ hasText: 'Summarize this page' }).click();
    await expect(shell.locator('#ai-question')).toHaveValue(/Summarize this page/);
    await expect(shell.locator('#ai-question')).not.toHaveValue(/Keep typing while waiting/);
    await expect(shell.locator('.ai-context-chip')).toContainText('page-other-profile');
    assert.equal(b.requests.length, 3, 'The palette starter must only prepare a new-profile draft');
  },
);
