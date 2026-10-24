'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
for (const kind of ['mv2', 'classic', 'module'])
  test(
    `native ${kind} browser facade preserves callbacks storage and authenticated contexts`,
    { timeout: 45000 },
    async (t) => {
      const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-api-'));
      const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory, ZACRO_CONTEXT_KIND: kind };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({
        args: [path.resolve(__dirname, '../fixtures/extensions/api-host.cjs')],
        env,
      });
      t.after(async () => {
        await app.close();
        await fs.rm(directory, { recursive: true, force: true });
      });
      await expect.poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 20000 }).toBeTruthy();
      const result = await app.evaluate(() => globalThis.contextResult);
      t.diagnostic(JSON.stringify(result));
      assert.equal(result.error, undefined);
      for (const label of ['page', 'background', 'content']) {
        assert.equal(result.reports[label]?.got, 42, label);
        assert.equal(result.reports[label]?.callback, 42, label);
        assert.equal(result.reports[label]?.invalid, true, label);
        assert.match(result.reports[label]?.error, /quota/i);
      }
      assert.equal(result.tabs.length, 1);
      assert.equal(result.tabs[0].id, result.pageId);
      if (kind === 'mv2') {
        const availability = await app.evaluate(() =>
          globalThis.apiFixture.frame.webContents.executeJavaScript(
            `({scripting:typeof chrome.scripting,executeScript:typeof chrome.scripting?.executeScript,registerContentScripts:typeof chrome.scripting?.registerContentScripts})`,
          ),
        );
        t.diagnostic(JSON.stringify({ availability }));
        return;
      }
      const extra = await app.evaluate(async () => {
        const { frame, page, record, bridge } = globalThis.apiFixture;
        const tabId = page.webContents.id;
        const dynamic = await frame.webContents
          .executeJavaScript(
            `chrome.scripting.executeScript({target:{tabId:${tabId}},func:async()=>{await chrome.storage.sync.set({dynamic:123});return (await chrome.storage.sync.get('dynamic')).dynamic;}})`,
          )
          .catch((error) => ({ error: error.message }));
        const mainWorld = await frame.webContents
          .executeJavaScript(
            `chrome.scripting.executeScript({target:{tabId:${tabId}},world:'MAIN',func:()=>typeof zacroExtension})`,
          )
          .catch((error) => ({ error: error.message }));
        const events = await frame.webContents.executeJavaScript(
          `(async()=>{const local=[];const listener=(changes,area)=>local.push(area);chrome.storage.onChanged.addListener(listener);const has=chrome.storage.onChanged.hasListener(listener);await chrome.storage.local.set({nativeLocal:true});await chrome.storage.sync.set({eventValue:1});await new Promise(resolve=>setTimeout(resolve,100));chrome.storage.onChanged.removeListener(listener);const removed=!chrome.storage.onChanged.hasListener(listener);return {local,has,removed,native:(await chrome.storage.local.get('nativeLocal')).nativeLocal,sync:(await chrome.storage.sync.get('nativeLocal')).nativeLocal};})()`,
        );
        const nativeMessage = await frame.webContents.executeJavaScript(
          `chrome.runtime.sendMessage('native')`,
        );
        await frame.webContents.executeJavaScript(
          `chrome.scripting.registerContentScripts([{id:'dynamic-registered',matches:['http://127.0.0.1/*'],js:['registered.js'],persistAcrossSessions:false}])`,
        );
        const registered = await frame.webContents.executeJavaScript(
          `chrome.scripting.getRegisteredContentScripts()`,
        );
        await page.loadURL(page.webContents.getURL() + 'registered');
        let registeredValue;
        for (let i = 0; i < 100; i++) {
          registeredValue = await frame.webContents.executeJavaScript(
            `chrome.storage.sync.get('registeredExecuted')`,
          );
          if (registeredValue.registeredExecuted) break;
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        await frame.webContents.executeJavaScript(
          `chrome.scripting.executeScript({target:{tabId:${tabId}},func:()=>{globalThis.accessEvents=[];chrome.storage.sync.onChanged.addListener(changes=>globalThis.accessEvents.push(Object.keys(changes)));}})`,
        );
        await frame.webContents.executeJavaScript(
          `chrome.storage.sync.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});`,
        );
        await frame.webContents.executeJavaScript(`chrome.storage.sync.set({trustedOnly:1})`);
        const restricted = await frame.webContents.executeJavaScript(
          `chrome.scripting.executeScript({target:{tabId:${tabId}},func:async()=>{let denied=false;try{await chrome.storage.sync.get(null)}catch{denied=true}return {denied,events:globalThis.accessEvents};}})`,
        );
        return { dynamic, mainWorld, events, nativeMessage, registered, registeredValue, restricted };
      });
      t.diagnostic(JSON.stringify(extra));
      assert.equal(extra.dynamic[0]?.result, 123, 'programmatic isolated injection facade');
      assert.equal(extra.mainWorld[0]?.result, 'undefined', 'main world unprivileged');
      assert.deepEqual(extra.events.local.sort(), ['local', 'sync']);
      assert.equal(extra.events.has, true);
      assert.equal(extra.events.removed, true);
      assert.equal(extra.events.native, true);
      assert.equal(extra.events.sync, undefined);
      assert.equal(extra.nativeMessage, 'native-reply');
      assert.deepEqual(extra.registered[0].js, ['zacro-compat-bootstrap.js', 'registered.js']);
      assert.equal(extra.registeredValue.registeredExecuted, true);
      assert.equal(extra.restricted[0].result.denied, true);
      assert.deepEqual(extra.restricted[0].result.events, []);
      if (kind === 'classic' || kind === 'module') {
        const lifecycle = await app.evaluate(async () => {
          const { frame, page, record } = globalThis.apiFixture;
          const ses = frame.webContents.session;
          const statuses = [];
          ses.serviceWorkers.on('running-status-changed', (event) =>
            statuses.push({ versionId: event.versionId, status: event.runningStatus }),
          );
          frame.webContents.debugger.attach('1.3');
          await frame.webContents.debugger.sendCommand('ServiceWorker.enable');
          await frame.webContents.debugger.sendCommand('ServiceWorker.stopAllWorkers');
          const until = Date.now() + 5000;
          while (Object.keys(ses.serviceWorkers.getAllRunning()).length && Date.now() < until)
            await new Promise((resolve) => setTimeout(resolve, 20));
          const stopped = Object.keys(ses.serviceWorkers.getAllRunning()).length === 0;
          delete globalThis.apiFixture.reports.background;
          globalThis.apiFixture.events.length = 0;
          globalThis.apiFixture.bridge.emit('p1', record.id, 'commands.onCommand', ['wake']);
          globalThis.apiFixture.store.call(record.id, 'set', [{ wakeKey: 7 }], { trusted: true });
          const deadline = Date.now() + 5000;
          while (
            (!globalThis.apiFixture.reports.background || globalThis.apiFixture.events.length < 2) &&
            Date.now() < deadline
          )
            await new Promise((resolve) => setTimeout(resolve, 20));
          frame.webContents.debugger.detach();
          return {
            stopped,
            statuses,
            report: globalThis.apiFixture.reports.background,
            events: globalThis.apiFixture.events,
          };
        });
        t.diagnostic(JSON.stringify({ lifecycle }));
        assert.equal(lifecycle.stopped, true);
        assert.equal(lifecycle.report?.got, 42);
        assert.deepEqual(lifecycle.events, [
          ['command', 'wake'],
          ['sync', 7],
        ]);
        const frames = await app.evaluate(async () => {
          const { frame, page } = globalThis.apiFixture,
            tabId = page.webContents.id;
          await frame.webContents.executeJavaScript(
            `chrome.storage.sync.setAccessLevel({accessLevel:'TRUSTED_AND_UNTRUSTED_CONTEXTS'})`,
          );
          await page.webContents.executeJavaScript(
            `new Promise(resolve=>{const child=document.createElement('iframe');child.src='/child';child.onload=resolve;document.body.append(child);})`,
          );
          const normal = await frame.webContents.executeJavaScript(
            `chrome.scripting.executeScript({target:{tabId:${tabId},allFrames:true},func:async()=>{try{return {url:location.href,value:(await chrome.storage.sync.get('dynamic')).dynamic}}catch(error){return {url:location.href,error:error.message}}}})`,
          );
          await page.webContents.executeJavaScript(
            `new Promise(resolve=>{const child=document.createElement('iframe');child.sandbox='allow-scripts';child.srcdoc='<p>opaque</p>';child.onload=resolve;document.body.append(child);})`,
          );
          const opaque = await frame.webContents
            .executeJavaScript(
              `chrome.scripting.executeScript({target:{tabId:${tabId},allFrames:true},func:async()=>{try{return {url:location.href,value:(await chrome.storage.sync.get('dynamic')).dynamic}}catch(error){return {url:location.href,error:error.message}}}})`,
            )
            .catch((error) => ({ error: error.message }));
          return { normal, opaque };
        });
        t.diagnostic(JSON.stringify({ frames }));
        assert.equal(frames.normal.length, 2);
        assert.equal(frames.normal[0].result.value, 123, 'parent facade survives child navigation');
        assert.equal(frames.normal[1].result.value, 123, 'subframe has authenticated facade');
        const opaqueResult = frames.opaque.find((entry) => entry.result?.url === 'about:srcdoc');
        assert.match(opaqueResult.result.error, /transport unavailable/);
        assert.equal(frames.opaque[0].result.value, 123);
        assert.equal(frames.opaque.find((entry) => entry.result?.url.endsWith('/child')).result.value, 123);
        const teardown = await app.evaluate(async () => {
          const { frame, page, record, bridge } = globalThis.apiFixture;
          const broker = [...bridge.sessions.values()][0].brokers.get(record.id);
          broker.destroy();
          const content = await frame.webContents.executeJavaScript(
            `chrome.scripting.executeScript({target:{tabId:${page.webContents.id}},func:async()=>{try{await chrome.storage.sync.get(null);return 'unexpected'}catch(error){return error.message}}})`,
          );
          bridge.close();
          const direct = await frame.webContents.executeJavaScript(
            `chrome.storage.sync.get(null).then(()=> 'unexpected',error=>error.message)`,
          );
          return { content, direct };
        });
        assert.match(teardown.content[0].result, /disconnected|context|transport/i);
        assert.match(teardown.direct, /handler|closed|context/i);
      }
    },
  );
