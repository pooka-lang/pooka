import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepare, updateNotes } from './release-assets.mjs';
import { checksum } from './checksums.mjs';

test('generated download sections preserve handwritten notes on repeated publication', () => {
  const block = '<!-- pooka-downloads:start -->\nnew downloads\n<!-- pooka-downloads:end -->';
  const first = updateNotes('A handwritten changelog.', block);
  assert.match(first, /^A handwritten changelog\./);
  assert.equal(updateNotes(first, block), first);
  assert.throws(() => updateNotes('<!-- pooka-downloads:start -->', block));
});

test('release contains only the verified portable escript and its checksum', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pooka-release-'));
  try {
    await writeFile(join(root, 'pooka'), '#!/usr/bin/env escript\nfixture');
    await checksum(root, true);
    const options = { input: root, output: join(root, 'out'), repository: 'pooka-lang/pooka', tag: 'v0.1.0', runUrl: 'https://github.com/example/run' };
    const result = await prepare(options);
    assert.deepEqual(result.assets, ['pooka', 'pooka.sha256']);
    assert.match(result.notes, /Erlang\/OTP 29 is required/);
    assert.match(result.notes, /releases\/download\/v0.1.0\/pooka/);
    assert.match(result.notes, /blob\/v0.1.0\/docs\/install\.md/);
    assert.doesNotMatch(result.notes, /SetEnvironmentVariable|export PATH|```/);
    assert.doesNotMatch(result.notes, /\{\{[A-Z_]+\}\}/);
    assert.doesNotMatch(result.notes, /bundled|gleepack|\.tar\.gz/);
    assert.equal(await readFile(join(options.output, 'pooka'), 'utf8'), '#!/usr/bin/env escript\nfixture');
    await writeFile(join(root, 'pooka'), 'damaged');
    await assert.rejects(prepare(options), /checksum mismatch/);
    await assert.rejects(prepare({ ...options, tag: '../bad' }), /release tag/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
