'use strict';
// Only the privileged session hooks change rendering. This controller owns
// extension precedence and local durability; it never injects page CSS.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { negotiateEngineCapabilities } = require('./engine-capabilities.cjs');
const FAMILIES = new Set(['standard', 'sansserif', 'serif', 'fixed', 'cursive', 'fantasy', 'math']);
// Chrome's published ScriptCode enum, rather than arbitrary four-letter input.
const SCRIPTS = new Set(
  'Afak Arab Armi Armn Avst Bali Bamu Bass Batk Beng Blis Bopo Brah Brai Bugi Buhd Cakm Cans Cari Cham Cher Cirt Copt Cprt Cyrl Cyrs Deva Dsrt Dupl Egyd Egyh Egyp Elba Ethi Geor Geok Glag Goth Gran Grek Gujr Guru Hang Hani Hano Hans Hant Hebr Hluw Hmng Hung Inds Ital Java Jpan Jurc Kali Khar Khmr Khoj Knda Kpel Kthi Lana Laoo Latf Latg Latn Lepc Limb Lina Linb Lisu Loma Lyci Lydi Mand Mani Maya Mend Merc Mero Mlym Moon Mong Mroo Mtei Mymr Narb Nbat Nkgb Nkoo Nshu Ogam Olck Orkh Orya Osma Palm Perm Phag Phli Phlp Phlv Phnx Plrd Prti Rjng Roro Runr Samr Sara Sarb Saur Sgnw Shaw Shrd Sind Sinh Sora Sund Sylo Syrc Syre Syrj Syrn Tagb Takr Tale Talu Taml Tang Tavt Telu Teng Tfng Tglg Thaa Thai Tibt Tirh Ugar Vaii Visp Wara Wole Xpeo Xsux Yiii Zmth Zsym Zyyy'.split(
    ' ',
  ),
);
const SIZES = {
  DefaultFontSize: 'defaultFontSize',
  DefaultFixedFontSize: 'defaultFixedFontSize',
  MinimumFontSize: 'minimumFontSize',
};
const MAX_BYTES = 4 * 1024 * 1024;
const clone = (value) => structuredClone(value);
function object(value, allowed) {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value))
  )
    throw new Error('Invalid font settings details');
  if (Object.keys(value).some((key) => !allowed.includes(key)))
    throw new Error('Unsupported font settings properties');
  return value;
}
function fontId(value) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 256 || /[\x00-\x1f\x7f]/.test(value))
    throw new Error('Invalid font ID');
  return value;
}
function fontKey(details) {
  const script = details.script === undefined ? 'Zyyy' : details.script;
  if (!FAMILIES.has(details.genericFamily) || !SCRIPTS.has(script))
    throw new Error('Invalid font family or script');
  return script + ':' + details.genericFamily;
}
function size(key, value) {
  if (!Number.isInteger(value) || value < (key === 'minimumFontSize' ? 0 : 1) || value > 512)
    throw new Error('Invalid font pixel size');
  return value;
}
function rank(record) {
  return { id: record.id, installedAt: Number.isFinite(record.installedAt) ? record.installedAt : 0 };
}
function compare(a, b) {
  return a.installedAt - b.installedAt || a.id.localeCompare(b.id, 'en');
}
function level(owner, receiver) {
  if (owner?.id === receiver.id) return 'controlled_by_this_extension';
  return owner && compare(owner, receiver) > 0
    ? 'controlled_by_other_extensions'
    : 'controllable_by_this_extension';
}
function snapshot(value) {
  object(value, ['fonts', ...Object.values(SIZES)]);
  if (!Array.isArray(value.fonts) || value.fonts.length > 2048)
    throw new Error('Invalid native font preferences');
  const values = {};
  for (const item of value.fonts) {
    object(item, ['script', 'genericFamily', 'fontId']);
    if (
      typeof item.fontId !== 'string' ||
      Buffer.byteLength(item.fontId) > 4096 ||
      /[\x00-\x1f\x7f]/.test(item.fontId)
    )
      throw new Error('Invalid native font ID');
    if (!SCRIPTS.has(item.script)) continue;
    values[fontKey(item)] = item.fontId;
  }
  for (const key of Object.values(SIZES)) values[key] = size(key, value[key]);
  return values;
}
function validateState(value) {
  object(value, ['schema', 'owners']);
  if (value.schema !== 1) throw new Error('Invalid font settings state schema');
  object(value.owners, Object.keys(value.owners || {}));
  if (Object.keys(value.owners).length > 128) throw new Error('Font settings owner limit');
  for (const [id, settings] of Object.entries(value.owners)) {
    if (!/^[a-p]{32}$/.test(id)) throw new Error('Invalid font settings owner');
    object(settings, Object.keys(settings || {}));
    if (Object.keys(settings).length > 512) throw new Error('Font settings entry limit');
    for (const [key, value] of Object.entries(settings)) {
      if (Object.values(SIZES).includes(key)) size(key, value);
      else {
        const [script, genericFamily, ...extra] = key.split(':');
        if (extra.length) throw new Error('Invalid font settings key');
        fontKey({ script, genericFamily });
        fontId(value);
      }
    }
  }
  return value;
}
class FontSettingsController {
  constructor(options) {
    Object.assign(this, options);
    this.profiles = new Map();
    this.queues = new Map();
    this.epochs = new Map();
    this.closed = false;
  }
  assertProfile(profileId) {
    const profile = this.getProfile(profileId);
    if (this.closed || !profile || profile.private)
      throw new Error('Font settings profile unavailable or private');
  }
  profile(profileId) {
    this.assertProfile(profileId);
    const session = this.getSession(profileId);
    if (
      !negotiateEngineCapabilities(session).fontSettings ||
      typeof session.extensions.getZacroFontPreferences !== 'function'
    )
      throw new Error('Native font settings unavailable');
    return session.extensions;
  }
  guard(context) {
    context.assertCurrent?.();
    this.profile(context.profileId);
    if (context.kind === 'content-script') throw new Error('Trusted extension contexts only');
    const metadata = this.resolveExtension(context.profileId, context.extensionId);
    if (!metadata?.enabled || metadata.generation !== context.generation)
      throw new Error('Expired or disabled extension context');
    if (!metadata.grants?.permissions?.includes('fontSettings'))
      throw new Error('Missing fontSettings permission');
  }
  enqueue(profileId, work, { native = true } = {}) {
    const epoch = this.epochs.get(profileId);
    const guard = () => {
      if (native) this.profile(profileId);
      else this.assertProfile(profileId);
      if (this.epochs.get(profileId) !== epoch) throw new Error('Expired font settings profile');
    };
    const pending = (this.queues.get(profileId) || Promise.resolve())
      .catch(() => {})
      .then(() => {
        guard();
        return work(guard);
      });
    this.queues.set(profileId, pending);
    return pending.finally(() => {
      if (this.queues.get(profileId) === pending) this.queues.delete(profileId);
    });
  }
  state(profileId) {
    let state = this.profiles.get(profileId);
    if (!state) {
      let durable = { schema: 1, owners: {} };
      try {
        const filename = path.join(this.profilePath(profileId), 'font-settings.json');
        if (fs.statSync(filename).size > MAX_BYTES) throw new Error('Font settings state is too large');
        durable = validateState(JSON.parse(fs.readFileSync(filename, 'utf8')));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      state = { durable, owners: {}, values: null };
      this.profiles.set(profileId, state);
    }
    return state;
  }
  eligible(profileId) {
    return this.listExtensions(profileId).filter((record) => {
      const live = this.resolveExtension(profileId, record.id);
      return live?.enabled && live.grants?.permissions?.includes('fontSettings');
    });
  }
  effective(profileId, durable) {
    const values = {},
      owners = {};
    for (const record of this.eligible(profileId).sort((a, b) => compare(rank(a), rank(b))))
      for (const [key, value] of Object.entries(durable.owners[record.id] || {})) {
        values[key] = value;
        owners[key] = rank(record);
      }
    const overrides = { fonts: [] };
    for (const [key, value] of Object.entries(values)) {
      if (Object.values(SIZES).includes(key)) overrides[key] = value;
      else {
        const [script, genericFamily] = key.split(':');
        overrides.fonts.push({ script, genericFamily, fontId: value });
      }
    }
    return { overrides, owners };
  }
  persist(profileId, durable) {
    validateState(durable);
    const bytes = JSON.stringify(durable);
    if (Buffer.byteLength(bytes) > MAX_BYTES) throw new Error('Font settings state is too large');
    const filename = path.join(this.profilePath(profileId), 'font-settings.json');
    fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
    const temporary = filename + '.' + crypto.randomUUID() + '.tmp';
    try {
      const fd = fs.openSync(temporary, 'wx', 0o600);
      try {
        fs.writeFileSync(fd, bytes);
        fs.fsyncSync(fd);
      } finally {
        fs.closeSync(fd);
      }
      fs.renameSync(temporary, filename);
      if (process.platform !== 'win32') {
        let directory;
        try {
          directory = fs.openSync(path.dirname(filename), 'r');
          fs.fsyncSync(directory);
        } catch {
          /* Some filesystems cannot flush directories. */
        } finally {
          if (directory !== undefined) fs.closeSync(directory);
        }
      }
    } finally {
      fs.rmSync(temporary, { force: true });
    }
  }
  notify(profileId, before, after, oldOwners, newOwners) {
    const keys = new Set([
      ...Object.keys(before),
      ...Object.keys(after),
      ...Object.keys(oldOwners),
      ...Object.keys(newOwners),
    ]);
    for (const record of this.eligible(profileId)) {
      const receiver = rank(record);
      for (const key of keys) {
        const oldLevel = level(oldOwners[key], receiver),
          newLevel = level(newOwners[key], receiver);
        const previous = before[key] ?? '',
          value = after[key] ?? '';
        if (previous === value && oldLevel === newLevel) continue;
        const suffix = Object.keys(SIZES).find((name) => SIZES[name] === key);
        const details = suffix
          ? { pixelSize: value, levelOfControl: newLevel }
          : (() => {
              const [script, genericFamily] = key.split(':');
              return { fontId: value, script, genericFamily, levelOfControl: newLevel };
            })();
        // A listener or queued native worker cannot receive after its permission
        // or document generation is revoked; host adds the bridge filter too.
        try {
          this.emit?.(profileId, record.id, 'fontSettings.on' + (suffix || 'Font') + 'Changed', [details]);
        } catch {
          /* Committed preferences survive listener failures. */
        }
      }
    }
  }
  async apply(profileId, durable, guard) {
    const api = this.profile(profileId),
      state = this.state(profileId);
    guard();
    const nativeBefore = snapshot(await api.getZacroFontPreferences());
    guard();
    const before = state.values || nativeBefore,
      oldOwners = state.owners;
    const next = this.effective(profileId, durable);
    try {
      await api.setZacroFontPreferences(next.overrides);
      guard();
      const after = snapshot(await api.getZacroFontPreferences());
      guard();
      this.persist(profileId, durable);
      state.durable = durable;
      state.values = after;
      state.owners = next.owners;
      this.notify(profileId, before, after, oldOwners, next.owners);
    } catch (error) {
      // A cancelled context may have lost permission while the native setter
      // awaited. Restore only settings still owned by enabled authorized peers.
      try {
        await api.setZacroFontPreferences(this.effective(profileId, state.durable).overrides);
      } catch (rollback) {
        throw new AggregateError([error, rollback], 'Font settings apply and native rollback failed');
      }
      throw error;
    }
  }
  reconcile(profileId) {
    try {
      this.assertProfile(profileId);
    } catch (error) {
      return Promise.reject(error);
    }
    // Capture removal at notification time. A queued reconciliation must not
    // let an immediate reinstall with the same ID inherit the old owner's data.
    const installed = new Set(this.listExtensions(profileId).map((r) => r.id));
    return this.enqueue(
      profileId,
      async (guard) => {
        const state = this.state(profileId),
          durable = clone(state.durable);
        let removed = false;
        for (const id of Object.keys(durable.owners)) {
          if (!installed.has(id)) {
            delete durable.owners[id];
            removed = true;
          }
        }
        // Uninstall invalidates local ownership even on stock Electron or when
        // native application fails. Disabled installed owners remain retained.
        if (removed) {
          guard();
          this.persist(profileId, durable);
          state.durable = durable;
        }
        try {
          this.profile(profileId);
        } catch (error) {
          // A stock session can prune local owners, but never invoke font hooks.
          if (error.message === 'Native font settings unavailable') return;
          throw error;
        }
        await this.apply(profileId, durable, () => {
          guard();
          this.profile(profileId);
        });
      },
      { native: false },
    );
  }
  call(context, method, args) {
    return Promise.resolve().then(async () => {
      this.guard(context);
      if (this.ready) {
        await this.ready(context);
        this.guard(context);
      }
      if (!Array.isArray(args) || args.length > 1) throw new Error('Invalid font settings arguments');
      if (method === 'getFontList') {
        if (args.length) throw new Error('Invalid font list arguments');
        return this.enqueue(context.profileId, async (guard) => {
          this.guard(context);
          const list = await this.profile(context.profileId).getZacroFontList();
          guard();
          this.guard(context);
          if (
            !Array.isArray(list) ||
            list.length > 32768 ||
            Buffer.byteLength(JSON.stringify(list)) > MAX_BYTES
          )
            throw new Error('Invalid native font list');
          return list.map((item) => {
            object(item, ['fontId', 'displayName']);
            if (
              typeof item.fontId !== 'string' ||
              Buffer.byteLength(item.fontId) > 4096 ||
              /[\x00-\x1f\x7f]/.test(item.fontId)
            )
              throw new Error('Invalid native font ID');
            if (
              typeof item.displayName !== 'string' ||
              item.displayName.length > 512 ||
              /[\x00-\x1f\x7f]/.test(item.displayName)
            )
              throw new Error('Invalid native font display name');
            return clone(item);
          });
        });
      }
      const match = /^(get|set|clear)(Font|DefaultFontSize|DefaultFixedFontSize|MinimumFontSize)$/.exec(
        method,
      );
      if (!match) throw new Error('Unsupported font settings method');
      const [, action, suffix] = match;
      const details = args.length ? args[0] : {};
      object(
        details,
        suffix === 'Font'
          ? ['genericFamily', 'script', ...(action === 'set' ? ['fontId'] : [])]
          : action === 'set'
            ? ['pixelSize']
            : [],
      );
      const key = suffix === 'Font' ? fontKey(details) : SIZES[suffix];
      const value =
        action === 'set'
          ? suffix === 'Font'
            ? fontId(details.fontId)
            : size(key, details.pixelSize)
          : undefined;
      return this.enqueue(context.profileId, async (guard) => {
        const current = () => {
          guard();
          this.guard(context);
        };
        current();
        const state = this.state(context.profileId);
        if (action === 'get') {
          const values = snapshot(await this.profile(context.profileId).getZacroFontPreferences());
          current();
          const owner = this.effective(context.profileId, state.durable).owners[key];
          const record = this.listExtensions(context.profileId).find((r) => r.id === context.extensionId);
          return {
            [suffix === 'Font' ? 'fontId' : 'pixelSize']: values[key] ?? '',
            levelOfControl: level(owner, rank(record || { id: context.extensionId })),
          };
        }
        const durable = clone(state.durable);
        durable.owners[context.extensionId] ||= {};
        if (action === 'clear') delete durable.owners[context.extensionId][key];
        else durable.owners[context.extensionId][key] = value;
        if (!Object.keys(durable.owners[context.extensionId]).length)
          delete durable.owners[context.extensionId];
        validateState(durable);
        await this.apply(context.profileId, durable, current);
      });
    });
  }
  forgetProfile(profileId) {
    this.epochs.set(profileId, crypto.randomUUID());
    this.profiles.delete(profileId);
  }
  close() {
    this.closed = true;
    this.profiles.clear();
  }
}
module.exports = { FontSettingsController };