test(
  'native optional host grant and revocation rebuild scripting and fetch rights without losing drafts',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-permissions-'));
    const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/permission-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect.poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 20000 }).toBeTruthy();
    const result = await app.evaluate(() => globalThis.contextResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.ok(result.before.injected.error);
    assert.ok(result.before.network.error);
    assert.equal(result.granted.injected[0].result, 'unsaved');
    assert.equal(result.granted.network, 42);
    assert.deepEqual(result.narrowManifest, ['http://127.0.0.1/*']);
    assert.equal(result.restored.injected[0].result, 'unsaved');
    assert.equal(result.restored.network, 42);
    for (const probe of [result.unrelatedGranted, result.unrelatedRestored, result.unrelatedRemoved]) {
      assert.ok(probe.injected.error, 'declaration alone must not grant scripting on another host');
      assert.ok(probe.network.error, 'declaration alone must not grant fetch on another host');
    }
    assert.equal(result.pending.enabled, false);
    assert.equal(result.pending.status, 'pending-reload');
    assert.equal(result.pending.enableDenied, true);
    assert.equal(result.pending.nativeLoaded, false);
    assert.equal(result.pending.draft, 'draft remains');
    assert.ok(result.removed.injected.error);
    assert.ok(result.removed.network.error);
    assert.deepEqual(result.effective.host_permissions, []);
    assert.deepEqual(result.effective.optional_host_permissions, []);
  },
);

