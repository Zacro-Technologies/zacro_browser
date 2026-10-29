'use strict';
// Pause only the real main-process AI teardown await. Storage, extension API,
// browser deletion, database transactions and network requests remain real.
const { AIService } = require('../../../src/main/ai.cjs');
const handle = AIService.prototype.handle;
AIService.prototype.handle = async function (action, payload) {
  if (action === 'ai:reset' && globalThis.pauseProfileDeletion) {
    globalThis.profileDeletionWaiting = true;
    await new Promise((resolve, reject) => {
      globalThis.releaseProfileDeletion = (fail = false) => {
        globalThis.pauseProfileDeletion = false;
        if (fail) reject(new Error('Synthetic AI teardown failure'));
        else resolve();
      };
    });
  }
  return handle.call(this, action, payload);
};
require('./sync-browser.cjs');
