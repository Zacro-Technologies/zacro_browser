'use strict';

// Exact-file patch integration check. This creates a small external copy, not
// a Chromium checkout, and deliberately does not claim compilation or execution.
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { manifest, inspect, verifiedPatch } = require('./apply.cjs');
const execute = promisify(execFile);

async function validate(referenceDirectory) {
  if (!referenceDirectory || !path.isAbsolute(referenceDirectory))
    throw new Error('Provide the absolute directory containing the pinned upstream files.');
  const references = await inspect({ source: referenceDirectory, requireRevision: false });
  if (references.state !== 'unpatched') throw new Error('Validation starts from exact upstream originals.');
  const copy = await fs.mkdtemp(path.join(referenceDirectory, '.zacro-validated-'));
  for (const file of manifest.files) {
    const target = path.join(copy, file.path);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.copyFile(path.join(referenceDirectory, file.path), target);
  }
  const patch = await verifiedPatch();
  await execute(
    'git',
    ['-c', 'core.autocrlf=false', '-C', copy, 'apply', '--check', '--whitespace=error', patch],
    { windowsHide: true },
  );
  await execute('git', ['-c', 'core.autocrlf=false', '-C', copy, 'apply', '--whitespace=error', patch], {
    windowsHide: true,
  });
  const after = await inspect({ source: copy, requireRevision: false });
  if (after.state !== 'patched') throw new Error('Sparse application did not produce the reviewed files.');
  const result = {
    schemaVersion: 1,
    checkedAt: new Date().toISOString(),
    sourceRevision: manifest.revision,
    patchSha256: manifest.patch.sha256,
    selectedUpstreamFilesVerified: manifest.files.length,
    forwardApply: 'passed',
    reverseApplyCheck: 'passed',
    outputHashes: 'passed',
    fullCheckoutRevisionVerified: false,
    compiled: false,
    executed: false,
    googleAcceptance: 'untested',
    validationDirectory: copy,
  };
  await fs.writeFile(path.join(copy, 'validation-result.json'), JSON.stringify(result, null, 2) + '\n');
  return result;
}
if (require.main === module)
  validate(process.argv[2])
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
module.exports = { validate };