for (const cancellation of ['filter', 'disable', 'profile', 'trusted', 'expiry'])
  test(
    `R1 pending native worker notifications recheck ${cancellation} at authenticated readiness`,
    { timeout: 30000 },
    async (t) => {
      const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-wake-guard-'));
      const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory, ZACRO_CONTEXT_KIND: 'classic' };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({
        args: [path.resolve(__dirname, '../fixtures/extensions/api-host.cjs')],
        env,
      });
      t.after(async () => {
        await app.close();
        await fs.rm(directory, { recursive: true, force: true });
      });
      await expect.poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 15000 }).toBeTruthy();
      const result = await app.evaluate(async (_electron, cancellation) => {
        const f = globalThis.apiFixture,
          ses = f.frame.webContents.session;
        if (cancellation === 'trusted') {
          await f.frame.webContents.executeJavaScript(
            `chrome.scripting.executeScript({target:{tabId:${f.page.webContents.id}},func:()=>{globalThis.pendingAccess=[];chrome.storage.sync.onChanged.addListener(changes=>globalThis.pendingAccess.push(Object.keys(changes)));}})`,
          );
          await new Promise((r) => setTimeout(r, 100));
        }
        f.frame.webContents.debugger.attach('1.3');
        await f.frame.webContents.debugger.sendCommand('ServiceWorker.enable');
        await f.frame.webContents.debugger.sendCommand('ServiceWorker.stopAllWorkers');
        const stopDeadline = Date.now() + 5000;
        while (Object.keys(ses.serviceWorkers.getAllRunning()).length && Date.now() < stopDeadline)
          await new Promise((r) => setTimeout(r, 20));
        const stopped = Object.keys(ses.serviceWorkers.getAllRunning()).length === 0;
        let release,
          waiting = false,
          allowed = true;
        const blocked = new Promise((resolve) => (release = resolve)),
          original = f.bridge.handle.bind(f.bridge),
          errors = [];
        f.bridge.onError = (error, context) => errors.push({ message: error.message, event: context.event });
        f.bridge.handle = async (event, request) => {
          if (event.type === 'service-worker' && request.method === 'zacro.events.subscribe') {
            waiting = true;
            await blocked;
          }
          return original(event, request);
        };
        f.events.length = 0;
        let checks = 0;
        f.bridge.emit('p1', f.record.id, 'commands.onCommand', ['pending'], {
          filter: () => {
            checks++;
            return allowed;
          },
        });
        const readyDeadline = Date.now() + 5000;
        while (!waiting && Date.now() < readyDeadline) await new Promise((r) => setTimeout(r, 20));
        const before = f.events.slice();
        if (cancellation === 'filter') {
          // A changed source/link/access policy must be evaluated at actual delivery.
          allowed = false;
          for (let index = 0; index < 130; index++)
            f.bridge.emit('p1', f.record.id, 'commands.onCommand', ['bounded'], { filter: () => allowed });
        } else if (cancellation === 'trusted') {
          f.store.call(f.record.id, 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }], {
            trusted: true,
          });
          f.store.call(f.record.id, 'set', [{ wakeKey: 91 }], { trusted: true });
        } else if (cancellation === 'expiry') await new Promise((r) => setTimeout(r, 10200));
        else if (cancellation === 'disable') await f.manager.disable('p1', f.record.id);
        else await f.manager.invalidateProfile('p1');
        release();
        await new Promise((r) => setTimeout(r, 250));
        const after = f.events.slice(),
          queues = [...f.bridge.sessions.values()]
            .flatMap((e) => [...e.backgrounds.values()])
            .reduce((n, s) => n + s.queue.length, 0);
        f.frame.webContents.debugger.detach();
        const contentEvents =
          cancellation === 'trusted'
            ? await f.frame.webContents.executeJavaScript(
                `chrome.scripting.executeScript({target:{tabId:${f.page.webContents.id}},func:()=>globalThis.pendingAccess})`,
              )
            : null;
        return { stopped, waiting, before, after, queues, checks, errors, contentEvents };
      }, cancellation);
      t.diagnostic(JSON.stringify(result));
      assert.equal(result.stopped, true);
      assert.equal(result.waiting, true, 'native wake must reach fresh authenticated subscription');
      assert.deepEqual(result.before, []);
      assert.deepEqual(
        result.after,
        cancellation === 'trusted'
          ? [
              ['command', 'pending'],
              ['sync', 91],
            ]
          : [],
      );
      if (cancellation === 'trusted') assert.deepEqual(result.contentEvents[0].result, []);
      if (cancellation === 'expiry') assert.match(result.errors[0]?.message, /deadline/);
      assert.equal(result.queues, 0);
      if (cancellation === 'filter') {
        assert.equal(result.checks, 1, 'filter runs only at delivery');
        assert.equal(result.errors.length, 3, '128-event queue reports overflow without unbounded retention');
        assert.ok(result.errors.every((error) => /queue limit/.test(error.message)));
      }
    },
  );
