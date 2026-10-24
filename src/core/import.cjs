'use strict';
const { webUrl } = require('./store.cjs');

function decodeEntities(text) {
  return text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (match, entity) => {
    if (entity[0] === '#') {
      const n =
        entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '\uFFFD';
    }
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }[entity.toLowerCase()] || match;
  });
}
function parseBookmarksHtml(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > 16 * 1024 * 1024)
    throw new Error('Bookmark file exceeds 16 MB.');
  const records = [];
  const pattern = /<a\b([^>]{0,20000})>([\s\S]*?)<\/a\s*>/gi;
  for (const match of text.matchAll(pattern)) {
    const href = match[1].match(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
    if (!href) continue;
    const url = webUrl(decodeEntities(href[1] ?? href[2] ?? href[3]));
    if (!url) continue;
    records.push({
      url,
      title:
        decodeEntities(match[2].replace(/<[^>]*>/g, ''))
          .trim()
          .slice(0, 500) || url,
    });
    if (records.length > 20000) throw new Error('Bookmark file exceeds 20,000 entries.');
  }
  if (!records.length) throw new Error('No supported HTTP or HTTPS bookmarks were found.');
  return records;
}
module.exports = { parseBookmarksHtml, decodeEntities };
