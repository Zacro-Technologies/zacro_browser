'use strict';
const { preflight } = require('../lib/preflight.cjs');
const lock = require('./native-build.lock.json');
const { diskPolicy } = require('./disk-policy.cjs');

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
  const policy = diskPolicy();
  report.diskPolicy = policy;
  if (phase === 'build' || policy.lowDisk) {
    report.sourceBuild.blockers = report.sourceBuild.blockers.filter(
      (message) => message !== 'Available disk is below the experiment source-checkout guard of 100 GiB.',
    );
    const minimum = phase === 'build' ? policy.buildMinimumGiB : policy.sourceMinimumGiB;
    if (report.freeGiB < minimum)
      report.sourceBuild.blockers.push(
        `Native ${phase} requires at least ${minimum} GiB remaining before it starts.`,
      );
  }
  if (policy.lowDisk)
    report.sourceBuild.warnings.push(
      'Low-disk attempt enabled: 20 GiB starting floor; the 15 GiB runtime stop remains active. Completion is not guaranteed.',
    );
  report.diskReserveGiB = 15;
  report.sourceBuild.ready = report.sourceBuild.blockers.length === 0;
  return report;
}
module.exports = { nativePreflight };
