import { execFileSync, spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { prepare, updateNotes } from './release-assets.mjs';

const repository = process.env.GH_REPO;
const tag = process.env.RELEASE_TAG;
const manifest = await readFile('gleam.toml', 'utf8');
const version = /^version = "([^"]+)"/m.exec(manifest)?.[1];
if (!version) throw new Error('Missing compiler version in gleam.toml');
if (tag !== `v${version}`) throw new Error(`Release tag ${tag} does not match gleam.toml version ${version}`);
const output = 'release-assets';
const prepared = await prepare({
  input: 'release-inputs', output, repository, tag,
  runUrl: `https://github.com/${repository}/actions/runs/${process.env.GITHUB_RUN_ID}`,
});
const gh = args => execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const existing = spawnSync('gh', ['api', `repos/${repository}/releases/tags/${tag}`], { encoding: 'utf8' });
let release;
if (existing.status === 0) release = JSON.parse(existing.stdout);
else {
  let missing = false;
  try { missing = JSON.parse(existing.stdout).message === 'Not Found'; } catch {}
  if (!missing) throw new Error(existing.stderr);
}
const notesFile = join(output, 'notes.md');
await writeFile(notesFile, updateNotes(release?.body ?? '', prepared.notes));
const fresh = !release;
if (fresh) {
  gh(['release', 'create', tag, '--repo', repository, '--verify-tag', '--draft', ...(tag.includes('-') ? ['--prerelease'] : []), '--title', `Pooka ${tag}`, '--notes-file', notesFile]);
}
gh(['release', 'upload', tag, ...prepared.assets.map(name => join(output, name)), '--repo', repository, '--clobber']);
gh(['release', 'edit', tag, '--repo', repository, '--notes-file', notesFile, ...(fresh ? ['--draft=false'] : [])]);
console.log(`Uploaded ${prepared.assets.length} assets to https://github.com/${repository}/releases/tag/${tag}`);
