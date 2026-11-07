// Exercise the compiler that will be shipped, not the Gleam development runner.
// Container mode uses host-side Node and executes only Erlang inside the target
// image, including architectures for which Node has no native runtime.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync, copyFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, delimiter, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { checksum } from './checksums.mjs';

let [mode, ...args] = process.argv.slice(2);
let container;
let program;
let relocation;
let environment = process.env;
const tool = (name, path) => path.split(delimiter)
  .map(part => join(part, name + (process.platform === 'win32' ? '.exe' : '')))
  .find(file => existsSync(file));
if (mode === '--package') {
  const input = resolve(args[0] ?? 'downloaded');
  await checksum(input);
  const destination = mkdtempSync(join(process.env.RUNNER_TEMP ?? tmpdir(), 'relocated compiler-'));
  relocation = destination;
  program = join(destination, 'pooka');
  copyFileSync(join(input, 'pooka'), program);
  if (process.platform !== 'win32') chmodSync(program, 0o755);
  const runtime = tool('escript', process.env.PATH);
  assert.ok(runtime, 'Erlang escript is missing');
  const path = [dirname(runtime), ...(process.platform === 'win32' ? [] : ['/usr/bin', '/bin'])].join(delimiter);
  assert.equal(tool('gleam', path), undefined, 'Gleam must not be on the isolated PATH');
  environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.toLowerCase() !== 'path'));
  environment.PATH = path;
} else if (mode === '--container') {
  [container, program] = args;
  assert.ok(container && program, 'Container ID and compiler path are required');
} else {
  program = resolve(mode ?? 'pooka');
}
const metadata = readFileSync(new URL('../gleam.toml', import.meta.url), 'utf8');
const version = /^version = "([^"]+)"/m.exec(metadata)[1];
const root = mkdtempSync(join(process.env.RUNNER_TEMP ?? tmpdir(), 'pooka-release-'));
const invoke = (values, cwd = root, executable = program, expected = 0) => {
  const file = container ? 'docker' : 'escript';
  const command = container
    ? ['exec', '--workdir', cwd, container, 'escript', executable, ...values]
    : [executable, ...values];
  const result = spawnSync(file, command, { cwd, env: environment, encoding: 'utf8', timeout: 180000, maxBuffer: 4 * 1024 * 1024 });
  if (result.error) throw result.error;
  assert.equal(result.status, expected, `${values.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return (result.stdout + result.stderr).replaceAll('\r\n', '\n');
};
try {
  assert.equal(invoke(['--version']).trim(), `pooka ${version}`);
  assert.match(invoke(['--help']), /Create a new Pooka project/);
  invoke(['not_a_command'], root, program, 1);
  invoke(['new', 'release_smoke']);
  const project = join(root, 'release_smoke');
  // The compiler is released before the first stdlib Hex package. Keep the
  // generated Hex declaration covered, then replace it through the real CLI
  // with a local package. This also exercises dependency resolution on every
  // platform without depending on registry availability.
  assert.match(readFileSync(join(project, 'pooka.toml'), 'utf8'), /^pooka_stdlib = ">= 0\.1\.0 and <= 1\.0\.0"$/m);
  const library = join(root, 'stdlib_fixture');
  mkdirSync(join(library, 'src/pooka'), { recursive: true });
  writeFileSync(join(library, 'pooka.toml'), 'name = "pooka_stdlib"\nversion = "0.1.0"\n');
  writeFileSync(join(library, 'src/pooka/release_probe.pooka'), 'module release_probe\nanswer() -> Int { 42 }\n');
  invoke(['add', 'pooka_stdlib', '--path', library], project);
  writeFileSync(join(project, 'src/main.pooka'), `module main

import pooka/release_probe

class Box(value: a) {
  get() -> a { value }
}

answer() -> Int { Box(release_probe.answer()).get() }

main() { echo #(answer(), "α🐇") }
`);
  writeFileSync(join(project, 'test/main.spec.pooka'), `module main_test

import main

test "compiled classes preserve their values" {
  assert main.answer() == 42
}

test "generic classes preserve Unicode strings" {
  assert main.Box("α🐇").get() == "α🐇"
}
`);
  for (const values of [['format'], ['format', '--check'], ['check'], ['build']]) invoke(values, project);
  assert.ok(invoke(['run'], project).includes('#(42, "α🐇")'));
  assert.match(invoke(['test'], project), /2 tests, 2 passed/);
  invoke(['export', 'escript'], project);
  assert.ok(invoke([], project, join(project, 'build/release_smoke')).includes('#(42, "α🐇")'));
  console.log('Compiler release smoke checks passed');
} finally {
  rmSync(root, { recursive: true, force: true });
  if (relocation) rmSync(relocation, { recursive: true, force: true });
}
