'use strict';

// Maintainer tool: regenerate the reviewed patch from exact upstream originals.
// This does not download source, build Chromium, or alter the source directory.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const REVISION = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c';
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2)
    throw new Error(`Expected one source anchor: ${before.slice(0, 70)}`);
  return source.replace(before, after);
}
function guid(value) {
  const fields = value.replaceAll('-', '');
  const bytes = fields
    .slice(16)
    .match(/../g)
    .map((part) => `0x${part}`);
  return (
    `{0x${fields.slice(0, 8)},\n` +
    `                                  0x${fields.slice(8, 12)},\n` +
    `                                  0x${fields.slice(12, 16)},\n` +
    `                                  {${bytes.slice(0, 7).join(', ')},\n` +
    `                                   ${bytes[7]}}}`
  );
}
const transformations = {
  'chrome/app/theme/chromium/BRANDING': (source) => {
    const values = {
      COMPANY_FULLNAME: 'Zacro Technologies',
      COMPANY_SHORTNAME: 'Zacro',
      PRODUCT_FULLNAME: 'Zacro Prototype',
      PRODUCT_SHORTNAME: 'Zacro Prototype',
      PRODUCT_INSTALLER_FULLNAME: 'Zacro Prototype Installer',
      PRODUCT_INSTALLER_SHORTNAME: 'Zacro Prototype Installer',
      MAC_BUNDLE_ID: 'com.zacro.prototype',
      MAC_CREATOR_CODE: 'ZcPr',
    };
    for (const [key, value] of Object.entries(values)) {
      const match = source.match(new RegExp(`^${key}=.*$`, 'm'));
      if (!match) throw new Error(`Missing branding field ${key}`);
      source = replaceOnce(source, match[0], `${key}=${value}`);
    }
    return source;
  },
  'chrome/install_static/chromium_install_modes.h': (source) => {
    for (const [before, after] of [
      ['kProductPathName[] = L"Chromium"', 'kProductPathName[] = L"ZacroPrototype"'],
      ['.base_app_name = L"Chromium"', '.base_app_name = L"Zacro Prototype"'],
      ['.base_app_id = L"Chromium"', '.base_app_id = L"ZacroPrototype"'],
      ['L"ChromiumHTM"', 'L"ZacroPrototypeHTM"'],
      ['L"Chromium HTML Document"', 'L"Zacro Prototype HTML Document"'],
      ['.direct_launch_url_scheme = "chromium"', '.direct_launch_url_scheme = "zacro-prototype"'],
      ['L"ChromiumPDF"', 'L"ZacroPrototypePDF"'],
      ['L"Chromium PDF Document"', 'L"Zacro Prototype PDF Document"'],
      ['{7D2B3E1D-D096-4594-9D8F-A6667F12E0AC}', '{A967A707-D048-4D51-9F8C-9E57864CD0C1}'],
      [
        'L"S-1-15-2-3251537155-1984446955-2931258699-841473695-"\n            L"1938553385-"\n            L"924012148-"',
        'L"S-1-15-2-3045172681-2460473198-1102504830-3674811205-"\n            L"1967338402-"\n            L"2827945061-"',
      ],
    ])
      source = replaceOnce(source, before, after);
    for (const [field, value] of Object.entries({
      toast_activator_clsid: 'E14F2796-3358-4382-86ED-01CA256DB1C2',
      elevator_clsid: '08B480A7-DB52-4490-98D3-53CEAE55C6EA',
      tracing_service_clsid: '3905F73B-97D1-4CD2-B21D-17A73C99FE6F',
    })) {
      const expression = new RegExp(`\\.${field} = \\{[^;]*?\\}\\}`, 'm');
      const match = source.match(expression);
      if (!match) throw new Error(`Missing COM class ${field}`);
      source = replaceOnce(source, match[0], `.${field} = ${guid(value)}`);
    }
    // Interface IIDs describe unchanged upstream COM contracts. Only the class
    // registrations get independent identities; interface implementations stay.
    return source;
  },
  'chrome/common/chrome_paths_mac.mm': (source) =>
    replaceOnce(source, 'product_dir_name = "Chromium";', 'product_dir_name = "Zacro Prototype";'),
  'chrome/app/app-Info.plist': (source) =>
    replaceOnce(
      source,
      '\t<key>CFBundleDisplayName</key>\n\t<string>${EXECUTABLE_NAME}</string>',
      '\t<key>CFBundleDisplayName</key>\n\t<string>${EXECUTABLE_NAME}</string>\n\t<key>CrProductDirName</key>\n\t<string>Zacro Prototype</string>',
    ),
  'chrome/common/chrome_paths.cc': (source) =>
    replaceOnce(
      source,
      '"/Library/Application Support/Chromium/NativeMessagingHosts"',
      '"/Library/Application Support/Zacro Prototype/NativeMessagingHosts"',
    ),
  'components/os_crypt/common/keychain_password_mac.mm': (source) => {
    source = replaceOnce(
      source,
      'kDefaultServiceName[] = "Chromium Safe Storage"',
      'kDefaultServiceName[] = "Zacro Prototype Safe Storage"',
    );
    return replaceOnce(
      source,
      'kDefaultAccountName[] = "Chromium"',
      'kDefaultAccountName[] = "Zacro Prototype"',
    );
  },
  'components/version_info/version_info_with_user_agent.cc': (source) => {
    source = replaceOnce(
      source,
      'return base::StrCat({"Chrome/", GetMajorVersionNumber(), ".0.0.0"});',
      '// Preserve the engine compatibility token and disclose this product.\n' +
        '  return base::StrCat({"Chrome/", GetMajorVersionNumber(),\n' +
        '                       ".0.0.0 ZacroPrototype/", GetMajorVersionNumber(),\n' +
        '                       ".0.0.0"});',
    );
    return replaceOnce(
      source,
      'return base::StrCat({"Chrome/", GetVersionNumber()});',
      'return base::StrCat({"Chrome/", GetVersionNumber(),\n' +
        '                       " ZacroPrototype/", GetVersionNumber()});',
    );
  },
  'components/embedder_support/user_agent_utils.cc': (source) =>
    replaceOnce(
      source,
      'std::optional<std::string> brand;\n#if !BUILDFLAG(CHROMIUM_BRANDING)\n  brand = version_info::GetProductName();\n#endif',
      '// The prototype has its own product identity even with Chromium branding\n' +
        '  // assets. Keep the Chromium engine brand and upstream GREASE ordering.\n' +
        '  std::optional<std::string> brand = version_info::GetProductName();',
    ),
  'chrome/app/chromium_strings.grd': (source) => {
    const selected = new Set([
      'IDS_PRODUCT_NAME',
      'IDS_SHORT_PRODUCT_NAME',
      'IDS_APP_MENU_YOUR_CHROME_HEADER',
      'IDS_PRODUCT_DESCRIPTION',
      'IDS_WELCOME_TO_CHROME',
      'IDS_FIRST_RUN_DIALOG_WINDOW_TITLE',
      'IDS_TASK_MANAGER_TITLE',
      'IDS_BROWSER_WINDOW_TITLE_FORMAT',
      'IDS_CAPTIVE_PORTAL_BROWSER_WINDOW_TITLE_FORMAT',
      'IDS_ACCESSIBLE_BROWSER_WINDOW_TITLE_FORMAT',
      'IDS_ACCNAME_APP',
      'IDS_BROWSER_HUNGBROWSER_MESSAGE',
      'IDS_COULDNT_STARTUP_PROFILE_ERROR',
      'IDS_UNINSTALL_CLOSE_APP',
      'IDS_UNINSTALL_VERIFY',
      'IDS_UNINSTALL_CHROME',
      'IDS_FR_CUSTOMIZE_DEFAULT_BROWSER',
      'IDS_DEFAULT_BROWSER_CHANGED_MESSAGE',
      'IDS_ABOUT',
      'IDS_APP_MENU_PRODUCT_NAME',
      'IDS_HELPER_NAME',
      'IDS_SHORT_HELPER_NAME',
    ]);
    const changed = new Set();
    source = source.replace(
      /(<message\b[^>]*\bname="([^"]+)"[^>]*>)([\s\S]*?)(<\/message>)/g,
      (full, start, name, body, end) => {
        if (!selected.has(name) || !body.includes('Chromium')) return full;
        changed.add(name);
        if (name === 'IDS_PRODUCT_DESCRIPTION')
          body = '\n          Zacro Prototype is an experimental browser built on Chromium.\n        ';
        else body = body.replaceAll('Chromium', 'Zacro Prototype');
        return start + body + end;
      },
    );
    if (changed.size !== selected.size) throw new Error('A selected native product string did not match.');
    return source;
  },
};
async function generate(sourceRoot, outputRoot = __dirname) {
  if (!path.isAbsolute(sourceRoot)) throw new Error('Pass an absolute pinned source-reference directory.');
  // Regeneration cannot silently accept source drift. A new upstream pin needs
  // an explicit review of this generator and the manifest, not fuzzy patching.
  let existing;
  try {
    existing = JSON.parse(await fs.readFile(path.join(outputRoot, 'manifest.json'), 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (existing && existing.revision !== REVISION)
    throw new Error('Existing manifest uses a different revision.');
  const temporary = await fs.mkdtemp(path.join(sourceRoot, '.zacro-patch-'));
  const files = [],
    parts = [];
  for (const [relative, transform] of Object.entries(transformations)) {
    const before = await fs.readFile(path.join(sourceRoot, relative));
    const recorded = existing?.files.find((file) => file.path === relative);
    if (existing && (!recorded || recorded.beforeSha256 !== hash(before)))
      throw new Error(`Upstream source digest changed: ${relative}`);
    const after = Buffer.from(transform(before.toString('utf8')));
    if (before.equals(after)) throw new Error(`No change for ${relative}`);
    const changedFile = path.join(temporary, relative);
    await fs.mkdir(path.dirname(changedFile), { recursive: true });
    await fs.writeFile(changedFile, after);
    let diff;
    try {
      execFileSync(
        'git',
        [
          '-c',
          'core.autocrlf=false',
          'diff',
          '--no-index',
          '--no-ext-diff',
          '--no-color',
          '--',
          path.join(sourceRoot, relative),
          changedFile,
        ],
        { encoding: 'utf8' },
      );
      throw new Error('Expected a changed source file.');
    } catch (error) {
      if (error.status !== 1 || !error.stdout) throw error;
      diff = error.stdout;
    }
    diff = diff
      .replace(/^diff --git .*$/m, `diff --git a/${relative} b/${relative}`)
      .replace(/^--- .*$/m, `--- a/${relative}`)
      .replace(/^\+\+\+ .*$/m, `+++ b/${relative}`);
    parts.push(diff);
    files.push({
      path: relative,
      beforeSha256: hash(before),
      afterSha256: hash(after),
      sourceUrl: `https://raw.githubusercontent.com/chromium/chromium/${REVISION}/${relative}`,
    });
  }
  const patch = parts.join('');
  const patchPath = 'patches/0001-zacro-prototype-native-identity.patch';
  await fs.mkdir(path.join(outputRoot, 'patches'), { recursive: true });
  await fs.writeFile(path.join(outputRoot, patchPath), patch);
  const manifest = {
    schemaVersion: 1,
    revision: REVISION,
    version: '156.0.8078.48',
    product: 'Zacro Prototype',
    macBundleId: 'com.zacro.prototype',
    windowsAppId: 'ZacroPrototype',
    outputs: {
      'win32-x64': 'chrome.exe',
      'darwin-arm64': 'Zacro Prototype.app/Contents/MacOS/Zacro Prototype',
      'darwin-x64': 'Zacro Prototype.app/Contents/MacOS/Zacro Prototype',
    },
    patch: { path: patchPath, sha256: hash(patch) },
    files,
  };
  await fs.writeFile(path.join(outputRoot, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return {
    changedFiles: files.length,
    patchSha256: manifest.patch.sha256,
    temporaryPatchedSources: temporary,
  };
}
if (require.main === module)
  generate(process.argv[2])
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
module.exports = { REVISION, generate, transformations };
