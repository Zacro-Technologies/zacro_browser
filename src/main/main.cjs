'use strict';

const {
  app,
  BrowserWindow,
  View,
  WebContentsView,
  ipcMain,
  session,
  dialog,
  Menu,
  shell,
  clipboard,
  nativeTheme,
  screen,
  webContents,
} = require('electron');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { BrowserStore, normalizeAddress } = require('../core/store.cjs');
const { webURL, safeFilename, unusedPath, renameWithoutOverwrite } = require('./security.cjs');
const { browserLayout, presentView, resolveSplit, restoreWindowPlacement } = require('./layout.cjs');
const { FaviconLoader } = require('./favicon.cjs');
const { windowChrome, macShortcut, macMenuTemplate } = require('./mac.cjs');
const { SyncController } = require('./sync/controller.cjs');
const { ExtensionHost } = require('./extensions/host.cjs');
const { createBrowserAdapter } = require('./extensions/browser.cjs');
const faviconLoader = new FaviconLoader();

app.setName('Zacro');
app.enableSandbox();
// Separate, explicitly chosen test profiles make automation reproducible without
// granting any extra capabilities to web content or the renderer.
if (process.env.ZACRO_USER_DATA) app.setPath('userData', path.resolve(process.env.ZACRO_USER_DATA));
const singleInstance = app.requestSingleInstanceLock();
if (!singleInstance) app.quit();

const UI_FILE = path.join(__dirname, '../renderer/index.html');
const UI_URL = pathToFileURL(UI_FILE).href;
const NEW_TAB = 'zacro://newtab';
const views = new Map();
const sessions = new Map();
const liveDownloads = new Map();
const downloadReservations = new Set();
const promptRequests = new Set();
let store, win, ai, syncAccount, extensionHost, extensionBrowser, archiveTimer, publishTimer;
let extensionsReady = false;
let extensionTabSnapshot = new Map();
let splitTabId = null;
let splitPair = null;
let normalWindowBounds = null;
let peek = null;
let layout = {
  sidebarWidth: 224,
  panelWidth: 0,
  contentTop: process.platform === 'darwin' ? 8 : 36,
  overlay: false,
};
let quitting = false;
let lastProfileId = null;
let closingWindow = false;
let allowWindowClose = false;
let popupTimes = [];
let pendingAuth = null;
let backdropGeneration = 0;
let backdropContext = null;
let windowReady = null;
let startupReady = false;
let quitRequested = false;
let drainingExternalURLs = false;
const externalURLs = [];
let defaultBrowser = { supported: process.platform === 'darwin' && app.isPackaged, configured: false };

const activeSpace = () => store.state.spaces.find((item) => item.id === store.state.activeSpaceId);
const activeTab = () => store.state.tabs.find((item) => item.id === store.state.activeTabId);
const activeProfile = () => store.state.profiles.find((item) => item.id === activeSpace()?.profileId);
const activeEntry = () => {
  if (peek?.entry) return peek.entry;
  const entry = views.get(store.state.activeTabId);
  return entry && (!entry.dormant || entry.blankPopup) && (activeTab()?.url !== NEW_TAB || entry.blankPopup)
    ? entry
    : undefined;
};
const activeContents = () => activeEntry()?.contents;
const validWindow = () => win && !win.isDestroyed();
function focusContentOrChrome(contents = activeContents()) {
  if (!validWindow() || closingWindow || quitting) return;
  if (!layout.overlay && contents && !contents.isDestroyed()) contents.focus();
  else if (!win.webContents.isDestroyed()) win.webContents.focus();
}

function emit(event) {
  if (validWindow() && !win.webContents.isDestroyed()) win.webContents.send('zacro:event', event);
}
function toast(message) {
  emit({ type: 'toast', message: String(message).slice(0, 500) });
}
function report(error) {
  console.error('[Zacro]', error?.stack || error);
  toast(error?.message || 'The action could not be completed.');
}
function clearBackdrop() {
  backdropGeneration++;
  backdropContext = null;
  emit({ type: 'page:backdrop', frames: [] });
}
async function captureBackdrop() {
  const generation = ++backdropGeneration;
  if (activeProfile()?.private) {
    clearBackdrop();
    return;
  }
  const entries = [...views.values(), ...(peek ? [peek.entry] : [])]
    .filter(
      (entry) => entry.presentation.visible && entry.presentation.bounds && !entry.contents.isDestroyed(),
    )
    .slice(0, 2);
  const context = {
    profileId: activeSpace()?.profileId,
    tabId: store.state.activeTabId,
    contentIds: new Set(entries.map((entry) => entry.contents.id)),
  };
  backdropContext = context;
  for (const entry of entries) entry.backdropCaptureGeneration = generation;
  const frames = await Promise.all(
    entries.map(async (entry) => {
      const bounds = { ...entry.presentation.bounds };
      let timer;
      try {
        const capture = await Promise.race([
          entry.contents.capturePage(undefined, { stayHidden: true }),
          new Promise((resolve) => {
            timer = setTimeout(() => resolve(null), 200);
          }),
        ]);
        if (!capture || capture.isEmpty()) return null;
        const size = capture.getSize();
        const image = size.width > 1024 ? capture.resize({ width: 1024, quality: 'good' }) : capture;
        const bytes = image.toJPEG(65);
        if (!bytes.length || bytes.length > 1024 * 1024) return null;
        return { bounds, dataUrl: `data:image/jpeg;base64,${bytes.toString('base64')}` };
      } catch {
        return null;
      } finally {
        clearTimeout(timer);
        if (entry.backdropCaptureGeneration === generation) entry.backdropCaptureGeneration = null;
        arrangeViews();
      }
    }),
  );
  if (
    generation !== backdropGeneration ||
    !layout.overlay ||
    context.profileId !== activeSpace()?.profileId ||
    context.tabId !== store.state.activeTabId
  )
    return;
  emit({ type: 'page:backdrop', frames: frames.filter(Boolean) });
}
function finishAuth(credentials = null, reason = 'cancelled') {
  const request = pendingAuth;
  if (!request) return;
  pendingAuth = null;
  clearTimeout(request.timer);
  try {
    if (credentials) request.callback(credentials.username, credentials.password);
    else request.callback();
  } catch {
    /* the challenged request may already have been cancelled */
  }
  emit({ type: 'auth:closed', id: request.id, reason });
}
function requestAuthentication(event, contents, details, authInfo, callback) {
  event.preventDefault();
  const source = tabForContents(contents);
  const url = webURL(details.url);
  if (!url || !source || source.profileId !== activeSpace()?.profileId || pendingAuth || !validWindow()) {
    callback();
    return;
  }
  const id = randomUUID();
  pendingAuth = { id, callback, contentsId: contents.id, profileId: source.profileId, url, timer: null };
  pendingAuth.timer = setTimeout(() => finishAuth(null, 'expired'), 120000);
  const origin = authInfo.isProxy ? `${authInfo.host}:${authInfo.port}` : new URL(url).origin;
  emit({
    type: 'auth:request',
    id,
    profileId: source.profileId,
    origin,
    realm: String(authInfo.realm || '').slice(0, 200),
    isProxy: Boolean(authInfo.isProxy),
    scheme: authInfo.scheme,
    title: source.title || '',
  });
  win.webContents.focus();
}
function pageState(entry) {
  if (!entry || entry.dormant || entry.contents.isDestroyed())
    return { loading: false, canGoBack: false, canGoForward: false, zoom: 1 };
  const wc = entry.contents;
  return {
    loading: wc.isLoading(),
    canGoBack: wc.navigationHistory.canGoBack(),
    canGoForward: wc.navigationHistory.canGoForward(),
    zoom: wc.getZoomFactor(),
    error: entry.error || null,
    audible: wc.isCurrentlyAudible(),
    muted: wc.isAudioMuted(),
    favicon: entry.favicon || null,
    url: wc.getURL(),
  };
}
function snapshot() {
  const result = store.snapshot();
  const status = ai?.status() || {};
  const preview = peek && !peek.entry.contents.isDestroyed() ? peek : null;
  result.runtime = {
    page: pageState(activeEntry()),
    extensionPanel: extensionHost?.sidePanel?.snapshot() || null,
    pages: Object.fromEntries([...views].map(([id, entry]) => [id, pageState(entry)])),
    splitTabId,
    peek: preview
      ? {
          url: preview.entry.contents.getURL() || preview.url,
          title: preview.entry.contents.getTitle() || 'Peek',
          loading: preview.entry.contents.isLoading(),
          error: preview.entry.error,
        }
      : null,
    platform: process.platform,
    version: app.getVersion(),
    chromium: process.versions.chrome,
    aiConfigured: Boolean(status.configured),
    aiBusy: Boolean(status.busy),
    aiProvider: status.provider,
    aiModel: status.model,
    maximized: validWindow() && win.isMaximized(),
    fullScreen: Boolean(validWindow() && win.isFullScreen()),
    focused: Boolean(validWindow() && win.isFocused()),
    defaultBrowser,
    dark: nativeTheme.shouldUseDarkColors,
  };
  // Managed extension paths are operational details, not a renderer capability.
  result.extensions = extensionHost?.snapshot(activeProfile()?.id) || [];
  result.extensionPageWarnings = extensionHost?.pendingPageReloads(activeProfile()?.id) || [];
  result.sync = syncAccount?.status() || { state: 'setup-required', account: null, profiles: [] };
  return result;
}
function publish() {
  extensionHost?.refreshRemote();
  if (publishTimer || quitting || !validWindow() || win.webContents.isDestroyed()) return;
  publishTimer = setTimeout(() => {
    publishTimer = null;
    if (!quitting && validWindow() && !win.webContents.isDestroyed()) {
      updateMacMenu();
      win.webContents.send('zacro:state', snapshot());
    }
  }, 25);
}

