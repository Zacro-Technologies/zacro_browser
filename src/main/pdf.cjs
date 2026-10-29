'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const path = require('node:path');

const MAX_PDF_BYTES = 20 * 1024 * 1024;
const MAX_PAGES = 100;
const MAX_CHARS = 60000;
const TIMEOUT_MS = 20000;

class PDFError extends Error {
  constructor(message, code = 'PDF_ERROR') {
    super(message);
    this.name = 'PDFError';
    this.code = code;
  }
}

function validateInput(buffer, options) {
  if (!Buffer.isBuffer(buffer) && !(buffer instanceof Uint8Array))
    throw new PDFError('PDF content must be supplied as bytes.', 'PDF_INPUT');
  if (buffer.byteLength > MAX_PDF_BYTES)
    throw new PDFError('This PDF exceeds the 20 MB limit. Choose a smaller document.', 'PDF_SIZE');
  if (
    buffer.byteLength < 8 ||
    !Buffer.from(buffer.buffer, buffer.byteOffset, Math.min(buffer.byteLength, 1024)).includes('%PDF-')
  )
    throw new PDFError('The selected document is not a readable PDF.', 'PDF_INVALID');
  const maxPages = options.maxPages ?? MAX_PAGES;
  const maxChars = options.maxChars ?? MAX_CHARS;
  if (!Number.isInteger(maxPages) || maxPages < 1 || maxPages > MAX_PAGES)
    throw new PDFError('PDF extraction supports 1–100 pages per request.', 'PDF_INPUT');
  if (!Number.isInteger(maxChars) || maxChars < 1 || maxChars > MAX_CHARS)
    throw new PDFError('PDF extraction supports up to 60,000 characters per request.', 'PDF_INPUT');
  return { maxPages, maxChars };
}

/** Extract text without executing PDF actions, rendering pages, or following links. */
async function extractPDF(buffer, options = {}) {
  const limits = validateInput(buffer, options);
  if (options.signal?.aborted) throw new PDFError('PDF extraction was cancelled.', 'PDF_CANCELLED');
  // PDF.js uses a same-thread fallback worker in Node. Run the complete parser
  // in our own worker so pathological documents cannot freeze browser chrome.
  const data = Uint8Array.from(buffer);
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, {
      workerData: { zacroPdfTextWorker: true, data: data.buffer, ...limits },
      transferList: [data.buffer],
      resourceLimits: { maxOldGenerationSizeMb: 192, stackSizeMb: 4 },
      // PDF.js imports native canvas before getDocument(useSystemFonts: false)
      // applies. Text extraction needs no OS fonts; skip canvas's startup scan
      // in this worker without changing the browser process environment.
      env: { ...process.env, DISABLE_SYSTEM_FONTS_LOAD: '1' },
    });
    let done = false;
    const finish = (error, value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', cancel);
      worker.terminate().catch(() => {});
      if (error) reject(error);
      else resolve(value);
    };
    const cancel = () => finish(new PDFError('PDF extraction was cancelled.', 'PDF_CANCELLED'));
    const timer = setTimeout(
      () => finish(new PDFError('This PDF took too long to read. Try a smaller document.', 'PDF_TIMEOUT')),
      TIMEOUT_MS,
    );
    options.signal?.addEventListener('abort', cancel, { once: true });
    worker.once('message', (message) => {
      if (message.error) finish(new PDFError(message.error.message, message.error.code));
      else finish(null, message.result);
    });
    worker.once('error', () =>
      finish(
        new PDFError(
          'This PDF could not be read within the supported memory and format limits.',
          'PDF_PARSE',
        ),
      ),
    );
    worker.once('exit', (code) => {
      if (!done)
        finish(
          new PDFError(
            `PDF extraction stopped unexpectedly${code ? ' while reading this document' : ''}.`,
            'PDF_PARSE',
          ),
        );
    });
  });
}

async function parseInWorker({ data, maxPages, maxChars }) {
  // No document URL is accepted. Network access through the parser's Fetch API
  // is denied even if a future library version attempts to resolve a resource.
  globalThis.fetch = async () => {
    throw new PDFError('PDF resource fetching is disabled.', 'PDF_NETWORK');
  };
  const { getDocument } = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const packageRoot = path.dirname(require.resolve('pdfjs-dist/package.json'));
  const loading = getDocument({
    data: new Uint8Array(data),
    verbosity: 0,
    stopAtErrors: true,
    disableFontFace: true,
    useSystemFonts: false,
    useWorkerFetch: false,
    disableAutoFetch: true,
    disableRange: true,
    disableStream: true,
    useWasm: false,
    isEvalSupported: false,
    isOffscreenCanvasSupported: false,
    isImageDecoderSupported: false,
    enableXfa: false,
    cMapUrl: path.join(packageRoot, 'cmaps').replace(/\\/g, '/') + '/',
    cMapPacked: true,
    standardFontDataUrl: path.join(packageRoot, 'standard_fonts').replace(/\\/g, '/') + '/',
  });
  try {
    const document = await loading.promise;
    const pages = [];
    let text = '';
    let truncated = document.numPages > maxPages;
    for (let pageNumber = 1; pageNumber <= Math.min(document.numPages, maxPages); pageNumber++) {
      const page = await document.getPage(pageNumber);
      let pageText = '';
      try {
        const content = await page.getTextContent({ includeMarkedContent: false });
        for (const item of content.items) {
          if (typeof item.str !== 'string') continue;
          pageText += item.str + (item.hasEOL ? '\n' : ' ');
          if (pageText.length > maxChars) {
            truncated = true;
            break;
          }
        }
      } finally {
        page.cleanup();
      }
      pageText = pageText
        .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
        .replace(/[^\S\n]+/g, ' ')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
      const separator = text ? '\n\n' : '';
      const remaining = maxChars - text.length - separator.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      if (pageText.length > remaining) {
        pageText = pageText.slice(0, remaining);
        truncated = true;
      }
      pages.push({ page: pageNumber, text: pageText });
      text += separator + pageText;
      if (text.length >= maxChars) {
        truncated ||= pageNumber < document.numPages;
        break;
      }
    }
    if (!text.trim())
      throw new PDFError(
        'This PDF contains no extractable text. Scanned and image-only documents require OCR, which is not available.',
        'PDF_NO_TEXT',
      );
    return { text, pages, totalPages: document.numPages, truncated };
  } catch (error) {
    if (error instanceof PDFError) throw error;
    if (error.name === 'PasswordException')
      throw new PDFError(
        'Password-protected PDFs cannot be shared with AI. Export an unlocked copy first.',
        'PDF_PASSWORD',
      );
    if (error.name === 'InvalidPDFException' || error.name === 'FormatError')
      throw new PDFError('This PDF is damaged or uses an unsupported format.', 'PDF_INVALID');
    throw new PDFError(
      'This PDF could not be read. It may be damaged, encrypted, or use unsupported fonts.',
      'PDF_PARSE',
    );
  } finally {
    await loading.destroy().catch(() => {});
  }
}

if (!isMainThread && workerData?.zacroPdfTextWorker) {
  parseInWorker(workerData)
    .then((result) => parentPort.postMessage({ result }))
    .catch((error) =>
      parentPort.postMessage({ error: { message: error.message, code: error.code || 'PDF_PARSE' } }),
    );
}

module.exports = { extractPDF, PDFError, MAX_PDF_BYTES };
