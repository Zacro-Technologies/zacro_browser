'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
for (const context of ['page', 'content'])
  for (const mode of ['immediate', 'gated'])
    test(
      `F1 live ${context} listener receives ${mode} sync events before subscription snapshot`,
      { timeout: 20000 },
      async (t) => {
        const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-live-event-'));
        const env = {
          ...process.env,
          ZACRO_CONTEXT_ROOT: directory,
          ZACRO_CONTEXT_KIND: 'classic',
          ZACRO_LIVE_EVENTS_PROBE: '1',
        };
        delete env.ELECTRON_RUN_AS_NODE;
        const app = await electron.launch({
          args: [path.resolve(__dirname, '../fixtures/extensions/api-host.cjs')],
          env,
        });
        t.after(async () => {
          await app.close();
          await fs.rm(directory, { recursive: true, force: true });
        });
        await expect
          .poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 10000 })
          .toBeTruthy();
        assert.equal((await app.evaluate(() => globalThis.contextResult)).error, undefined);
        if (mode === 'gated')
          await app.evaluate(() => {
            const f = globalThis.apiFixture,
              handle = f.bridge.handle.bind(f.bridge);
            f.subscriptionGate = new Promise((resolve) => (f.releaseSubscription = resolve));
            f.bridge.handle = async (event, request) => {
              if (event.type !== 'service-worker' && request.method === 'zacro.events.subscribe') {
                f.subscriptionWaiting = true;
                await f.subscriptionGate;
              }
              return handle(event, request);
            };
          });
        // Registration and the first write happen together in the same native
        // extension execution, with no preceding storage write, timer, or await.
        await app.evaluate(
          async (_electron, { context, mode }) => {
            const f = globalThis.apiFixture;
            const listener = `async function(mode){chrome.storage.sync.onChanged.addListener(changes=>{for(const key of ['liveFirst','liveRestricted'])if(changes[key])zacroExtension.invoke('test.liveEvent',[key,changes[key].newValue]);});if(mode==='immediate')await chrome.storage.sync.set({liveFirst:42});}`;
            const source =
              context === 'page'
                ? `(${listener})(${JSON.stringify(mode)})`
                : `chrome.scripting.executeScript({target:{tabId:${f.page.webContents.id}},func:${listener},args:[${JSON.stringify(mode)}]})`;
            return f.frame.webContents.executeJavaScript(source);
          },
          { context, mode },
        );
        if (mode === 'gated') {
          await expect
            .poll(() => app.evaluate(() => globalThis.apiFixture.subscriptionWaiting), { timeout: 3000 })
            .toBe(true);
          await app.evaluate(() => {
            const f = globalThis.apiFixture;
            f.store.call(f.record.id, 'set', [{ liveFirst: 42 }], { trusted: true });
          });
        }
        await expect
          .poll(() => app.evaluate(() => globalThis.apiFixture.liveEvents), { timeout: 2000 })
          .toEqual([['liveFirst', 42]]);
        await app.evaluate(() => {
          const f = globalThis.apiFixture;
          f.store.call(f.record.id, 'setAccessLevel', [{ accessLevel: 'TRUSTED_CONTEXTS' }], {
            trusted: true,
          });
          f.store.call(f.record.id, 'set', [{ liveRestricted: 43 }], { trusted: true });
        });
        if (context === 'page')
          await expect
            .poll(() => app.evaluate(() => globalThis.apiFixture.liveEvents), { timeout: 2000 })
            .toEqual([
              ['liveFirst', 42],
              ['liveRestricted', 43],
            ]);
        // A native round trip after delivery drains the earlier IPC; no delayed
        // foreground subscription may bypass the current trusted-only policy.
        await app.evaluate(async () => {
          const f = globalThis.apiFixture;
          f.releaseSubscription?.();
          await f.frame.webContents.executeJavaScript('chrome.storage.sync.get(null)');
          await new Promise((resolve) => setTimeout(resolve, 100));
        });
        const events = await app.evaluate(() => globalThis.apiFixture.liveEvents);
        t.diagnostic(JSON.stringify({ context, mode, events }));
        assert.deepEqual(
          events,
          context === 'page'
            ? [
                ['liveFirst', 42],
                ['liveRestricted', 43],
              ]
            : [['liveFirst', 42]],
        );
      },
    );
