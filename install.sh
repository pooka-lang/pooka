#!/bin/sh
# Give the source build a place in the user's bin directory. Gleam's native
# exporter carries the compiler dependencies; Erlang remains on the host.
set -eu
compiler_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir=${POOKA_INSTALL_DIR:-"$HOME/.local/bin"}
for tool in gleam erl escript; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required\n' "$tool" >&2; exit 1; }
done
cd "$compiler_dir"
gleam export escript
mkdir -p "$install_dir"
install -m 755 pooka "$install_dir/pooka"
"$install_dir/pooka" --version
printf 'Installed in %s. Add that directory to PATH if needed.\n' "$install_dir"
