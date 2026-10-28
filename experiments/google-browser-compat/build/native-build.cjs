#!/usr/bin/env node
'use strict';

// Build the full native browser. Never reads an existing browser profile.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { ensureRoot, assertContained, assertRegularMarker } = require('../lib/paths.cjs');
const { digests, writeStoredZip } = require('../lib/artifacts.cjs');
const { manualEnvironment, validateStartURL } = require('../cli.cjs');
const { nativePreflight } = require('./native-preflight.cjs');
const { sourceLayout, sourceEnvironment, owner, execute } = require('./native-source.cjs');
const branding = require('../native-branding/apply.cjs');
const lock = require('./native-build.lock.json');
const { managedTools } = require('./managed-tools.cjs');
const { windowsInventory, macInventory } = require('./runtime-inventory.cjs');
const { verifySource, verifySyncReceipt } = require('./native-sync.cjs');
const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');

function options(argv) {
  const commands = {
    preflight: ['root', 'platform'],
    configure: ['root', 'platform'],
    build: ['root', 'platform', 'jobs'],
    package: ['root', 'platform'],
    launch: ['root', 'platform', 'role', 'url'],
  };
  const [command, ...rest] = argv;
  if (!commands[command]) throw new Error('Use preflight, configure, build, package or launch.');
  const result = { command };
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index].replace(/^--/, '');
    if (
      !rest[index].startsWith('--') ||
      !commands[command].includes(key) ||
      Object.hasOwn(result, key) ||
      !rest[index + 1] ||
      rest[index + 1].startsWith('--')
    )
      throw new Error('Invalid or repeated native build option.');
    result[key] = rest[index + 1];
  }
  result.platform ||= `${process.platform}-${process.arch}`;
  if (!lock.platforms.includes(result.platform)) throw new Error('Unsupported native target.');
  if (result.jobs !== undefined && !/^(?:[1-9]|[1-5][0-9]|6[0-4])$/.test(result.jobs))
    throw new Error('Jobs must be between 1 and 64.');
  if (command === 'launch' && !['regular-a', 'regular-b', 'private'].includes(result.role))
    throw new Error('Choose regular-a, regular-b or private.');
  if (command === 'launch') validateStartURL(result.url);
  return result;
}

function buildLayout(root, platform) {
  const source = sourceLayout(root, platform);
  const evidence = path.join(root, 'native-builds', lock.sourceVersion, platform);
  return {
    ...source,
    evidence,
    out: path.join(source.src, 'out', 'ZacroPrototype'),
    configured: path.join(evidence, 'configure.json'),
    built: path.join(evidence, 'build.json'),
  };
}

