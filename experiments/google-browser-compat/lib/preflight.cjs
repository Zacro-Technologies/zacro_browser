'use strict';
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { resolveRoot } = require('./paths.cjs');
const execute = promisify(execFile);
const sourceRequirements = Object.freeze({
  windows: {
    visualStudioMinimum: '18.0.0',
    sdkRelease: '10.0.28000.2270',
    sdkIncludeDirectory: '10.0.28000.0',
    debuggerMinimum: '10.0.26100.3323',
    fileSystem: 'NTFS',
  },
  macOS: {
    minimumSdk: '15',
    upstreamOfficialSdk: '27.0',
    upstreamOfficialSdkBuild: '26A425',
    minimumDeploymentTarget: '13.0',
    fileSystem: 'APFS',
  },
  sourceResourcePolicy: {
    minimumFreeGiB: 100,
    minimumRamGiB: 8,
    recommendedFreeGiB: 200,
    recommendedRamGiB: 32,
    basis:
      '100 GB/8 GB are documented Windows floors; this experiment conservatively applies equivalent storage/RAM preflight guards on Mac. They are not claims of official Mac minima or sufficient build capacity.',
  },
});
function versionAtLeast(actual, required) {
  const left = String(actual).split('.').map(Number),
    right = String(required).split('.').map(Number);
  if (left.some((part) => !Number.isFinite(part))) return false;
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    if ((left[index] || 0) !== (right[index] || 0)) return (left[index] || 0) > (right[index] || 0);
  }
  return true;
}
async function command(program, args) {
  try {
    return {
      ok: true,
      output: (
        await execute(program, args, { windowsHide: true, timeout: 20000, maxBuffer: 256 * 1024 })
      ).stdout.trim(),
    };
  } catch (error) {
    return { ok: false, error: error.code || 'command-failed' };
  }
}
async function existingDirectory(input) {
  let target = input;
  while (true) {
    try {
      await fs.access(target);
      return target;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const parent = path.dirname(target);
      if (parent === target) throw error;
      target = parent;
    }
  }
}

function macContainingVolume(output) {
  if (typeof output !== 'string') return null;
  const rows = output.trim().split(/\r?\n/u);
  // df -P -I emits one header and one row for the single requested path.
  // The mount point is the remaining field, so volume names may contain spaces.
  if (rows.length !== 2) return null;
  const match = rows[1].match(/^(\/dev\/disk\d+(?:s\d+)*)\s+-?\d+\s+-?\d+\s+-?\d+\s+\d+%\s+(\/.*)$/u);
  if (!match || /[\0\r\n]/u.test(match[2])) return null;
  return { device: match[1], mountPoint: match[2] };
}

