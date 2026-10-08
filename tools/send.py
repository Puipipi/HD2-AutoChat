# -*- coding: utf-8 -*-
"""Write a command into AutoChat's trigger file, and show what came back.

The mod polls `AutoChat\trigger.txt` about twice a second, sends the first
non-empty line once, then clears the file. This wraps that so you do not have to
remember the path or the clearing behaviour.

    python send.py 1433223          # send this text as a chat line
    python send.py inspect          # dump the readable text in the chat object
    python send.py find 1433223     # search the chat object for exact bytes
    python send.py --status         # read the mod's STATUS and recent log

Text is written as UTF-8. A chat line is limited to 512 bytes by the game, and
the mod refuses to send into a session with no other players.
"""
import argparse
import io
import os
import time

ROOT = os.path.join(os.environ.get("LOCALAPPDATA", "."),
                    "CowboyBingus", "Helldivers2")
TRIGGER = os.path.join(ROOT, "AutoChat", "trigger.txt")
STATUS = os.path.join(ROOT, "AutoChat", "AutoChat-STATUS.txt")
LOG = os.path.join(ROOT, "Logs", "AutoChat.log")


def write_trigger(text):
    os.makedirs(os.path.dirname(TRIGGER), exist_ok=True)
    with io.open(TRIGGER, "w", encoding="utf-8", newline="") as handle:
        handle.write(text + "\n")
    print("wrote %r to %s" % (text, TRIGGER))


def tail(path, count):
    if not os.path.exists(path):
        return []
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()[-count:]


def status():
    print("=== STATUS ===")
    if os.path.exists(STATUS):
        for line in io.open(STATUS, encoding="utf-8", errors="replace").read().splitlines():
            if line.strip():
                print("  " + line.rstrip())
    else:
        print("  (no STATUS file - has the game been started with the mod?)")
    print()
    print("=== last 20 log lines ===")
    for line in tail(LOG, 20):
        print("  " + line.rstrip())


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("text", nargs="*", help="text to send, or 'inspect'/'find X'")
    parser.add_argument("--status", action="store_true", help="show status and log, send nothing")
    parser.add_argument("--wait", type=float, default=6.0,
                        help="seconds to wait before showing the result (default 6)")
    args = parser.parse_args()

    if args.status or not args.text:
        status()
        return

    command = " ".join(args.text)
    before = len(tail(LOG, 400))
    write_trigger(command)
    print("waiting %.0fs for the mod to poll it..." % args.wait)
    time.sleep(args.wait)
    print()
    print("=== new log lines ===")
    lines = tail(LOG, 400)
    fresh = lines[before:] if len(lines) > before else lines[-8:]
    if not fresh:
        print("  (nothing new - is the game running?)")
    for line in fresh:
        print("  " + line.rstrip())
    print()
    print("trigger file now contains: %r" %
          (io.open(TRIGGER, encoding="utf-8").read() if os.path.exists(TRIGGER) else ""))


if __name__ == "__main__":
    main()
