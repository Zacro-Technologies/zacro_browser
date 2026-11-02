'use strict';
// Real profile-retirement checks in the disposable MV3 worker.
// The harness sets the profile's real download directory to its owned temp
// folder before invoking this module; production download defaults are intact.
globalThis.zacroDownloadRetirementFixture = (() => {
  const owned = new Map();
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function state(id) {
    assert(owned.has(id), 'Refusing an unowned download ID');
    const values = await chrome.downloads.search({id});
    assert(values.length === 1, 'Owned worker download disappeared');
    return values[0];
  }
  async function until(id, accept, description) {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const value = await state(id);
      if (accept(value)) return value;
      await pause(40);
    }
    throw new Error(description);
  }
  async function start(baseURL) {
    const url = new URL('/download', baseURL);
    assert(url.protocol === 'http:' && url.hostname === '127.0.0.1', 'Only owned loopback downloads are allowed');
    url.searchParams.set('fixture', crypto.randomUUID());
    const filename = `zacro-native-retirement-${crypto.randomUUID()}.bin`;
    const id = await chrome.downloads.download({url: url.href, filename, saveAs: false, conflictAction: 'uniquify'});
    owned.set(id, filename);
    return {id, filename, url: url.href};
  }
  async function verifyStreaming(id) {
    return until(id, value => value.state === 'in_progress' && value.bytesReceived > 0,
      'A real MV3 worker download did not receive bytes');
  }
  async function pauseAndVerify(id) {
    await chrome.downloads.pause(id);
    const first = await until(id, value => value.state === 'in_progress' && value.paused, 'Pause was not retained');
    await pause(150);
    const after = await state(id);
    assert(after.paused && after.state === 'in_progress', 'Paused worker item was cancelled by missing CEF browser');
    return {before: first.bytesReceived, after: after.bytesReceived};
  }
  async function resumeAndVerify(id) {
    const first = await state(id);
    await chrome.downloads.resume(id);
    return until(id, value => value.bytesReceived > first.bytesReceived || value.state === 'complete',
      'Native worker download did not resume');
  }
  async function verifyRetired(id) {
    const value = await until(id, value => value.state === 'interrupted' && value.error === 'USER_CANCELED',
      'Retirement did not cancel the browserless native item');
    assert(!value.canResume, 'Retired native item remains resumable');
    return value;
  }
  async function verifyFutureDownloadCancelled(baseURL) {
    const value = await start(baseURL);
    return verifyRetired(value.id);
  }
  async function cleanup(ownedDirectory) {
    assert(typeof ownedDirectory === 'string' && ownedDirectory.startsWith('/') && ownedDirectory.length > 1,
      'The harness must provide its exact owned download directory');
    const prefix = ownedDirectory.replace(/\/$/, '') + '/';
    for (const [id, name] of owned) {
      let values = await chrome.downloads.search({id});
      if (!values.length) { owned.delete(id); continue; }
      let value = values[0];
      if (value.state === 'in_progress') { await chrome.downloads.cancel(id); value = await state(id); }
      if (value.state === 'complete' && value.exists) {
        assert(value.filename.startsWith(prefix) && !value.filename.slice(prefix.length).includes('/'),
          'Refusing to remove a download outside the exact fixture directory');
        const basename = value.filename.slice(prefix.length);
        assert(basename === name || basename.startsWith(name.slice(0, -4) + ' (') && /^.* \(\d+\)\.bin$/.test(basename),
          'Refusing to remove a nonfixture filename');
        await chrome.downloads.removeFile(id);
      }
      await chrome.downloads.erase({id}); owned.delete(id);
    }
    return true;
  }
  return {start, state, verifyStreaming, pauseAndVerify, resumeAndVerify,
    verifyRetired, verifyFutureDownloadCancelled, cleanup};
})();
