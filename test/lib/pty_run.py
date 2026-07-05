#!/usr/bin/env python3
"""Run a command under a pseudo-terminal, auto-answering SEQS confirm prompts.

setup-qubes.sh's confirm() reads the go-ahead word from /dev/tty (deliberately,
so a piped stdin can't be mistaken for approval). To drive it non-interactively
the test harness needs a real controlling terminal -- that's what forkpty gives
us. Whenever the child prints a prompt containing 'type CONTINUE' / 'type
OVERWRITE' we type that word back; all child output is mirrored to our stdout so
the test can assert on it. Exit status is propagated.

Usage: pty_run.py <cmd> [args...]
"""
import os
import sys
import select

PROMPTS = {b"type CONTINUE": b"CONTINUE\n", b"type OVERWRITE": b"OVERWRITE\n"}


def main():
    cmd = sys.argv[1:]
    if not cmd:
        sys.stderr.write("pty_run.py: no command given\n")
        sys.exit(2)

    pid, fd = os.forkpty()
    if pid == 0:  # child: pty is our controlling terminal, so /dev/tty works
        os.execvp(cmd[0], cmd)
        os._exit(127)

    buf = b""
    answered = set()
    out = sys.stdout.buffer
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 30)
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
        buf += data
        tail = buf[-200:]  # prompts have no trailing newline; watch the tail
        for needle, reply in PROMPTS.items():
            key = (needle, buf.count(needle))
            if needle in tail and key not in answered:
                answered.add(key)
                os.write(fd, reply)

    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))


if __name__ == "__main__":
    main()