function permissionOrigin(value) {
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) ? url.origin : null;
  } catch {
    return null;
  }
}
function savedPermission(profileId, origin, permission) {
  return store.state.permissions.find(
    (item) => item.profileId === profileId && item.origin === origin && item.permission === permission,
  );
}
function profileSession(profileId) {
  if (sessions.has(profileId)) return sessions.get(profileId);
  const profile = store.state.profiles.find((item) => item.id === profileId);
  if (!profile) throw new Error('This browser profile no longer exists.');
  const ses = session.fromPartition(`${profile.private ? '' : 'persist:'}zacro-${profileId}`);
  // Keep Chromium's browser identification; custom app/Electron tokens cause
  // sites to serve incompatible embedded-browser pages.
  ses.setUserAgent(
    ses
      .getUserAgent()
      .replace(/\sElectron\/\S+/g, '')
      .replace(/\sZacro\/\S+/gi, '')
      .replace(/\szacro-browser\/\S+/gi, ''),
  );
  ses.setPermissionCheckHandler((_contents, permission, requestingOrigin) => {
    const origin = permissionOrigin(requestingOrigin);
    return Boolean(origin && savedPermission(profileId, origin, permission)?.allowed);
  });
  ses.setPermissionRequestHandler(async (contents, permission, callback, details) => {
    const origin = permissionOrigin(details.requestingUrl || details.securityOrigin || contents?.getURL());
    const supported = [
      'media',
      'geolocation',
      'notifications',
      'clipboard-read',
      'midiSysex',
      'pointerLock',
      'fullscreen',
      'idle-detection',
    ];
    if (!origin || !supported.includes(permission) || !contents || contents.isDestroyed() || !validWindow()) {
      callback(false);
      return;
    }
    const requestingTab = tabForContents(contents);
    if (
      !requestingTab ||
      profileId !== activeSpace()?.profileId ||
      ![store.state.activeTabId, splitTabId, 'peek'].includes(requestingTab.id)
    ) {
      callback(false);
      return;
    }
    const recorded = savedPermission(profileId, origin, permission);
    if (recorded) {
      callback(Boolean(recorded.allowed));
      return;
    }
    const key = `${profileId}:${origin}:${permission}`;
    const topURL = contents.getURL();
    if (promptRequests.has(key)) {
      callback(false);
      return;
    }
    promptRequests.add(key);
    const labels = {
      media: 'use your camera and microphone',
      geolocation: 'access your location',
      notifications: 'send desktop notifications',
      'clipboard-read': 'read your clipboard',
      midiSysex: 'access MIDI devices',
      pointerLock: 'capture your pointer',
      fullscreen: 'enter full screen',
      'idle-detection': 'detect when you are away',
    };
    try {
      const answer = await dialog.showMessageBox(win, {
        type: 'question',
        title: 'Site permission',
        message: `${origin} wants to ${labels[permission]}.`,
        detail: `Profile: ${profile.name}. You can revoke site permissions in Settings.`,
        buttons: ['Block', 'Allow'],
        defaultId: 0,
        cancelId: 0,
        checkboxLabel: 'Remember for this site',
        checkboxChecked: false,
      });
      const allowed = answer.response === 1;
      const currentTab = !contents.isDestroyed() && tabForContents(contents);
      const stillCurrent =
        !contents.isDestroyed() &&
        contents.getURL() === topURL &&
        store.state.profiles.some((item) => item.id === profileId) &&
        profileId === activeSpace()?.profileId &&
        Boolean(currentTab) &&
        [store.state.activeTabId, splitTabId, 'peek'].includes(currentTab.id) &&
        (permissionOrigin(topURL) === origin ||
          contents.mainFrame.framesInSubtree.some((frame) => permissionOrigin(frame.url) === origin));
      if (answer.checkboxChecked && stillCurrent)
        store.dispatch('permission:set', { profileId, origin, permission, allowed });
      callback(stillCurrent && allowed);
    } catch {
      callback(false);
    } finally {
      promptRequests.delete(key);
    }
  });
  // Device pairing requires a product-level chooser; never silently grant it.
  ses.setDevicePermissionHandler(() => false);
  ses.on('will-download', (event, item, contents) => onDownload(event, item, contents, profileId));
  sessions.set(profileId, ses);
  return ses;
}

