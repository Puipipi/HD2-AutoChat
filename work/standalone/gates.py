# -*- coding: utf-8 -*-
"""The build gates, as a module, so they can be tested instead of trusted.

`build_mod.py` used to carry these inline. They are separated out for one
concrete reason: an inline gate cannot be shown to fail, and three of these were
found to be incapable of failing. `tests/test_build_gates.py` mutates a source
and asserts each gate rejects it.

Each check returns a list of failure strings; an empty list means pass.
"""
import re

# Symbols that must never appear in an ffi.cdef block in this mod family. LuaJIT's
# C namespace is process-global and `ffi.cdef` keeps the FIRST declaration, so
# re-declaring GetCursorPos with a different prototype silently disables every
# other mod that declared it first. This shipped once.
USER32 = frozenset({
    "GetCursorPos", "GetClientRect", "ScreenToClient", "GetForegroundWindow",
    "GetAsyncKeyState", "GetWindowThreadProcessId", "GetCurrentProcessId",
    "ShowCursor", "ClipCursor", "SetCursorPos", "GetKeyState",
})

# This mod deliberately does NOT declare process-memory write primitives. It does
# now send chat (a game-level action), so the module is no longer "read-only" in
# the behavioural sense -- but it must never gain the ability to patch memory,
# because nothing in it needs that and every extra primitive is a way to take the
# process down.
#
# Chosen on purpose: `VirtualProtect` is excluded from the mod entirely, even
# though the workspace's own patterns declare it, because writing to game memory
# is not something this mod does.
WRITE_SYMBOLS = frozenset({
    "WriteProcessMemory", "VirtualProtect", "VirtualProtectEx", "VirtualAllocEx",
    "CreateRemoteThread", "NtWriteVirtualMemory", "VirtualFreeEx",
})

# Two spellings of ffi.cdef occur in this workspace. The upstream gate only knew
# `ffi.cdef[[...]]`; every mod here actually writes `pcall(ffi.cdef, [[...]])`,
# so upstream found zero blocks and reported "no user32" unconditionally.
CDEF_PATTERNS = (
    r"ffi\.cdef\s*\[\[(.*?)\]\]",
    r"ffi\.cdef\s*,\s*\[\[(.*?)\]\]",
    r"ffi\.cdef\s*,\s*'([^']*)'",
)

# The `\b` must NOT be placed before the alternation: with it, `\b(?:k|u|kernel32)\.`
# satisfies the alternation on the single letter `k` of "kernel" and then demands
# a '.' where an 'e' sits, so `kernel.Foo(` matches nothing at all.
SYMBOL_CALL = r"(?:kernel|kernel32|user32|bcrypt|ffi\.C|k|u)\.([A-Za-z_]\w*)\s*\("

_DECLARATION = re.compile(r"([A-Za-z_]\w*)\s*\([^;()]*\)\s*;")


def declared_symbols(source):
    """Every C symbol declared in any ffi.cdef block of `source`."""
    found = set()
    for pattern in CDEF_PATTERNS:
        for block in re.findall(pattern, source, re.S):
            found.update(m.group(1) for m in _DECLARATION.finditer(block))
    return found


def called_symbols(source):
    """Every `<module>.CName(` call in `source`."""
    return {m.group(1) for m in re.finditer(SYMBOL_CALL, source)}


def check_user32(source):
    clash = declared_symbols(source) & USER32
    if clash:
        return ["user32 symbol(s) declared: %s" % ", ".join(sorted(clash))]
    return []


def check_called_are_declared(source):
    declared = declared_symbols(source)
    called = called_symbols(source)
    missing = sorted(called - declared - {"GetModuleHandleA", "GetProcAddress"})
    if missing:
        return ["called but not declared (hard error at the call site): %s"
                % ", ".join(missing)]
    return []


def check_no_memory_writes(source):
    """No process-memory write primitive may be declared.

    Named for what it checks, not for a behaviour: the mod sends chat, so calling
    it "read-only" would be a lie. What it must never do is patch memory.
    """
    clash = declared_symbols(source) & WRITE_SYMBOLS
    if clash:
        return ["declares a process-memory write primitive: %s" % ", ".join(sorted(clash))]
    return []


def check_detection_is_live(source):
    """Refuse to report success for a gate that cannot see anything.

    A regex that matches nothing makes every other check pass vacuously. This is
    the failure mode that hid the two pattern bugs, so it is checked explicitly.
    """
    problems = []
    if not declared_symbols(source):
        problems.append(
            "no ffi.cdef declaration was found at all - the extraction pattern is "
            "wrong, so the user32 and write-primitive gates cannot detect anything")
    if not called_symbols(source):
        problems.append(
            "no C symbol call was found at all - the extraction pattern is wrong, "
            "so the declared-before-call gate cannot detect anything")
    return problems


def run(source):
    """All gates. Returns (ok, messages)."""
    messages = []
    for check in (check_user32, check_called_are_declared, check_no_memory_writes,
                  check_detection_is_live):
        messages.extend(check(source))
    return (not messages), messages
