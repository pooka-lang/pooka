import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function checksum(directory, write = false) {
  const bytes = await readFile(join(directory, 'pooka'));
  const digest = createHash('sha256').update(bytes).digest('hex');
  const expected = `${digest}  pooka\n`;
  const file = join(directory, 'pooka.sha256');
  if (write) await writeFile(file, expected);
  else if (await readFile(file, 'utf8') !== expected) throw new Error('Escript checksum mismatch');
  return bytes;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await checksum(process.argv[3], process.argv[2] === 'write');
  console.log('Escript checksum verified');
}
