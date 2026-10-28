'use strict';
const { preflight } = require('../lib/preflight.cjs');
const lock = require('./native-build.lock.json');

async function nativePreflight({ root, platform, phase = 'source' } = {}) {
  if (!['source', 'build'].includes(phase)) throw new Error('Unknown native build phase.');
  const report = await preflight({ root, platform });
  report.sourceVersion = lock.sourceVersion;
  report.sourceRevision = lock.sourceRevision;
  report.phase = phase;
  report.requirements = structuredClone(report.requirements);
  report.requirements.macOS.upstreamOfficialSdk = '26.5';
  report.requirements.macOS.upstreamOfficialSdkBuild = '25F70';
  report.sourceBuild.warnings = report.sourceBuild.warnings.filter(
    (message) => !message.startsWith('Installed SDK differs'),
  );
  if (report.host.startsWith('darwin') && report.tools.macSdk && report.tools.macSdk !== '26.5')
    report.sourceBuild.warnings.push(
      'SDK differs from Chromium 156 official SDK 26.5 / 25F70; minimum SDK 15 still applies.',
    );
  // The 100 GiB initial checkout guard is separate from remaining headroom after
  // sources/dependencies have occupied disk. Compilation must retain a reserve.
  if (phase === 'build') {
    report.sourceBuild.blockers = report.sourceBuild.blockers.filter(
      (message) => message !== 'Available disk is below the experiment source-checkout guard of 100 GiB.',
    );
    if (report.freeGiB < 40)
      report.sourceBuild.blockers.push('Compilation requires at least 40 GiB remaining before it starts.');
  }
  report.diskReserveGiB = 15;
  report.sourceBuild.ready = report.sourceBuild.blockers.length === 0;
  return report;
}
module.exports = { nativePreflight };
