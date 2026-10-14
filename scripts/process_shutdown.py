"""Close owned JSONL children without killing an in-flight capture start.

The native EOF handler keeps the child alive until its capture cleanup finishes.
Discard unread responses so a full stdout pipe cannot prevent reaching EOF.
False means cleanup is still pending; keep the child/pipe reference for a later
wait. It never authorizes replay, signals, or a replacement helper.
"""
import os
import selectors
import time


def drain_process_after_eof(process, timeout=10):
    if process.stdin is not None and not process.stdin.closed:
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
    deadline = time.monotonic() + timeout
    with selectors.DefaultSelector() as selector:
        if process.stdout is not None and not process.stdout.closed:
            selector.register(process.stdout, selectors.EVENT_READ)
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            if not selector.get_map():
                time.sleep(min(remaining, 0.02))
                continue
            for key, _ in selector.select(min(remaining, 0.05)):
                if not os.read(key.fd, 65536):
                    selector.unregister(key.fileobj)
    if process.stdout is not None:
        process.stdout.close()
    return True
