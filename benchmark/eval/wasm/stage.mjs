import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

export const projectRoot = fileURLToPath(new URL('../../../', import.meta.url));
export const webFiles = ['index.html', 'pdf-parser.mjs', 'pdf-parser-worker.mjs', 'worker.mjs', 'app.mjs'];

export async function stage(destination) {
  const directory = resolve(destination);
  await mkdir(directory, { recursive: true });
  const sources = [...webFiles.map(name => [`web/${name}`, name]), ['zig-out/bin/pdf_parser.wasm', 'pdf_parser.wasm']];
  const files = {};
  for (const [source, name] of sources) {
    const bytes = await readFile(resolve(projectRoot, source));
    await copyFile(resolve(projectRoot, source), resolve(directory, name));
    files[name] = { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
  }
  await writeFile(resolve(directory, 'asset-manifest.json'), JSON.stringify({ files }, null, 2) + '\n');
  return { directory, files };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(JSON.stringify(await stage(process.argv[2] ?? resolve(projectRoot, 'benchmark/eval/outputs/wasm-stage')), null, 2));
}
