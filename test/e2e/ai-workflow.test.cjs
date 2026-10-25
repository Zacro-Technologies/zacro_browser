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

async function fixture(t) {
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
  const env = { ...process.env, ZACRO_USER_DATA: directory };
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
  await invoke('ai:configure', { provider: 'compatible', baseUrl: `${base}/v1`, model: 'fixture' });
  const open = async (section) => {
    await shell.getByRole('button', { name: 'Library', exact: true }).click();
    await shell
      .getByRole('dialog', { name: 'Library', exact: true })
      .locator(`[data-key="panel-${section}"]`)
      .click();
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
