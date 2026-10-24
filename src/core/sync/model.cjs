'use strict';
const own = (o, k) => Object.hasOwn(o, k);
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const clone = (v) => JSON.parse(JSON.stringify(v));
function jsonValue(value, depth = 0, parents = new Set()) {
  if (depth > 64) throw new Error('JSON value nesting is too deep.');
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'object' || parents.has(value))
    throw new Error('This value cannot be serialized as JSON.');
  if (!Array.isArray(value) && ![Object.prototype, null].includes(Object.getPrototypeOf(value)))
    throw new Error('This value cannot be serialized as JSON.');
  if (Reflect.ownKeys(value).some((key) => typeof key !== 'string'))
    throw new Error('This value cannot be serialized as JSON.');
  parents.add(value);
  let result;
  if (Array.isArray(value)) {
    result = [];
    for (let i = 0; i < value.length; i++) {
      if (!own(value, i)) throw new Error('Sparse arrays cannot be serialized as JSON.');
      result.push(jsonValue(value[i], depth + 1, parents));
    }
  } else {
    const entries = [];
    for (const key of Object.keys(value)) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!own(descriptor, 'value')) throw new Error('Accessor values cannot be serialized as JSON.');
      entries.push([key, jsonValue(descriptor.value, depth + 1, parents)]);
    }
    result = Object.fromEntries(entries);
  }
  parents.delete(value);
  return result;
}
function equal(a, b) {
  if (a === b) return true;
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((v, i) => equal(v, b[i]));
  if (!object(a) || !object(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((k) => own(b, k) && equal(a[k], b[k]));
}
const bytes = (key, value) => Buffer.byteLength(key) + Buffer.byteLength(JSON.stringify(value));
function checkQuota(values) {
  if (Object.keys(values).length > 512) throw new Error('MAX_ITEMS quota exceeded.');
  let total = 0;
  for (const [key, value] of Object.entries(values)) {
    const size = bytes(key, value);
    if (size > 8192) throw new Error('QUOTA_BYTES_PER_ITEM quota exceeded.');
    total += size;
  }
  if (total > 102400) throw new Error('QUOTA_BYTES quota exceeded.');
}
function difference(before, after) {
  return Object.fromEntries(
    [...new Set([...Object.keys(before), ...Object.keys(after)])]
      .filter((key) => own(before, key) !== own(after, key) || !equal(before[key], after[key]))
      .map((key) => [
        key,
        {
          ...(own(before, key) ? { oldValue: clone(before[key]) } : {}),
          ...(own(after, key) ? { newValue: clone(after[key]) } : {}),
        },
      ]),
  );
}
function applySettings(values, payload, revisions = {}, baseRevision = Infinity) {
  const map = new Map(Object.entries(values));
  if (payload.clear)
    for (const key of map.keys())
      if ((own(revisions, key) ? revisions[key] : 0) <= baseRevision) map.delete(key);
  for (const key of payload.remove || []) map.delete(key);
  for (const [key, value] of Object.entries(payload.set || {})) map.set(key, value);
  return Object.fromEntries(map);
}
module.exports = { own, object, clone, jsonValue, equal, bytes, checkQuota, difference, applySettings };
