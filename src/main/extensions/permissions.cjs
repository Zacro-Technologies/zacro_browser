'use strict';
const { inspectManifest, supportedHost } = require('./catalog.cjs');
function matches(pattern, url) {
  try {
    const target = new URL(url);
    if (!['http:', 'https:'].includes(target.protocol)) return false;
    if (pattern === '<all_urls>') return true;
    const match = /^(\*|https?):\/\/(\*|\*\.[^/]+|[^/]+)(\/.*)$/.exec(pattern);
    if (!match || (match[1] !== '*' && target.protocol !== match[1] + ':')) return false;
    const [host, port] = match[2].split(':');
    if (port && port !== (target.port || (target.protocol === 'https:' ? '443' : '80'))) return false;
    if (
      host !== '*' &&
      target.hostname !== host &&
      !(
        host.startsWith('*.') &&
        (target.hostname === host.slice(2) || target.hostname.endsWith(host.slice(1)))
      )
    )
      return false;
    return new RegExp(
      '^' +
        match[3]
          .split('*')
          .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
          .join('.*') +
        '$',
    ).test(target.pathname + target.search);
  } catch {
    return false;
  }
}
function permissionDetails(value) {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.keys(value).some((key) => !['permissions', 'origins'].includes(key))
  )
    throw new Error('Invalid permissions or user gesture');
  const out = {};
  for (const key of ['permissions', 'origins']) {
    const list = value[key] || [];
    if (!Array.isArray(list) || list.length > 1000 || list.some((item) => typeof item !== 'string' || !item))
      throw new Error('Invalid permissions');
    out[key] = [...new Set(list)].sort();
  }
  return out;
}
function optionalGrants(manifest, current, requested, remove = false) {
  const inspection = inspectManifest({
    name: 'Permission validation',
    version: '1',
    manifest_version: 3,
    ...manifest,
  });
  for (const key of ['permissions', 'origins'])
    for (const value of requested[key]) {
      if (remove && inspection.required[key].includes(value))
        throw new Error('Required permissions cannot be removed');
      if (!inspection.optional[key].includes(value)) throw new Error('Permission was not declared optional');
      if (
        inspection.unsupported.some((item) => item.capability === value) ||
        (key === 'origins' && !supportedHost(value))
      )
        throw new Error('Unsupported permission');
    }
  return Object.fromEntries(
    ['permissions', 'origins'].map((key) => [
      key,
      remove
        ? current[key].filter((value) => !requested[key].includes(value))
        : [...new Set([...current[key], ...requested[key]])].sort(),
    ]),
  );
}
module.exports = { matches, permissionDetails, optionalGrants };