async function save(filename, data) {
  try {
    await assertRegularMarker(filename);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
  await fs.mkdir(path.dirname(filename), { recursive: true });
  const handle = await fs.open(temporary, 'wx');
  try {
    await handle.writeFile(JSON.stringify(data, null, 2) + '\n');
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(temporary, filename);
}

async function nativeContext(args, { requireSource = true, phase = 'build' } = {}) {
  if (args.platform !== `${process.platform}-${process.arch}`)
    throw new Error('Run on the selected native OS and architecture.');
  const root = await ensureRoot(args.root);
  const layout = buildLayout(root, args.platform);
  for (const location of [layout.evidence, layout.out, layout.configured, layout.built])
    await assertContained(root, location);
  if (requireSource) await owner(layout, root, args.platform, false);
  const report = await nativePreflight({ root, platform: args.platform, phase });
  const env = sourceEnvironment(layout.depot);
  if (process.platform === 'win32') {
    const compiler = report.tools.visualStudio?.find((item) => Number(item.version.split('.')[0]) >= 18);
    if (compiler) env.vs2026_install = compiler.path;
  }
  return { root, layout, report, env };
}

function assertReady(report) {
  if (!report.sourceBuild.ready)
    throw new Error(`Native compilation is blocked: ${report.sourceBuild.blockers.join(' ')}`);
}

async function argumentsText(platform) {
  return fs.readFile(path.join(__dirname, `native-args.${platform}.gn`), 'utf8');
}

function outputOwner(platform, patchSha256 = branding.manifest.patch.sha256) {
  return {
    schemaVersion: 1,
    kind: 'zacro-native-build-output',
    platform,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: patchSha256,
  };
}

async function verifyOutputOwner(context, platform) {
  const filename = await assertContained(
    context.root,
    path.join(context.layout.out, '.zacro-native-output.json'),
  );
  await assertRegularMarker(filename);
  if (
    JSON.stringify(JSON.parse(await fs.readFile(filename, 'utf8'))) !== JSON.stringify(outputOwner(platform))
  )
    throw new Error('Build-output ownership differs from this native source pin.');
}

async function configure(args) {
  const context = await nativeContext(args);
  const { root, layout, report, env } = context;
  assertReady(report);
  await verifySource({ layout, platform: args.platform, env, execute });
  const tools = await managedTools({ root, layout, env, execute, bootstrap: false });
  const sync = await verifySyncReceipt({ root, layout, platform: args.platform, env, execute, tools });
  const patched = await branding.apply({ source: layout.src });
  const expectedOwner = outputOwner(args.platform, patched.patchSha256);
  const outOwner = path.join(layout.out, '.zacro-native-output.json');
  await fs.mkdir(layout.out, { recursive: true });
  const existing = await fs.readdir(layout.out);
  if (!existing.includes(path.basename(outOwner))) {
    if (existing.length) throw new Error('Refusing to adopt an existing build output directory.');
    await fs.writeFile(outOwner, JSON.stringify(expectedOwner, null, 2) + '\n', { flag: 'wx' });
  } else {
    await assertRegularMarker(outOwner);
    if (JSON.stringify(JSON.parse(await fs.readFile(outOwner))) !== JSON.stringify(expectedOwner))
      throw new Error('Build-output ownership differs from this native source pin.');
  }
  const desired = await argumentsText(args.platform);
  const argsPath = path.join(layout.out, 'args.gn');
  try {
    await assertRegularMarker(argsPath);
    if ((await fs.readFile(argsPath, 'utf8')) !== desired)
      throw new Error('Existing GN arguments were changed; retained without replacement.');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await fs.writeFile(argsPath, desired, { flag: 'wx' });
  }
  await execute(tools.vpython, [path.join(layout.depot, 'gclient.py'), 'runhooks'], {
    cwd: layout.checkout,
    env,
    diskRoot: root,
  });
  await execute(
    tools.python,
    [path.join(layout.depot, 'gn.py'), 'gen', layout.out, '--fail-on-unused-args'],
    {
      cwd: layout.src,
      env,
      diskRoot: root,
    },
  );
  await verifySource({ layout, platform: args.platform, env, execute, expectPatched: true });
  const result = {
    schemaVersion: 1,
    productName: lock.productName,
    platform: args.platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    depotToolsRevision: lock.depotToolsRevision,
    brandingPatchSha256: patched.patchSha256,
    gnArgsSha256: sha256(desired),
    syncEvidence: { receipt: sync.receipt, dependencyCount: sync.dependencyCount },
    configuredAt: new Date().toISOString(),
    compiled: false,
  };
  await save(layout.configured, result);
  return result;
}

async function verifyConfiguration(context, platform) {
  const { layout } = context;
  await verifyOutputOwner(context, platform);
  await assertRegularMarker(layout.configured);
  const configured = JSON.parse(await fs.readFile(layout.configured, 'utf8'));
  const patch = await branding.inspect({ source: layout.src });
  const expectedArgs = await argumentsText(platform);
  const argsPath = await assertContained(context.root, path.join(layout.out, 'args.gn'));
  await assertRegularMarker(argsPath);
  if (
    configured.schemaVersion !== 1 ||
    configured.compiled !== false ||
    configured.productName !== lock.productName ||
    configured.sourceVersion !== lock.sourceVersion ||
    !Number.isFinite(Date.parse(configured.configuredAt)) ||
    patch.state !== 'patched' ||
    configured.sourceRevision !== lock.sourceRevision ||
    configured.depotToolsRevision !== lock.depotToolsRevision ||
    configured.platform !== platform ||
    configured.brandingPatchSha256 !== patch.patchSha256 ||
    configured.gnArgsSha256 !== sha256(expectedArgs) ||
    (await fs.readFile(argsPath, 'utf8')) !== expectedArgs
  )
    throw new Error(
      'Source, patch or build configuration changed. Configure the matching prototype before building.',
    );
  const depotHead = await execute('git', ['-C', layout.depot, 'rev-parse', 'HEAD'], {
    env: context.env,
    capture: true,
  });
  if (depotHead !== lock.depotToolsRevision) throw new Error('Depot tools revision changed.');
  const sync = await verifySyncReceipt({ ...context, platform, execute, expectPatched: true });
  if (
    JSON.stringify({ receipt: sync.receipt, dependencyCount: sync.dependencyCount }) !==
    JSON.stringify(configured.syncEvidence)
  )
    throw new Error('Dependency sync evidence changed; configure again before compilation.');
  return configured;
}

async function runtimeFiles(context, platform) {
  const { root, layout, env } = context;
  if (platform.startsWith('darwin')) {
    const bundle = path.join(layout.out, 'Zacro Prototype.app');
    await assertContained(root, bundle);
    return macInventory(bundle);
  }
  const dependencies = await execute(
    context.tools.python,
    [path.join(layout.depot, 'gn.py'), 'desc', layout.out, '//chrome:chrome', 'runtime_deps'],
    { cwd: layout.src, env, capture: true },
  );
  return windowsInventory(layout.out, dependencies);
}

async function build(args) {
  const context = await nativeContext(args);
  assertReady(context.report);
  const { root, layout, env } = context;
  context.tools = await managedTools({ root, layout, env, execute, bootstrap: false });
  const configured = await verifyConfiguration(context, args.platform);
  await execute(
    context.tools.python,
    [path.join(layout.depot, 'autoninja.py'), '-C', layout.out, '-j', args.jobs || '8', 'chrome'],
    { cwd: layout.src, env, diskRoot: root },
  );
  const after = await verifyConfiguration(context, args.platform);
  if (JSON.stringify(after) !== JSON.stringify(configured))
    throw new Error('Native configuration changed during compilation; no build receipt was issued.');
  const executableRelative = branding.manifest.outputs[args.platform];
  const executable = await assertContained(layout.out, path.join(layout.out, executableRelative));
  const executableSha256 = (await digests(executable)).sha256;
  const files = await runtimeFiles(context, args.platform);
  if (!files.some((file) => file.path === executableRelative && file.sha256 === executableSha256))
    throw new Error('Built executable missing from runtime integrity inventory.');
  const result = {
    ...configured,
    configurationSha256: sha256(JSON.stringify(configured)),
    builtAt: new Date().toISOString(),
    executableRelative,
    executableSha256,
    runtimeSha256: sha256(JSON.stringify(files)),
    compiled: true,
    files,
    securityConfiguration: 'upstream sandbox, TLS and native permission/authentication services retained',
    signedForDistribution: false,
    googleAcceptance: 'untested',
  };
  await save(layout.built, result);
  return { ...result, files: `${files.length} verified runtime entries`, receiptPath: layout.built };
}

async function verifiedBuild(args) {
  const context = await nativeContext(args);
  try {
    await assertRegularMarker(context.layout.built);
  } catch (error) {
    if (error.code === 'ENOENT')
      throw new Error(
        'The native prototype has not been built. Complete configure and build before packaging or launch.',
      );
    throw error;
  }
  const receipt = JSON.parse(await fs.readFile(context.layout.built, 'utf8'));
  if (
    receipt.schemaVersion !== 1 ||
    receipt.compiled !== true ||
    receipt.productName !== lock.productName ||
    receipt.sourceVersion !== lock.sourceVersion ||
    receipt.sourceRevision !== lock.sourceRevision ||
    receipt.platform !== args.platform ||
    receipt.brandingPatchSha256 !== branding.manifest.patch.sha256 ||
    receipt.executableRelative !== branding.manifest.outputs[args.platform] ||
    !Array.isArray(receipt.files)
  )
    throw new Error('Native build receipt does not identify this prototype.');
  context.tools = await managedTools({ ...context, execute, bootstrap: false });
  const configured = await verifyConfiguration(context, args.platform);
  if (receipt.configurationSha256 !== sha256(JSON.stringify(configured)))
    throw new Error('Native configuration changed after this build. Rebuild before packaging or launch.');
  const actual = await runtimeFiles(context, args.platform);
  if (
    JSON.stringify(actual) !== JSON.stringify(receipt.files) ||
    sha256(JSON.stringify(actual)) !== receipt.runtimeSha256
  )
    throw new Error('Native runtime changed after compilation. It was not launched or packaged.');
  const executable = await assertContained(
    context.layout.out,
    path.join(context.layout.out, receipt.executableRelative),
  );
  if ((await digests(executable)).sha256 !== receipt.executableSha256)
    throw new Error('Built executable hash differs.');
  return { ...context, receipt, executable };
}

async function packageBuild(args) {
  const { root, layout, receipt } = await verifiedBuild(args);
  const directory = await assertContained(root, path.join(root, 'native-output'));
  await fs.mkdir(directory, { recursive: true });
  const destination = path.join(
    directory,
    `Zacro-Prototype-${lock.sourceVersion}-${args.platform}-${receipt.runtimeSha256.slice(0, 12)}.zip`,
  );
  try {
    await fs.access(destination);
    throw new Error('This exact output archive already exists; it was retained.');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const staging = await assertContained(root, path.join(directory, `.staging-${crypto.randomUUID()}.zip`));
  let integrity;
  try {
    if (args.platform === 'win32-x64') {
      const entries = receipt.files.map((file) => ({
        name: `Zacro Prototype/${file.path}`,
        source: path.join(layout.out, file.path),
      }));
      entries.push({
        name: 'Zacro Prototype/NATIVE-BUILD.json',
        data: JSON.stringify({ ...receipt, files: undefined }, null, 2) + '\n',
      });
      entries.push({ name: 'Zacro Prototype/LICENSE.chromium', source: path.join(layout.src, 'LICENSE') });
      await writeStoredZip(staging, entries);
    } else {
      await execute('/usr/bin/ditto', [
        '-c',
        '-k',
        '--sequesterRsrc',
        '--keepParent',
        path.join(layout.out, 'Zacro Prototype.app'),
        staging,
      ]);
    }
    integrity = await digests(staging);
    // Publish without replacing a file another invocation may have created.
    await fs.link(staging, destination);
  } finally {
    // Only this invocation's randomly named staging file is removed. Published
    // archives and another invocation's destination are never overwritten.
    await assertContained(root, staging);
    await fs.unlink(staging).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
  }
  const result = {
    schemaVersion: 1,
    productName: lock.productName,
    platform: args.platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: receipt.brandingPatchSha256,
    executableSha256: receipt.executableSha256,
    runtimeSha256: receipt.runtimeSha256,
    compiled: true,
    signedForDistribution: false,
    googleAcceptance: 'untested',
    destination,
    ...integrity,
  };
  await save(`${destination}.json`, result);
  return result;
}

async function launch(args) {
  const { root, receipt, executable } = await verifiedBuild(args);
  const directory = await assertContained(
    root,
    path.join(
      root,
      'profiles',
      'zacro-native',
      lock.sourceVersion,
      args.platform,
      receipt.runtimeSha256,
      args.role,
    ),
  );
  await fs.mkdir(directory, { recursive: true });
  const marker = path.join(directory, '.zacro-native-profile.json');
  const expected = {
    schemaVersion: 1,
    kind: 'manual-native-zacro-profile',
    platform: args.platform,
    sourceRevision: lock.sourceRevision,
    executableSha256: receipt.executableSha256,
    runtimeSha256: receipt.runtimeSha256,
    role: args.role,
  };
  const entries = await fs.readdir(directory);
  if (!entries.includes(path.basename(marker))) {
    if (entries.length) throw new Error('Refusing to adopt an existing profile.');
    await fs.writeFile(marker, JSON.stringify(expected, null, 2) + '\n', { flag: 'wx' });
  } else {
    await assertRegularMarker(marker);
    if (JSON.stringify(JSON.parse(await fs.readFile(marker, 'utf8'))) !== JSON.stringify(expected))
      throw new Error('Profile ownership differs from this native build.');
  }
  const flags = [`--user-data-dir=${directory}`, '--no-first-run', '--profile-directory=Default'];
  if (args.role === 'private') flags.push('--incognito');
  flags.push(validateStartURL(args.url));
  const child = spawn(executable, flags, {
    detached: true,
    stdio: 'ignore',
    windowsHide: false,
    env: manualEnvironment(),
  });
  await new Promise((resolve, reject) => {
    child.once('spawn', resolve);
    child.once('error', reject);
  });
  child.unref();
  const result = {
    schemaVersion: 1,
    launchedAt: new Date().toISOString(),
    productName: lock.productName,
    platform: args.platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: receipt.brandingPatchSha256,
    executableSha256: receipt.executableSha256,
    runtimeSha256: receipt.runtimeSha256,
    role: args.role,
    processId: child.pid,
    automationAttached: false,
    googleAcceptance: 'untested',
  };
  await save(
    await assertContained(root, path.join(root, 'launches', `native-${crypto.randomUUID()}.json`)),
    result,
  );
  return result;
}

async function main(argv) {
  const args = options(argv);
  if (args.command === 'preflight') return nativePreflight(args);
  if (args.command === 'configure') return configure(args);
  if (args.command === 'build') return build(args);
  if (args.command === 'package') return packageBuild(args);
  return launch(args);
}
if (require.main === module)
  main(process.argv.slice(2))
    .then((result) => process.stdout.write(JSON.stringify(result, null, 2) + '\n'))
    .catch((error) => {
      process.stderr.write(error.message + '\n');
      process.exitCode = 1;
    });
module.exports = {
  options,
  buildLayout,
  nativeContext,
  verifyConfiguration,
  configure,
  build,
  runtimeFiles,
  verifiedBuild,
  packageBuild,
  launch,
  main,
};
