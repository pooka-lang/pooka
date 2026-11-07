import { copyFile, mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { checksum } from './checksums.mjs';

export const start = '<!-- pooka-downloads:start -->';
export const end = '<!-- pooka-downloads:end -->';
export function updateNotes(previous, downloads) {
  const first = previous.indexOf(start);
  const last = previous.indexOf(end);
  if (first >= 0 && last >= first) {
    return previous.slice(0, first) + downloads + previous.slice(last + end.length);
  }
  if (first >= 0 || last >= 0) throw new Error('Incomplete generated download section');
  return `${previous.trimEnd()}${previous.trim() ? '\n\n' : ''}${downloads}\n`;
}

export async function prepare({ input, output, repository, tag, runUrl }) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository)) throw new Error('Invalid repository');
  if (!/^v\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(tag)) throw new Error('Expected a v<version> release tag');
  await checksum(input);
  await mkdir(output, { recursive: true });
  const assets = ['pooka', 'pooka.sha256'];
  for (const file of assets) await copyFile(join(input, file), join(output, file));
  const base = `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}`;
  const template = await readFile(new URL('./release-notes.md', import.meta.url), 'utf8');
  const rendered = template.replaceAll('{{DOWNLOAD_BASE}}', base).replaceAll('{{RUN_URL}}', runUrl).replaceAll('{{INSTALL_URL}}', `https://github.com/${repository}/blob/${encodeURIComponent(tag)}/docs/install.md`);
  const notes = `${start}\n${rendered.trim()}\n${end}`;
  return { assets, notes };
}