function tabForContents(contents) {
  for (const [id, entry] of views)
    if (entry.contents === contents) return store.state.tabs.find((tab) => tab.id === id);
  if (peek?.entry.contents === contents)
    return { ...peek, id: 'peek', title: contents.getTitle(), url: contents.getURL() };
  return null;
}
function extensionPageURL(profileId, value) {
  try {
    const url = new URL(value);
    return url.protocol === 'chrome-extension:' &&
      !url.pathname.startsWith('/zacro-compat-') &&
      extensionHost?.manager.resolveExtension(profileId, url.hostname)?.enabled
      ? url.href
      : null;
  } catch {
    return null;
  }
}
function safeNavigate(entry, address) {
  if (!entry || entry.contents.isDestroyed()) return;
  const url = webURL(address) || extensionPageURL(entry.profileId, address);
  if (!url) throw new Error('Only web pages and enabled extension pages can be opened.');
  entry.dormant = false;
  entry.error = null;
  entry.requestedURL = url;
  entry.contents.loadURL(url).catch((error) => {
    if (error.code !== 'ERR_ABORTED' && !entry.contents.isDestroyed()) {
      entry.error = {
        code: error.code,
        description: error.code?.includes('CERT')
          ? 'This connection is not secure. The certificate could not be verified.'
          : 'This page could not be reached.',
        url,
      };
      arrangeViews();
      publish();
    }
  });
}
function guestPreferences(profileId) {
  return {
    session: profileSession(profileId),
    preload: path.join(__dirname, 'guest-preload.cjs'),
    nodeIntegration: false,
    nodeIntegrationInWorker: false,
    nodeIntegrationInSubFrames: false,
    contextIsolation: true,
    sandbox: true,
    webSecurity: true,
    allowRunningInsecureContent: false,
    navigateOnDragDrop: false,
    spellcheck: true,
    scrollBounce: process.platform === 'darwin',
  };
}
function createEntry(profileId, tabId = null, suppliedOptions = {}) {
  // Electron supplies the actual popup WebContents here. Adopting it preserves
  // Chromium's opener/POST state; creating a different one breaks that contract.
  const view = new WebContentsView({
    ...(suppliedOptions.webContents ? { webContents: suppliedOptions.webContents } : {}),
    webPreferences: { ...(suppliedOptions.webPreferences || {}), ...guestPreferences(profileId) },
  });
  const entry = {
    view,
    contents: view.webContents,
    contentsId: view.webContents.id,
    profileId,
    tabId,
    error: null,
    requestedURL: null,
    dormant: !suppliedOptions.webContents,
    documentEpoch: 0,
    disposing: false,
    presentation: { visible: false, bounds: null, attached: false },
  };
  const wc = view.webContents;
  view.setBorderRadius(10);
  view.setBackgroundColor(nativeTheme.shouldUseDarkColors ? '#1b1a1d' : '#ffffff');
  view.setVisible(false);
  wc.setWindowOpenHandler((details) => {
    const url = webURL(details.url);
    const blank = details.url === 'about:blank' || !details.url;
    if (!url && !blank) return { action: 'deny' };
    const now = Date.now();
    popupTimes = popupTimes.filter((time) => now - time < 1000);
    if (popupTimes.length >= 4) {
      toast('Additional pop-ups were blocked.');
      return { action: 'deny' };
    }
    popupTimes.push(now);
    const source = tabForContents(wc);
    if (!source?.spaceId) return { action: 'deny' };
    // Returning the created webContents lets Chromium preserve form POST data,
    // opener relationships, referrers, and named-window navigation.
    return {
      action: 'allow',
      outlivesOpener: true,
      overrideBrowserWindowOptions: { webPreferences: guestPreferences(source.profileId) },
      createWindow: (options) => {
        const tab = store.dispatch('tab:create', {
          url: url || NEW_TAB,
          spaceId: source.spaceId,
          active: false,
        });
        const child = createEntry(source.profileId, tab.id, options);
        child.requestedURL = url || 'about:blank';
        child.blankPopup = blank;
        views.set(tab.id, child);
        if (details.disposition !== 'background-tab') {
          // Complete Chromium's popup creation before a preview can be closed.
          setImmediate(() => invoke('tab:activate', { id: tab.id }).catch(report));
        }
        arrangeViews();
        publish();
        return child.contents;
      },
    };
  });
  wc.on('will-navigate', (event, url) => {
    if (!webURL(url) && !extensionPageURL(entry.profileId, url)) event.preventDefault();
  });
  wc.on('will-redirect', (event, url) => {
    if (!webURL(url) && !extensionPageURL(entry.profileId, url)) event.preventDefault();
  });
  wc.on('will-attach-webview', (event) => event.preventDefault());
  wc.on('did-start-loading', () => {
    entry.error = null;
    publish();
  });
  wc.on('did-start-navigation', (_event, url, _isInPlace, isMainFrame) => {
    if (isMainFrame && entry.tabId) publishExtensionTab(entry, { status: 'loading', url });
    if (isMainFrame && !_isInPlace) {
      entry.faviconRequest?.abort();
      entry.favicon = null;
      publish();
    }
    if (isMainFrame && backdropContext?.contentIds.has(wc.id)) clearBackdrop();
    if (isMainFrame && pendingAuth?.contentsId === wc.id && url !== pendingAuth.url) finishAuth();
  });
  wc.on('did-stop-loading', () => {
    if (entry.tabId) publishExtensionTab(entry, { status: 'complete' });
    arrangeViews();
    publish();
  });
  wc.on('did-navigate', (_event, url) => {
    entry.documentEpoch++;
    navigated(entry, url, true);
  });
  wc.on('did-navigate-in-page', (_event, url, isMainFrame) => {
    if (isMainFrame) navigated(entry, url, false);
  });
  wc.on('page-title-updated', (_event, title) => {
    if (
      entry.tabId &&
      (webURL(wc.getURL()) || extensionPageURL(profileId, wc.getURL()) || entry.blankPopup) &&
      store.state.tabs.some((tab) => tab.id === entry.tabId)
    )
      store.dispatch('tab:update', { id: entry.tabId, title: title.slice(0, 300) });
    const visit = store.state.history.find(
      (item) => item.profileId === entry.profileId && item.url === wc.getURL(),
    );
    if (visit) visit.title = title.slice(0, 500);
    publish();
  });
  wc.on('page-favicon-updated', (_event, urls) => {
    entry.faviconRequest?.abort();
    const request = new AbortController();
    entry.faviconRequest = request;
    const pageURL = wc.getURL();
    faviconLoader
      .load(wc.session, pageURL, urls, { signal: request.signal })
      .then((favicon) => {
        if (
          request.signal.aborted ||
          wc.isDestroyed() ||
          wc.getURL() !== pageURL ||
          entry.faviconRequest !== request
        )
          return;
        entry.favicon = favicon;
        publish();
      })
      .catch(() => {});
  });
  wc.on('did-fail-load', (_event, code, description, url, isMainFrame) => {
    if (!isMainFrame || code === -3) return;
    entry.error = {
      code,
      description:
        code <= -200 && code >= -299
          ? 'This connection is not secure. The certificate could not be verified.'
          : 'This page could not be reached. Check the address and your connection.',
      url,
    };
    arrangeViews();
    publish();
  });
  wc.on('render-process-gone', (_event, details) => {
    entry.error = {
      code: details.reason,
      description: 'This tab stopped responding. Reload it to continue.',
      url: entry.requestedURL,
    };
    arrangeViews();
    publish();
  });
  wc.on('unresponsive', () =>
    toast('A page is taking longer than expected. You can reload or close its tab.'),
  );
  wc.on('media-started-playing', publish);
  wc.on('media-paused', publish);
  wc.on('found-in-page', (_event, result) => emit({ type: 'find:result', ...result }));
  wc.on('before-input-event', (event, input) => {
    extensionHost?.sidePanel?.recordTabInput(entry, input);
    handleShortcut(event, input, wc);
  });
  wc.on('before-mouse-event', (_event, input) => extensionHost?.sidePanel?.recordTabInput(entry, input));
  wc.on('context-menu', (_event, params) => showPageMenu(entry, params));
  wc.on('focus', () => {
    if (!peek && splitPair?.includes(entry.tabId) && store.state.activeTabId !== entry.tabId) {
      store.dispatch('tab:activate', { id: entry.tabId });
    }
  });
  wc.on('will-prevent-unload', (event) => {
    const answer = dialog.showMessageBoxSync(win, {
      type: 'warning',
      title: 'Leave this page?',
      message: 'Changes you made may not be saved.',
      detail: `${wc.getTitle() || wc.getURL()}`,
      buttons: ['Stay on page', 'Leave page'],
      defaultId: 0,
      cancelId: 0,
    });
    if (answer === 1) event.preventDefault();
    else {
      const request = entry.closeRequest;
      entry.closeRequest = null;
      request?.resolve(false);
      // A typed address is optimistic in the shell. Restore it when the
      // document rejects navigation, including reload/back/forward changes.
      const currentURL = wc.getURL();
      entry.requestedURL = currentURL;
      const extensionURL = extensionPageURL(entry.profileId, currentURL);
      if (
        entry.tabId &&
        (webURL(currentURL) || extensionURL) &&
        store.state.tabs.some((tab) => tab.id === entry.tabId)
      ) {
        store.dispatch(extensionURL ? 'tab:extension-page' : 'tab:update', {
          id: entry.tabId,
          url: currentURL,
          title: wc.getTitle(),
        });
      }
      publish();
    }
  });
  wc.on('destroyed', () => {
    entry.faviconRequest?.abort();
    if (backdropContext?.contentIds.has(entry.contentsId)) clearBackdrop();
    const request = entry.closeRequest;
    entry.closeRequest = null;
    request?.resolve(true);
    if (pendingAuth?.contentsId === entry.contentsId) finishAuth();
    if (peek?.entry === entry) {
      peek = null;
      try {
        if (validWindow()) win.contentView.removeChildView(entry.view);
      } catch {}
      arrangeViews();
      publish();
      focusContentOrChrome();
    }
    if (entry.disposing || quitting || !entry.tabId || views.get(entry.tabId) !== entry) return;
    views.delete(entry.tabId);
    try {
      if (validWindow()) win.contentView.removeChildView(entry.view);
    } catch {}
    if (!closingWindow && !entry.replacing && store.state.tabs.some((tab) => tab.id === entry.tabId)) {
      const wasActive = store.state.activeTabId === entry.tabId;
      store.dispatch('tab:close', { id: entry.tabId });
      // The closing native view may still be Cocoa's first responder. Move
      // keyboard input to the surviving page (or shell for New Tab) only when
      // the active tab closed; background closes must not steal input focus.
      if (wasActive) focusContentOrChrome();
    }
  });
  wc.on('enter-html-full-screen', () => {
    // Keep browser chrome visible, and a persistent escape path available.
    toast('Page entered full screen. Press Escape to leave.');
  });
  return entry;
}
function publishExtensionTab(entry, changes) {
  const tab = store.state.tabs.find((item) => item.id === entry.tabId);
  if (tab && extensionBrowser && extensionHost)
    extensionHost.api.publish(entry.profileId, 'tabs.onUpdated', [
      entry.contents.id,
      changes,
      extensionBrowser.tabData(tab),
    ]);
}
function navigated(entry, url, addHistory) {
  if (!webURL(url) && !extensionPageURL(entry.profileId, url)) return;
  entry.requestedURL = url;
  entry.blankPopup = false;
  entry.error = null;
  if (entry.tabId && store.state.tabs.some((tab) => tab.id === entry.tabId)) {
    const title = entry.contents.getTitle() || new URL(url).hostname;
    store.dispatch(url.startsWith('chrome-extension:') ? 'tab:extension-page' : 'tab:update', {
      id: entry.tabId,
      url,
      title,
    });
    if (addHistory && webURL(url)) store.dispatch('history:add', { profileId: entry.profileId, url, title });
  }
  publish();
}
function destroyEntry(entry) {
  if (!entry) return;
  entry.disposing = true;
  if (validWindow()) {
    try {
      win.contentView.removeChildView(entry.view);
    } catch {}
  }
  if (!entry.contents.isDestroyed()) entry.contents.close({ waitForBeforeUnload: false });
}
function requestCloseEntry(entry) {
  if (!entry || entry.contents.isDestroyed()) return Promise.resolve(true);
  if (entry.closeRequest) return entry.closeRequest.promise;
  const request = {};
  request.promise = new Promise((resolve) => {
    request.resolve = resolve;
  });
  entry.closeRequest = request;
  entry.contents.close({ waitForBeforeUnload: true });
  return request.promise;
}
async function requestCloseTab(id) {
  const tab = store.state.tabs.find((item) => item.id === id);
  if (!tab) return null;
  const entry = views.get(id);
  if (!entry) {
    store.dispatch('tab:close', { id });
    return true;
  }
  return requestCloseEntry(entry);
}
async function requestClosePeek() {
  if (!peek) return true;
  const entry = peek.entry;
  const closed = await requestCloseEntry(entry);
  if (closed && peek?.entry === entry) {
    peek = null;
    try {
      if (validWindow()) win.contentView.removeChildView(entry.view);
    } catch {}
    arrangeViews();
    publish();
    focusContentOrChrome();
  }
  return closed;
}
function reserveView(tab) {
  if (!views.has(tab.id)) views.set(tab.id, createEntry(tab.profileId, tab.id));
  return views.get(tab.id);
}
function ensureView(tabId) {
  const tab = store.state.tabs.find((item) => item.id === tabId);
  if (!tab) return null;
  const entry = reserveView(tab);
  if (extensionsReady && entry.dormant && (webURL(tab.url) || extensionPageURL(tab.profileId, tab.url))) {
    // Establish the native parent and visible bounds before the first load.
    // A newly created renderer must inherit the page's actual presentation.
    entry.dormant = false;
    arrangeViews();
    safeNavigate(entry, tab.url);
  }
  return entry;
}
function reconcile() {
  if (!validWindow() || quitting || closingWindow) return;
  const profileId = activeSpace()?.profileId;
  if (
    backdropContext &&
    (backdropContext.profileId !== profileId || backdropContext.tabId !== store.state.activeTabId)
  )
    clearBackdrop();
  if (pendingAuth && pendingAuth.profileId !== profileId) finishAuth(null, 'profile-changed');
  if (lastProfileId && lastProfileId !== profileId) {
    ai?.handle('ai:cancel', {}).catch(() => {});
    syncAccount?.profileChanged();
    extensionHost?.profileChanged();
  }
  lastProfileId = profileId;
  for (const [id, entry] of views) {
    const tab = store.state.tabs.find((item) => item.id === id);
    if (!tab) {
      destroyEntry(entry);
      views.delete(id);
    }
  }
  // Allocate stable native tab identities without starting renderers or
  // network navigation for restored/background pages.
  for (const tab of store.state.tabs) reserveView(tab);
  extensionHost?.sidePanel?.reconcile();
  publishExtensionTabChanges();
  const split = resolveSplit(splitPair, store.state.tabs, store.state.activeTabId, store.state.activeSpaceId);
  splitTabId = split?.otherId || null;
  if (!split) splitPair = null;
  if (
    peek &&
    (peek.spaceId !== store.state.activeSpaceId ||
      !store.state.profiles.some((profile) => profile.id === peek.profileId))
  )
    closePeek(false);
  ensureView(store.state.activeTabId);
  if (splitTabId) ensureView(splitTabId);
  const theme = ['dark', 'light'].includes(store.state.settings.theme)
    ? store.state.settings.theme
    : 'system';
  if (nativeTheme.themeSource !== theme) nativeTheme.themeSource = theme;
  arrangeViews();
  publish();
}
function publishExtensionTabChanges() {
  if (!extensionBrowser || !extensionHost) return;
  const next = new Map();
  for (const tab of store.state.tabs) {
    if (store.state.profiles.find((profile) => profile.id === tab.profileId)?.private) continue;
    const value = extensionBrowser.tabData(tab),
      previous = extensionTabSnapshot.get(tab.id);
    next.set(tab.id, { profileId: tab.profileId, value });
    if (!previous) extensionHost.api.publish(tab.profileId, 'tabs.onCreated', [value]);
    else {
      const changed = {};
      for (const key of ['url', 'title', 'pinned', 'audible', 'status'])
        if (previous.value[key] !== value[key]) changed[key] = value[key];
      if (Object.keys(changed).length)
        extensionHost.api.publish(tab.profileId, 'tabs.onUpdated', [value.id, changed, value]);
      if (value.active && !previous.value.active)
        extensionHost.api.publish(tab.profileId, 'tabs.onActivated', [
          { tabId: value.id, windowId: value.windowId },
        ]);
    }
  }
  for (const [id, previous] of extensionTabSnapshot)
    if (!next.has(id))
      extensionHost.api.publish(previous.profileId, 'tabs.onRemoved', [
        previous.value.id,
        { windowId: previous.value.windowId, isWindowClosing: closingWindow },
      ]);
  extensionTabSnapshot = next;
}
function arrangeViews() {
  if (!validWindow()) return;
  const [width, height] = win.getContentSize();
  const rectangles = browserLayout({ width, height, ...layout, split: Boolean(splitPair) });
  const desired = new Map();
  if (!layout.overlay) {
    if (peek) desired.set(peek.entry, { bounds: rectangles.peek, visible: !peek.entry.error });
    else {
      const first = views.get(splitPair?.[0] || store.state.activeTabId);
      const second = splitPair ? views.get(splitPair[1]) : null;
      if (
        first &&
        !first.dormant &&
        (first.blankPopup || store.state.tabs.find((t) => t.id === first.tabId)?.url !== NEW_TAB)
      )
        desired.set(first, { bounds: rectangles.primary, visible: !first.error });
      if (
        second &&
        !second.dormant &&
        rectangles.secondary &&
        store.state.tabs.find((t) => t.id === second.tabId)?.url !== NEW_TAB
      )
        desired.set(second, { bounds: rectangles.secondary, visible: !second.error });
    }
  }
  for (const entry of [...views.values(), ...(peek ? [peek.entry] : [])]) {
    if (!entry.contents.isDestroyed())
      entry.presentation = presentView(
        entry.view,
        entry.presentation,
        desired.get(entry) || {
          visible: false,
          // A detached native surface cannot complete a compositor copy. Keep
          // only the captured page attached, already hidden and unfocused, for
          // the bounded request. Normal inactive pages detach immediately.
          retainAttachment: layout.overlay && entry.backdropCaptureGeneration === backdropGeneration,
        },
        win.contentView,
      );
  }
  extensionHost?.sidePanel?.arrange(layout);
}
async function openPeek(url, source = activeTab()) {
  url = webURL(url);
  if (!url || !source) throw new Error('Choose a web link to preview.');
  if (!(await requestClosePeek())) return null;
  const entry = createEntry(source.profileId);
  peek = {
    entry,
    url,
    profileId: source.profileId,
    spaceId: source.spaceId,
    sourceTabId: source.sourceTabId || source.id,
  };
  arrangeViews();
  safeNavigate(entry, url);
  publish();
  focusContentOrChrome(entry.contents);
}
function closePeek(focus = true) {
  if (!peek) return;
  const entry = peek.entry;
  peek = null;
  destroyEntry(entry);
  arrangeViews();
  publish();
  if (focus) focusContentOrChrome();
}
function promotePeek() {
  if (!peek) return;
  const current = peek;
  peek = null;
  const url = current.entry.contents.getURL() || current.url;
  const tab = store.dispatch('tab:create', { url, spaceId: current.spaceId });
  // Reuse the living page, including its scroll position and back stack.
  const redundant = views.get(tab.id);
  if (redundant) destroyEntry(redundant);
  current.entry.tabId = tab.id;
  views.set(tab.id, current.entry);
  const title = current.entry.contents.getTitle() || tab.title;
  store.dispatch('tab:update', { id: tab.id, title });
  // A transient preview is not a visit until it becomes a tab. Record its
  // current destination, which may differ from the link originally previewed.
  store.dispatch('history:add', { profileId: current.profileId, url, title });
  arrangeViews();
  publish();
  focusContentOrChrome(current.entry.contents);
}