async function macFileSystem(directory, run = command) {
  // diskutil accepts a device or mount point, not an arbitrary descendant.
  // df uses statfs on the requested path, which also preserves external volumes
  // and APFS Data-volume/firmlink resolution instead of assuming the root volume.
  const discovered = await run('/bin/df', ['-P', '-I', directory]);
  const volume = discovered.ok ? macContainingVolume(discovered.output) : null;
  if (!volume) return { fileSystem: null, mountPoint: null };
  const detail = await run('/usr/sbin/diskutil', ['info', '-plist', volume.mountPoint]);
  return {
    fileSystem: detail.ok
      ? detail.output.match(/<key>FilesystemType<\/key>\s*<string>([A-Za-z0-9_-]+)<\/string>/u)?.[1] || null
      : null,
    mountPoint: volume.mountPoint,
  };
}
async function preflight({ root: input, platform = `${process.platform}-${process.arch}` } = {}) {
  const root = resolveRoot(input),
    nearest = await existingDirectory(root),
    disk = await fs.statfs(nearest);
  const report = {
    schemaVersion: 1,
    observedAt: new Date().toISOString(),
    host: `${process.platform}-${process.arch}`,
    requestedPlatform: platform,
    node: process.versions.node,
    osRelease: os.release(),
    root,
    logicalCpus: os.cpus().length,
    ramGiB: Number((os.totalmem() / 1024 ** 3).toFixed(2)),
    freeGiB: Number(((disk.bavail * disk.bsize) / 1024 ** 3).toFixed(2)),
    requirements: sourceRequirements,
    tools: {},
    sourceBuild: { ready: false, blockers: [], warnings: [] },
    runtimeExperiment: {
      nativeExecutionAvailable:
        ['win32-x64', 'darwin-arm64'].includes(platform) &&
        platform === `${process.platform}-${process.arch}`,
      liveGoogleAcceptance: 'untested',
      customBrowserCompiled: false,
    },
  };
  const { blockers, warnings } = report.sourceBuild;
  if (!versionAtLeast(process.versions.node, '24.0.0'))
    blockers.push('Experiment tooling requires Node.js 24 or newer.');
  if (platform !== report.host)
    blockers.push('This host cannot establish native build or execution results for the requested platform.');
  if (!['win32-x64', 'darwin-arm64', 'darwin-x64'].includes(platform))
    blockers.push('This source plan supports Windows x64 and Mac arm64/x64 only.');
  if (/\s/.test(path.join(root, 'source')))
    blockers.push('The source checkout path must not contain spaces.');
  if (report.freeGiB < sourceRequirements.sourceResourcePolicy.minimumFreeGiB)
    blockers.push('Available disk is below the experiment source-checkout guard of 100 GiB.');
  if (report.ramGiB < sourceRequirements.sourceResourcePolicy.minimumRamGiB)
    blockers.push('Available RAM is below the experiment source-build guard of 8 GiB.');
  if (report.freeGiB < 200)
    warnings.push(
      'Less than 200 GiB free: toolchain installation, dependencies and outputs may exceed the remaining headroom.',
    );
  if (report.ramGiB < 32)
    warnings.push('Less than 32 GiB RAM: linking and local compile throughput may be constrained.');
  report.tools.git = await command('git', ['--version']);
  if (!report.tools.git.ok) blockers.push('Git was not found.');
  if (process.platform === 'win32') {
    const programFiles = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
    const vswhere = path.join(programFiles, 'Microsoft Visual Studio/Installer/vswhere.exe');
    const discovery = await command(vswhere, [
      '-all',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      'Microsoft.VisualStudio.Component.VC.ATLMFC',
      '-format',
      'json',
      '-utf8',
    ]);
    let installs = [];
    if (discovery.ok) {
      try {
        installs = JSON.parse(discovery.output || '[]');
      } catch {}
    }
    report.tools.visualStudio = installs.map((item) => ({
      version: item.installationVersion,
      path: item.installationPath,
    }));
    if (
      !installs.some((item) =>
        versionAtLeast(item.installationVersion, sourceRequirements.windows.visualStudioMinimum),
      )
    )
      blockers.push('VS 2026 (18.0+) with x64 C++ and ATL/MFC components is not installed.');
    const kit = path.join(programFiles, 'Windows Kits/10');
    report.tools.sdkIncludeDirectories = await fs.readdir(path.join(kit, 'Include')).catch(() => []);
    if (
      !report.tools.sdkIncludeDirectories.some((version) =>
        versionAtLeast(version, sourceRequirements.windows.sdkIncludeDirectory),
      )
    )
      blockers.push(
        'Windows SDK headers for 10.0.28000.0 or newer were not found. Required SDK release is 10.0.28000.2270.',
      );
    else
      warnings.push(
        'Header folder names omit SDK servicing revisions; confirm installer release 10.0.28000.2270 or newer before a source build.',
      );
    const debugFile = path.join(kit, 'Debuggers/x64/dbghelp.dll');
    const debug = await command('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      `(Get-Item -LiteralPath '${debugFile.replaceAll("'", "''")}' -ErrorAction Stop).VersionInfo.FileVersion`,
    ]);
    report.tools.debuggingTools = debug.ok ? debug.output.match(/\d+\.\d+\.\d+\.\d+/)?.[0] || null : null;
    if (
      !report.tools.debuggingTools ||
      !versionAtLeast(report.tools.debuggingTools, sourceRequirements.windows.debuggerMinimum)
    )
      blockers.push('Required x64 Windows SDK Debugging Tools were not verified.');
    const drive = path.parse(root).root.match(/^([A-Za-z]):/)?.[1];
    const volume = drive
      ? await command('powershell.exe', [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          `(Get-Volume -DriveLetter '${drive}' -ErrorAction Stop).FileSystem`,
        ])
      : { ok: false };
    report.fileSystem = volume.ok ? volume.output : null;
    if (report.fileSystem?.toUpperCase() !== 'NTFS')
      blockers.push('Source-checkout volume was not confirmed as NTFS.');
  } else if (process.platform === 'darwin') {
    report.tools.xcode = await command('/usr/bin/xcodebuild', ['-version']);
    const sdk = await command('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-version']);
    report.tools.macSdk = sdk.ok ? sdk.output : null;
    if (!report.tools.xcode.ok || !sdk.ok || !versionAtLeast(sdk.output, sourceRequirements.macOS.minimumSdk))
      blockers.push('Xcode and the pinned source minimum macOS SDK 15 or newer are required.');
    else if (sdk.output !== sourceRequirements.macOS.upstreamOfficialSdk)
      warnings.push(
        'Installed SDK differs from upstream official SDK 27.0; this is not the source minimum, but the exact build is not yet validated.',
      );
    const volume = await macFileSystem(nearest);
    report.fileSystem = volume.fileSystem;
    report.fileSystemMountPoint = volume.mountPoint;
    if (report.fileSystem?.toLowerCase() !== 'apfs')
      blockers.push('Source-checkout volume was not confirmed as APFS.');
  } else blockers.push('Source compilation needs a supported native Windows or Mac environment.');
  report.sourceBuild.ready = blockers.length === 0;
  return report;
}
module.exports = { preflight, sourceRequirements, versionAtLeast, macContainingVolume, macFileSystem };
