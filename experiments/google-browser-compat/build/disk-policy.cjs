'use strict';

function diskPolicy(env = process.env) {
  const value = env.ZACRO_NATIVE_LOW_DISK;
  if (value !== undefined && value !== '0' && value !== '1')
    throw new Error('ZACRO_NATIVE_LOW_DISK must be 0 or 1.');
  const lowDisk = value === '1';
  return { lowDisk, sourceMinimumGiB: lowDisk ? 20 : 100, buildMinimumGiB: lowDisk ? 20 : 40 };
}

module.exports = { diskPolicy };
