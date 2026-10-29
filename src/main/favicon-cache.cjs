'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { webURL } = require('./security.cjs');
const { normalizeRaster, MAX_BYTES } = require('./favicon.cjs');

const MAX_CACHE_BYTES = 4 * 1024 * 1024;
const cacheKey = (profileId, url) => JSON.stringify([profileId, url]);
const filename = (key) => createHash('sha256').update(key).digest('hex') + '.raster';

function rasterDataURL(value) {
  if (typeof value !== 'string' || value.length > MAX_BYTES * 1.4 + 64) return null;
  const match = /^data:image\/(?:png|x-icon);base64,([A-Za-z0-9+/=]+)$/.exec(value);
  return match ? normalizeRaster(Buffer.from(match[1], 'base64')) : null;
}

// Every saved destination retains a bounded, validated raster file. The memory
// LRU is only a speed-up: evicting it never deletes another saved tab's icon.
// The store's 1,000-tab limit bounds disk usage to 3,000 files (home/current/Peek),
// each at most 128 KiB. Private destinations are never eligible for disk storage.
class SavedFaviconCache {
  constructor(directory, { maxEntries = 128, maxBytes = MAX_CACHE_BYTES } = {}) {
    this.directory = path.join(directory, 'saved-favicons');
    this.maxEntries = maxEntries;
    this.maxBytes = maxBytes;
    this.entries = new Map();
    this.allowed = new Map();
    this.pending = new Map();
    this.missing = new Set();
    this.deletions = new Set();
    this.bytes = 0;
    this.cleanup = false;
    this.timer = null;
    this.initialized = false;
  }

  retain(state) {
    const profiles = new Set(
      state.profiles.filter((profile) => !profile.private).map((profile) => profile.id),
    );
    const allowed = new Map();
    for (const tab of state.tabs) {
      if (!profiles.has(tab.profileId)) continue;
      const urls = [tab.savedPeek?.url];
      if (tab.pinned || tab.favorite) urls.push(tab.pinnedUrl, tab.url);
      for (const value of urls) {
        const url = webURL(value);
        if (url) allowed.set(cacheKey(tab.profileId, url), { profileId: tab.profileId, url });
      }
    }
    const changed =
      !this.initialized ||
      allowed.size !== this.allowed.size ||
      [...allowed.keys()].some((key) => !this.allowed.has(key));
    this.allowed = allowed;
    this.initialized = true;
    for (const key of this.entries.keys()) if (!allowed.has(key)) this.remove(key);
    for (const key of this.pending.keys()) if (!allowed.has(key)) this.pending.delete(key);
    for (const key of this.missing) if (!allowed.has(key)) this.missing.delete(key);
    if (changed) {
      this.cleanup = true;
      this.changed();
    }
  }

  get(profileId, url) {
    const key = cacheKey(profileId, url);
    if (!this.allowed.has(key) || this.deletions.has(filename(key))) return null;
    const record = this.entries.get(key) || this.pending.get(key);
    if (record) {
      if (this.entries.has(key)) {
        this.entries.delete(key);
        this.entries.set(key, record);
      }
      return record.dataUrl;
    }
    if (this.missing.has(key)) return null;
    try {
      const file = path.join(this.directory, filename(key));
      if (fs.statSync(file).size > MAX_BYTES) {
        this.missing.add(key);
        return null;
      }
      const dataUrl = normalizeRaster(fs.readFileSync(file));
      if (dataUrl) this.put({ profileId, url, dataUrl });
      else this.missing.add(key);
      return dataUrl;
    } catch {
      // A missing or damaged optional icon must never block loading the browser.
      this.missing.add(key);
      return null;
    }
  }

  remember(profileId, url, value) {
    const key = cacheKey(profileId, url);
    if (!this.allowed.has(key) || !value || this.get(profileId, url) === value) return;
    const dataUrl = rasterDataURL(value);
    if (!dataUrl) return; // A failed/offline fetch never replaces valid pixels.
    const record = { profileId, url, dataUrl };
    this.put(record);
    this.pending.set(key, record);
    this.missing.delete(key);
    this.deletions.delete(filename(key));
    this.changed();
  }

  put(record) {
    const bytes = Buffer.byteLength(JSON.stringify(record)) + 1;
    if (bytes > this.maxBytes) return;
    const key = cacheKey(record.profileId, record.url);
    this.remove(key);
    while (this.entries.size && (this.entries.size >= this.maxEntries || this.bytes + bytes > this.maxBytes))
      this.remove(this.entries.keys().next().value);
    this.entries.set(key, { ...record, bytes });
    this.bytes += bytes;
  }

  remove(key) {
    const record = this.entries.get(key);
    if (record) this.bytes -= record.bytes;
    this.entries.delete(key);
  }

  clearProfile(profileId) {
    for (const [key, record] of this.allowed)
      if (record.profileId === profileId) {
        this.remove(key);
        this.pending.delete(key);
        this.missing.add(key);
        this.deletions.add(filename(key));
      }
    this.flush();
  }

  changed() {
    if (!this.timer) {
      this.timer = setTimeout(() => this.flush(), 200);
      this.timer.unref?.();
    }
  }

  flush() {
    clearTimeout(this.timer);
    this.timer = null;
    try {
      if (this.pending.size) fs.mkdirSync(this.directory, { recursive: true });
      for (const [key, record] of this.pending) {
        const file = path.join(this.directory, filename(key));
        const temporary = file + '.tmp';
        const bytes = Buffer.from(record.dataUrl.slice(record.dataUrl.indexOf(',') + 1), 'base64');
        fs.writeFileSync(temporary, bytes, { mode: 0o600 });
        fs.renameSync(temporary, file);
        this.pending.delete(key);
      }
      if (this.cleanup && fs.existsSync(this.directory)) {
        const keep = new Set([...this.allowed.keys()].map(filename));
        for (const file of fs.readdirSync(this.directory))
          if (/^[a-f0-9]{64}\.raster(?:\.tmp)?$/.test(file) && !keep.has(file)) this.deletions.add(file);
      }
      for (const file of this.deletions) {
        fs.rmSync(path.join(this.directory, file), { force: true });
        this.deletions.delete(file);
      }
      this.cleanup = false;
    } catch {
      // Browsing remains usable when the optional presentation cache cannot save.
    }
  }
}

module.exports = { SavedFaviconCache, MAX_CACHE_BYTES };
