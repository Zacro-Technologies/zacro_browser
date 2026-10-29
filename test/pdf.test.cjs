'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const workerThreads = require('node:worker_threads');
const { extractPDF, MAX_PDF_BYTES } = require('../src/main/pdf.cjs');
const { makePDF } = require('./fixtures/pdf.cjs');

test('extracts actual PDF text with page numbers and leaves source bytes unchanged', async () => {
  const bytes = makePDF(['The cancellation fee is twenty dollars.', 'The contract expires in October.']);
  const original = Buffer.from(bytes);
  const result = await extractPDF(bytes);
  assert.match(result.text, /cancellation fee is twenty dollars/);
  assert.match(result.text, /contract expires in October/);
  assert.equal(result.pages.length, 2);
  assert.equal(result.pages[1].page, 2);
  assert.equal(result.totalPages, 2);
  assert.equal(result.truncated, false);
  assert.deepEqual(bytes, original);
});

test('text extraction never initializes or scans operating-system fonts inside its worker', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-pdf-font-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    assert.equal(path.dirname(real).toLowerCase(), (await fs.realpath(os.tmpdir())).toLowerCase());
    assert.match(path.basename(real), /^zacro-pdf-font-test-/u);
    await fs.rm(real, { recursive: true });
  });
  const guard = path.join(directory, 'font-guard.cjs');
  const accessed = path.join(directory, 'system-font-access.txt');
  const binding = path.join(path.dirname(require.resolve('@napi-rs/canvas')), 'js-binding.js');
  // Keep the real native canvas bindings and PDF parser. Fail if either system
  // font entry point runs during dependency import or text extraction.
  await fs.writeFile(
    guard,
    `
    const { GlobalFonts } = require(${JSON.stringify(binding)});
    for (const name of ['enableSystemFonts', 'loadFontsFromDir']) {
      GlobalFonts[name] = () => {
        require('node:fs').appendFileSync(${JSON.stringify(accessed)}, name + '\\n');
        throw new Error('PDF extraction requested operating-system fonts.');
      };
    }
  `,
  );
  const filename = path.resolve(__dirname, '../src/main/pdf.cjs');
  const nativeRequire = createRequire(filename);
  const module = { exports: {} };
  const parentFontSetting = process.env.DISABLE_SYSTEM_FONTS_LOAD;
  class GuardedWorker extends workerThreads.Worker {
    constructor(workerFile, options) {
      super(workerFile, {
        ...options,
        env: { ...process.env, DISABLE_SYSTEM_FONTS_LOAD: '', ...options.env },
        execArgv: ['--require', guard],
      });
    }
  }
  vm.runInNewContext(await fs.readFile(filename, 'utf8'), {
    module,
    __filename: filename,
    Buffer,
    Uint8Array,
    process,
    setTimeout,
    clearTimeout,
    require(id) {
      return id === 'node:worker_threads' ? { ...workerThreads, Worker: GuardedWorker } : nativeRequire(id);
    },
  });
  const result = await module.exports.extractPDF(makePDF(['Text without a system font scan.']));
  assert.equal(result.text, 'Text without a system font scan.');
  assert.equal(result.totalPages, 1);
  await assert.rejects(fs.access(accessed), { code: 'ENOENT' });
  assert.equal(process.env.DISABLE_SYSTEM_FONTS_LOAD, parentFontSetting);
});

test('page and character budgets disclose truncated PDF context', async () => {
  const bytes = makePDF(['First page evidence.', 'Second page evidence.']);
  const limitedPages = await extractPDF(bytes, { maxPages: 1 });
  assert.equal(limitedPages.pages.length, 1);
  assert.equal(limitedPages.truncated, true);
  assert.ok(!limitedPages.text.includes('Second'));
  const limitedText = await extractPDF(bytes, { maxChars: 12 });
  assert.equal(limitedText.text.length, 12);
  assert.equal(limitedText.truncated, true);
});

test('does not execute PDF JavaScript open actions while reading text', async () => {
  const result = await extractPDF(makePDF(['Only page text is evidence.'], { openAction: true }));
  assert.equal(result.text, 'Only page text is evidence.');
  assert.ok(!result.text.includes('PDF_SCRIPT_MUST_NOT_RUN'));
});

test('blank and image-only PDFs fail clearly instead of pretending they were read', async () => {
  await assert.rejects(extractPDF(makePDF([''])), { code: 'PDF_NO_TEXT' });
});

test('invalid, excessive, or cancelled PDF inputs fail before parsing', async () => {
  await assert.rejects(extractPDF(Buffer.from('<html>not a PDF</html>')), { code: 'PDF_INVALID' });
  await assert.rejects(extractPDF(Buffer.alloc(MAX_PDF_BYTES + 1)), { code: 'PDF_SIZE' });
  await assert.rejects(extractPDF(makePDF(), { maxPages: 500 }), { code: 'PDF_INPUT' });
  await assert.rejects(extractPDF(makePDF(), { maxChars: 60001 }), { code: 'PDF_INPUT' });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(extractPDF(makePDF(), { signal: controller.signal }), { code: 'PDF_CANCELLED' });
});
