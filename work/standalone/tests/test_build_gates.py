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
import re
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
TOOLS = os.path.join(STANDALONE, "tools")

GET_PROC = "void *GetCurrentProcess(void);"


def lupa_runtime():
    """A LuaJIT state, imported lazily so the gate tests stay runnable without it."""
    import lupa.luajit21 as luajit
    return luajit.LuaRuntime(unpack_returned_tuples=True)


class ArmoryFrameTest(unittest.TestCase):
    """The panel frame must be Armory's, and that claim has to be checkable.

    The user asked repeatedly for Armory's look rather than an invented one, and I had
    already shipped an invented one once. "I copied Armory" is worth nothing as an
    assertion, so the frame's actual constants are compared against Armory's source
    where it is available on this machine.

    The reference is NOT redistributed, so this SKIPS with a reason when absent -- a
    silent pass would be worse than no test here, because it is the only thing standing
    between "I copied it" and "I think I copied it".
    """

    REFERENCE = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.dirname(HERE))))),
        "outputs", "validated-2026-10-04", "hud-compatibility", "sources",
        "installed-Super-Earth-Armory-Forge-v6.2.1-0-0.lua")

    # The frame elements that make Armory's panel recognisable, as Armory writes them.
    # Each is a literal from its draw(); ours must contain the same numbers.
    FRAME_ELEMENTS = [
        ("background fill at z950", "rect(0, 0, W, H, C.BG, 950)"),
        ("outer border at z955", "border(0, 0, W, H, C.LINE, 955)"),
        ("yellow strip along the TOP edge", "rect(0, 0, W, 3, C.YELLOW, 952)"),
        ("tab strip starts at y=108", "border(x, 108, w, 40"),
        ("tab hit region at y=108, height 40", "region(key, x, 108, w, 40)"),
        ("tab width capped at 230", "math.min(230"),
    ]

    @classmethod
    def setUpClass(cls):
        with io.open(SOURCE, encoding="utf-8") as handle:
            cls.source = handle.read()

    def test_armory_reference_is_present_or_this_skips_loudly(self):
        if not os.path.exists(self.REFERENCE):
            self.skipTest("Armory reference not present (not redistributed): %s"
                          % self.REFERENCE)
        with io.open(self.REFERENCE, encoding="utf-8", errors="replace") as handle:
            self.reference = handle.read()

    def test_the_reference_really_contains_the_frame_we_claim_to_copy(self):
        """Guards the test itself: if the reference has changed shape, it must not
        quietly start passing against a frame that is no longer Armory's."""
        if not os.path.exists(self.REFERENCE):
            self.skipTest("Armory reference not present")
        with io.open(self.REFERENCE, encoding="utf-8", errors="replace") as handle:
            reference = handle.read()
        for label, literal in [("background fill at z950", "rect(0, 0, W, H, C.BG, 950)"),
                               ("outer border at z955", "border(0, 0, W, H, C.LINE, 955)"),
                               ("yellow strip along the TOP edge",
                                "rect(0, 0, W, 3, C.YELLOW, 952)"),
                               ("tab strip y=108, height 40", "border(x, 108, w, 40")]:
            self.assertIn(literal, reference,
                          "the reference no longer contains %s, so this test can no "
                          "longer prove the frame was copied" % label)

    def test_the_shipped_frame_carries_armorys_numbers(self):
        """The frame must use Armory's GEOMETRY, whatever it is spelled as.

        Comparing call sites as raw text failed the first time this ran, and it was the
        test that was wrong: this file names the strip's position and height as TAB_Y and
        TAB_H rather than repeating 108 and 40, which is clearer and cannot drift between
        the border, the fill and the hit region. So the NUMBERS are compared instead --
        which is the property that actually matters -- and the call sites are checked to
        use those named values.
        """
        if not os.path.exists(self.REFERENCE):
            self.skipTest("Armory reference not present")
        source = self.source

        # Armory's top strip sits at y=108 and is 40 tall; ours must say so.
        for name, expected in (("TAB_Y", 108), ("TAB_H", 40)):
            match = re.search(r"local\s+%s\s*=\s*(\d+)" % name, source)
            self.assertIsNotNone(match, "%s must be a literal so it can be checked" % name)
            self.assertEqual(expected, int(match.group(1)),
                             "%s must be Armory's value (%d), not an invention"
                             % (name, expected))

        # And the three things that must agree about that rectangle must all use them.
        for label, literal in [
                ("tab fill", "rect(x, TAB_Y, w, TAB_H"),
                ("tab border", "border(x, TAB_Y, w, TAB_H"),
                ("tab hit region", "region(key, x, TAB_Y, w, TAB_H)")]:
            self.assertIn(literal, source,
                          "the %s must be drawn from the same named rectangle, or the "
                          "click area can disagree with what is drawn" % label)

        # The recognisable outer elements, which ARE literals in both files.
        for label, literal in [
                ("background fill at z950", "rect(0, 0, W, H, C.BG, 950)"),
                ("outer border at z955", "border(0, 0, W, H, C.LINE, 955)"),
                ("yellow strip along the TOP edge", "rect(0, 0, W, 3, C.YELLOW, 952)"),
                ("tab width capped at 230", "math.min(230")]:
            self.assertIn(literal, source,
                          "the panel frame is missing Armory's %s; an invented frame is "
                          "what the user rejected" % label)

    def test_the_frame_has_no_mod_options_menu_dependency(self):
        """MOM was explicitly rejected. Reconnaissance of it is fine; a dependency is
        not, and this is the check that keeps one from creeping in."""
        for forbidden in ("ModOptionsMenu", "register_option", "BingusTranslations",
                          "MOM."):
            self.assertNotIn(forbidden, self.source,
                             "%s is a ModOptionsMenu dependency; the panel must be "
                             "standalone" % forbidden)


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
    def test_declaration_table_and_user_calls_are_visible_to_gates(self):
        snippet = "local declarations = {'void *VirtualAlloc(void *p, size_t n, uint32_t t, uint32_t f);'}\nuser.RegisterRawInputDevices(nil, 0, 16)"
        self.assertIn('VirtualAlloc', gates.declared_symbols(snippet))
        self.assertIn('RegisterRawInputDevices', gates.called_symbols(snippet))
        self.assertTrue(gates.check_called_are_declared(snippet))

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

    # ------------------------------------------------- silent LuaJIT limits
    def test_source_compiles_under_the_luajit_limits(self):
        """The silent-skip failures are compile-time, so a successful load is proof.

        A mod the loader skips produces NO log line at all, which makes it the most
        expensive failure mode in this family. The two causes are compile-time
        ("too many constants", "function too long"), so compiling the shipped source
        is real evidence that neither was tripped -- and compiling in the harness uses
        the same LuaJIT the game does.
        """
        lua = lupa_runtime()
        ok, err = lua.eval("(function(p) local c, e = loadfile(p) "
                           "return c ~= nil, tostring(e) end)")(SOURCE)
        self.assertTrue(ok, "the shipped source must compile: %s" % err)

    def test_the_tool_reproduces_the_limit_it_checks(self):
        """A budget check that cannot reproduce the failure proves nothing.

        The tool asserts its own self-check; this pins that the limit it reports is
        genuinely reproducible, so it cannot silently decay into always-passing.
        """
        import subprocess
        result = subprocess.run(
            [sys.executable, "-B", os.path.join(TOOLS, "bytecode_budget.py"), SOURCE],
            capture_output=True, text=True)
        self.assertEqual(0, result.returncode,
                         "the bytecode budget tool must pass:\n%s\n%s"
                         % (result.stdout, result.stderr))
        self.assertIn("constant limit     : reproduced", result.stdout,
                      "the tool must prove the limit is reproducible, not just claim "
                      "the file is fine")

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


    def test_virtualprotect_only_allows_exact_owned_thunk_rw_to_rx(self):
        self.assertEqual([], gates.check_no_memory_writes(self.source),
                         "the one protected page must be the newly allocated thunk")
        mutated = self.source.replace(
            "kernel.VirtualProtect(code, 4096, 0x20, old_protect)",
            "kernel.VirtualProtect(game_base, 4096, 0x20, old_protect)")
        failures = gates.check_no_memory_writes(mutated)
        self.assertTrue(failures, "protecting the game image must stay prohibited")
        self.assertIn("owned thunk page", " ".join(failures))
        appended = self.source + "\nkernel.VirtualProtect(game_base, 4096, 0x20, old_protect)\n"
        self.assertTrue(gates.check_no_memory_writes(appended),
                        "a legal thunk transition must not whitelist later calls")
        rebound = self.source.replace(
            "local c = ffi.cast('uint8_t *', code)",
            "code = game_base\n        local c = ffi.cast('uint8_t *', code)")
        self.assertTrue(gates.check_no_memory_writes(rebound),
                        "the allocated target must not be rebound before protection")
        inline_rebound = self.source.replace(
            "local c = ffi.cast('uint8_t *', code)",
            "if true then code = game_base end\n        local c = ffi.cast('uint8_t *', code)")
        self.assertTrue(gates.check_no_memory_writes(inline_rebound),
                        "an inline block must not rebind the protected allocation")
        alternate_namespace = self.source + "\nffi.C.VirtualProtect(game_base, 4096, 0x20, old_protect)\n"
        self.assertTrue(gates.check_no_memory_writes(alternate_namespace),
                        "a second namespace cannot bypass the unique approved call")

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
