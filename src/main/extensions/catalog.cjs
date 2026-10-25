'use strict';
// A conservative capability inventory, not a promise of Chrome-wide compatibility.
const API_PERMISSIONS = new Set([
  'storage',
  'tabs',
  'scripting',
  'contextMenus',
  'webRequest',
  'webRequestBlocking',
  'unlimitedStorage',
]);
function list(value, name) {
  if (value === undefined) return [];
  if (
    !Array.isArray(value) ||
    value.length > 1000 ||
    value.some((item) => typeof item !== 'string' || !item || item.length > 2048)
  )
    throw new Error(`Invalid manifest ${name}`);
  return value;
}
function host(value) {
  return value === '<all_urls>' || value.includes('://');
}
function supportedHost(value) {
  return (
    value === '<all_urls>' || /^(?:\*|https?):\/\/(?:\*|(?:\*\.)?[a-z0-9.-]+)(?::\d+)?\/[^\s]*$/i.test(value)
  );
}
function versionParts(version) {
  if (
    typeof version !== 'string' ||
    !/^\d+(?:\.\d+){0,3}$/.test(version) ||
    version.split('.').some((n) => Number(n) > 65535 || n.length > 5 || (n.length > 1 && n[0] === '0')) ||
    version.split('.').every((n) => Number(n) === 0)
  )
    throw new Error('Invalid extension version');
  return [...version.split('.').map(Number), 0, 0, 0].slice(0, 4);
}
function compareVersions(a, b) {
  const left = versionParts(a),
    right = versionParts(b);
  for (let i = 0; i < 4; i++) if (left[i] !== right[i]) return Math.sign(left[i] - right[i]);
  return 0;
}
function inspectManifest(manifest) {
  if (
    !manifest ||
    typeof manifest !== 'object' ||
    Array.isArray(manifest) ||
    ![2, 3].includes(manifest.manifest_version) ||
    typeof manifest.name !== 'string' ||
    !manifest.name ||
    manifest.name.length > 2048
  )
    throw new Error('Invalid extension manifest');
  versionParts(manifest.version);
  if (
    manifest.devtools_page !== undefined &&
    (typeof manifest.devtools_page !== 'string' ||
      !manifest.devtools_page ||
      manifest.devtools_page.length > 2048 ||
      /[\\\x00-\x20\x7f:%?#]/.test(manifest.devtools_page) ||
      manifest.devtools_page.split('/').some((part) => !part || part === '.' || part === '..'))
  )
    throw new Error('Invalid devtools_page');
  const requiredPermissions = list(manifest.permissions, 'permissions'),
    optionalPermissions = list(manifest.optional_permissions, 'optional_permissions');
  const contentScripts = manifest.content_scripts || [];
  if (!Array.isArray(contentScripts) || contentScripts.length > 1000)
    throw new Error('Invalid content_scripts');
  const requiredOrigins = [
    ...list(manifest.host_permissions, 'host_permissions'),
    ...contentScripts.flatMap((entry) => list(entry?.matches, 'content matches')),
  ];
  const optionalOrigins = list(manifest.optional_host_permissions, 'optional_host_permissions');
  const make = (permissions, origins) => ({
    permissions: [...new Set(permissions.filter((p) => !host(p)))].sort(),
    origins: [...new Set([...origins, ...permissions.filter(host)])].sort(),
  });
  const required = make(requiredPermissions, requiredOrigins),
    optional = make(optionalPermissions, optionalOrigins),
    unsupported = [];
  for (const permission of required.permissions)
    if (!API_PERMISSIONS.has(permission))
      unsupported.push({
        capability: permission,
        required: true,
        reason:
          permission === 'activeTab'
            ? 'Electron cannot grant native one-tab temporary host access; activeTab is unsupported.'
            : 'This API is not supported by the current extension host.',
      });
  if (manifest.manifest_version === 2 && required.permissions.includes('scripting'))
    unsupported.push({
      capability: 'scripting',
      required: true,
      reason: 'Native scripting is available only to Manifest V3 extensions.',
    });
  for (const origin of required.origins)
    if (!supportedHost(origin))
      unsupported.push({
        capability: origin,
        required: true,
        reason: 'Only HTTP and HTTPS host access is supported.',
      });
  for (const permission of optional.permissions)
    if (!API_PERMISSIONS.has(permission))
      unsupported.push({
        capability: permission,
        required: false,
        reason: 'This optional API cannot be granted.',
      });
  if (manifest.manifest_version === 2 && optional.permissions.includes('scripting'))
    unsupported.push({
      capability: 'scripting',
      required: false,
      reason: 'Native scripting is available only to Manifest V3 extensions.',
    });
  for (const origin of optional.origins)
    if (!supportedHost(origin))
      unsupported.push({
        capability: origin,
        required: false,
        reason: 'This optional origin cannot be granted.',
      });
  for (const key of ['chrome_url_overrides', 'sandbox', 'declarative_net_request'])
    if (manifest[key])
      unsupported.push({
        capability: key,
        required: true,
        reason: 'This extension context or engine feature is not supported.',
      });
  return {
    required,
    optional,
    unsupported,
    compatible: !unsupported.some((item) => item.required),
    limitations: [
      'Compatibility is limited to the documented Electron and Zacro APIs; undeclared API use can still fail.',
    ],
  };
}
function requiresReview(previous, next, grants) {
  return (
    next.required.permissions.some((value) => !grants.permissions.includes(value)) ||
    next.required.origins.some((value) => !grants.origins.includes(value)) ||
    next.unsupported.some(
      (value) =>
        !previous.unsupported.some(
          (old) => old.capability === value.capability && old.required === value.required,
        ),
    )
  );
}
module.exports = { inspectManifest, compareVersions, requiresReview, supportedHost };
