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
The child's process group then gets SIGTERM, and SIGKILL 5 seconds later, as
on any exit of this script; if this script dies, the child itself gets
SIGKILL. A process that left the group, or runs under sudo as root, is out
of reach.

Usage: pty_run.py <cmd> [args...]
"""
import ctypes
import os
import select
import signal
import sys
import time

# PTY_RUN_ANSWERS: comma-separated answers to the prompts in turn, the last
# one repeating, such as "y,n" or "" (Enter); default y. PTY_RUN_PROMPT: the
# prompt text to answer; default [y/N].
ANSWERS = os.environb.get(b"PTY_RUN_ANSWERS", b"y").split(b",")
PROMPT = os.environb.get(b"PTY_RUN_PROMPT", b"[y/N]")


def main():
    cmd = sys.argv[1:]
    if not cmd:
        sys.stderr.write("pty_run.py: no command given\n")
        sys.exit(2)

    pid, fd = os.forkpty()
    if pid == 0:  # child: pty is our controlling terminal, so /dev/tty works
        ctypes.CDLL(None).prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
        os.execvp(cmd[0], cmd)
        os._exit(127)

    status = []

    def reap(block):
        if not status:
            done, st = os.waitpid(pid, 0 if block else os.WNOHANG)
            if done:
                status.append(st)

    def kill_child(*_):
        # The child leads its own session; TERM lets its traps clean up.
        for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 0)):
            try:
                os.killpg(pid, sig)
                for _ in range(grace * 10):
                    reap(False)
                    os.killpg(pid, 0)  # raises once the whole group is gone
                    time.sleep(0.1)
            except ProcessLookupError:
                return

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: (kill_child(), sys.exit(1)))
    try:
        loop(fd)
    finally:
        kill_child()
    reap(True)
    rc = os.waitstatus_to_exitcode(status[0])
    sys.exit(rc if rc >= 0 else 128 - rc)  # killed by signal N: 128+N, as in bash


def loop(fd):
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
        if PROMPT in window:
            window = b""
            os.write(fd, (ANSWERS.pop(0) if len(ANSWERS) > 1 else ANSWERS[0]) + b"\n")


if __name__ == "__main__":
    main()
