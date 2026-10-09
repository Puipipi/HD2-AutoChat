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
#
# GetCurrentProcessId is deliberately NOT here: it is kernel32, not user32, and the
# original list misclassified it. That misclassification is why the gate once
# reported a kernel32 declaration as a user32 clash. See KERNEL32_LOOKALIKES.
USER32 = frozenset({
    "GetCursorPos", "GetClientRect", "ScreenToClient", "GetForegroundWindow",
    "GetAsyncKeyState", "GetWindowThreadProcessId",
    "ShowCursor", "ClipCursor", "SetCursorPos", "GetKeyState", "GetClipCursor",
    "GetSystemMetrics", "OpenClipboard", "CloseClipboard", "GetClipboardData",
    "GetRegisteredRawInputDevices", "RegisterRawInputDevices", "GetWindowLongPtrW", "SetWindowLongPtrW",
})

# Kernel32 symbols that are frequently mistaken for user32. Declaring these inside a
# "user32" block is a reader trap and risks a mismatched prototype, so the gate
# refuses to let them be listed there.
KERNEL32_LOOKALIKES = frozenset({
    "GetCurrentProcessId", "GetCurrentProcess", "ReadProcessMemory",
    "VirtualQuery", "GetModuleHandleA", "QueryPerformanceCounter",
    "CreateDirectoryA", "GetCurrentThreadId",
})

# The verbatim prototypes from Super Earth Armory Forge v6.2.1's own build_input().
# Checked byte for byte: the whole point is that two mods declaring the same symbol
# must agree exactly, since only the first declaration survives.
REFERENCE_PROTOTYPES = {
    "GetRegisteredRawInputDevices": "uint32_t GetRegisteredRawInputDevices(void *devices, uint32_t *count, uint32_t size);",
    "RegisterRawInputDevices": "int RegisterRawInputDevices(const void *devices, uint32_t count, uint32_t size);",
    "GetWindowLongPtrW": "intptr_t GetWindowLongPtrW(void *window, int index);",
    "SetWindowLongPtrW": "intptr_t SetWindowLongPtrW(void *window, int index, intptr_t value);",
    "GetForegroundWindow": "void *GetForegroundWindow(void);",
    "GetWindowThreadProcessId": "uint32_t GetWindowThreadProcessId(void*,void*);",
    "GetCursorPos": "int GetCursorPos(void*);",
    "ScreenToClient": "int ScreenToClient(void*,void*);",
    "GetClientRect": "int GetClientRect(void*,void*);",
    "GetAsyncKeyState": "int16_t GetAsyncKeyState(int key);",
    "ShowCursor": "int ShowCursor(int show);",
    "ClipCursor": "int ClipCursor(const void *rect);",
    "GetClipCursor": "int GetClipCursor(void *rect);",
    "GetSystemMetrics": "int GetSystemMetrics(int index);",
    "OpenClipboard": "int OpenClipboard(void *owner);",
    "CloseClipboard": "int CloseClipboard(void);",
    "GetClipboardData": "void *GetClipboardData(uint32_t format);",
}

# This mod deliberately does NOT declare process-memory write primitives. It does
# now send chat (a game-level action), so the module is no longer "read-only" in
# the behavioural sense -- but it must never gain the ability to patch memory,
# because nothing in it needs that and every extra primitive is a way to take the
# process down.
#
# VirtualProtect is allowed only for the exact freshly-allocated thunk RW->RX
# transition checked below. Process/game memory writers remain prohibited.
WRITE_SYMBOLS = frozenset({
    "WriteProcessMemory", "VirtualProtectEx", "VirtualAllocEx",
    "CreateRemoteThread", "NtWriteVirtualMemory", "VirtualFreeEx",
})

# Two spellings of ffi.cdef occur in this workspace. The upstream gate only knew
# `ffi.cdef[[...]]`; every mod here actually writes `pcall(ffi.cdef, [[...]])`,
# so upstream found zero blocks and reported "no user32" unconditionally.
CDEF_PATTERNS = (
    r"local\s+(?:USER32_DECLS|declarations)\s*=\s*\{(.*?)\}",
    r"ffi\.cdef\s*\[\[(.*?)\]\]",
    r"ffi\.cdef\s*,\s*\[\[(.*?)\]\]",
    r"ffi\.cdef\s*,\s*'([^']*)'",
)

