# -*- coding: utf-8 -*-
"""Provenance check: every byte literal in the probe must match the third-party
source it was transcribed from, and no more.

The probe asserts five machine-code prefixes. If a byte was mistyped, the probe
would report a "signature changed" that is really a bug in this repo -- the most
expensive kind of false positive, because it sends you looking at the game
instead of at your own file. And if a prefix were LONGER than the part of the
reference literal whose meaning was actually reasoned about, a harmless relink
would look like a signature break.

So this test reads the reference source directly and compares.

Reference (read-only, third-party, not redistributed):
    outputs/validated-2026-10-05/crash-165213-no-smooth/source-audit/
        sources/mods__cowboybingus__better_lobby_management.lua

If that file is absent the test SKIPS rather than passing quietly.

Run:  python -B tests/test_signature_provenance.py
"""
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
def _walk_up(relative):
    current = HERE
    while True:
        candidate = os.path.join(current, relative)
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(current)
        if parent == current:
            raise AssertionError("cannot locate %s above %s" % (relative, HERE))
        current = parent


SOURCE = _walk_up(os.path.join("src", "auto_chat.lua"))
REFERENCE_REL = os.path.join(
    "outputs", "validated-2026-10-05", "crash-165213-no-smooth",
    "source-audit", "sources", "mods__cowboybingus__better_lobby_management.lua")


def find_reference():
    """Walk up from this test until the workspace holding outputs/ is found.

    Hard-coding a depth would break the moment this repo is moved or nested
    differently, and a provenance test that silently skips is worse than no
    test at all.
    """
    current = HERE
    while True:
        candidate = os.path.join(current, REFERENCE_REL)
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


REFERENCE = find_reference()

# rva -> how many leading bytes of the reference literal this probe is entitled
# to assert. Anything past this is a rip-relative displacement that a relink
# legitimately changes, so asserting it would be a false alarm.
VERIFIED_PREFIX = {
    0x1097560: 32,   # 2 pushes + sub rsp + 2 static-offset loads + mov [rsp+..] + cmp
    0xbde430: 28,    # 5 pushes + 2 movs + sub rsp + 2 static-offset loads + mov [rsp+..]
    0x186025d: 21,   # load + lea(dr7) + lea / add rcx, imm + partial call
    0xbeb103: 16,    # mov r9d,1 + mov rdx,rax + mov ecx,imm + partial call
    0x1097a7c: 12,   # two 6-byte [reg+disp32] loads (pure static disp32, no rip-relative part)
}


def parse_lua_bytes(text):
    """Decode a Lua byte-literal such as '\\65\\86\\72' into a bytes object."""
    out = bytearray()
    for value in re.findall(r"\\(\d{1,3})", text):
        out.append(int(value) & 0xFF)
    return bytes(out)


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def probe_signatures(path):
    """{rva: bytes} for every entry of the probe's M.CODE table."""
    src = read_text(path)
    block = re.search(r"M\.CODE\s*=\s*\{(.*?)\n\}", src, re.S)
    if not block:
        raise AssertionError("M.CODE table not found in %s" % path)
    found = {}
    for entry in re.finditer(
        r"rva\s*=\s*(0x[0-9a-fA-F]+)\s*,\s*name\s*=\s*'([^']*)'\s*,\s*bytes\s*=\s*'((?:\\.|[^'])*)'",
        block.group(1),
    ):
        found[int(entry.group(1), 16)] = (entry.group(2), parse_lua_bytes(entry.group(3)))
    return found


def reference_signatures(path):
    """{rva: bytes} for every entry of the reference's C.SEND / C.RPC / C.CODE."""
    src = read_text(path)
    found = {}
    for entry in re.finditer(
        r"rva\s*=\s*(0x[0-9a-fA-F]+)\s*,\s*type\s*=\s*'[^']*'\s*,\s*bytes\s*=\s*'((?:\\.|[^'])*)'",
        src,
    ):
        found[int(entry.group(1), 16)] = parse_lua_bytes(entry.group(2))
    for entry in re.finditer(
        r"\{rva\s*=\s*(0x[0-9a-fA-F]+)\s*,\s*name\s*=\s*'[^']*'\s*,\s*bytes\s*=\s*'((?:\\.|[^'])*)'",
        src,
    ):
        found[int(entry.group(1), 16)] = parse_lua_bytes(entry.group(2))
    # One reference entry is split across a Lua concatenation; join it.
    for entry in re.finditer(
        r"\{rva\s*=\s*(0x[0-9a-fA-F]+)\s*,\s*name\s*=\s*'([^']*)'\s*,\s*bytes\s*=\s*'((?:\\.|[^'])*)'"
        r"\s*\.\.\s*'((?:\\.|[^'])*)'",
        src,
    ):
        found[int(entry.group(1), 16)] = (
            parse_lua_bytes(entry.group(3)) + parse_lua_bytes(entry.group(4))
        )
    return found


@unittest.skipUnless(REFERENCE,
                     "third-party reference source not present in this checkout")
class SignatureProvenanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = probe_signatures(SOURCE)
        cls.reference = reference_signatures(REFERENCE)

    def test_every_probe_signature_exists_in_the_reference(self):
        for rva, (name, _) in self.probe.items():
            self.assertIn(rva, self.reference,
                          "%s (0x%x) is not in the reference at all" % (name, rva))

    def test_no_byte_was_mistyped(self):
        for rva, (name, mine) in self.probe.items():
            theirs = self.reference[rva]
            self.assertEqual(
                theirs[:len(mine)], mine,
                "%s (0x%x): transcribed bytes differ from the reference\n"
                "  probe    : %s\n  reference: %s"
                % (name, rva, mine.hex().upper(), theirs[:len(mine)].hex().upper()))

    def test_no_prefix_claims_more_than_was_verified(self):
        for rva, (name, mine) in self.probe.items():
            limit = VERIFIED_PREFIX[rva]
            self.assertLessEqual(
                len(mine), limit,
                "%s (0x%x) asserts %d bytes but only %d were reasoned about; the "
                "rest is a rip-relative displacement that a relink changes"
                % (name, rva, len(mine), limit))

    def test_prefix_table_covers_exactly_the_probe_table(self):
        self.assertEqual(set(VERIFIED_PREFIX), set(self.probe),
                         "VERIFIED_PREFIX and M.CODE must describe the same set")


if __name__ == "__main__":
    unittest.main(verbosity=2)
