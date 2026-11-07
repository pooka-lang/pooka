// SPDX-License-Identifier: Apache-2.0
// Open the prepared parcels in three neighbouring workshops. This check never
// uploads anything: it seeds local dependencies from the exact Hex archives.
// Usage: node scripts/check-hex-packages.mjs /path/to/build/publish
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, readdirSync, copyFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const publish = resolve(process.argv[2] ?? '../pooka_stdlib/build/publish');
const names = ['pooka_stdlib'];
const versions = new Map();
const archives = new Map(names.map(name => {
  const directory = join(publish, name);
  const files = readdirSync(directory).filter(file => file.startsWith(`${name}-`) && file.endsWith('.tar'));
  if (files.length !== 1) throw new Error(`Expected one prepared package tarball in ${directory}`);
  versions.set(name, files[0].slice(name.length + 1, -4));
  return [name, join(directory, files[0])];
}));
const version = versions.get('pooka_stdlib');
for (const file of archives.values()) if (!existsSync(file)) throw new Error(`Prepare this archive first: ${file}`);
const work = mkdtempSync(join(tmpdir(), 'pooka-hex-consumers-'));
const write = (file, text) => { mkdirSync(resolve(file, '..'), { recursive: true }); writeFileSync(file, text); };
const bin = join(work, 'bin');
mkdirSync(bin);
writeFileSync(join(bin, 'pooka'), '#!/bin/sh\necho "Consumer unexpectedly invoked the Pooka compiler" >&2\nexit 73\n', { mode: 0o755 });
const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MIX_REBAR3: execFileSync('which', ['rebar3'], { encoding: 'utf8' }).trim() };
delete env.ERL_LIBS;
const run = (command, args, cwd) => execFileSync(command, args, { cwd, env, stdio: 'inherit', timeout: 120_000 });

// Read only the inner contents, rejecting paths outside the destination. The
// fixture uses the real Hex v3 envelope rather than a hand-built source tree.
function unpack(name, destination) {
  mkdirSync(destination, { recursive: true });
  const expression = `
    [Tar, Dest] = init:get_plain_arguments(),
    {ok, Outer} = erl_tar:extract(Tar, [memory]),
    {"VERSION", <<"3">>} = lists:keyfind("VERSION", 1, Outer),
    {"metadata.config", Meta} = lists:keyfind("metadata.config", 1, Outer),
    {"contents.tar.gz", Contents} = lists:keyfind("contents.tar.gz", 1, Outer),
    {"CHECKSUM", Checksum} = lists:keyfind("CHECKSUM", 1, Outer),
    Checksum = binary:encode_hex(crypto:hash(sha256, [<<"3">>, Meta, Contents])),
    {ok, Files} = erl_tar:extract({binary, Contents}, [memory, compressed]),
    lists:foreach(fun({Name, Bytes}) ->
      relative = filename:pathtype(Name),
      false = lists:member("..", filename:split(Name)),
      Target = filename:join(Dest, Name),
      ok = filelib:ensure_dir(Target), ok = file:write_file(Target, Bytes)
    end, Files), halt(0).`;
  run('erl', ['-noshell', '-eval', expression, '-extra', archives.get(name), destination], work);
}

