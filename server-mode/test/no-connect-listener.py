#!/usr/bin/env python3
"""Bounded owned listener for local-rejection tests; print port, then accepts."""

import socket
import select
import sys
import time


with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    print(listener.getsockname()[1], flush=True)
    deadline = time.monotonic() + 10.0
    accepted = 0
    finished = False
    while (remaining := deadline - time.monotonic()) > 0:
        ready, _, _ = select.select([listener, sys.stdin], [], [], remaining)
        if listener in ready:
            peer, _ = listener.accept()
            with peer:
                accepted += 1
        if sys.stdin in ready:
            finished = sys.stdin.readline().strip() == "done"
            break
    # A connect completed before the parent's "done" can still be queued.
    listener.setblocking(False)
    while True:
        try:
            peer, _ = listener.accept()
        except BlockingIOError:
            break
        with peer:
            accepted += 1
    print(f"{'DONE' if finished else 'TIMEOUT'} {accepted}", flush=True)
