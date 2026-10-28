'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { macContainingVolume, macFileSystem } = require('../lib/preflight.cjs');

const output = (mount = '/System/Volumes/Data', device = '/dev/disk3s5') =>
  `Filesystem 512-blocks Used Available Capacity Mounted on\n${device} 994662584 300000000 600000000 34% ${mount}\n`;
const plist = (type) =>
  `<?xml version="1.0"?><plist><dict><key>FilesystemType</key>\n<string>${type}</string></dict></plist>`;

test('Mac filesystem discovery queries the containing Data mount instead of a home subdirectory', async () => {
  const calls = [];
  const result = await macFileSystem('/Users/runner/work/native-build', async (program, args) => {
    calls.push({ program, args });
    return program === '/bin/df' ? { ok: true, output: output() } : { ok: true, output: plist('apfs') };
  });
  assert.deepEqual(calls, [
    { program: '/bin/df', args: ['-P', '-I', '/Users/runner/work/native-build'] },
    { program: '/usr/sbin/diskutil', args: ['info', '-plist', '/System/Volumes/Data'] },
  ]);
  assert.deepEqual(result, { fileSystem: 'apfs', mountPoint: '/System/Volumes/Data' });
});

test('external volumes and paths resolved through links retain their actual containing mount', async () => {
  const calls = [];
  const result = await macFileSystem('/tmp/link-to-external/source', async (program, args) => {
    calls.push({ program, args });
    return program === '/bin/df'
      ? { ok: true, output: output('/Volumes/External Build Disk', '/dev/disk8s2') }
      : { ok: true, output: plist('exfat') };
  });
  assert.deepEqual(calls[1], {
    program: '/usr/sbin/diskutil',
    args: ['info', '-plist', '/Volumes/External Build Disk'],
  });
  assert.deepEqual(result, { fileSystem: 'exfat', mountPoint: '/Volumes/External Build Disk' });
  assert.equal(
    calls.some(({ args }) => args.includes('/')),
    false,
  );
  assert.deepEqual(macContainingVolume(output('/', '/dev/disk3s1s1')), {
    device: '/dev/disk3s1s1',
    mountPoint: '/',
  });
});

test('unusable or ambiguous df output does not guess a volume or invoke diskutil', async () => {
  for (const value of [
    '',
    'not filesystem data',
    `${output()}/dev/disk8s2 100 20 80 20% /Volumes/Other\n`,
    output().replace('/System/Volumes/Data', 'relative/path'),
    output().replace('/dev/disk3s5', 'remote:/share'),
    output().replace('34%', 'unknown'),
  ]) {
    assert.equal(macContainingVolume(value), null);
    let calls = 0;
    assert.deepEqual(
      await macFileSystem('/Users/runner', async (program) => {
        calls++;
        assert.equal(program, '/bin/df');
        return { ok: true, output: value };
      }),
      { fileSystem: null, mountPoint: null },
    );
    assert.equal(calls, 1);
  }
  assert.deepEqual(await macFileSystem('/Users/runner', async () => ({ ok: false })), {
    fileSystem: null,
    mountPoint: null,
  });
});

test('diskutil failure or an absent filesystem type remains unverified rather than assumed APFS', async () => {
  for (const detail of [{ ok: false }, { ok: true, output: '<plist><dict/></plist>' }]) {
    const result = await macFileSystem('/Users/runner', async (program) =>
      program === '/bin/df' ? { ok: true, output: output() } : detail,
    );
    assert.deepEqual(result, { fileSystem: null, mountPoint: '/System/Volumes/Data' });
  }
});

test(
  'native Mac filesystem discovery resolves a real subdirectory mount',
  {
    skip: process.platform !== 'darwin' ? 'Requires native macOS df and diskutil.' : false,
  },
  async () => {
    const result = await macFileSystem(require('node:os').homedir());
    assert.ok(result.mountPoint?.startsWith('/'));
    assert.ok(result.fileSystem);
  },
);
