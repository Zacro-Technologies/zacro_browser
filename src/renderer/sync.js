export function createSyncUI({
  getState,
  getProfile,
  invoke,
  esc,
  field,
  primary,
  secondary,
  button,
  formDialog,
  openDialog,
  closeDialog,
  toast,
}) {
  let serial = 0;
  const status = () => getState().sync || { profiles: [], state: 'setup-required' };
  const link = () => status().profiles.find((p) => p.profileId === getProfile()?.id);
  const call = (action, payload = {}, profileId = getProfile()?.id) =>
    invoke('sync:' + action, { ...payload, profileId });
  const options = `<label class="field">Choose settings<select name="settingsChoice"><option value="use-remote">Use settings from the sync profile</option><option value="upload-local">Upload settings from this device</option></select></label>`;
  const consent = `<label class="setting-toggle"><span>Sync extension settings</span><input type="checkbox" name="settingsSync" aria-label="Sync extension settings"></label><p class="provider-note">Extensions choose what they save. Settings may contain personal information or credentials. The synchronization service can read these values. Enabling this option means you agree to share them with your configured service.</p>${options}`;
  function form(title, description, fields, label, submit, danger = false) {
    const profileId = getProfile()?.id,
      token = serial;
    formDialog(
      title,
      description,
      `<div data-sync-dialog>${fields}</div>`,
      label,
      async (data, context) => {
        const current = () => token === serial && getProfile()?.id === profileId && context.isCurrent();
        if (!current()) return;
        await submit(data, { ...context, isCurrent: current, profileId });
      },
      { danger },
    );
  }
  function display(title, html) {
    openDialog(
      'form',
      `<div data-sync-dialog><div class="dialog-header"><h2>${esc(title)}</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body">${html}</div></div>`,
      { title, focus: 'button' },
    );
  }
  function recovery(codes) {
    display(
      'Save your recovery codes',
      `<p>Store these codes somewhere private. Each code can be used once to recover your account. They will disappear when you close this window.</p><div class="recovery-codes">${codes.map((code) => `<code>${esc(code)}</code>`).join('')}</div>${primary('ui:dialog-close', 'I saved my recovery codes')}`,
    );
  }
  async function review(datasetId, token = serial, profileId = getProfile()?.id) {
    const preview = await call('link-preview', { datasetId }, profileId);
    if (token !== serial || profileId !== getProfile()?.id) return;
    const local = preview.localExtensions || [],
      remote = preview.extensions.filter((e) => e.state !== 'removed');
    form(
      'Review profile link',
      `Link ${getProfile().name} to “${preview.dataset.name}”. New extensions still require permission on this device.`,
      `<p>${remote.length} extensions in the sync profile; ${local.length} portable extensions on this device.</p>${remote.length ? `<ul>${remote.map((e) => `<li>${esc(e.name || e.extensionId)} · ${esc(e.state)}</li>`).join('')}</ul>` : ''}<label class="field">Extension library<select name="libraryChoice"><option value="remote-only">Use the sync profile’s library</option><option value="merge-local">Also share this device’s portable extensions</option></select></label>${consent}`,
      'Link this profile',
      async (data, context) => {
        const settingsSync = data.get('settingsSync') === 'on';
        await call(
          'link',
          {
            datasetId,
            libraryChoice: data.get('libraryChoice'),
            settingsSync,
            settingsConsent: settingsSync,
            settingsChoice: data.get('settingsChoice'),
          },
          context.profileId,
        );
        if (context.isCurrent()) context.close();
      },
    );
  }
  async function devices() {
    const token = serial,
      profileId = getProfile()?.id;
    const list = await call('devices', {}, profileId);
    if (token !== serial || profileId !== getProfile()?.id) return;
    display(
      'Your devices',
      `<p>Revoking a device stops its future synchronization. Files already downloaded remain on that device.</p>${list.map((d) => `<article class="sync-device"><strong>${esc(d.name)}</strong><p class="small muted">${esc(d.platform)}${d.id === status().device?.id ? ' · This device' : ''}${d.revoked ? ' · Revoked' : ''}</p>${!d.revoked ? `<div class="setting-actions">${secondary('ui:sync-rename-device', 'Rename', '', `data-id="${esc(d.id)}" data-name="${esc(d.name)}"`)}${secondary('ui:sync-revoke-device', 'Revoke', '', `data-id="${esc(d.id)}"`)}</div>` : ''}</article>`).join('')}`,
    );
  }
  return {
    profileChanged() {
      serial++;
      if (document.querySelector('[data-sync-dialog]')) closeDialog();
    },
    render() {
      if (getProfile()?.private)
        return `<details class="setting-section" id="account-sync"><summary>Account & sync</summary><p>Private profiles do not use extensions or synchronization.</p></details>`;
      const s = status(),
        current = link();
      const labels = {
        'setup-required': 'Set up a synchronization service',
        'signed-out': 'Signed out',
        connected: 'Connected',
        offline: 'Offline — changes remain on this device',
        conflict: 'Some changes need attention',
        'reconnect-required': 'Sign in again to reconnect this device',
        'dataset-removed': 'The sync profile was removed',
      };
      let html = `<p class="sync-state" role="status">${esc(labels[s.state] || s.state)}</p>${s.endpoint ? `<p class="small muted sync-endpoint">${esc(s.endpoint)}</p>` : ''}<div class="setting-actions">${secondary('ui:sync-configure', 'Configure service')}</div>`;
      if (s.endpoint && !s.account)
        html += `<div class="setting-actions">${primary('ui:sync-register', 'Create account')}${secondary('ui:sync-login', 'Sign in')}${secondary('ui:sync-recover', 'Recover account')}</div>`;
      if (s.account) {
        html += `<p>Signed in as <strong>${esc(s.account.username)}</strong></p><div class="setting-actions">${secondary('ui:sync-devices', 'Devices')}${secondary('ui:sync-now', 'Sync now')}${secondary('ui:sync-logout', 'Sign out')}</div>`;
        html += current
          ? `<p><strong>${esc(current.name)}</strong> is linked to this profile.</p><p class="small muted">${current.pending ? 'Changes are waiting to be accepted by the service.' : current.lastSync ? `Last synchronized ${esc(new Date(current.lastSync).toLocaleString())}` : 'Waiting for the first synchronization.'}</p><div class="setting-actions">${secondary('ui:sync-settings', current.settingsSync ? 'Turn off settings sync' : 'Enable settings sync')}${secondary('ui:sync-unlink', 'Unlink profile')}${secondary('ui:sync-delete-dataset', 'Delete cloud profile')}</div>`
          : `<p>This browser profile is not linked. Local extensions keep working.</p>${primary('ui:sync-link', 'Link profile')}`;
        if (current?.rejected.length)
          html += `<div class="sync-rejections">${current.rejected.map((r) => `<article><p>${r.code === 'storage_quota' ? 'Settings could not fit in cloud storage. Your local values are retained.' : 'A change conflicts with the current sync profile.'}</p><div class="setting-actions">${secondary('ui:sync-retry', 'Retry', '', `data-id="${esc(r.id)}"`)}${secondary('ui:sync-export', 'Export', '', `data-id="${esc(r.id)}"`)}${secondary('ui:sync-discard', 'Discard', '', `data-id="${esc(r.id)}"`)}</div></article>`).join('')}</div>`;
        html += `<div class="setting-actions">${secondary('ui:sync-password', 'Change password')}${secondary('ui:sync-codes', 'Recovery codes')}${secondary('ui:sync-delete-account', 'Delete account')}</div>`;
      }
      return `<details class="setting-section" id="account-sync"><summary>Account & sync</summary>${html}</details>`;
    },
    async handle(action, data) {
      const name = action.slice('ui:sync-'.length);
      if (name === 'configure') {
        form(
          'Synchronization service',
          'Enter the HTTPS address of a service you trust. Changing it signs out this device. Development builds can explicitly allow local HTTP.',
          field('endpoint', 'Service URL', status().endpoint || '', 'url', 'required autocomplete="off"'),
          'Save service',
          async (data, context) => {
            await call('configure', { endpoint: data.get('endpoint') }, context.profileId);
            if (context.isCurrent()) context.close();
          },
        );
      } else if (name === 'register' || name === 'login' || name === 'recover') {
        const recovering = name === 'recover',
          creating = name === 'register';
        const title = recovering ? 'Recover account' : creating ? 'Create account' : 'Sign in';
        form(
          title,
          recovering
            ? 'Use one unused recovery code. This replaces your password, recovery codes and previous device sessions.'
            : 'Use a username and a password of at least 12 characters. No email account is required.',
          field(
            'username',
            'Username',
            '',
            'text',
            'required minlength="3" maxlength="64" autocomplete="username" autocapitalize="none"',
          ) +
            (recovering
              ? field('recoveryCode', 'Recovery code', '', 'password', 'required autocomplete="off"')
              : '') +
            field(
              recovering ? 'newPassword' : 'password',
              recovering ? 'New password' : 'Password',
              '',
              'password',
              `required minlength="12" maxlength="256" autocomplete="${creating || recovering ? 'new-password' : 'current-password'}"`,
            ) +
            field('deviceName', 'Device name', 'My computer', 'text', 'required maxlength="128"'),
          title,
          async (data, context) => {
            const result = await call(name, Object.fromEntries(data), context.profileId);
            if (!context.isCurrent()) return;
            context.close();
            if (result.recoveryCodes) recovery(result.recoveryCodes);
          },
        );
      } else if (name === 'devices') await devices();
      else if (name === 'rename-device')
        form(
          'Rename device',
          '',
          field('name', 'Device name', data.name, 'text', 'required maxlength="128"'),
          'Rename device',
          async (d, context) => {
            await call('rename-device', { id: data.id, name: d.get('name') }, context.profileId);
            if (context.isCurrent()) {
              context.close();
              await devices();
            }
          },
        );
      else if (name === 'revoke-device')
        form(
          'Revoke device?',
          'This device will need to sign in again. Previously downloaded data cannot be erased remotely.',
          '',
          'Revoke device',
          async (_d, context) => {
            await call('revoke-device', { id: data.id }, context.profileId);
            if (context.isCurrent()) context.close();
          },
          true,
        );
      else if (name === 'link') {
        const token = serial,
          profileId = getProfile()?.id,
          datasets = await call('datasets', {}, profileId);
        if (token !== serial || profileId !== getProfile()?.id) return;
        form(
          'Link browser profile',
          'Create a new sync profile or review one already owned by your account.',
          `${datasets.length ? `<label class="field">Existing sync profile<select id="sync-dataset-choice">${datasets.map((d) => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join('')}</select></label>${secondary('ui:sync-join-choice', 'Review selected profile')}` : ''}${field('name', 'New sync profile name', '', 'text', 'required maxlength="128"')}`,
          'Create sync profile',
          async (d, context) => {
            const dataset = await call('create-dataset', { name: d.get('name') }, context.profileId);
            if (context.isCurrent()) await review(dataset.id, token, profileId);
          },
        );
      } else if (name === 'join-choice') await review(document.querySelector('#sync-dataset-choice').value);
      else if (name === 'settings') {
        if (link()?.settingsSync) await call('settings', { enabled: false });
        else
          form(
            'Enable settings synchronization',
            'Review the privacy notice and choose which settings to use.',
            consent,
            'Enable settings sync',
            async (d, context) => {
              if (d.get('settingsSync') !== 'on')
                throw new Error('Select “Sync extension settings” to give consent.');
              await call(
                'settings',
                { enabled: true, settingsConsent: true, settingsChoice: d.get('settingsChoice') },
                context.profileId,
              );
              if (context.isCurrent()) context.close();
            },
          );
      } else if (name === 'password' || name === 'codes')
        form(
          name === 'password' ? 'Change password' : 'Replace recovery codes',
          name === 'password'
            ? 'Other devices will be signed out.'
            : 'Previous recovery codes will stop working. Save the replacement codes.',
          field('password', 'Current password', '', 'password', 'required autocomplete="current-password"') +
            (name === 'password'
              ? field(
                  'newPassword',
                  'New password',
                  '',
                  'password',
                  'required minlength="12" maxlength="256" autocomplete="new-password"',
                )
              : ''),
          name === 'password' ? 'Change password' : 'Replace recovery codes',
          async (d, context) => {
            const result = await call(
              name === 'codes' ? 'recovery-codes' : 'password',
              Object.fromEntries(d),
              context.profileId,
            );
            if (context.isCurrent()) {
              context.close();
              if (result.recoveryCodes) recovery(result.recoveryCodes);
            }
          },
        );
      else if (name === 'delete-account' || name === 'delete-dataset') {
        const datasetId = link()?.datasetId;
        form(
          name === 'delete-account' ? 'Delete account' : 'Delete cloud profile',
          name === 'delete-account'
            ? 'Remove your account, all cloud profiles and device sessions. Local browser data remains on each device.'
            : 'Remove the cloud extension library and settings from this sync profile. Local installations remain available.',
          field('password', 'Current password', '', 'password', 'required autocomplete="current-password"') +
            `<label class="setting-toggle"><span>I understand this cloud data will be deleted</span><input type="checkbox" name="confirm" required></label>`,
          'Delete permanently',
          async (d, context) => {
            await call(
              name,
              { id: datasetId, password: d.get('password'), confirm: d.get('confirm') === 'on' },
              context.profileId,
            );
            if (context.isCurrent()) context.close();
          },
          true,
        );
      } else if (name === 'unlink') await call('unlink');
      else if (name === 'logout') {
        await call('logout');
        toast('Signed out of synchronization.');
      } else if (['now', 'retry', 'export'].includes(name)) await call(name, { id: data.id });
      else if (name === 'discard')
        form(
          'Discard unsynced change?',
          'The accepted cloud settings will replace this rejected local change. Export it first if you want a copy.',
          '',
          'Discard change',
          async (_d, context) => {
            await call('discard', { id: data.id }, context.profileId);
            if (context.isCurrent()) context.close();
          },
          true,
        );
      else throw new Error('Unknown synchronization control.');
    },
  };
}