function showPageMenu(entry, params) {
  const wc = entry.contents;
  const source = tabForContents(wc);
  const link = webURL(params.linkURL);
  const items = [];
  if (params.misspelledWord && params.isEditable) {
    for (const suggestion of (params.dictionarySuggestions || []).slice(0, 5))
      items.push({ label: suggestion, click: () => wc.replaceMisspelling(suggestion) });
    if (items.length) items.push({ type: 'separator' });
  }
  if (process.platform === 'darwin' && params.selectionText?.trim()) {
    items.push({ label: 'Look Up Selection', click: () => wc.showDefinitionForSelection() });
    items.push({ type: 'separator' });
  }
  if (link && source)
    items.push(
      {
        label: 'Open link in new tab',
        click: () => invoke('tab:create', { url: link, spaceId: source.spaceId }).catch(report),
      },
      {
        label: 'Open link in background',
        click: () =>
          invoke('tab:create', { url: link, spaceId: source.spaceId, active: false }).catch(report),
      },
      { label: 'Peek at link', accelerator: 'Alt+Click', click: () => openPeek(link, source).catch(report) },
      { label: 'Copy link address', click: () => clipboard.writeText(link) },
      { type: 'separator' },
    );
  if (params.isEditable)
    items.push(
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { role: 'selectAll' },
    );
  else if (params.selectionText)
    items.push(
      { label: 'Copy', click: () => wc.copy() },
      {
        label: 'Search selection',
        click: () =>
          invoke('tab:create', {
            url: normalizeAddress(params.selectionText.slice(0, 2000), store.state.settings.searchEngine),
            spaceId: source?.spaceId,
          }).catch(report),
      },
    );
  if (webURL(params.srcURL))
    items.push(
      { label: 'Save image as…', click: () => wc.downloadURL(params.srcURL) },
      { label: 'Copy image address', click: () => clipboard.writeText(params.srcURL) },
    );
  if (items.length) items.push({ type: 'separator' });
  items.push(
    { label: 'Back', enabled: wc.navigationHistory.canGoBack(), click: () => wc.navigationHistory.goBack() },
    {
      label: 'Forward',
      enabled: wc.navigationHistory.canGoForward(),
      click: () => wc.navigationHistory.goForward(),
    },
    { label: 'Reload', click: () => wc.reload() },
    {
      label: wc.isAudioMuted() ? 'Unmute tab' : 'Mute tab',
      click: () => {
        wc.setAudioMuted(!wc.isAudioMuted());
        publish();
      },
    },
    { label: 'Print…', click: () => wc.print({}) },
    { type: 'separator' },
    { label: 'Inspect element', click: () => wc.inspectElement(params.x, params.y) },
  );
  const extensionItems = extensionHost?.menu(entry, params) || [];
  if (extensionItems.length) items.push({ type: 'separator' }, ...extensionItems);
  Menu.buildFromTemplate(items).popup({ window: win });
}

function handleShortcut(event, input, contents) {
  if (input.type !== 'keyDown' || input.isComposing || !validWindow()) return;
  const mod = process.platform === 'darwin' ? input.meta : input.control;
  const key = input.key.toLowerCase();
  const run = (callback) => {
    event.preventDefault();
    try {
      const value = callback();
      if (value?.catch) value.catch(report);
    } catch (error) {
      report(error);
    }
  };
  if (extensionHost?.shortcut(input)) {
    event.preventDefault();
    return;
  }
  if (process.platform === 'darwin') {
    const action = macShortcut(input);
    if (action) return run(() => runMacAction(action, contents !== win.webContents));
    // These belong to Cocoa: Command-H hides the app and Command-Tab is the
    // system application switcher. They must never become browser actions.
    // Unrecognized modified Command combinations also remain native. Falling
    // through would turn, for example, Command-Option-T into a new tab.
    if (input.meta && (input.control || input.alt || input.shift || ['h', 'q', 'tab'].includes(key))) return;
  }
  if (key === 'f6') {
    return run(() => {
      const target = activeContents();
      if (contents === win.webContents && !layout.overlay && target) target.focus();
      else {
        win.webContents.focus();
        emit({ type: 'focus:chrome' });
      }
    });
  }
  if (mod && input.shift && key === 'b')
    return run(() => emit({ type: 'sidebar:toggle', fromPage: contents !== win.webContents }));
  // The shell owns focused fields and command-panel shortcuts itself.
  if (contents === win.webContents && !['f5', 'f11', 'f12'].includes(key)) return;
  if (contents === win.webContents && ['f5', 'f12'].includes(key)) {
    const target = activeContents();
    return run(() => {
      if (!target) return;
      if (key === 'f12') target.openDevTools({ mode: 'detach' });
      else if (input.shift) target.reloadIgnoringCache();
      else target.reload();
    });
  }
  if (key === 'escape' && peek) return run(() => requestClosePeek());
  if (mod && key === 't' && input.shift) return run(() => invoke('tab:restore', {}));
  if (mod && ['l', 'k', 't'].includes(key))
    return run(async () => {
      if (key === 't' && !(await invoke('tab:create', {}))) return;
      emit({ type: 'command', mode: key === 't' ? 'navigate' : 'address' });
      win.webContents.focus();
    });
  if (mod && key === 'w')
    return run(() => (peek ? requestClosePeek() : requestCloseTab(store.state.activeTabId)));
  if (mod && key === 'f')
    return run(() => {
      emit({ type: 'find' });
      win.webContents.focus();
    });
  if (mod && key === 'd') return run(() => store.dispatch('bookmark:toggle', {}));
  if (mod && key === 'enter')
    return run(() => {
      emit({ type: 'ai:shortcut' });
      win.webContents.focus();
    });
  if (mod && ['h', 'j', ','].includes(key))
    return run(() => {
      emit({ type: 'panel', panel: { h: 'history', j: 'downloads', ',': 'settings' }[key] });
      win.webContents.focus();
    });
  if (mod && key === 'p') return run(() => contents.print({}));
  if ((mod && key === 'r') || key === 'f5')
    return run(() => (input.shift ? contents.reloadIgnoringCache() : contents.reload()));
  if (process.platform !== 'darwin' && mod && key === 'tab') return run(() => cycleTab(input.shift ? -1 : 1));
  if (mod && /^[1-9]$/.test(key))
    return run(() => {
      const tabs = store.state.tabs.filter((tab) => tab.spaceId === store.state.activeSpaceId);
      const tab = tabs[key === '9' ? tabs.length - 1 : Number(key) - 1];
      if (tab) return invoke('tab:activate', { id: tab.id });
    });
  if (process.platform !== 'darwin' && input.alt && key === 'arrowleft')
    return run(() => contents.navigationHistory.canGoBack() && contents.navigationHistory.goBack());
  if (process.platform !== 'darwin' && input.alt && key === 'arrowright')
    return run(() => contents.navigationHistory.canGoForward() && contents.navigationHistory.goForward());
  if (mod && ['+', '=', '-', '0'].includes(key))
    return run(() => zoom(contents, key === '0' ? { reset: true } : { delta: key === '-' ? -0.1 : 0.1 }));
  if (key === 'f11') return run(() => win.setFullScreen(!win.isFullScreen()));
  if (key === 'f12' || (mod && input.shift && key === 'i'))
    return run(() => contents.openDevTools({ mode: 'detach' }));
}
async function cycleTab(direction) {
  const tabs = store.state.tabs.filter((tab) => tab.spaceId === store.state.activeSpaceId);
  if (!tabs.length) return;
  const index = tabs.findIndex((tab) => tab.id === store.state.activeTabId);
  const id = tabs[(index + direction + tabs.length) % tabs.length].id;
  const result = await invoke('tab:activate', { id });
  if (result && store.state.activeTabId === id) focusContentOrChrome();
  return result;
}
function zoom(contents, payload) {
  if (!contents) return;
  contents.setZoomFactor(
    payload.reset
      ? 1
      : Math.min(
          3,
          Math.max(
            0.25,
            contents.getZoomFactor() + Math.max(-0.5, Math.min(0.5, Number(payload.delta) || 0)),
          ),
        ),
  );
  publish();
}

