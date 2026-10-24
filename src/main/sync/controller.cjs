'use strict';
const path = require('node:path');
const fs = require('node:fs/promises');
const { app, safeStorage, dialog } = require('electron');
const { SyncClient } = require('./client.cjs');

class SyncController {
  constructor({
    directory,
    getProfile,
    activeProfile,
    getWindow,
    getPortableLibrary = () => [],
    onLibraryChange,
    onStorageChange,
    publish,
  }) {
    this.activeProfile = activeProfile;
    this.getWindow = getWindow;
    this.getPortableLibrary = getPortableLibrary;
    const available = () => {
      if (
        !safeStorage.isEncryptionAvailable() ||
        (process.platform === 'linux' && safeStorage.getSelectedStorageBackend() === 'basic_text')
      )
        throw new Error('OS credential protection is unavailable.');
    };
    this.client = new SyncClient({
      directory,
      getProfile,
      protect: (text) => {
        available();
        return safeStorage.encryptString(text);
      },
      unprotect: (bytes) => {
        available();
        return safeStorage.decryptString(bytes);
      },
      allowInsecureLoopback: !app.isPackaged && process.env.ZACRO_SYNC_DEV_LOOPBACK === '1',
      onLibraryChange,
      onStorageChange,
      onChange: publish,
    });
    this.ready =
      !this.client.status().endpoint && process.env.ZACRO_SYNC_URL
        ? this.client.configure({ endpoint: process.env.ZACRO_SYNC_URL })
        : Promise.resolve();
  }
  status() {
    const value = this.client.status();
    return this.activeProfile()?.private
      ? { endpoint: value.endpoint, account: null, device: null, profiles: [], state: 'private' }
      : value;
  }
  profileChanged() {
    this.client.invalidate();
    this.client.schedule(100);
  }
  async handle(action, payload) {
    await this.ready;
    if (action === 'sync:status') return this.status();
    const profile = this.activeProfile();
    if (!profile || profile.private)
      throw new Error('Account and synchronization controls are unavailable in private profiles.');
    if (payload.profileId && payload.profileId !== profile.id)
      throw new Error('The active profile changed. Open these controls again.');
    const epoch = this.client.epoch;
    const guard = () => {
      if (this.activeProfile()?.id !== profile.id)
        throw new Error('The active profile changed. Open these controls again.');
    };
    let result;
    switch (action) {
      case 'sync:configure':
        result = await this.client.configure({ endpoint: payload.endpoint });
        break;
      case 'sync:register':
      case 'sync:login':
        result = await this.client[action === 'sync:register' ? 'register' : 'login']({
          username: payload.username,
          password: payload.password,
          deviceName: payload.deviceName,
          platform: process.platform,
        });
        break;
      case 'sync:recover':
        result = await this.client.recover({
          username: payload.username,
          recoveryCode: payload.recoveryCode,
          newPassword: payload.newPassword,
          deviceName: payload.deviceName,
          platform: process.platform,
        });
        break;
      case 'sync:logout':
        result = await this.client.logout();
        break;
      case 'sync:devices':
        result = await this.client.devices();
        break;
      case 'sync:rename-device':
        result = await this.client.renameDevice(payload.id, payload.name);
        break;
      case 'sync:revoke-device':
        result = await this.client.revokeDevice(payload.id);
        break;
      case 'sync:password':
        result = await this.client.changePassword(payload.password, payload.newPassword);
        break;
      case 'sync:recovery-codes':
        result = await this.client.recoveryCodes(payload.password);
        break;
      case 'sync:delete-account':
        result = await this.client.deleteAccount(payload.password, payload.confirm);
        break;
      case 'sync:datasets':
        result = await this.client.datasets();
        break;
      case 'sync:create-dataset':
        result = await this.client.createDataset(payload.name);
        break;
      case 'sync:delete-dataset':
        result = await this.client.deleteDataset(payload.id, payload.password, payload.confirm);
        break;
      case 'sync:link-preview': {
        result = await this.client.previewLink({ profileId: profile.id, datasetId: payload.datasetId });
        guard();
        result.localExtensions = this.getPortableLibrary(profile.id);
        break;
      }
      case 'sync:link':
        result = await this.client.linkProfile({
          profileId: profile.id,
          datasetId: payload.datasetId,
          libraryChoice: payload.libraryChoice,
          localLibrary: this.getPortableLibrary(profile.id),
          settingsSync: payload.settingsSync === true,
          settingsChoice: payload.settingsChoice,
          settingsConsent: payload.settingsConsent === true,
        });
        break;
      case 'sync:unlink':
        result = await this.client.unlinkProfile(profile.id);
        break;
      case 'sync:settings':
        result = await this.client.setSettingsSync(profile.id, payload.enabled === true, {
          settingsChoice: payload.settingsChoice,
          settingsConsent: payload.settingsConsent === true,
        });
        break;
      case 'sync:now':
        result = await this.client.syncNow();
        break;
      case 'sync:retry':
        result = await this.client.retryRejected(profile.id, payload.id);
        break;
      case 'sync:discard':
        result = await this.client.discardRejected(profile.id, payload.id);
        break;
      case 'sync:export': {
        const data = this.client.exportRejected(profile.id, payload.id);
        const answer = await dialog.showSaveDialog(this.getWindow(), {
          title: 'Export unsynced extension settings',
          defaultPath: 'extension-settings.json',
          filters: [{ name: 'JSON', extensions: ['json'] }],
        });
        guard();
        this.client.guard(epoch);
        if (!answer.canceled && answer.filePath) {
          await fs.writeFile(path.resolve(answer.filePath), JSON.stringify(data, null, 2), { mode: 0o600 });
          result = { saved: true };
        } else result = { saved: false };
        break;
      }
      default:
        throw new Error('Unsupported synchronization action.');
    }
    guard();
    return result ?? null;
  }
  close() {
    this.client.close();
  }
}
module.exports = { SyncController };
