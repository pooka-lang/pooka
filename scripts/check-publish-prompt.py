#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Give OTP a terminal without borrowing an author's key or contacting Hex."""

import glob
import os
import select
import signal
import subprocess
import time
import unittest

# pty is POSIX-only. The publishing code itself uses OTP's Windows terminal
# support too; this harness checks the Unix terminal driver on macOS and Linux.
if os.name == "posix":
    import pty


PROGRAM = '''
case pooka_publish_ffi:secret(<<"Hidden test key: ">>) of
    {ok, _} -> io:put_chars("SECRET_READ\\n");
    {error, _} -> io:put_chars("CANCELLED\\n")
end,
io:put_chars("Visible line: "),
case io:get_line("") of
    "echo-restored\\n" -> io:put_chars("RESTORED\\n");
    <<"echo-restored\\n">> -> io:put_chars("RESTORED\\n");
    _ -> halt(2)
end,
halt().
'''


def command(program):
    paths = [os.path.abspath(path) for path in glob.glob("build/dev/erlang/*/ebin")]
    return ["erl", "-pa", *paths, "-noshell", "-eval", program]


def environment():
    return {**os.environ, "HEX_API_KEY": "", "HEXPM_API_KEY": "", "HEX_OTP": ""}


@unittest.skipUnless(os.name == "posix", "POSIX pseudo-terminal harness")
class PublishPrompt(unittest.TestCase):
    def conversation(self, answer, expected, program=PROGRAM):
        pid, master = pty.fork()
        if pid == 0:
            os.execvpe("erl", command(program), environment())
        output = b""
        entered = restored = confirmed = False
        status = None
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if not confirmed and b"Upload the prepared files? [y/N] " in output:
                        confirmed = True
                        os.write(master, b"y\n")
                    if not entered and b"Hidden test key: " in output:
                        entered = True
                        os.write(master, answer)
                    if not restored and b"Visible line: " in output:
                        restored = True
                        os.write(master, b"echo-restored\n")
                finished, code = os.waitpid(pid, os.WNOHANG)
                if finished:
                    status = code
                    break
            else:
                self.fail("Hidden-input test timed out")
            if status is None or not os.WIFEXITED(status):
                _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode(errors="replace"))
            self.assertIn(expected, output)
            self.assertIn(b"echo-restored", output, "Terminal echo was not restored")
            self.assertIn(b"RESTORED", output)
            self.assertNotIn(b"fake-terminal-secret", output, "Hidden input was echoed")
        finally:
            os.close(master)
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass

    def test_secret_is_hidden_and_echo_returns(self):
        self.conversation(b"fake-terminal-secret\n", b"SECRET_READ")

    def test_confirmation_accepts_binary_io_before_hidden_input(self):
        program = 'io:setopts([{binary, true}]), true = pooka_publish_ffi:confirm(<<"Preview\\n">>), ' + PROGRAM
        self.conversation(b"fake-terminal-secret\n", b"SECRET_READ", program)

    def test_empty_input_cancels_and_echo_returns(self):
        self.conversation(b"\n", b"CANCELLED")

    def test_eof_result_cancels_and_echo_returns(self):
        # Simulate the OTP reader's EOF result while retaining the terminal,
        # so restoration can be observed rather than closing our only handle.
        program = PROGRAM.replace('<<"Hidden test key: ">>)',
                                  '<<"Hidden test key: ">>, fun() -> eof end)')
        self.conversation(b"", b"CANCELLED", program)

    def test_read_failure_cancels_and_echo_returns(self):
        program = PROGRAM.replace('<<"Hidden test key: ">>)',
                                  '<<"Hidden test key: ">>, fun() -> error(read_failed) end)')
        self.conversation(b"", b"CANCELLED", program)

    def test_redirected_input_is_not_consumed_as_a_secret(self):
        program = '''
{error, _} = pooka_publish_ffi:secret(<<"MUST_NOT_PROMPT">>),
"pipe-input\\n" = io:get_line(""),
io:put_chars("PIPE_UNCONSUMED\\n"), halt().
'''
        result = subprocess.run(command(program), input=b"pipe-input\n", capture_output=True,
                                env=environment(), timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"PIPE_UNCONSUMED", result.stdout)
        self.assertNotIn(b"MUST_NOT_PROMPT", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
