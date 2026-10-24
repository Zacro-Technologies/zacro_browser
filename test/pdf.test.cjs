'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
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
