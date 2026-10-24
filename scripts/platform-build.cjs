'use strict';

const path = require('node:path');

function assertNativeTarget(platform, arch, hostPlatform = process.platform, hostArch = process.arch) {
  if (!['win32', 'darwin', 'linux'].includes(platform) || !['x64', 'arm64'].includes(arch))
    throw new Error('Build a separate x64 or arm64 package; universal and 32-bit packages are unsupported.');
  if (platform !== hostPlatform || arch !== hostArch)
    throw new Error(
      `Build ${platform}/${arch} on a matching Node.js host; this host is ${hostPlatform}/${hostArch}. Run npm ci on the target host first.`,
    );
}

function binaryTarget(bytes) {
  if (bytes.length < 64) return null;
  if (bytes.toString('ascii', 0, 2) === 'MZ') {
    const offset = bytes.readUInt32LE(0x3c);
    if (offset + 6 > bytes.length || bytes.toString('ascii', offset, offset + 4) !== 'PE\0\0') return null;
    return { platform: 'win32', arch: { 0x8664: 'x64', 0xaa64: 'arm64' }[bytes.readUInt16LE(offset + 4)] };
  }
  if (bytes.readUInt32LE(0) === 0xfeedfacf)
    return { platform: 'darwin', arch: { 0x01000007: 'x64', 0x0100000c: 'arm64' }[bytes.readUInt32LE(4)] };
  if (bytes.toString('hex', 0, 4) === '7f454c46' && bytes[4] === 2 && bytes[5] === 1)
    return { platform: 'linux', arch: { 62: 'x64', 183: 'arm64' }[bytes.readUInt16LE(18)] };
  return null;
}

function packagedPaths(root, platform = process.platform, arch = process.arch) {
  if (platform === 'darwin') {
    const bundle = path.join(root, 'dist', arch === 'x64' ? 'mac' : `mac-${arch}`, 'Zacro.app');
    return {
      bundle,
      executable: path.join(bundle, 'Contents/MacOS/Zacro'),
      resources: path.join(bundle, 'Contents/Resources'),
    };
  }
  const directory = path.join(
    root,
    'dist',
    platform === 'win32'
      ? arch === 'x64'
        ? 'win-unpacked'
        : `win-${arch}-unpacked`
      : arch === 'x64'
        ? 'linux-unpacked'
        : `linux-${arch}-unpacked`,
  );
  return {
    bundle: directory,
    executable: path.join(directory, platform === 'win32' ? 'Zacro.exe' : 'zacro-browser'),
    resources: path.join(directory, 'resources'),
  };
}

function notarizationCredentials(env) {
  if (env.APPLE_ID || env.APPLE_APP_SPECIFIC_PASSWORD) {
    if (!env.APPLE_ID || !env.APPLE_APP_SPECIFIC_PASSWORD || !env.APPLE_TEAM_ID)
      throw new Error('Set APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID together.');
    return {
      appleId: env.APPLE_ID,
      appleIdPassword: env.APPLE_APP_SPECIFIC_PASSWORD,
      teamId: env.APPLE_TEAM_ID,
    };
  }
  if (env.APPLE_API_KEY || env.APPLE_API_KEY_ID || env.APPLE_API_ISSUER) {
    if (!env.APPLE_API_KEY || !env.APPLE_API_KEY_ID || !env.APPLE_API_ISSUER)
      throw new Error('Set APPLE_API_KEY, APPLE_API_KEY_ID and APPLE_API_ISSUER together.');
    return {
      appleApiKey: env.APPLE_API_KEY,
      appleApiKeyId: env.APPLE_API_KEY_ID,
      appleApiIssuer: env.APPLE_API_ISSUER,
    };
  }
  if (env.APPLE_KEYCHAIN_PROFILE)
    return {
      keychainProfile: env.APPLE_KEYCHAIN_PROFILE,
      ...(env.APPLE_KEYCHAIN ? { keychain: env.APPLE_KEYCHAIN } : {}),
    };
  throw new Error(
    'A signed macOS release requires Apple notarization credentials or an APPLE_KEYCHAIN_PROFILE.',
  );
}

module.exports = { assertNativeTarget, binaryTarget, packagedPaths, notarizationCredentials };