# The `\b` must NOT be placed before the alternation: with it, `\b(?:k|u|kernel32)\.`
# satisfies the alternation on the single letter `k` of "kernel" and then demands
# a '.' where an 'e' sits, so `kernel.Foo(` matches nothing at all.
SYMBOL_CALL = r"(?:kernel|kernel32|user|user32|bcrypt|ffi\.C|k|u)\.([A-Za-z_]\w*)\s*\("

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
    """user32 declarations are permitted ONLY as exact copies of the reference.

    LuaJIT's C namespace is process-global and `ffi.cdef` keeps the FIRST
    declaration, so re-declaring GetCursorPos with a different prototype silently
    disables every mod that declared it first. That shipped once, and the original
    gate banned the whole symbol set.

    The in-game panel needs GetAsyncKeyState / ShowCursor / ClipCursor / GetCursorPos,
    so the ban is relaxed deliberately (approved) -- and replaced with a stricter
    check that keeps the property the ban was protecting:

      * every user32 name declared must use a prototype BYTE-IDENTICAL to
        Super Earth Armory Forge's own declaration, so whichever mod declares first
        the process holds one identical prototype and neither is disabled;
      * each declaration must sit inside pcall(ffi.cdef, ...) so an already-declared
        symbol cannot abort the load;
      * no user32 name may be declared outside an `already_declared` guard.

    A wrong prototype, a stray declaration, or an unguarded cdef all still fail.
    """
    problems = []
    declared = declared_symbols(source)

    # 1. Every declaration of a clobber-prone symbol must be the approved prototype,
    # exactly. Checking only that the approved string is present somewhere is not
    # enough: a file could carry the good prototype AND a bad second one, and only
    # the bad one would matter at run time.
    for name in sorted(USER32):
        approved = REFERENCE_PROTOTYPES.get(name)
        # Any C declaration of this symbol, however it is spelled.
        found = re.findall(r"\b[\w \*]+?\b%s\s*\([^;]*\)\s*;" % re.escape(name), source)
        for declaration in found:
            if approved is None:
                problems.append("declares user32 symbol %s, which has no approved "
                                "prototype in REFERENCE_PROTOTYPES" % name)
            elif declaration.strip() != approved:
                problems.append(
                    "declares %s as %r, but the approved prototype is %r. LuaJIT "
                    "keeps the FIRST declaration, so a different prototype changes "
                    "what every other mod sees." % (name, declaration.strip(), approved))

    # 2. Every user32 cdef must be inside a pcall. A single-quoted cdef is how this
    # mod family iterates a declaration table, so that is the shape checked.
    for match in re.finditer(r"ffi\.cdef\s*,\s*'([^']*)'", source):
        snippet = match.group(1)
        for name in sorted(set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", snippet)) & USER32):
            if "pcall" not in source[max(0, match.start() - 40):match.start()]:
                problems.append("ffi.cdef for user32 symbol %s is not inside a pcall; "
                                "an already-declared symbol would abort the load"
                                % name)

    # 3. Declaring user32 at all requires the runtime guard to exist.
    if (declared & USER32) and "already_declared" not in source:
        problems.append("declares user32 symbols without an already_declared() guard, "
                        "so it cannot avoid clobbering a mod that declared them first")

    # 4. kernel32 names must not be smuggled into the user32 list.
    for name in sorted(declared & KERNEL32_LOOKALIKES):
        # Only a problem when the name sits among the user32 declarations.
        window = re.search(r"USER32_DECLS(.*?)\n\}", source, re.S)
        if window and re.search(r"\b%s\b" % re.escape(name), window.group(1)):
            problems.append("%s lives in kernel32 but is listed among the user32 "
                            "declarations; that misleads readers and invites a "
                            "mismatched prototype" % name)
    return problems


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
    if "VirtualProtect" in declared_symbols(source):
        calls = list(re.finditer(
            r"([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\.VirtualProtect\s*\(([^)]*)\)", source))
        if len(calls) != 1:
            return ["VirtualProtect is allowed only for one owned thunk RW->RX call"]
        call = calls[0]
        if call.group(1) != "kernel" or re.sub(r"\s+", "", call.group(2)) != "code,4096,0x20,old_protect":
            return ["VirtualProtect is allowed only to change the owned thunk page from RW to RX"]
        allocations = list(re.finditer(
            r"local\s+code\s*=\s*kernel\.VirtualAlloc\(nil\s*,\s*4096\s*,\s*0x3000\s*,\s*0x04\s*\)",
            source))
        if len(allocations) != 1 or allocations[0].end() > call.start():
            return ["VirtualProtect target must be the uniquely allocated owned thunk page"]
        between = source[allocations[0].end():call.start()]
        if re.search(r"\b(?:local\s+)?code\s*=(?!=)", between, re.M):
            return ["VirtualProtect target variable is reassigned after allocation"]
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
