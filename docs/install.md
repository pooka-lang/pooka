# Installing Pooka

Pooka travels light. The whole compiler is one file, called `pooka`, small enough to carry in a coat pocket. It only asks for one thing in return: a warm place to run, which is Erlang.

This guide has four short paths. Pick the one that matches your machine and follow it from top to bottom.

1. [Install Erlang](#1-install-erlang) (everyone)
2. [Install Pooka on macOS or Linux](#2-install-pooka-on-macos-or-linux)
3. [Install Pooka on Windows](#3-install-pooka-on-windows)
4. [Build Pooka from source](#4-build-pooka-from-source) (optional)

If you only want Pooka inside GitHub Actions, skip to [Continuous integration](#continuous-integration).

## 1. Install Erlang

Pooka needs **Erlang/OTP 29**.

| System | Command |
| --- | --- |
| macOS (Homebrew) | `brew install erlang` |
| Linux | Use your package manager, or a version manager such as [mise](https://mise.jdx.dev) or [asdf](https://asdf-vm.com) if its Erlang is older than 29 |
| Windows | Download the installer from [erlang.org/downloads](https://www.erlang.org/downloads) |

Check which version you have:

```sh
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
```

It should print `29`. If it prints a smaller number, the compiler may refuse to start, so update Erlang before you go on.

## 2. Install Pooka on macOS or Linux

**Download the compiler and its checksum.**

```sh
curl -fLO https://github.com/pooka-lang/pooka/releases/download/v0.1.0/pooka
curl -fLO https://github.com/pooka-lang/pooka/releases/download/v0.1.0/pooka.sha256
```

**Check the download.** This makes sure the file arrived whole.

```sh
shasum -a 256 -c pooka.sha256
```

On Linux systems without `shasum`, use `sha256sum -c pooka.sha256` instead. It should say `pooka: OK`. If it says anything else, delete both files and download them again.

**Put it somewhere on your PATH.**

```sh
chmod +x pooka
mkdir -p ~/.local/bin
mv pooka ~/.local/bin/pooka
```

**Make sure your shell can find it.** If `~/.local/bin` is not already on your PATH, add this line to `~/.zshrc` (macOS) or `~/.bashrc` (most Linux systems), then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

**Say hello.**

```sh
pooka --version
```

You should see `pooka 0.1.0`. That's it. You can [start your first project](getting_started.md).

## 3. Install Pooka on Windows

Windows does not know how to run a file without an extension, so we give it a small launcher.

1. Create a folder for it, for example `C:\Tools\Pooka`.
2. Download [`pooka`](https://github.com/pooka-lang/pooka/releases/download/v0.1.0/pooka) and [`pooka.sha256`](https://github.com/pooka-lang/pooka/releases/download/v0.1.0/pooka.sha256) into that folder.
3. Check the download in PowerShell. The two hashes should be the same:

   ```powershell
   (Get-FileHash C:\Tools\Pooka\pooka -Algorithm SHA256).Hash
   Get-Content C:\Tools\Pooka\pooka.sha256
   ```

4. In the same folder, create a file called `pooka.cmd` with these two lines:

   ```bat
   @echo off
   escript "%~dp0pooka" %*
   ```

5. Add `C:\Tools\Pooka` to your PATH: open *Start*, search for *Edit environment variables for your account*, select `Path`, choose *Edit*, then *New*, and paste the folder.
6. Open a new terminal and run:

   ```powershell
   pooka --version
   ```

You should see `pooka 0.1.0`.

## 4. Build Pooka from source

You only need this if you want to work on the compiler itself, or try something that is not released yet. You will need Erlang/OTP 29, [Gleam](https://gleam.run) and Git.

```sh
git clone https://github.com/pooka-lang/pooka.git
cd pooka
./install.sh
```

The installer builds the compiler, copies it to `~/.local/bin/pooka`, and prints the version. To put it somewhere else, set `POOKA_INSTALL_DIR`:

```sh
POOKA_INSTALL_DIR=/opt/bin ./install.sh
```

Run `./install.sh` again whenever you pull new changes.

## Continuous integration

In GitHub Actions, the [`setup-pooka`](https://github.com/peregrinefinch/setup-pooka) action installs an exact version and checks its checksum for you:

```yaml
- uses: erlef/setup-beam@v1
  with:
    otp-version: "29"
    rebar3-version: "3"
- uses: peregrinefinch/setup-pooka@v1
  with:
    pooka-version: "0.1.0"
- run: pooka test
```

Projects made with `pooka new` already include a workflow like this, in `.github/workflows/test.yml`.

## If something goes wrong

| What you see | What to try |
| --- | --- |
| `command not found: pooka` | The folder is not on your PATH yet. Open a new terminal, or check the PATH step again. |
| `escript: command not found` | Erlang is not installed, or not on your PATH. Go back to [step 1](#1-install-erlang). |
| The compiler starts, then complains about the runtime | Your Erlang is older than OTP 29. Update it. |
| `pooka.sha256` does not match | The download was damaged or mixed up. Download both files again from the same release. |

## Uninstalling

Pooka keeps everything in one file. To remove it, delete `pooka` (and `pooka.cmd` on Windows). Each project keeps its own build files in its `build` folder, and `pooka clean` removes them.

The lantern goes out, and nothing else in the house is disturbed.
