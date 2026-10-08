# -*- coding: utf-8 -*-
"""Find where the chat entries actually live, from a live `dump` of the region.

The `ring` reader reported noise because its slot base was wrong. Rather than guess
again, this pulls the live bytes around the chat object and reports every readable
text run with its exact offset. The messages the mod sent are known strings, so the
offset they appear at IS the answer.

    python -B find_ring_layout.py [--chat-offset 0x900] [--bytes 0x2000]
"""
import argparse
import ctypes
import os
import re
import sys
import time

ROOT = os.path.join(os.environ.get("LOCALAPPDATA", "."),
                    "CowboyBingus", "Helldivers2")
TRIGGER = os.path.join(ROOT, "AutoChat", "trigger.txt")
LOG = os.path.join(ROOT, "Logs", "AutoChat.log")

# Matches the mod's own `dump` output: "  +0x120  41 42 ...  AB.."
DUMP_LINE = re.compile(r"\+0x([0-9A-F]+)\s+((?:[0-9A-F]{2} )+)\s*(.*)$")


def send(command, wait=7.0):
    with open(TRIGGER, "w", encoding="utf-8", newline="") as handle:
        handle.write(command + "\n")
    time.sleep(wait)


def read_lines():
    if not os.path.exists(LOG):
        return []
    with open(LOG, encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start", type=lambda v: int(v, 0), default=0x900)
    parser.add_argument("--end", type=lambda v: int(v, 0), default=0x1400)
    args = parser.parse_args()

    before = len(read_lines())
    # `dumpregion` is not a command the mod has; drive the existing `dump` per slot
    # instead, which prints a whole 0x228 entry as hex+ASCII.
    print("dumping ring slots 0..5 via the mod's own `dump` command")
    collected = {}
    for slot in range(0, 6):
        mark = len(read_lines())
        send("dump %d" % slot)
        for line in read_lines()[mark:]:
            m = DUMP_LINE.search(line)
            if m:
                offset = int(m.group(1), 16)
                raw = bytes(int(b, 16) for b in m.group(2).split())
                collected.setdefault(slot, {})[offset] = raw

    print()
    for slot in sorted(collected):
        blob = collected[slot]
        if not blob:
            print("slot %d: no data" % slot)
            continue
        # reassemble
        data = bytearray()
        expected = 0
        for offset in sorted(blob):
            if offset != expected:
                break
            data += blob[offset]
            expected = offset + len(blob[offset])
        print("slot %d at chat+0x%X :" % (slot, 0x9598 + slot * 0x228))
        for m in re.finditer(rb"[\x20-\x7e]{4,}", bytes(data)):
            print("   +0x%03X  %r" % (m.start(), m.group().decode("ascii")))
        if not re.search(rb"[\x20-\x7e]{4,}", bytes(data)):
            print("   (no readable run >= 4 chars)")
        print()


if __name__ == "__main__":
    main()
