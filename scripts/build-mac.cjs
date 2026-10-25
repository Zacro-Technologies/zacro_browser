'use strict';
const { build, Platform, Arch } = require('electron-builder');
const { validateRuntime } = require('./prepare-runtime.cjs');

async function buildMac({ directory = false, release = false } = {}) {
  await validateRuntime('darwin', process.arch);
  if (release) process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'true';
  // Ad-hoc previews intentionally disable Hardened Runtime to avoid granting
  // disable-library-validation merely to run a local, unsigned test build.
  // The release path uses Developer ID, Hardened Runtime and notarization.
  return build({
    targets: Platform.MAC.createTarget(directory ? ['dir'] : ['dmg', 'zip'], Arch[process.arch]),
    config: release
      ? { forceCodeSigning: true }
      : {
          mac: {
            identity: '-',
            hardenedRuntime: false,
            notarize: false,
            artifactName: 'Zacro-${version}-mac-${arch}-development.${ext}',
          },
          dmg: { sign: false },
        },
  });
}

if (require.main === module) {
  const unknown = process.argv.slice(2).filter((argument) => argument !== '--dir');
  const task = unknown.length
    ? Promise.reject(
        new Error('Only --dir is supported. Build each architecture on its matching native Node.js host.'),
      )
    : buildMac({ directory: process.argv.includes('--dir') });
  task.catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
module.exports = { buildMac };
