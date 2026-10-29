'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { IdentityController, getRedirectURL } = require('../src/main/extensions/identity.cjs');
const id = 'a'.repeat(32),
  other = 'b'.repeat(32);
function harness() {
  const windows = [],
    session = {};
  let valid = true;
  const metadata = { enabled: true, generation: 'g', grants: { permissions: ['identity'] } };
  class Window extends EventEmitter {
    constructor(options) {
      super();
      this.options = options;
      this.webContents = new EventEmitter();
      this.webContents.setWindowOpenHandler = (handler) => {
        this.popup = handler;
      };
      this.dead = false;
      this.shown = false;
      windows.push(this);
    }
    loadURL(url) {
      this.url = url;
      return Promise.resolve();
    }
    show() {
      this.shown = true;
    }
    isDestroyed() {
      return this.dead;
    }
    destroy() {
      this.dead = true;
      this.emit('closed');
    }
  }
  const controller = new IdentityController({
    native: { BrowserWindow: Window },
    getSession: () => session,
    getProfile: () => ({ id: 'p' }),
    resolveExtension: () => metadata,
  });
  const context = {
    profileId: 'p',
    extensionId: id,
    generation: 'g',
    contextId: 'lease:1',
    kind: 'extension-page',
    assertCurrent: () => {
      if (!valid) throw Error('Expired caller');
    },
  };
  function navigate(win, url, event = 'will-redirect') {
    let prevented = false;
    win.webContents.emit(
      event,
      {
        preventDefault() {
          prevented = true;
        },
      },
      url,
      false,
      true,
    );
    return prevented;
  }
  return {
    controller,
    context,
    metadata,
    windows,
    session,
    navigate,
    expire: () => {
      valid = false;
    },
  };
}
test('redirect URL stays on the exact extension HTTPS origin', () => {
  assert.equal(getRedirectURL(id), 'https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.chromiumapp.org/');
  assert.equal(
    getRedirectURL(id, 'done?state=x#ok'),
    'https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.chromiumapp.org/done?state=x#ok',
  );
  for (const value of ['//evil.test', 'https://evil.test', '../escape', '\\evil', 'x\n'])
    assert.throws(() => getRedirectURL(id, value), /redirect path/);
});
test('auth window is isolated, hidden initially, and returns full intercepted same-ID redirect', async () => {
  const h = harness();
  const flow = h.controller.call(h.context, 'launchWebAuthFlow', [
    { url: 'https://provider.test/login', interactive: true },
  ]);
  const w = h.windows[0];
  assert.equal(w.options.show, false);
  assert.deepEqual(w.options.webPreferences, {
    session: h.session,
    sandbox: true,
    contextIsolation: true,
    nodeIntegration: false,
    nodeIntegrationInSubFrames: false,
    webSecurity: true,
  });
  assert.deepEqual(w.popup({ url: 'https://elsewhere.test' }), { action: 'deny' });
  w.webContents.emit('did-finish-load');
  assert.equal(w.shown, true);
  const callback = `https://${id}.chromiumapp.org/callback?code=secret#state=fragment`;
  assert.equal(h.navigate(w, callback), true);
  assert.equal(await flow, callback);
  assert.equal(w.dead, true);
  assert.equal(h.controller.flows.size, 0);
});
test('foreign callback and insecure or credential navigation fail closed without leaking tokens', async () => {
  for (const url of [
    `https://${other}.chromiumapp.org/cb?token=secret`,
    `https://${id}.chromiumapp.org.evil.test/cb`,
    `https://user:pass@${id}.chromiumapp.org/cb`,
    'http://provider.test/cb',
    'file:///etc/passwd',
  ]) {
    const h = harness();
    const flow = h.controller.call(h.context, 'launchWebAuthFlow', [{ url: 'https://provider.test' }]);
    assert.equal(h.navigate(h.windows[0], url), true);
    await assert.rejects(
      flow,
      (e) => /authentication navigation/.test(e.message) && !e.message.includes('secret'),
    );
    assert.equal(h.windows[0].dead, true);
  }
});
test('invalid flow URLs/options are rejected before creating windows', async () => {
  const h = harness();
  for (const details of [
    { url: 'http://provider.test' },
    { url: 'https://u:p@provider.test' },
    { url: 'javascript:alert(1)' },
    { url: 'https://provider.test', interactive: 'yes' },
    { url: 'https://provider.test', timeoutMsForNonInteractive: 0 },
    { url: 'https://provider.test', timeoutMsForNonInteractive: 600001 },
    { url: 'https://provider.test', unknown: true },
  ])
    await assert.rejects(h.controller.call(h.context, 'launchWebAuthFlow', [details]), /Invalid/);
  assert.equal(h.windows.length, 0);
});
test('concurrent flows isolate results, limit resources and release capacity', async () => {
  const h = harness();
  const one = h.controller.call(h.context, 'launchWebAuthFlow', [{ url: 'https://provider.test' }]);
  const two = h.controller.call(h.context, 'launchWebAuthFlow', [{ url: 'https://provider.test' }]);
  await assert.rejects(
    h.controller.call(h.context, 'launchWebAuthFlow', [{ url: 'https://provider.test' }]),
    /Too many/,
  );
  h.navigate(h.windows[1], `https://${id}.chromiumapp.org/two`);
  assert.match(await two, /\/two$/);
  h.navigate(h.windows[0], `https://${id}.chromiumapp.org/one`);
  assert.match(await one, /\/one$/);
});
test('noninteractive load aborts by default, delayed JS redirects work with explicit bounded timeout', async () => {
  const h = harness();
  const first = h.controller.call(h.context, 'launchWebAuthFlow', [{ url: 'https://provider.test' }]);
  h.windows[0].webContents.emit('did-finish-load');
  await assert.rejects(first, /interaction required/);
  const delayed = h.controller.call(h.context, 'launchWebAuthFlow', [
    { url: 'https://provider.test', abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 1000 },
  ]);
  h.windows[1].webContents.emit('did-finish-load');
  assert.equal(h.windows[1].shown, false);
  h.navigate(h.windows[1], `https://${id}.chromiumapp.org/delayed`, 'will-navigate');
  assert.match(await delayed, /delayed$/);
  await assert.rejects(
    h.controller.call(h.context, 'launchWebAuthFlow', [
      { url: 'https://provider.test', abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 10 },
    ]),
    /timed out/,
  );
});
test('close, context revocation, generation change, profile death and dispose destroy pending auth', async () => {
  for (const cause of ['close', 'context', 'generation', 'profile', 'dispose', 'caller']) {
    const h = harness();
    const flow = h.controller.call(h.context, 'launchWebAuthFlow', [
      { url: 'https://provider.test', interactive: true },
    ]);
    if (cause === 'close') h.windows[0].destroy();
    if (cause === 'context') h.controller.revoke({ profileId: 'p', extensionId: id, contextId: 'lease:1' });
    if (cause === 'generation') {
      h.metadata.generation = 'new';
      h.navigate(h.windows[0], `https://${id}.chromiumapp.org/cb`);
    }
    if (cause === 'profile') h.controller.revoke({ profileId: 'p' });
    if (cause === 'dispose') h.controller.dispose();
    if (cause === 'caller') h.expire();
    await assert.rejects(flow);
    assert.equal(h.windows[0].dead, true);
    assert.equal(h.controller.flows.size, 0);
  }
});
test('identity requires current trusted permission, returns empty account and never fabricates tokens', async () => {
  const h = harness();
  assert.deepEqual(await h.controller.call(h.context, 'getProfileUserInfo', []), { email: '', id: '' });
  await assert.rejects(h.controller.call(h.context, 'getAuthToken', []), /Google.*unsupported/);
  await assert.rejects(
    h.controller.call({ ...h.context, kind: 'content-script' }, 'launchWebAuthFlow', [
      { url: 'https://provider.test' },
    ]),
    /Trusted/,
  );
  h.metadata.grants.permissions = [];
  await assert.rejects(h.controller.call(h.context, 'getProfileUserInfo', []), /identity permission/);
});
test('subframes cannot complete or transmit extension callback results', async (t) => {
  const h = harness();
  t.after(() => h.controller.dispose());
  const flow = h.controller.call(h.context, 'launchWebAuthFlow', [
    { url: 'https://provider.test', interactive: true },
  ]);
  let prevented = false;
  h.windows[0].webContents.emit(
    'will-redirect',
    {
      preventDefault() {
        prevented = true;
      },
    },
    `https://${id}.chromiumapp.org/frame?token=synthetic`,
    false,
    false,
  );
  assert.equal(prevented, true);
  assert.equal(h.windows[0].dead, false);
  h.navigate(h.windows[0], `https://${id}.chromiumapp.org/top`);
  assert.match(await flow, /\/top$/);
});
