# -*- coding: utf-8 -*-
"""The build gates must be able to FAIL.

A gate that cannot fail is worse than no gate: it reports "clean" while the thing
it was supposed to catch sails through. Three of the gates in this repo were
measured incapable of failing, so every one of them is checked here by mutating a
real source and asserting the gate rejects it.

The two pattern bugs this file pins down:

  * the user32 gate must find `pcall(ffi.cdef, [[...]])`, which is how this
    workspace writes cdefs. Upstream's pattern only knows `ffi.cdef[[...]]` and
    found ZERO blocks here, so it reported "no user32" no matter what the file
    declared.
  * the declared-before-call gate must find `kernel.Foo(`. Upstream's pattern
    `\\b(?:k|u|kernel32|...)\\.` cannot: the alternation satisfies itself on the
    single letter `k` of "kernel" and then demands a '.' that is not there.

Run:  python -B tests/test_build_gates.py
"""
import io
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STANDALONE = os.path.abspath(os.path.join(HERE, os.pardir))
sys.path.insert(0, STANDALONE)

import gates  # noqa: E402


def walk_up(relative):
    current = HERE
    while True:
        candidate = os.path.join(current, relative)
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(current)
        if parent == current:
            raise AssertionError("cannot locate %s above %s" % (relative, HERE))
        current = parent


SOURCE = walk_up(os.path.join("src", "auto_chat.lua"))

GET_PROC = "void *GetCurrentProcess(void);"


class LiveSourceTest(unittest.TestCase):
    """The shipped source must pass every gate."""

    @classmethod
    def setUpClass(cls):
        with io.open(SOURCE, encoding="utf-8") as handle:
            cls.source = handle.read()

    def test_all_gates_pass(self):
        ok, messages = gates.run(self.source)
        self.assertTrue(ok, "shipped source must pass the gates: %s" % messages)

    def test_source_declares_no_user32(self):
        self.assertEqual([], gates.check_user32(self.source))

    def test_called_symbols_are_all_declared(self):
        called = gates.called_symbols(self.source)
        self.assertTrue(called, "the gate must actually find calls")
        self.assertEqual([], gates.check_called_are_declared(self.source))

    def test_probe_declares_no_write_symbol(self):
        self.assertEqual([], gates.check_no_memory_writes(self.source))

    def test_detection_is_live(self):
        self.assertEqual([], gates.check_detection_is_live(self.source))


class GateCanFailTest(unittest.TestCase):
    """Each gate must reject a source that violates it."""

    @classmethod
    def setUpClass(cls):
        with io.open(SOURCE, encoding="utf-8") as handle:
            cls.source = handle.read()

    # ------------------------------------------------------------- user32
    def test_user32_gate_fires_on_pcall_style_cdef(self):
        """A user32 declaration with the WRONG prototype must still be rejected.

        The gate no longer bans user32 outright -- the panel legitimately needs
        GetCursorPos/GetAsyncKeyState/ShowCursor/ClipCursor, declared as verbatim
        copies of Super Earth Armory Forge's prototypes so that whichever mod
        declares first, the process holds one identical signature. What must never
        pass is a DIFFERENT prototype: LuaJIT keeps the first declaration, so a
        mismatch silently changes what every other mod sees.

        The mutation declares GetCursorPos with a plausible-looking but
        non-identical prototype -- the shape a careless re-declaration takes.
        """
        mutated = self.source.replace(
            GET_PROC, GET_PROC + "\n    int GetCursorPos(void *point);")
        failures = gates.check_user32(mutated)
        self.assertTrue(failures, "a user32 declaration must be rejected")
        self.assertIn("GetCursorPos", " ".join(failures))

    def test_user32_gate_accepts_the_reference_prototypes(self):
        """The approved declarations must pass, or the panel could never ship."""
        self.assertEqual([], gates.check_user32(self.source),
                         "the shipped source's user32 declarations must be accepted")

    def test_upstream_pattern_really_cannot_see_this_style(self):
        """Pins the reason the extra pattern exists, instead of assuming it."""
        import re
        upstream = re.findall(r"ffi\.cdef\s*\[\[(.*?)\]\]", self.source, re.S)
        self.assertEqual([], upstream,
                         "if this is no longer empty the source changed shape and "
                         "the note in gates.py is stale")

    # ------------------------------------------------- declared before call
    def test_undeclared_call_is_rejected(self):
        mutated = self.source + "\nlocal probe = kernel.NotARealSymbol(1)\n"
        failures = gates.check_called_are_declared(mutated)
        self.assertTrue(failures, "an undeclared call must be rejected")
        self.assertIn("NotARealSymbol", " ".join(failures))

    def test_symbol_pattern_matches_kernel_dot_and_upstream_does_not(self):
        import re
        probe = "local a = kernel.GetCurrentProcess()"
        upstream = r"\b(?:k|u|kernel32|user32|bcrypt|ffi\.C)\.([A-Za-z_]\w*)\s*\("
        self.assertEqual([], re.findall(upstream, probe),
                         "documents the upstream bug this gate works around")
        self.assertEqual(["GetCurrentProcess"], re.findall(gates.SYMBOL_CALL, probe))

    # ------------------------------------------------------------- read-only
    def test_write_symbol_is_rejected(self):
        mutated = self.source.replace(
            GET_PROC, GET_PROC + "\n    int WriteProcessMemory(void);")
        failures = gates.check_no_memory_writes(mutated)
        self.assertTrue(failures, "a write symbol must be rejected")
        self.assertIn("WriteProcessMemory", " ".join(failures))

    # ------------------------------------------------------- vacuous success
    def test_a_source_the_patterns_cannot_parse_is_rejected(self):
        """The bug that hid both pattern errors: 'found nothing' == 'all clear'."""
        unparseable = "local x = 1\n-- no cdef and no C calls anywhere\n"
        failures = gates.check_detection_is_live(unparseable)
        self.assertEqual(2, len(failures),
                         "both 'found nothing' conditions must be reported")

    def test_shipped_source_is_parsed_by_both_extractors(self):
        self.assertTrue(gates.declared_symbols(self.source))
        self.assertTrue(gates.called_symbols(self.source))


if __name__ == "__main__":
    unittest.main(verbosity=2)
