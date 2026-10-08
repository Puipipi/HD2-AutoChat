# -*- coding: utf-8 -*-
"""Wait until you are really in a squad, send one chat line normally, and report
the game's own before/after evidence.

This is the missing half of AutoChat's verification. Everything up to "the game
accepted the message" was established with the author alone; whether the OTHER
players receive it can only be shown with a second player present. That is what
this script waits for.

How to use it:

    1. Start Helldivers 2 with AutoChat and Bingus Shared Loader enabled.
    2. Run:  python -B tools/watch_for_squad.py
    3. Join a mission that has at least one other player in the squad.
       (A public mission with a random is enough.)
    4. Watch the log it prints. When the peer count goes to 1 or more it sends one
       line and prints what the game's own chat state did.

The send it performs is the NORMAL path -- the peer guard is not bypassed. If the
session is still empty the mod refuses, and this reports that as "not yet" rather
than pretending.

What a pass looks like:

    peer count = 1
    sending "AUTOCHAT-CHECK" ...
    history 0/0 -> 0/1        <- the game itself recorded the line

and, importantly, the other player says they can see it. That last part is a
human observation and no script can produce it.
"""
import argparse
import io
import os
import re
import sys
import time

ROOT = os.path.join(os.environ.get("LOCALAPPDATA", "."),
                    "CowboyBingus", "Helldivers2")
TRIGGER = os.path.join(ROOT, "AutoChat", "trigger.txt")
LOG = os.path.join(ROOT, "Logs", "AutoChat.log")
STATUS = os.path.join(ROOT, "AutoChat", "AutoChat-STATUS.txt")

PEER = re.compile(r"peer count:\s*(\d+)")
SENT = re.compile(r"sent \d+ bytes.*history (\S+) -> (\S+)")
REFUSED = re.compile(r"send refused - (.+)$")
SIGNATURE = re.compile(r"signature\s*:\s*(\S+)")


def read(path):
    if not os.path.exists(path):
        return ""
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def trigger(text):
    os.makedirs(os.path.dirname(TRIGGER), exist_ok=True)
    with io.open(TRIGGER, "w", encoding="utf-8", newline="") as handle:
        handle.write(text + "\n")


def tail_log(count=12):
    return read(LOG).splitlines()[-count:]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--message", default="AUTOCHAT-CHECK",
                        help="the line to send once a squad is detected")
    parser.add_argument("--timeout", type=float, default=1800,
                        help="give up after this many seconds (default 1800 = 30 min)")
    parser.add_argument("--poll", type=float, default=3.0)
    args = parser.parse_args()

    status = read(STATUS)
    if not status:
        sys.exit("AutoChat's STATUS file is missing. Is the game running with the "
                 "mod deployed?")

    signature = SIGNATURE.search(status)
    if not signature or signature.group(1) != "match":
        sys.exit("AutoChat is dormant: %s. It will not send - fix the signature "
                 "first (see the log)." % (signature.group(1) if signature else "?"))

    print("AutoChat says signature: match")
    print("waiting for a squad with at least one other player ...")
    print("(join a mission, or invite a friend; Ctrl+C to stop)")
    print()

    deadline = time.time() + args.timeout
    last_peers = None
    sent = False
    while time.time() < deadline:
        peers = None
        for match in PEER.finditer(read(LOG)):
            peers = int(match.group(1))
        if peers != last_peers:
            print("  peer count = %s%s" % (peers,
                  "" if peers is None else ("   <- squad detected" if peers >= 1 else
                                            "   (still alone)")))
            last_peers = peers

        if peers and peers >= 1 and not sent:
            print()
            print("squad detected (%d other player(s)). sending %r ..." % (peers, args.message))
            mark = len(read(LOG))
            trigger(args.message)
            time.sleep(6)
            fresh = read(LOG)[mark:]
            print()
            for line in fresh.splitlines():
                print("  " + line.strip())
            sent = True

            hit = SENT.search(fresh)
            refused = REFUSED.search(fresh)
            print()
            if hit:
                print("RESULT: the game recorded the line. history %s -> %s"
                      % (hit.group(1), hit.group(2)))
                print("        Now ASK THE OTHER PLAYER whether they can see it.")
                print("        That answer, not this log, is what proves delivery.")
            elif refused:
                print("RESULT: refused - %s" % refused.group(1))
            else:
                print("RESULT: no send line appeared. Check the log above.")
            return

        time.sleep(args.poll)

    print()
    print("Gave up after %.0f minutes without ever seeing another player." % (args.timeout / 60))
    print("The mod's network delivery therefore remains UNVERIFIED - not failed,")
    print("just never exercised. Re-run this when you have someone to play with.")


if __name__ == "__main__":
    main()