try {
  const rebar = join(work, 'rebar');
  const stdlib = join(rebar, 'pooka_stdlib');
  unpack('pooka_stdlib', stdlib);
  run('rebar3', ['compile'], stdlib);
  run('erl', ['-noshell', '-pa', join(stdlib, '_build/default/lib/pooka_stdlib/ebin'),
    '-eval', `[1,4,9] = 'pooka@pooka_stdlib@pooka@list':map([1,2,3], fun(X) -> X*X end), {ok,_} = application:ensure_all_started(pooka_stdlib), halt(0).`], rebar);
  console.log('✓ rebar3 builds and runs the published source');

  const mix = join(work, 'mix');
  unpack('pooka_stdlib', join(mix, 'packages/pooka_stdlib'));
  write(join(mix, 'mix.exs'), `defmodule PookaConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :pooka_consumer, version: "0.1.0", deps: [
    {:pooka_stdlib, path: "packages/pooka_stdlib"}
  ]]
  def application, do: [extra_applications: [:pooka_stdlib]]
end
`);
  run('mix', ['deps.get'], mix);
  run('mix', ['run', '-e', `xs = :"pooka@pooka_stdlib@pooka@list".map([1,2,3], fn x -> x*x end); if xs != [1,4,9], do: raise("bad published map result")`], mix);
  console.log('✓ Mix builds and runs the published source');

  const gleam = join(work, 'gleam');
  for (const name of names) unpack(name, join(gleam, 'build/packages', name));
  write(join(gleam, 'gleam.toml'), `name = "published_consumer"\nversion = "1.0.0"\n[dependencies]\npooka_stdlib = "~> ${version}"\n`);
  write(join(gleam, 'build/packages/packages.toml'), `[packages]\npooka_stdlib = "${version}"\n`);
  const checksum = name => createHash('sha256').update(readFileSync(archives.get(name))).digest('hex').toUpperCase();
  const entries = names.map(name => `  { name = "${name}", version = "${versions.get(name)}", build_tools = ${name === 'pooka_stdlib' ? '["pooka", "rebar3"]' : '["rebar3"]'}, requirements = [], otp_app = "${name}", source = "hex", outer_checksum = "${checksum(name)}" }`);
  write(join(gleam, 'manifest.toml'), `packages = [\n${entries.join(',\n')}\n]\n[requirements]\npooka_stdlib = { version = "~> ${version}" }\n`);
  write(join(gleam, 'src/published_consumer.gleam'), `@external(erlang, "pooka@pooka_stdlib@pooka@list", "map")
fn map(xs: List(a), f: fn(a) -> b) -> List(b)

pub fn main() {
  let assert [1, 4, 9] = map([1, 2, 3], fn(x) { x * x })
  Nil
}
`);
  run('gleam', ['run'], gleam);
  console.log('✓ Gleam builds and runs the published source');
  // If the stdlib's assertion suite has already been built, run its test
  // entrypoints against the rebar3-compiled production modules, not the original
  // compiler BEAMs. This exercises the source round trip across the whole API.
  const specs = resolve(publish, '../dev/erlang/pooka_stdlib/ebin');
  if (existsSync(specs)) {
    const testBeams = readdirSync(specs).filter(file => file.includes('@$test@') && file.endsWith('.beam'));
    if (testBeams.length) {
      const tests = join(work, 'spec-ebin');
      mkdirSync(tests);
      for (const file of testBeams) copyFileSync(join(specs, file), join(tests, file));
      run('erl', ['-noshell', '-pa', tests, join(stdlib, '_build/default/lib/pooka_stdlib/ebin'),
        '-eval', `
          [Directory] = init:get_plain_arguments(),
          persistent_term:put(pooka_test_capture, true),
          Modules = [list_to_atom(filename:basename(F, ".beam")) || F <- filelib:wildcard(filename:join(Directory, "*.beam"))],
          Tests = lists:append([begin {module,M} = code:ensure_loaded(M), [{M,F} || {F,0} <- M:module_info(exports), lists:prefix("$pooka_test_", atom_to_list(F))] end || M <- Modules]),
          true = length(Tests) > 0,
          lists:foreach(fun({M,F}) -> apply(M,F,[]) end, Tests),
          io:format("Published-source assertions: ~p passed~n", [length(Tests)]), halt(0).
        `, '-extra', tests], work);
    }
  }
  console.log('All three consumers passed with a failing pooka stub on PATH. No package was uploaded.');
  rmSync(work, { recursive: true, force: true });
} catch (error) {
  console.error(`Consumer fixtures retained at ${work}`);
  throw error;
}
