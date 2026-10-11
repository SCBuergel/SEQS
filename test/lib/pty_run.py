#!/usr/bin/env python3
"""Run a command under a pseudo-terminal, auto-answering SEQS confirm prompts.

setup-qubes.sh's confirm() reads a default-no [y/N] answer from /dev/tty
(deliberately, so piped stdin cannot be mistaken for approval). To drive it
non-interactively the test harness needs a real controlling terminal -- that is
what forkpty gives us. Whenever the child prints the prompt, we type y (or
the next of PTY_RUN_ANSWERS); all
child output is mirrored to stdout so the test can assert on it. Exit status is
propagated.

The run ends when the child has printed nothing for PTY_RUN_IDLE_TIMEOUT
seconds (default 30; 0 waits indefinitely, for real Salt runs on hardware).

Usage: pty_run.py <cmd> [args...]
"""
import os
import sys
import select

# PTY_RUN_ANSWERS: comma-separated answers to the prompts in turn, the last
# one repeating, such as "y,n" or "" (Enter); default y.
ANSWERS = os.environb.get(b"PTY_RUN_ANSWERS", b"y").split(b",")


def main():
    cmd = sys.argv[1:]
    if not cmd:
        sys.stderr.write("pty_run.py: no command given\n")
        sys.exit(2)

    pid, fd = os.forkpty()
    if pid == 0:  # child: pty is our controlling terminal, so /dev/tty works
        os.execvp(cmd[0], cmd)
        os._exit(127)

    idle = float(os.environ.get("PTY_RUN_IDLE_TIMEOUT", "30")) or None
    # Prompts have no trailing newline and may span two reads, so watch a short
    # window of recent output; clearing it after a reply answers each prompt once.
    window = b""
    out = sys.stdout.buffer
    while True:
        try:
            r, _, _ = select.select([fd], [], [], idle)
        except (OSError, select.error):
            break
        if not r:
            break
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out.write(data)
        out.flush()
        window = (window + data)[-400:]
        if b"[y/N]" in window:
            window = b""
            os.write(fd, (ANSWERS.pop(0) if len(ANSWERS) > 1 else ANSWERS[0]) + b"\n")

    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    main()
