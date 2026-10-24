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
// Decide inclusion of two supported match-pattern languages. A bounded glob
// automaton avoids treating wildcard declarations as literal strings, or using
// a few example URLs as an unsafe proof that one pattern contains another.
function globContains(outer, inner) {
  if (outer === inner || outer === '/*') return true;
  const alphabet = [...new Set([...outer, ...inner].filter((char) => char !== '*')), '\0'];
  const closure = (pattern, values) => {
    const states = new Set(values);
    for (const position of states) if (pattern[position] === '*') states.add(position + 1);
    return [...states].sort((a, b) => a - b);
  };
  const step = (pattern, states, char) =>
    closure(
      pattern,
      states.flatMap((position) =>
        pattern[position] === '*' ? [position] : pattern[position] === char ? [position + 1] : [],
      ),
    );
  const pending = [[closure(outer, [0]), closure(inner, [0])]],
    seen = new Set();
  while (pending.length) {
    const [left, right] = pending.pop(),
      key = left.join(',') + '/' + right.join(',');
    if (seen.has(key)) continue;
    if (seen.size >= 8192) return false; // Fail closed for pathological patterns.
    seen.add(key);
    if (right.includes(inner.length) && !left.includes(outer.length)) return false;
    for (const char of alphabet) {
      const next = step(inner, right, char);
      if (next.length) pending.push([step(outer, left, char), next]);
    }
  }
  return true;
}
function hostContains(outer, inner) {
  if (!supportedHost(outer) || !supportedHost(inner)) return false;
  const parse = (value) => {
    if (value === '<all_urls>') return { scheme: '*', host: '*', port: '', path: '/*' };
    const match = /^(\*|https?):\/\/([^/]+)(\/.*)$/i.exec(value);
    if (!match) return null;
    const [host, port = ''] = match[2].toLowerCase().split(':');
    if (port && (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535)) return null;
    return { scheme: match[1].toLowerCase(), host, port: port ? String(Number(port)) : '', path: match[3] };
  };
  const a = parse(outer),
    b = parse(inner);
  if (!a || !b || (a.scheme !== '*' && a.scheme !== b.scheme) || (a.port && a.port !== b.port)) return false;
  const host =
    a.host === '*' ||
    a.host === b.host ||
    (a.host.startsWith('*.') &&
      b.host !== '*' &&
      (b.host === a.host.slice(2) || b.host.endsWith(a.host.slice(1))));
  return host && globContains(a.path, b.path);
}
function covers(values, value, key) {
  return key === 'origins' ? values.some((pattern) => hostContains(pattern, value)) : values.includes(value);
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
      if (
        remove &&
        inspection.required[key].some((required) =>
          key === 'origins' ? hostContains(value, required) : value === required,
        )
      )
        throw new Error('Required permissions cannot be removed');
      if (!covers(inspection.optional[key], value, key))
        throw new Error('Permission was not declared optional');
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
        ? current[key].filter((value) => !covers(requested[key], value, key))
        : [...new Set([...current[key], ...requested[key]])].sort(),
    ]),
  );
}
module.exports = { matches, hostContains, covers, permissionDetails, optionalGrants };
