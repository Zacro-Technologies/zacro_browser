'use strict';

// Deterministic, genuine PDF fixture with an xref table; no generator dependency.
function makePDF(pageTexts = ['A verified PDF passage.'], { openAction = false } = {}) {
  const objects = [];
  const pageIds = pageTexts.map((_, index) => 4 + index * 2);
  objects[1] = `<< /Type /Catalog /Pages 2 0 R${openAction ? ' /OpenAction << /S /JavaScript /JS (throw new Error\\(PDF_SCRIPT_MUST_NOT_RUN\\);) >>' : ''} >>`;
  objects[2] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pageTexts.length} >>`;
  objects[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
  pageTexts.forEach((text, index) => {
    const page = pageIds[index];
    const escaped = text.replace(/([\\()])/g, '\\$1');
    const stream = text ? `BT /F1 12 Tf 50 750 Td (${escaped}) Tj ET` : '';
    objects[page] =
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${page + 1} 0 R >>`;
    objects[page + 1] = `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`;
  });
  let result = '%PDF-1.4\n';
  const offsets = [0];
  for (let id = 1; id < objects.length; id++) {
    offsets[id] = Buffer.byteLength(result);
    result += `${id} 0 obj\n${objects[id]}\nendobj\n`;
  }
  const startXref = Buffer.byteLength(result);
  result += `xref\n0 ${objects.length}\n0000000000 65535 f \n`;
  for (let id = 1; id < objects.length; id++) result += `${String(offsets[id]).padStart(10, '0')} 00000 n \n`;
  result += `trailer\n<< /Size ${objects.length} /Root 1 0 R >>\nstartxref\n${startXref}\n%%EOF\n`;
  return Buffer.from(result);
}

module.exports = { makePDF };
