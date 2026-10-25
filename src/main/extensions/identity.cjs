'use strict';
// Provider pages receive only a sandboxed web window in the caller's session.
// In particular this module never installs the extension transport or a preload.
const MAX_URL = 16384;
function getRedirectURL(extensionId, path = '') {
  if (!/^[a-p]{32}$/.test(extensionId)) throw new Error('Invalid extension identity');
  if (
    typeof path !== 'string' ||
    path.length > 2048 ||
    /[\\\x00-\x20\x7f]/.test(path) ||
    path.startsWith('//') ||
    /^[a-z][a-z0-9+.-]*:/i.test(path) ||
    path.split(/[/?#]/).some((part) => part === '.' || part === '..')
  )
    throw new Error('Invalid redirect path');
  const base = `https://${extensionId}.chromiumapp.org/`;
  const url = new URL(path.replace(/^\//, ''), base);
  if (url.origin !== new URL(base).origin) throw new Error('Invalid redirect path');
  return url.href;
}
function httpsURL(value) {
  if (typeof value !== 'string' || value.length > MAX_URL || /[\\\x00-\x20\x7f]/.test(value))
    throw new Error('Invalid authentication URL');
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error('Invalid authentication URL');
  }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password)
    throw new Error('Invalid authentication URL');
  return url;
}
function flowOptions(value) {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.keys(value).some(
      (key) =>
        !['url', 'interactive', 'abortOnLoadForNonInteractive', 'timeoutMsForNonInteractive'].includes(key),
    )
  )
    throw new Error('Invalid authentication options');
  for (const key of ['interactive', 'abortOnLoadForNonInteractive'])
    if (value[key] !== undefined && typeof value[key] !== 'boolean')
      throw new Error('Invalid authentication options');
  if (
    value.timeoutMsForNonInteractive !== undefined &&
    (!Number.isInteger(value.timeoutMsForNonInteractive) ||
      value.timeoutMsForNonInteractive < 1 ||
      value.timeoutMsForNonInteractive > 600000)
  )
    throw new Error('Invalid authentication timeout');
  httpsURL(value.url);
  return {
    ...value,
    interactive: value.interactive === true,
    abortOnLoadForNonInteractive: value.abortOnLoadForNonInteractive !== false,
  };
}
class IdentityController {
  constructor({ native, getSession, getProfile, resolveExtension }) {
    Object.assign(this, { native, getSession, getProfile, resolveExtension });
    this.flows = new Set();
    this.closed = false;
  }
  guard(context) {
    context.assertCurrent?.();
    const metadata = this.resolveExtension(context.profileId, context.extensionId);
    if (
      this.closed ||
      !this.getProfile(context.profileId) ||
      !metadata?.enabled ||
      metadata.generation !== context.generation
    )
      throw new Error('Expired authentication context');
    if (context.kind === 'content-script' || context.kind === 'offscreen-document')
      throw new Error('Trusted extension contexts only');
    if (!metadata.grants.permissions.includes('identity')) throw new Error('Missing identity permission');
    getRedirectURL(context.extensionId);
  }
  async call(context, method, args) {
    this.guard(context);
    if (!Array.isArray(args) || args.length > 1) throw new Error('Invalid identity arguments');
    if (method === 'getRedirectURL') return getRedirectURL(context.extensionId, args[0]);
    if (method === 'getProfileUserInfo') {
      const details = args[0];
      if (
        details !== undefined &&
        (!details ||
          typeof details !== 'object' ||
          Array.isArray(details) ||
          Object.keys(details).some((key) => key !== 'accountStatus') ||
          (details.accountStatus !== undefined && !['SYNC', 'ANY'].includes(details.accountStatus)))
      )
        throw new Error('Invalid profile details');
      return { email: '', id: '' };
    }
    if (['getAuthToken', 'removeCachedAuthToken', 'clearAllCachedAuthTokens', 'getAccounts'].includes(method))
      throw new Error('Google identity account and token services are unsupported in this Electron runtime');
    if (method !== 'launchWebAuthFlow') throw new Error('Unsupported identity method');
    return this.launch(context, flowOptions(args[0]));
  }
  launch(context, options) {
    if (
      this.flows.size >= 8 ||
      [...this.flows].filter(
        (f) => f.context.profileId === context.profileId && f.context.extensionId === context.extensionId,
      ).length >= 2
    )
      throw new Error('Too many authentication flows');
    const session = this.getSession(context.profileId);
    this.guard(context);
    const window = new this.native.BrowserWindow({
      width: 640,
      height: 720,
      show: false,
      title: 'Extension sign in',
      autoHideMenuBar: true,
      webPreferences: {
        session,
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        webSecurity: true,
      },
    });
    return new Promise((resolve, reject) => {
      const contents = window.webContents;
      let done = false,
        timeout,
        liveness;
      const listeners = [];
      const on = (emitter, name, handler) => {
        emitter.on(name, handler);
        listeners.push([emitter, name, handler]);
      };
      const finish = (error, result) => {
        if (done) return;
        done = true;
        clearTimeout(timeout);
        clearInterval(liveness);
        this.flows.delete(flow);
        for (const [emitter, name, handler] of listeners) emitter.removeListener(name, handler);
        if (!window.isDestroyed()) window.destroy();
        if (error) reject(error);
        else resolve(result);
      };
      const flow = { context, cancel: () => finish(new Error('Authentication flow cancelled')) };
      this.flows.add(flow);
      const check = () => {
        try {
          this.guard(context);
          return true;
        } catch {
          finish(new Error('Authentication context revoked'));
          return false;
        }
      };
      const navigate = (event, value, _inPlace, mainFrame = true) => {
        if (done) {
          event.preventDefault();
          return;
        }
        if (!check()) {
          event.preventDefault();
          return;
        }
        let url;
        try {
          url = httpsURL(value);
        } catch {
          event.preventDefault();
          finish(new Error('Invalid authentication navigation'));
          return;
        }
        const expected = `${context.extensionId}.chromiumapp.org`;
        if (url.hostname === expected && !url.port) {
          event.preventDefault();
          // An iframe must never deliver a result or send callback tokens out.
          if (mainFrame) finish(null, value);
          return;
        }
        if (url.hostname === 'chromiumapp.org' || url.hostname.includes('.chromiumapp.org')) {
          event.preventDefault();
          finish(new Error('Invalid authentication navigation'));
        }
      };
      contents.setWindowOpenHandler(() => ({ action: 'deny' }));
      on(contents, 'will-redirect', navigate);
      on(contents, 'will-navigate', navigate);
      on(contents, 'will-frame-navigate', (event) => navigate(event, event.url, false, event.isMainFrame));
      on(contents, 'did-finish-load', () => {
        if (done || !check()) return;
        if (options.interactive) window.show();
        else if (options.abortOnLoadForNonInteractive)
          finish(new Error('Authentication interaction required'));
      });
      on(contents, 'did-fail-load', (_event, code, _description, _url, mainFrame) => {
        if (mainFrame !== false && code !== -3) finish(new Error('Authentication page failed to load'));
      });
      on(contents, 'render-process-gone', () => finish(new Error('Authentication page closed')));
      on(contents, 'destroyed', () => finish(new Error('Authentication page closed')));
      on(window, 'closed', () => finish(new Error('Authentication window closed')));
      timeout = setTimeout(
        () => finish(new Error('Authentication flow timed out')),
        options.interactive ? 300000 : (options.timeoutMsForNonInteractive ?? 60000),
      );
      liveness = setInterval(check, 100);
      // Also check the initial URL: never contact a callback endpoint on the network.
      let prevented = false;
      navigate(
        {
          preventDefault() {
            prevented = true;
          },
        },
        options.url,
      );
      if (!prevented) {
        try {
          Promise.resolve(window.loadURL(options.url)).catch(() => {
            if (!done) finish(new Error('Authentication page failed to load'));
          });
        } catch {
          finish(new Error('Authentication page failed to load'));
        }
      }
    });
  }
  revoke(target) {
    for (const flow of [...this.flows])
      if (
        ['profileId', 'extensionId', 'contextId'].every(
          (key) => target[key] === undefined || target[key] === flow.context[key],
        )
      )
        flow.cancel();
  }
  dispose() {
    this.closed = true;
    this.revoke({});
  }
}
module.exports = { IdentityController, getRedirectURL };