async function onDownload(event, item, contents, profileId) {
  const source = tabForContents(contents);
  let filename;
  try {
    filename = safeFilename(item.getFilename() || 'download');
  } catch {
    filename = `download-${Date.now()}${path
      .extname(item.getFilename())
      .replace(/[^.a-z0-9]/gi, '')
      .slice(0, 12)}`;
  }
  const id = randomUUID();
  const record = {
    id,
    profileId,
    name: filename,
    url: item.getURL(),
    sourceUrl: source?.url || '',
    sourceTitle: source?.title || '',
    path: '',
    state: 'progressing',
    receivedBytes: 0,
    totalBytes: item.getTotalBytes(),
    startedAt: Date.now(),
    paused: false,
  };
  store.state.downloads.unshift(record);
  liveDownloads.set(id, item);
  // Reserve synchronously before returning from will-download. Electron starts
  // writing immediately once this callback returns.
  const directory = app.getPath('downloads');
  let candidate = path.join(directory, filename);
  const ext = path.extname(filename),
    stem = path.basename(filename, ext);
  let index = 1;
  while (fs.existsSync(candidate) || downloadReservations.has(candidate))
    candidate = path.join(directory, `${stem} (${index++})${ext}`);
  downloadReservations.add(candidate);
  record.path = candidate;
  record.name = path.basename(candidate);
  item.setSavePath(candidate);
  store.changed();
  emit({ type: 'panel', panel: 'downloads' });
  let lastUpdate = 0;
  item.on('updated', (_event, state) => {
    record.state = state;
    record.receivedBytes = item.getReceivedBytes();
    record.totalBytes = item.getTotalBytes();
    record.paused = item.isPaused();
    if (Date.now() - lastUpdate > 150) {
      lastUpdate = Date.now();
      store.changed();
    }
  });
  item.once('done', (_event, state) => {
    record.state = state;
    record.receivedBytes = item.getReceivedBytes();
    record.finishedAt = Date.now();
    record.paused = false;
    liveDownloads.delete(id);
    downloadReservations.delete(candidate);
    store.changed();
    if (state === 'completed') toast(`Downloaded ${record.name}`);
    else if (state === 'interrupted') toast(`Download interrupted: ${record.name}`);
  });
}
function downloadRecord(id) {
  const record = store.state.downloads.find(
    (item) => item.id === id && item.profileId === activeSpace()?.profileId,
  );
  if (!record) throw new Error('This download is not available in the active profile.');
  return record;
}
async function renameDownload(payload, undo = false) {
  const record = downloadRecord(payload.id);
  if (record.state !== 'completed') throw new Error('Wait for the download to finish before renaming it.');
  const current = record.path;
  if (!current || !fs.existsSync(current)) throw new Error('This file has been moved or deleted.');
  let target;
  if (undo) {
    if (!record.previousPath || path.dirname(record.previousPath) !== path.dirname(current))
      throw new Error('There is no rename to undo.');
    target = record.previousPath;
  } else {
    const name = safeFilename(payload.name, record.name);
    target = path.join(path.dirname(current), name);
  }
  if (target === current) return record;
  await renameWithoutOverwrite(current, target).catch((error) => {
    if (error.code === 'EEXIST')
      throw new Error('A file with that name already exists. Choose another name.');
    throw error;
  });
  record.path = target;
  record.name = path.basename(target);
  record.previousPath = undo ? null : current;
  store.changed();
  return record;
}

function managedExtensionRoot() {
  return path.join(app.getPath('userData'), 'extensions');
}
function managedExtensionPath(value) {
  if (typeof value !== 'string') return false;
  const root = path.resolve(managedExtensionRoot());
  const candidate = path.resolve(value);
  return candidate.startsWith(root + path.sep) && candidate !== root;
}

async function exportData() {
  const selection = await dialog.showSaveDialog(win, {
    title: 'Export Zacro data',
    defaultPath: `zacro-${new Date().toISOString().slice(0, 10)}.json`,
    filters: [{ name: 'Zacro data', extensions: ['json'] }],
  });
  if (selection.canceled || !selection.filePath) return null;
  await fsp.writeFile(selection.filePath, JSON.stringify(store.exportData(), null, 2), { mode: 0o600 });
  toast('Spaces, tabs, and bookmarks exported.');
  return { path: selection.filePath };
}
async function importData() {
  const selection = await dialog.showOpenDialog(win, {
    title: 'Import Zacro data or browser bookmarks',
    properties: ['openFile'],
    filters: [{ name: 'Browser exports', extensions: ['json', 'html', 'htm'] }],
  });
  if (selection.canceled || !selection.filePaths[0]) return null;
  const stat = await fsp.stat(selection.filePaths[0]);
  if (stat.size > 20 * 1024 * 1024) throw new Error('Choose a browser export smaller than 20 MB.');
  const content = await fsp.readFile(selection.filePaths[0], 'utf8');
  let result;
  if (content.trimStart().startsWith('{')) result = store.importData(JSON.parse(content));
  else {
    const { parseBookmarksHtml } = require('../core/import.cjs');
    result = store.importBookmarks(parseBookmarksHtml(content), activeSpace().profileId);
  }
  toast('Browser data imported.');
  return result;
}
async function clearProfileData(profileId) {
  const profile = store.state.profiles.find((item) => item.id === profileId);
  if (!profile) throw new Error('Profile not found.');
  const answer = await dialog.showMessageBox(win, {
    type: 'warning',
    title: 'Clear browsing data',
    message: `Clear browsing data for ${profile.name}?`,
    detail:
      'This removes history, site permissions, cookies, cached files, and site storage. You will be signed out of websites. Bookmarks and saved tabs stay.',
    buttons: ['Cancel', 'Clear data'],
    defaultId: 0,
    cancelId: 0,
  });
  if (answer.response !== 1) return;
  if (activeSpace()?.profileId === profileId) await ai?.handle('ai:reset', {});
  if (peek?.profileId === profileId) closePeek(false);
  for (const [id, entry] of views)
    if (entry.profileId === profileId) {
      destroyEntry(entry);
      views.delete(id);
    }
  const ses = profileSession(profileId);
  faviconLoader.clear(ses);
  await ses.clearStorageData();
  await ses.clearCache();
  await ses.clearAuthCache();
  store.dispatch('history:clear', { profileId });
  store.dispatch('permission:clear', { profileId });
  reconcile();
  toast('Browsing data cleared.');
}

