'use strict';

// Persist destinations only: Chromium pageState may contain form values or POST
// bodies. Never save it in browser snapshots, exports or recovery files.
function cleanNavigationHistory(value, currentURL) {
  if (!value || !Array.isArray(value.entries) || !Number.isInteger(value.index)) return null;
  if (value.index < 0 || value.index >= value.entries.length) return null;
  const start = Math.max(0, value.index - 49);
  const end = Math.min(value.entries.length, start + 100);
  const entries = [];
  let index = -1;
  for (let i = start; i < end; i++) {
    const item = value.entries[i];
    if (typeof item?.url !== 'string' || item.url.length > 8192) continue;
    let url;
    try {
      url = new URL(item.url);
    } catch {
      continue;
    }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) continue;
    if (i === value.index) index = entries.length;
    entries.push({ url: url.href, title: typeof item.title === 'string' ? item.title.slice(0, 500) : '' });
  }
  if (index < 0 || (currentURL && entries[index].url !== currentURL)) return null;
  return { entries, index };
}

module.exports = { cleanNavigationHistory };
