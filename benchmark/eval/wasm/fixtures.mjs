import { deflateSync } from 'node:zlib';

// Independent byte-level PDF builder: xref offsets count serialized bytes.
// It deliberately avoids the parser's fixture generator as a shared oracle.
export function makePdf({ pages = 1, lines = 1, compressed = false } = {}) {
  const objects = [];
  const add = body => { objects.push(Buffer.from(body)); return objects.length; };
  add('<< /Type /Catalog /Pages 2 0 R >>');
  add('');
  const font = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  const kids = [];
  for (let page = 0; page < pages; page++) {
    let content = 'BT /F1 10 Tf 20 780 Td\n';
    for (let line = 0; line < lines; line++) {
      content += `(Independent WASM fixture page ${page + 1} line ${line + 1} retains bounded native text.) Tj 0 -12 Td\n`;
    }
    content += 'ET\n';
    const stream = compressed ? deflateSync(Buffer.from(content)) : Buffer.from(content);
    const streamId = add(Buffer.concat([
      Buffer.from(`<< /Length ${stream.length}${compressed ? ' /Filter /FlateDecode' : ''} >>\nstream\n`),
      stream, Buffer.from('\nendstream'),
    ]));
    kids.push(add(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${streamId} 0 R >>`));
  }
  objects[1] = Buffer.from(`<< /Type /Pages /Count ${pages} /Kids [${kids.map(id => `${id} 0 R`).join(' ')}] >>`);
  const chunks = [Buffer.from('%PDF-1.7\n')];
  const offsets = [0];
  let offset = chunks[0].length;
  objects.forEach((body, index) => {
    offsets.push(offset);
    const chunk = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`), body, Buffer.from('\nendobj\n')]);
    chunks.push(chunk);
    offset += chunk.length;
  });
  const xref = offset;
  chunks.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map(n => `${String(n).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

export const normalizeText = text => text.replace(/\s+/g, ' ').trim();