async function getPageContext(ids, signal) {
  const profile = activeProfile();
  if (!profile || profile.private) throw new Error('AI page sharing is unavailable in private profiles.');
  const results = [];
  for (const id of ids.slice(0, 12)) {
    if (signal?.aborted) throw new Error('Page reading was cancelled.');
    const tab = store.state.tabs.find((item) => item.id === id && item.profileId === profile.id);
    if (!tab) throw new Error('Only tabs in the active profile can be shared.');
    const entry = views.get(id);
    if (!entry || entry.contents.isDestroyed() || entry.error) {
      results.push({
        id,
        title: tab.title,
        url: tab.url,
        text: '',
        error: 'This tab is not currently loaded or could not be read. Open it and try again.',
      });
      continue;
    }
    try {
      // This fixed, read-only expression never includes model-generated code.
      // Form controls and editing surfaces are removed before extracting text.
      const contextURL = entry.contents.getURL();
      const contextTitle = entry.contents.getTitle() || tab.title;
      // Read the selected document on demand. Electron's webRequest slots are
      // shared with extensions; a MIME observer there would replace listeners.
      entry.mimeType = await entry.contents.executeJavaScriptInIsolatedWorld(
        1001,
        [{ code: 'document.contentType' }],
        false,
      );
      if (
        entry.contents.isDestroyed() ||
        entry.contents.getURL() !== contextURL ||
        activeSpace()?.profileId !== profile.id
      )
        throw new Error('The page or profile changed while reading its type.');
      if (entry.mimeType === 'application/pdf' || /\.pdf(?:[?#]|$)/i.test(contextURL)) {
        const pdf = await readPDFContext(entry, contextURL, signal);
        if (
          entry.contents.isDestroyed() ||
          entry.contents.getURL() !== contextURL ||
          activeSpace()?.profileId !== profile.id
        )
          throw new Error('The page or profile changed while reading the PDF.');
        results.push({ id, title: contextTitle, url: contextURL, pdf: true, ...pdf });
        continue;
      }
      const text = await entry.contents.executeJavaScriptInIsolatedWorld(
        1001,
        [
          {
            code: `(() => {
        const root = document.body?.cloneNode(true);
        if (!root) return '';
        const original = document.body.querySelectorAll('*');
        const copies = root.querySelectorAll('*');
        for (let i = 0; i < original.length; i++) {
          const style = getComputedStyle(original[i]);
          if (style.display === 'none' || style.visibility === 'hidden') copies[i]?.remove();
        }
        root.querySelectorAll('script,style,noscript,input,textarea,select,option,[contenteditable],[hidden],[aria-hidden="true"],iframe,object,embed').forEach(node => node.remove());
        root.querySelectorAll('p,div,section,article,li,h1,h2,h3,h4,h5,h6,pre,blockquote,br,tr').forEach(node => node.appendChild(document.createTextNode('\\n\\n')));
        return (root.textContent || '').replace(/[^\\S\\n]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim().slice(0, 60000);
      })()`,
          },
        ],
        false,
      );
      if (entry.contents.isDestroyed() || entry.contents.getURL() !== contextURL)
        throw new Error('Page navigated during extraction.');
      results.push({
        id,
        title: contextTitle,
        url: contextURL,
        text,
        ...(text
          ? {}
          : { error: 'No readable text was available. This page may be a PDF viewer or require sign-in.' }),
      });
    } catch (error) {
      results.push({
        id,
        title: tab.title,
        url: tab.url,
        text: '',
        error:
          entry.mimeType === 'application/pdf' || /\.pdf(?:[?#]|$)/i.test(tab.url)
            ? `This PDF could not be read: ${error.message}`
            : 'This page could not be read.',
      });
    }
  }
  return results;
}

async function readPDFContext(entry, url, signal) {
  if (!webURL(url) || store.state.profiles.find((profile) => profile.id === entry.profileId)?.private)
    throw new Error('Only explicitly selected web PDFs in a regular profile can be shared.');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  const combinedSignal = signal ? AbortSignal.any([controller.signal, signal]) : controller.signal;
  try {
    const response = await profileSession(entry.profileId).fetch(url, {
      signal: combinedSignal,
      redirect: 'error',
    });
    if (!response.ok) throw new Error(`The PDF server returned HTTP ${response.status}.`);
    const limit = 20 * 1024 * 1024;
    if (Number(response.headers.get('content-length')) > limit) {
      controller.abort();
      throw new Error('PDFs larger than 20 MB are not supported.');
    }
    if (!response.body) throw new Error('The PDF server returned an empty document.');
    const chunks = [];
    let length = 0;
    for await (const chunk of response.body) {
      length += chunk.byteLength;
      if (length > limit) {
        controller.abort();
        throw new Error('PDFs larger than 20 MB are not supported.');
      }
      chunks.push(Buffer.from(chunk));
    }
    clearTimeout(timer);
    const { extractPDF } = require('./pdf.cjs');
    const result = await extractPDF(Buffer.concat(chunks, length), {
      maxPages: 100,
      maxChars: 60000,
      signal: combinedSignal,
    });
    if (!result.text)
      throw new Error('No text was available. Scanned PDFs need OCR, which is not supported.');
    return result;
  } catch (error) {
    if (controller.signal.aborted && error.name === 'AbortError')
      throw new Error('The PDF download took too long.');
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

const CORE_ACTIONS = new Set([
  'tab:create',
  'tab:activate',
  'tab:close',
  'tab:pin',
  'tab:move',
  'tab:restore',
  'space:create',
  'space:update',
  'space:activate',
  'space:delete',
  'profile:create',
  'profile:delete',
  'folder:create',
  'folder:update',
  'folder:delete',
  'bookmark:toggle',
  'bookmark:delete',
  'history:clear',
  'archive:clear',
  'settings:update',
  'permission:clear',
]);
async function invoke(action, payload = {}) {
  if (typeof action !== 'string' || !payload || typeof payload !== 'object' || Array.isArray(payload))
    throw new Error('Invalid browser action.');
  if (action.startsWith('sync:')) return syncAccount.handle(action, payload);
  if (action.startsWith('extension:')) return extensionHost.handle(action, payload);
  if (CORE_ACTIONS.has(action)) {
    const leavesPreview =
      ['tab:activate', 'tab:restore', 'space:activate', 'space:create', 'profile:create'].includes(action) ||
      (action === 'space:delete' && payload.id === peek?.spaceId) ||
      (action === 'tab:create' && payload.active !== false) ||
      (action === 'tab:move' &&
        payload.id === store.state.activeTabId &&
        payload.spaceId &&
        payload.spaceId !== store.state.activeSpaceId) ||
      (action === 'tab:close' && (!payload.id || payload.id === peek?.sourceTabId));
    if (peek && leavesPreview && !(await requestClosePeek())) return null;
    if (action === 'tab:close') return requestCloseTab(payload.id || store.state.activeTabId);
    if (action === 'profile:delete') {
      const profile = store.state.profiles.find((item) => item.id === payload.id);
      if (!profile) throw new Error('Profile not found.');
      if (!profile.private && store.state.profiles.filter((item) => !item.private).length < 2)
        throw new Error('Keep at least one regular browser profile.');
      const answer = await dialog.showMessageBox(win, {
        type: 'warning',
        title: 'Delete profile',
        message: `Delete ${profile.name}?`,
        detail:
          'Its Spaces, tabs, bookmarks, history, permissions, and site data will be removed from this device.',
        buttons: ['Cancel', 'Delete profile'],
        defaultId: 0,
        cancelId: 0,
      });
      if (answer.response !== 1) return null;
      if (!profile.private) await syncAccount?.client.deleteLocalProfile(profile.id);
      if (peek?.profileId === profile.id) closePeek(false);
      if (activeSpace()?.profileId === profile.id) await ai?.handle('ai:reset', {});
      for (const record of store.state.downloads.filter((item) => item.profileId === profile.id))
        liveDownloads.get(record.id)?.cancel();
      for (const [id, entry] of views)
        if (entry.profileId === profile.id) {
          destroyEntry(entry);
          views.delete(id);
        }
      const ses = profileSession(profile.id);
      faviconLoader.clear(ses);
      if (!profile.private) await extensionHost.removeProfile(profile.id);
      await ses.clearStorageData();
      await ses.clearCache();
      await ses.clearAuthCache();
      await ses.closeAllConnections();
      sessions.delete(profile.id);
    }
    const result = store.dispatch(action, payload);
    if (action === 'profile:delete') {
      store.flush();
      syncAccount?.client.completeLocalProfileDeletion(payload.id);
    }
    if (action === 'settings:update' && payload.values?.sidebarWidth && layout.sidebarWidth !== 0)
      layout.sidebarWidth = store.state.settings.sidebarWidth;
    return result;
  }
  const contents = activeContents();
  switch (action) {
    case 'app:quit':
      // Let the IPC reply settle before a successful quit destroys its sender.
      setImmediate(() => app.quit());
      return null;
    case 'app:set-default-browser':
      if (!defaultBrowser.supported)
        throw new Error('Install the macOS application before choosing it as your default browser.');
      app.setAsDefaultProtocolClient('http');
      app.setAsDefaultProtocolClient('https');
      refreshDefaultBrowser();
      publish();
      return { ...defaultBrowser };
    case 'state:get':
      return snapshot();
    case 'page:focus':
      focusContentOrChrome();
      return null;
    case 'auth:respond': {
      if (!pendingAuth || pendingAuth.id !== payload.id || pendingAuth.profileId !== activeSpace()?.profileId)
        throw new Error('This sign-in request has expired. Reload the page to try again.');
      if (
        typeof payload.username !== 'string' ||
        payload.username.length > 512 ||
        typeof payload.password !== 'string' ||
        payload.password.length > 4096
      )
        throw new Error('Enter a valid username and password.');
      finishAuth({ username: payload.username, password: payload.password }, 'submitted');
      return null;
    }
    case 'auth:cancel':
      if (pendingAuth?.id === payload.id) finishAuth();
      return null;
    case 'tab:update': {
      if (typeof payload.title !== 'string') throw new Error('A tab title is required.');
      return store.dispatch('tab:rename', { id: payload.id, title: payload.title });
    }
    case 'navigate': {
      const url = normalizeAddress(payload.url, store.state.settings.searchEngine);
      if (peek) {
        if (url === NEW_TAB) await requestClosePeek();
        else safeNavigate(peek.entry, url);
        break;
      }
      const tab = activeTab() || store.dispatch('tab:create', { url });
      if (url === NEW_TAB) {
        const entry = reserveView(tab);
        if (entry.contents.getURL() && entry.contents.getURL() !== 'about:blank') {
          try {
            await entry.contents.loadURL('about:blank');
          } catch (error) {
            if (error.code === 'ERR_ABORTED') return null;
            throw error;
          }
          if (entry.contents.isDestroyed() || entry.contents.getURL() !== 'about:blank') return null;
        }
        entry.dormant = true;
        entry.requestedURL = null;
        entry.error = null;
        store.dispatch('tab:update', { id: tab.id, url, title: 'New tab' });
        focusContentOrChrome();
        break;
      }
      store.dispatch('tab:update', { id: tab.id, url });
      const entry = ensureView(tab.id);
      if (entry.requestedURL !== url || entry.error) safeNavigate(entry, url);
      focusContentOrChrome(entry.contents);
      break;
    }
    case 'back':
      if (contents?.navigationHistory.canGoBack()) contents.navigationHistory.goBack();
      break;
    case 'forward':
      if (contents?.navigationHistory.canGoForward()) contents.navigationHistory.goForward();
      break;
    case 'reload':
      if (contents) {
        activeEntry().error = null;
        contents.reload();
        arrangeViews();
      }
      break;
    case 'stop':
      contents?.stop();
      break;
    case 'tab:mute': {
      const entry = views.get(payload.id || store.state.activeTabId);
      if (entry) entry.contents.setAudioMuted(!entry.contents.isAudioMuted());
      break;
    }
    case 'window:minimize':
      win.minimize();
      break;
    case 'window:maximize':
      win.isMaximized() ? win.unmaximize() : win.maximize();
      break;
    case 'window:close':
      win.close();
      break;
    case 'window:fullscreen':
      win.setFullScreen(!win.isFullScreen());
      break;
    case 'layout': {
      const previousOverlay = layout.overlay;
      const previousSidebarWidth = layout.sidebarWidth;
      if (Number.isFinite(payload.sidebarWidth))
        layout.sidebarWidth =
          payload.sidebarWidth === 0 ? 0 : Math.max(200, Math.min(380, payload.sidebarWidth));
      if (Number.isFinite(payload.panelWidth))
        layout.panelWidth = Math.max(0, Math.min(650, payload.panelWidth));
      if ([8, 36, 40].includes(payload.contentTop)) layout.contentTop = payload.contentTop;
      else if (payload.contentTop !== undefined || layout.sidebarWidth === 0) layout.contentTop = 40;
      else if (previousSidebarWidth === 0)
        layout.contentTop = process.platform === 'darwin' || win.isFullScreen() ? 8 : 36;
      if (typeof payload.overlay === 'boolean') layout.overlay = payload.overlay;
      if (typeof payload.extensionPanel === 'boolean') layout.extensionPanel = payload.extensionPanel;
      if (layout.overlay && !previousOverlay) void captureBackdrop();
      else if (!layout.overlay && previousOverlay) clearBackdrop();
      arrangeViews();
      if (layout.overlay) win.webContents.focus();
      return null;
    }
    case 'find':
      if (contents && typeof payload.text === 'string' && payload.text.length)
        return contents.findInPage(payload.text.slice(0, 1000), {
          forward: payload.forward !== false,
          findNext: Boolean(payload.findNext),
        });
      contents?.stopFindInPage('clearSelection');
      break;
    case 'find:stop':
      contents?.stopFindInPage('clearSelection');
      if (payload.focus !== false) focusContentOrChrome(contents);
      break;
    case 'zoom':
      zoom(contents, payload);
      break;
    case 'print':
      contents?.print({});
      break;
    case 'devtools':
      contents?.openDevTools({ mode: 'detach' });
      break;
    case 'split:toggle': {
      if (!(await requestClosePeek())) return null;
      if (splitTabId && !payload.id) {
        splitTabId = null;
        splitPair = null;
        break;
      }
      const selected =
        store.state.tabs.find(
          (tab) =>
            tab.id === payload.id &&
            tab.spaceId === store.state.activeSpaceId &&
            tab.id !== store.state.activeTabId &&
            tab.url !== NEW_TAB,
        ) ||
        store.state.tabs.find(
          (tab) =>
            tab.spaceId === store.state.activeSpaceId &&
            tab.id !== store.state.activeTabId &&
            tab.url !== NEW_TAB,
        );
      if (!selected) throw new Error('Open a second web page in this Space to use split view.');
      if (activeTab()?.url === NEW_TAB)
        throw new Error('Open a web page in the current tab before starting split view.');
      splitTabId = selected.id;
      splitPair = [store.state.activeTabId, selected.id];
      ensureView(splitTabId);
      break;
    }
    case 'peek:open':
      await openPeek(payload.url);
      break;
    case 'peek:close':
      return requestClosePeek();
    case 'peek:promote':
      promotePeek();
      break;
    case 'download:show': {
      const record = downloadRecord(payload.id);
      if (!record.path || !fs.existsSync(record.path))
        throw new Error('This file has been moved or deleted.');
      shell.showItemInFolder(record.path);
      break;
    }
    case 'download:cancel': {
      const record = downloadRecord(payload.id);
      liveDownloads.get(record.id)?.cancel();
      break;
    }
    case 'download:pause': {
      const record = downloadRecord(payload.id);
      liveDownloads.get(record.id)?.pause();
      record.paused = true;
      store.changed();
      break;
    }
    case 'download:resume': {
      const record = downloadRecord(payload.id);
      const item = liveDownloads.get(record.id);
      if (!item || !item.canResume())
        throw new Error('This download cannot be resumed. Download it again from the source page.');
      item.resume();
      record.paused = false;
      store.changed();
      break;
    }
    case 'download:rename':
      return renameDownload(payload);
    case 'download:undo':
      return renameDownload(payload, true);
    case 'data:export':
      return exportData();
    case 'data:import':
      return importData();
    case 'data:clear':
      return clearProfileData(payload.profileId || activeSpace().profileId);
    case 'external:open': {
      const url = webURL(payload.url);
      if (!url) throw new Error('Only web links may be opened externally.');
      await shell.openExternal(url);
      break;
    }
    case 'app:about':
      return {
        name: 'Zacro',
        version: app.getVersion(),
        electron: process.versions.electron,
        chromium: process.versions.chrome,
        platform: process.platform,
        packaged: app.isPackaged,
      };
    case 'app:check-updates':
      await shell.openExternal('https://github.com/Zacro-Technologies/zacro_browser/releases');
      break;
    case 'ai:open-sources': {
      const sources = ai?.latestSources || [];
      let first = null;
      for (const source of sources.slice(0, store.state.settings.openSourcesLimit || 3)) {
        const url = webURL(source.url);
        if (!url) continue;
        const existing = store.state.tabs.find(
          (tab) => tab.spaceId === store.state.activeSpaceId && tab.url.split('#')[0] === url.split('#')[0],
        );
        const tab = existing || store.dispatch('tab:create', { url, active: false });
        first ||= tab;
      }
      if (first) await invoke('tab:activate', { id: first.id });
      return { count: Math.min(sources.length, store.state.settings.openSourcesLimit || 3) };
    }
    default:
      if (action.startsWith('ai:') && ai) {
        if (action === 'ai:suggest-name') {
          const record = downloadRecord(payload.id);
          payload = {
            id: record.id,
            name: record.name,
            url: record.sourceUrl || record.url,
            title: record.sourceTitle,
          };
        }
        const result = await ai.handle(action, payload);
        publish();
        return result;
      }
      throw new Error('This browser action is not supported.');
  }
  arrangeViews();
  publish();
  return null;
}

function registerIPC() {
  ipcMain.handle('zacro:invoke', async (event, action, payload) => {
    if (
      !validWindow() ||
      event.sender !== win.webContents ||
      event.senderFrame !== win.webContents.mainFrame ||
      event.senderFrame.url !== UI_URL
    )
      throw new Error('Untrusted browser action.');
    // Reject excessively large messages before privileged work begins.
    if (JSON.stringify(payload ?? {}).length > 1024 * 1024) throw new Error('This request is too large.');
    return invoke(action, payload || {});
  });
  ipcMain.on('zacro:peek-link', (event, url) => {
    const tab = tabForContents(event.sender);
    if (!tab || event.senderFrame !== event.sender.mainFrame || !webURL(url)) return;
    openPeek(url, tab).catch(report);
  });
}
function buildMenu() {
  if (process.platform === 'darwin') {
    app.setAboutPanelOptions({
      applicationName: 'Zacro',
      applicationVersion: app.getVersion(),
      copyright: 'An independent, open-source browser by Zacro Technologies.',
      website: 'https://github.com/Zacro-Technologies/zacro_browser',
      iconPath: path.join(__dirname, '../../assets/icon.png'),
    });
    Menu.setApplicationMenu(
      Menu.buildFromTemplate(
        macMenuTemplate(
          (action) => runMacAction(action).catch(report),
          (action) => {
            // BrowserWindow.webContents is the shell, not necessarily the
            // native page's first responder. Respect focused page editors.
            const contents = webContents.getFocusedWebContents();
            if (contents && !contents.isDestroyed()) contents[action]();
          },
        ),
      ),
    );
    app.dock?.setMenu(
      Menu.buildFromTemplate([
        { label: 'Open Browser Window', click: () => ensureWindow().catch(report) },
        { label: 'New Tab', click: () => runMacAction('new-tab').catch(report) },
        { label: 'New Private Space', click: () => runMacAction('new-private-space').catch(report) },
      ]),
    );
    return;
  }
  const template = [
    ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        {
          label: 'New tab',
          click: () =>
            invoke('tab:create', {})
              .then((tab) => {
                if (!tab) return;
                emit({ type: 'command', mode: 'navigate' });
                win.webContents.focus();
              })
              .catch(report),
        },
        {
          label: 'New private Space',
          click: () => invoke('profile:create', { name: 'Private', private: true }).catch(report),
        },
        { label: 'Reopen closed tab', click: () => invoke('tab:restore', {}).catch(report) },
        { type: 'separator' },
        { label: 'Import browser data…', click: () => importData().catch(report) },
        { label: 'Export browser data…', click: () => exportData().catch(report) },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        { label: 'History', click: () => emit({ type: 'panel', panel: 'history' }) },
        { label: 'Downloads', click: () => emit({ type: 'panel', panel: 'downloads' }) },
        { label: 'Settings', click: () => emit({ type: 'panel', panel: 'settings' }) },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Help',
      submenu: [
        {
          label: 'Zacro releases',
          click: () => shell.openExternal('https://github.com/Zacro-Technologies/zacro_browser/releases'),
        },
        {
          label: 'Report an issue',
          click: () => shell.openExternal('https://github.com/Zacro-Technologies/zacro_browser/issues'),
        },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}
function refreshDefaultBrowser() {
  defaultBrowser = {
    supported: process.platform === 'darwin' && app.isPackaged,
    configured:
      process.platform === 'darwin' &&
      app.isPackaged &&
      app.isDefaultProtocolClient('http') &&
      app.isDefaultProtocolClient('https'),
  };
}
function updateMacMenu() {
  if (process.platform !== 'darwin') return;
  const menu = Menu.getApplicationMenu();
  if (!menu) return;
  const available = Boolean(validWindow() && !closingWindow);
  const page = available && activeContents();
  const pageAvailable = Boolean(page && !page.isDestroyed());
  const enable = (id, enabled) => {
    const item = menu.getMenuItemById(id);
    if (item) item.enabled = enabled;
  };
  for (const id of ['close-tab', 'close-window', 'sidebar-toggle', 'fullscreen', 'previous-tab', 'next-tab'])
    enable(id, available);
  for (const id of [
    'print',
    'reload',
    'force-reload',
    'find',
    'zoom-in',
    'zoom-out',
    'zoom-reset',
    'developer-tools',
    'bookmark',
  ])
    enable(id, pageAvailable);
  enable('history-back', pageAvailable && page.navigationHistory.canGoBack());
  enable('history-forward', pageAvailable && page.navigationHistory.canGoForward());
  const fullscreen = menu.getMenuItemById('fullscreen');
  if (fullscreen)
    fullscreen.label = available && win.isFullScreen() ? 'Exit Full Screen' : 'Enter Full Screen';
}
async function runMacAction(action, fromPage = false) {
  if (action === 'releases' || action === 'issues')
    return shell.openExternal(`https://github.com/Zacro-Technologies/zacro_browser/${action}`);
  if (['close-tab', 'close-window'].includes(action) && !validWindow()) return;
  await ensureWindow();
  if (!validWindow() || closingWindow || quitting) return;
  const contents = activeContents();
  const showChrome = (event) => {
    emit(event);
    win.webContents.focus();
  };
  switch (action) {
    case 'open-browser':
      return;
    case 'new-tab':
      if (!(await invoke('tab:create', {}))) return;
      return showChrome({ type: 'command', mode: 'navigate' });
    case 'new-private-space':
      await invoke('profile:create', { name: 'Private', private: true });
      return;
    case 'reopen-tab':
      return invoke('tab:restore', {});
    case 'close-tab':
      return peek ? requestClosePeek() : requestCloseTab(store.state.activeTabId);
    case 'close-window':
      win.close();
      return;
    case 'open-location':
      return showChrome({ type: 'command', mode: 'address' });
    case 'preferences':
    case 'history':
    case 'downloads':
      return showChrome({ type: 'panel', panel: action === 'preferences' ? 'settings' : action });
    case 'find':
      return showChrome({ type: 'find' });
    case 'print':
      return contents?.print({});
    case 'reload':
      return contents?.reload();
    case 'force-reload':
      return contents?.reloadIgnoringCache();
    case 'sidebar-toggle':
      return emit({ type: 'sidebar:toggle', fromPage });
    case 'zoom-in':
    case 'zoom-out':
    case 'zoom-reset':
      return zoom(
        contents,
        action === 'zoom-reset' ? { reset: true } : { delta: action === 'zoom-in' ? 0.1 : -0.1 },
      );
    case 'fullscreen':
      win.setFullScreen(!win.isFullScreen());
      return;
    case 'developer-tools':
      return contents?.openDevTools({ mode: 'detach' });
    case 'history-back':
      if (contents?.navigationHistory.canGoBack()) contents.navigationHistory.goBack();
      return;
    case 'history-forward':
      if (contents?.navigationHistory.canGoForward()) contents.navigationHistory.goForward();
      return;
    case 'previous-tab':
    case 'next-tab':
      return cycleTab(action === 'previous-tab' ? -1 : 1);
    case 'bookmark':
      return invoke('bookmark:toggle', {});
    case 'import':
      return importData();
    case 'export':
      return exportData();
  }
}
async function ensureWindow() {
  if (!store || quitting || quitRequested) return;
  if (windowReady) await windowReady;
  else if (!validWindow()) {
    windowReady = createWindow();
    try {
      await windowReady;
    } finally {
      windowReady = null;
    }
  }
  if (!validWindow() || closingWindow) return;
  if (win.isMinimized()) win.restore();
  if (process.platform === 'darwin' && app.isHidden()) app.show();
  win.show();
  win.focus();
}
async function drainExternalURLs() {
  if (!startupReady || drainingExternalURLs || quitRequested || quitting) return;
  drainingExternalURLs = true;
  try {
    await ensureWindow();
    while (externalURLs.length && validWindow() && !closingWindow && !quitRequested)
      await invoke('tab:create', { url: externalURLs.shift() });
  } finally {
    drainingExternalURLs = false;
  }
}
function receiveExternalURL(value) {
  const url = webURL(value);
  if (!url || externalURLs.length >= 32) return;
  externalURLs.push(url);
  void drainExternalURLs().catch(report);
}
async function endPrivateSessions() {
  // The Mac process survives closing its last window; private browsing must
  // not. Run only after every page has accepted the close, never on Cancel.
  for (const profile of store.state.profiles.filter((item) => item.private)) {
    for (const record of store.state.downloads.filter((item) => item.profileId === profile.id))
      liveDownloads.get(record.id)?.cancel();
    const ses = sessions.get(profile.id);
    if (ses) {
      faviconLoader.clear(ses);
      for (const extension of store.state.extensions.filter((item) => item.profileId === profile.id))
        if (extension.enabled) ses.extensions.removeExtension(extension.extensionId);
      await ses.closeAllConnections();
      await ses.clearStorageData();
      await ses.clearAuthCache();
      await ses.clearCache();
      sessions.delete(profile.id);
    }
    store.dispatch('profile:delete', { id: profile.id });
  }
}
async function createWindow() {
  closingWindow = false;
  allowWindowClose = false;
  splitTabId = null;
  splitPair = null;
  layout = {
    sidebarWidth: store.state.settings.sidebarWidth || 224,
    panelWidth: 0,
    contentTop: process.platform === 'darwin' ? 8 : 36,
    overlay: false,
  };
  clearTimeout(publishTimer);
  publishTimer = null;
  const primary = screen.getPrimaryDisplay();
  const displays = [primary, ...screen.getAllDisplays().filter((display) => display.id !== primary.id)];
  const bounds = restoreWindowPlacement(
    store.state.windowBounds,
    displays.map((display) => display.workArea),
  );
  const useContentSize = store.state.windowBounds?.sizeKind !== 'window';
  normalWindowBounds = { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height };
  win = new BrowserWindow({
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    minWidth: Math.min(960, bounds.width),
    minHeight: Math.min(640, bounds.height),
    title: 'Zacro',
    backgroundColor: '#f4f2ef',
    ...windowChrome(process.platform),
    useContentSize,
    icon: path.join(__dirname, '../../assets/icon.png'),
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      navigateOnDragDrop: false,
      spellcheck: false,
    },
  });
  if (!useContentSize && process.platform === 'win32') {
    // On fractional Windows scaling, constructing a frameless window may add
    // rounded non-client pixels even for outer bounds. Correct against the
    // measured native rectangle, with a fixed limit rather than accumulating
    // that conversion error in every saved session.
    const requested = { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height };
    for (let attempt = 0; attempt < 3; attempt++) {
      const actual = win.getBounds();
      if (['x', 'y', 'width', 'height'].every((key) => actual[key] === bounds[key])) break;
      for (const key of ['x', 'y', 'width', 'height']) requested[key] += bounds[key] - actual[key];
      requested.width = Math.max(1, requested.width);
      requested.height = Math.max(1, requested.height);
      win.setBounds(requested);
    }
  }
  // Website views and the shell must be native siblings. Nesting websites
  // inside BrowserWindow's original content view can leave their renderer
  // hidden on first navigation even when the native child reports visible.
  // A debugger masks that failure by keeping pages rendering.
  const shellView = win.contentView;
  const pageHost = new View();
  win.setContentView(pageHost);
  pageHost.addChildView(shellView);
  const sizeShell = () => {
    const [width, height] = win.getContentSize();
    shellView.setBounds({ x: 0, y: 0, width, height });
  };
  sizeShell();
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.webContents.on('will-redirect', (event) => event.preventDefault());
  win.webContents.on('will-attach-webview', (event) => event.preventDefault());
  win.webContents.on('before-input-event', (event, input) => handleShortcut(event, input, win.webContents));
  win.webContents.on('render-process-gone', () => {
    if (validWindow()) win.webContents.reload();
  });
  win.webContents.on('did-finish-load', () => {
    reconcile();
    publish();
  });
  const rememberNormalBounds = () => {
    if (!validWindow()) return;
    // Windows can emit moved/resize before its maximized flag settles. Reading
    // the visible rectangle then can replace a user's restore position with
    // the screen origin. The native restore rectangle remains authoritative in
    // maximized, minimized and fullscreen states, including the final close.
    const { x, y, width, height } = win.getNormalBounds();
    normalWindowBounds = { x, y, width, height };
  };
  rememberNormalBounds();
  win.on('resize', () => {
    rememberNormalBounds();
    sizeShell();
    arrangeViews();
    publish();
  });
  win.on('moved', rememberNormalBounds);
  win.on('maximize', publish);
  win.on('unmaximize', publish);
  win.on('focus', () => {
    if (extensionHost && activeProfile())
      extensionHost.api.publish(activeProfile().id, 'windows.onFocusChanged', [win.id]);
    refreshDefaultBrowser();
    publish();
  });
  win.on('blur', () => {
    if (extensionHost && activeProfile())
      extensionHost.api.publish(activeProfile().id, 'windows.onFocusChanged', [-1]);
    publish();
  });
  const fullscreenChanged = () => {
    // Native full-screen transitions can arrive before the renderer publishes
    // its matching layout. Preserve the 40px toolbar/Find reservation; otherwise
    // drop or restore the Windows caption rail immediately with the OS state.
    if (layout.contentTop !== 40)
      layout.contentTop = process.platform === 'darwin' || win.isFullScreen() ? 8 : 36;
    sizeShell();
    arrangeViews();
    const item = Menu.getApplicationMenu()?.getMenuItemById('fullscreen');
    if (item) item.label = win.isFullScreen() ? 'Exit Full Screen' : 'Enter Full Screen';
    publish();
  };
  win.on('enter-full-screen', fullscreenChanged);
  win.on('leave-full-screen', fullscreenChanged);
  win.on('close', (event) => {
    const hasPrivateSession =
      process.platform === 'darwin' && store.state.profiles.some((item) => item.private);
    if (!allowWindowClose && (views.size || peek || hasPrivateSession)) {
      event.preventDefault();
      if (closingWindow) return;
      closingWindow = true;
      (async () => {
        const candidates = [...views.values(), ...(peek ? [peek.entry] : [])];
        for (const entry of candidates) {
          if (!(await requestCloseEntry(entry))) {
            closingWindow = false;
            quitRequested = false;
            reconcile();
            if (externalURLs.length) setImmediate(() => drainExternalURLs().catch(report));
            return;
          }
        }
        if (peek?.entry.contents.isDestroyed()) peek = null;
        if (process.platform === 'darwin') await endPrivateSessions();
        allowWindowClose = true;
        if (validWindow()) win.close();
      })().catch((error) => {
        closingWindow = false;
        quitRequested = false;
        report(error);
        reconcile();
        if (externalURLs.length) setImmediate(() => drainExternalURLs().catch(report));
      });
      return;
    }
    rememberNormalBounds();
    // Persist outer bounds and restore them as outer bounds. Reinterpreting
    // rounded Windows client sizes as content sizes adds pixels every launch.
    store.state.windowBounds = { ...normalWindowBounds, sizeKind: 'window', maximized: win.isMaximized() };
    try {
      store.flush();
    } catch (error) {
      console.error('Session save failed:', error.message);
    }
  });
  win.on('closed', () => {
    clearTimeout(publishTimer);
    publishTimer = null;
    finishAuth();
    clearBackdrop();
    for (const entry of views.values()) destroyEntry(entry);
    views.clear();
    if (peek) {
      destroyEntry(peek.entry);
      peek = null;
    }
    win = null;
    updateMacMenu();
    splitTabId = null;
    splitPair = null;
    void ai?.handle('ai:cancel', {}).catch(() => {});
    if (quitRequested) setImmediate(() => app.quit());
    else if (process.platform === 'darwin' && externalURLs.length)
      setImmediate(() => drainExternalURLs().catch(report));
  });
  await win.loadFile(UI_FILE);
  if (bounds.maximized) win.maximize();
  win.show();
  reconcile();
}

// Register synchronously: Launch Services may deliver a link before ready.
app.on('open-url', (event, url) => {
  event.preventDefault();
  receiveExternalURL(url);
});
app.on('second-instance', (_event, argv) => {
  const urls = argv.filter((value) => webURL(value)).slice(0, 32);
  for (const url of urls) receiveExternalURL(url);
  if (!urls.length && startupReady) void ensureWindow().catch(report);
});
app.on('activate', () => {
  if (!startupReady) return;
  void ensureWindow().then(drainExternalURLs).catch(report);
});
app.on('certificate-error', (_event, _contents, _url, _error, _certificate, callback) => callback(false));
app.on('login', requestAuthentication);
app.on('web-contents-created', (_event, contents) =>
  contents.on('will-attach-webview', (event) => event.preventDefault()),
);
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('before-quit', (event) => {
  if (validWindow() && !allowWindowClose) {
    event.preventDefault();
    quitRequested = true;
    win.close();
  }
});
app.on('will-quit', () => {
  quitting = true;
  clearInterval(archiveTimer);
  clearTimeout(publishTimer);
  for (const item of liveDownloads.values()) item.cancel();
  finishAuth();
  ai?.close();
  syncAccount?.close();
  extensionHost?.close().catch(console.error);
  try {
    store?.flush();
  } catch (error) {
    console.error('Session save failed:', error.message);
  }
});
nativeTheme.on('updated', publish);

if (singleInstance)
  app
    .whenReady()
    .then(async () => {
      store = new BrowserStore(app.getPath('userData'));
      syncAccount = new SyncController({
        directory: path.join(app.getPath('userData'), 'sync'),
        getProfile: (id) => store.state.profiles.find((profile) => profile.id === id),
        activeProfile,
        getWindow: () => win,
        getPortableLibrary: (profile) => extensionHost?.portableLibrary(profile) || [],
        onStorageChange: (event) => extensionHost?.storageChanged(event),
        onLibraryChange: () => extensionHost?.refreshRemote(),
        publish,
      });
      await syncAccount.ready;
      extensionBrowser = createBrowserAdapter({
        store,
        views,
        getWindow: () => win,
        activeProfile,
        reserveView,
        ensureView,
        navigate: safeNavigate,
        closeTab: requestCloseTab,
        publish,
        reloadDocument: async (entry) => {
          try {
            await entry.contents.loadURL(entry.contents.getURL());
          } catch (error) {
            if (error.code !== 'ERR_ABORTED') throw error;
          }
        },
      });
      extensionHost = new ExtensionHost({
        root: managedExtensionRoot(),
        getProfile: (id) => store.state.profiles.find((profile) => profile.id === id),
        getProfiles: () => store.state.profiles,
        activeProfile,
        getSession: profileSession,
        getWindow: () => win,
        browser: extensionBrowser,
        panelChanged: () => {
          arrangeViews();
          publish();
        },
        syncClient: () => syncAccount.client,
        publish,
        report,
      });
      layout.sidebarWidth = store.state.settings.sidebarWidth || 224;
      for (const download of store.state.downloads)
        if (['progressing', 'interrupted'].includes(download.state)) {
          download.state = 'interrupted';
          download.paused = false;
        }
      try {
        const { AIService } = require('./ai.cjs');
        ai = new AIService({
          getState: () => store.state,
          getPageContext,
          emit: (event) => {
            emit(event);
            if (event.type !== 'ai:delta') publish();
          },
          userDataPath: app.getPath('userData'),
          openExternal: (url) => shell.openExternal(url),
        });
        await ai.ready;
      } catch (error) {
        console.error('AI initialization failed:', error.message);
      }
      store.on('change', reconcile);
      store.on('persistence-error', () =>
        toast('Your session could not be saved. Check free disk space and folder permissions.'),
      );
      registerIPC();
      buildMenu();
      refreshDefaultBrowser();
      await ensureWindow();
      if (store.recoveryWarning) toast(store.recoveryWarning);
      await extensionHost.start(store.state.extensions);
      store.state.extensions = [];
      store.changed();
      extensionsReady = true;
      reconcile();
      store.dispatch('tab:archive-stale', {
        excludeIds: [...views].filter(([, entry]) => !entry.dormant).map(([id]) => id),
      });
      archiveTimer = setInterval(
        () =>
          store.dispatch('tab:archive-stale', {
            excludeIds: [...views].filter(([, entry]) => !entry.dormant).map(([id]) => id),
          }),
        60_000,
      );
      startupReady = true;
      for (const url of process.argv.filter((value) => webURL(value)).slice(0, 32)) receiveExternalURL(url);
      await drainExternalURLs();
    })
    .catch((error) => {
      console.error(error);
      dialog.showErrorBox('Zacro could not start', error.message || 'An unexpected error occurred.');
      app.quit();
    });
