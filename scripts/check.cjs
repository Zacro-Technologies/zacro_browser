'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let failed = false;
function visit(dir) {
  for (const file of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, file.name);
    if (file.isDirectory()) visit(full);
    else if (/\.(c?js|mjs)$/.test(file.name)) {
      const result = spawnSync(process.execPath, ['--check', full], { encoding: 'utf8' });
      if (result.status !== 0) {
        failed = true;
        process.stderr.write(result.stderr);
      }
    }
  }
}
for (const dir of ['src', 'scripts', 'services', 'test']) visit(dir);
console.log(failed ? 'Syntax validation failed.' : 'All JavaScript files passed syntax validation.');
process.exitCode = failed ? 1 : 0;
