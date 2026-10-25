'use strict';
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '../../..');
const directory = process.env.ZACRO_CONTEXT_ROOT;
app.setPath('userData', path.join(directory, 'userdata'));
app.on('window-all-closed', (event) => event.preventDefault());
app.whenReady().then(async () => {
  const sentinel = new BrowserWindow({ show: false });
  await sentinel.loadURL('about:blank');
  try {
    const { ExtensionManager } = require(path.join(root, 'src/main/extensions/manager.cjs'));
    const { ExtensionBridge } = require(path.join(root, 'src/main/extensions/bridge.cjs'));
    const kind = process.env.ZACRO_WORKER_KIND;
    const source = path.join(directory, 'source');
    await fs.mkdir(path.join(source, 'js'), { recursive: true });
    const manifest = JSON.stringify({
      manifest_version: 3,
      name: `Native root worker ${kind}`,
      version: '1',
      background: { service_worker: '/js/background.js', ...(kind === 'module' ? { type: 'module' } : {}) },
    });
    const script = `${kind === 'module' ? "import './dependency.js';" : "'use strict';\nimportScripts('./dependency.js');"}\nglobalThis.zacroExtension.invoke('probe', [globalThis.relativeDependency, (function(){return this})() === undefined, location.href, chrome.runtime.getManifest().background.service_worker]);`;
    await fs.writeFile(path.join(source, 'manifest.json'), manifest);
    await fs.writeFile(path.join(source, 'js/background.js'), script);
    await fs.writeFile(
      path.join(source, 'js/dependency.js'),
      'globalThis.relativeDependency = "genuine-relative-dependency";',
    );
    const ses = session.fromPartition('persist:root-worker');
    let manager, probe;
    const bridge = new ExtensionBridge({
      resolveExtension: (profile, id) => manager.resolveExtension(profile, id),
      dispatch: (context, method, args) => {
        if (method !== 'probe') throw new Error('Unexpected method');
        probe = { args, kind: context.kind, nativeSender: Boolean(context.sender), id: context.extensionId };
        return true;
      },
    });
    manager = new ExtensionManager({
      root: path.join(directory, 'managed'),
      getProfile: (id) => ({ id }),
      getSession: () => ses,
      prepareSession: (nativeSession, profile) => bridge.attachSession(nativeSession, profile),
      confirmPermissions: async () => true,
    });
    await manager.restore('one');
    const installed = await manager.installLocal('one', source);
    const deadline = Date.now() + 10000;
    while (!probe && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
    const original = manager.versionPath('one', installed.current, 'original');
    const native = ses.extensions.getAllExtensions().find((item) => item.id === installed.id);
    globalThis.workerResourceResult = {
      enabled: installed.enabled,
      id: installed.id,
      probe,
      nativePath: native.manifest.background.service_worker,
      derivedPath: installed.current.effectiveManifest.background.service_worker,
      sourceUnchanged:
        (await fs.readFile(path.join(source, 'manifest.json'), 'utf8')) === manifest &&
        (await fs.readFile(path.join(source, 'js/background.js'), 'utf8')) === script,
      managedOriginalUnchanged:
        (await fs.readFile(path.join(original, 'manifest.json'), 'utf8')) === manifest &&
        (await fs.readFile(path.join(original, 'js/background.js'), 'utf8')) === script,
      versions: process.versions,
    };
    await manager.close();
    bridge.close();
  } catch (error) {
    globalThis.workerResourceResult = { error: error.stack };
  }
});
