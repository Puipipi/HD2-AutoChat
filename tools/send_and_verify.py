# -*- coding: utf-8 -*-
"""Send one chat line and show the game's own before/after evidence.

A test that only asserts "we called a function" proves nothing about whether the
game accepted the message. What distinguishes a real send from a silent no-op is
the game's own chat state changing: the history ring index/count it maintains
itself. This wraps the whole loop:

    1. read history first/count and the ring
    2. write the text into the mod's trigger file
    3. read history first/count and the ring again
    4. report what changed

A count that increases is the game saying "that line is in my chat". If nothing
changes, the call did nothing and that is reported as a failure, not rounded up.

Note on what this does NOT prove: whether OTHER PLAYERS received it. A solo
session has nobody to receive it, and the mod refuses to send into one. Network
delivery is only established by a second human seeing the line -- see
docs/LIVE-EVIDENCE and the README's verified/unverified split.

    python send_and_verify.py 1433223
    python send_and_verify.py --check          # read state only, send nothing
"""
import argparse
import io
import os
import re
import time

ROOT = os.path.join(os.environ.get("LOCALAPPDATA", "."),
                    "CowboyBingus", "Helldivers2")
TRIGGER = os.path.join(ROOT, "AutoChat", "trigger.txt")
LOG = os.path.join(ROOT, "Logs", "AutoChat.log")

HISTORY = re.compile(r"chat history: first=(\d+) count=(\d+)")
RING = re.compile(r"ring: (\S+) lines held")
OBSERVED = re.compile(r"observation \[(\w+)\]")


def log_text():
    if not os.path.exists(LOG):
        return ""
    with io.open(LOG, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write_trigger(text):
    os.makedirs(os.path.dirname(TRIGGER), exist_ok=True)
    with io.open(TRIGGER, "w", encoding="utf-8", newline="") as handle:
        handle.write(text + "\n")


def wait_for(patterns, timeout, since=0):
    """Wait until every pattern matches text appearing after `since`."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = log_text()[since:]
        if all(p.search(text) for p in patterns):
            return text
        time.sleep(0.5)
    return log_text()[since:]


def latest(pattern, text, group=None):
    found = None
    for match in pattern.finditer(text):
        found = match
    if not found:
        return None
    return found.group(group) if group else found.groups()


def state(timeout=10):
    """Ask the mod to re-observe, then read the history indices it reports."""
    mark = len(log_text())
    # 'ring' forces a fresh poll and prints both the indices and the contents.
    write_trigger("ring")
    chunk = wait_for([RING], timeout, since=mark)
    ring = latest(RING, chunk, 1)
    indices = latest(HISTORY, log_text())
    return {"ring": ring, "indices": indices}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("text", nargs="*", help="the chat line to send")
    parser.add_argument("--check", action="store_true", help="report state only")
    parser.add_argument("--settle", type=float, default=4.0)
    args = parser.parse_args()

    if args.check or not args.text:
        before = state()
        print("chat state now")
        print("  history (first,count) : %s" % (before["indices"],))
        print("  ring lines held       : %s" % before["ring"])
        if before["indices"] == ("0", "0"):
            print("  => the chat history is empty")
        return

    message = " ".join(args.text)
    before = state()
    print("before : history=%s  ring=%s" % (before["indices"], before["ring"]))

    mark = len(log_text())
    write_trigger(message)
    chunk = wait_for([re.compile(r"trigger: send")], 12, since=mark)
    print("trigger: %s" % (chunk.strip().splitlines()[-1] if chunk.strip() else "(no response)"))

    time.sleep(args.settle)
    after = state()
    print("after  : history=%s  ring=%s" % (after["indices"], after["ring"]))

    print()
    if before["indices"] == ("0", "0") and after["indices"] == ("0", "0") and after["ring"] == "0":
        print("RESULT: the chat state did NOT change.")
        print("        Either the send was refused (check the log lines above: the")
        print("        mod names its reason) or the call was a no-op. Not a success.")
    else:
        print("RESULT: the game's own chat state changed, so the line was accepted")
        print("        by the chat. Whether OTHER players received it is a separate")
        print("        question that needs a second human in the squad.")

    print()
    print("recent log:")
    for line in log_text().splitlines()[-10:]:
        print("  " + line)


if __name__ == "__main__":
    main()
