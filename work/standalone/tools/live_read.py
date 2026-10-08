# -*- coding: utf-8 -*-
"""Read the live game's chat state from outside the process, read-only.

Why this exists: the in-game probe can only report what it is programmed to look
at. When a send is refused, the question "is the offset wrong, or is the session
genuinely empty?" needs an answer from the process itself. This tool reads the
same offsets the mod uses and prints them, plus a bounded scan for a text needle,
so the mod's claims can be checked against the process rather than trusted.

It only reads. It opens the target with PROCESS_VM_READ | PROCESS_QUERY_INFORMATION
and never asks for a write right.

    python live_read.py --peer
    python live_read.py --find 114514
    python live_read.py --dump 0x16380 0x16400

Requires the game to be running.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import sys

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_GUARD = 0x100
PAGE_NOACCESS = 0x01

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

# Explicit argtypes matter on 64-bit: without them ctypes assumes a 32-bit int
# for the module handle and raises OverflowError on a real HMODULE.
kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
kernel32.OpenProcess.restype = ctypes.c_void_p
kernel32.ReadProcessMemory.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_void_p, ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_size_t)]
kernel32.ReadProcessMemory.restype = wt.BOOL
kernel32.VirtualQuery.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
kernel32.VirtualQuery.restype = ctypes.c_size_t
psapi.EnumProcessModules.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                     wt.DWORD, ctypes.POINTER(wt.DWORD)]
psapi.EnumProcessModules.restype = wt.BOOL
psapi.GetModuleBaseNameW.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                     ctypes.c_wchar_p, wt.DWORD]
psapi.GetModuleBaseNameW.restype = wt.DWORD

GAME_DLL = "game.dll"
CONTEXT_PTR = 0x347CEF0
PEER_COUNT = 0x16390
PEERS = 0x16398
PEER_STRIDE = 32
MAX_PEERS = 4
LOCAL = 0xB398
CHAT_OBJECT = 0xC418
HISTORY_FIRST = 0x9590
HISTORY_COUNT = 0x9594


class MBI(ctypes.Structure):
    """MEMORY_BASIC_INFORMATION, x64.

    The layout is a trap: RegionSize is a SIZE_T and therefore needs 8-byte
    alignment, so after AllocationProtect (a DWORD at 0x14) there are 4 bytes of
    padding before it. Getting this wrong does not raise -- it silently reads the
    wrong field, which here showed a committed region as State=0x10000.
    """
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),        # 0x00
        ("AllocationBase", ctypes.c_void_p),     # 0x08
        ("AllocationProtect", wt.DWORD),         # 0x10
        ("__alignment1", wt.DWORD),              # 0x14
        ("RegionSize", ctypes.c_size_t),         # 0x18
        ("State", wt.DWORD),                     # 0x20
        ("Protect", wt.DWORD),                   # 0x24
        ("Type", wt.DWORD),                      # 0x28
        ("__alignment2", wt.DWORD),              # 0x2C
    ]


def open_process():
    # Find the pid without shelling out to a locale-dependent tasklist.
    import subprocess
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq helldivers2.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if len(parts) >= 2 and parts[0].lower() == "helldivers2.exe":
            pids.append(int(parts[1]))
    if not pids:
        sys.exit("helldivers2.exe is not running")
    pid = pids[0]
    handle = kernel32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not handle:
        sys.exit("OpenProcess failed (error %d)" % ctypes.get_last_error())
    return pid, handle


def module_base(handle):
    """Base address of game.dll in the target.

    Derived from the module list rather than from the mod's own log, so that this
    tool does not depend on the thing it is checking.
    """
    needed = wt.DWORD()
    modules = (ctypes.c_void_p * 1024)()
    if not psapi.EnumProcessModules(handle, modules, ctypes.sizeof(modules),
                                    ctypes.byref(needed)):
        sys.exit("EnumProcessModules failed (error %d)" % ctypes.get_last_error())
    count = needed.value // ctypes.sizeof(ctypes.c_void_p)
    name = ctypes.create_unicode_buffer(260)
    for i in range(count):
        if psapi.GetModuleBaseNameW(handle, modules[i], name, 260):
            if name.value.lower() == GAME_DLL:
                return modules[i]
    sys.exit("game.dll not found in the target process")


def read(handle, address, size):
    if address < 0x10000 or address > 0x7FFFFFFFFFFF:
        return None
    mbi = MBI()
    if kernel32.VirtualQuery(ctypes.c_void_p(address), ctypes.byref(mbi), ctypes.sizeof(mbi)) != ctypes.sizeof(mbi):
        return None
    if mbi.State != MEM_COMMIT:
        return None
    if mbi.Protect == 0 or mbi.Protect == PAGE_NOACCESS or mbi.Protect >= PAGE_GUARD:
        return None
    buffer = ctypes.create_string_buffer(size)
    got = ctypes.c_size_t()
    if not kernel32.ReadProcessMemory(handle, ctypes.c_void_p(address), buffer, size, ctypes.byref(got)):
        return None
    if got.value != size:
        return None
    return buffer.raw


def u32(handle, address):
    blob = read(handle, address, 4)
    return None if blob is None else int.from_bytes(blob, "little")


def u64(handle, address):
    blob = read(handle, address, 8)
    return None if blob is None else int.from_bytes(blob, "little")


def show_peer(handle, base):
    ctx = u64(handle, base + CONTEXT_PTR)
    print("game.dll base     : 0x%X" % base)
    print("context pointer   : %s" % ("0x%X" % ctx if ctx else ctx))
    if not ctx:
        print("=> not in a session")
        return
    own = u32(handle, ctx + LOCAL)
    count = u32(handle, ctx + PEER_COUNT)
    print("session count     : %s" % count)
    print("local peer id (lo): %s (0x%X)" % (own, own or 0))
    for i in range(MAX_PEERS):
        entry = ctx + PEERS + i * PEER_STRIDE
        lo = u32(handle, entry)
        hi = u32(handle, entry + 4)
        idx = u32(handle, entry + 20)
        print("  peer[%d] lo=%-12s hi=%-12s index=%-4s %s"
              % (i, lo, hi, idx, "<- us" if lo == own else ""))
    chat = ctx + CHAT_OBJECT
    print("chat object       : 0x%X" % chat)
    print("  flag byte       : %s" % u32(handle, chat) if u32(handle, chat) is not None else "  flag byte       : unreadable")
    print("  history first   : %s" % u32(handle, chat + HISTORY_FIRST))
    print("  history count   : %s" % u32(handle, chat + HISTORY_COUNT))


def show_find(handle, base, needle, span):
    """Scan the chat object and its neighbourhood for a UTF-8 needle."""
    ctx = u64(handle, base + CONTEXT_PTR)
    if not ctx:
        sys.exit("not in a session")
    chat = ctx + CHAT_OBJECT
    targets = needle.encode("utf-8")
    hits = 0
    for offset in range(0, span):
        blob = read(handle, chat + offset, len(targets))
        if blob == targets:
            print("HIT at chat+0x%X" % offset)
            hits += 1
    print("needle %r : %d hit(s) in chat..chat+0x%X" % (needle, hits, span))
    if hits == 0:
        print("  (the message is not in that window -- either never sent, stored")
        print("   elsewhere, or the chat object holds a pointer to the text)")


def show_dump(handle, base, start, end):
    ctx = u64(handle, base + CONTEXT_PTR)
    if not ctx:
        sys.exit("not in a session")
    for address in range(start, end, 16):
        blob = read(handle, ctx + address, 16)
        if blob is None:
            print("%08X  <unreadable>" % address)
            continue
        hexpart = " ".join("%02X" % b for b in blob)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in blob)
        print("%08X  %-47s  %s" % (address, hexpart, text))


def font_probe(handle, base):
    """Read the three font resource ids the way the mod does, from the LIVE process.

    Why this is worth a tool: the ids live in globals the engine fills in at startup, so
    the file on disk reads as zeros and tells you nothing. The only way to know whether
    the real-text panel can work on THIS build and THIS launch is to look in the running
    process. A zero id here means the panel will fall back to the bitmap font, and that
    is a fact rather than a guess.
    """
    def u32(address):
        raw = read(handle, address, 4)
        return None if raw is None else ctypes.c_uint32.from_buffer_copy(raw).value

    def u64(address):
        raw = read(handle, address, 8)
        return None if raw is None else ctypes.c_uint64.from_buffer_copy(raw).value

    def id64(address):
        raw = read(handle, address, 8)
        if raw is None:
            return None, "unreadable"
        low = ctypes.c_uint32.from_buffer_copy(raw[0:4]).value
        high = ctypes.c_uint32.from_buffer_copy(raw[4:8]).value
        if low == 0 and high == 0:
            return None, "ZERO (engine has not filled it in)"
        return "%08x%08x" % (high, low), "populated"

    pe_at = u32(base + 0x3C)
    stamp = None
    if pe_at:
        raw = read(handle, base + pe_at, 12)
        if raw and raw[0:4] == b"PE\0\0":
            stamp = ctypes.c_uint32.from_buffer_copy(raw[8:12]).value
    print("  game.dll base   : 0x%X" % base)
    print("  PE TimeDateStamp: %s" % ("0x%08X" % stamp if stamp is not None else "unreadable"))
    print("  expected stamp  : 0x%08X  -> %s"
          % (GAME_STAMP, "MATCH" if stamp == GAME_STAMP else "different build"))

    for label, rva in (("FONT_RVA", 0x3772268), ("ATLAS_RVA", 0x3772EE8)):
        value, why = id64(base + rva)
        print("  %-10s 0x%X  id64=%s  %s" % (label, rva, value or "-", why))

    owner = u64(base + 0x37C5478)
    print("  MATERIAL   0x%X  owner=%s" % (0x37C5478,
                                           ("0x%X" % owner) if owner else "NULL"))
    if owner:
        value, why = id64(owner + 24)
        print("             -> material id64=%s  %s" % (value or "-", why))
    else:
        print("             -> the engine has not created the material holder yet")
    print()
    print("  A populated FONT + MATERIAL means the real-text panel can work on this")
    print("  launch. Zeros mean it will use the bitmap font, by design, not by bug.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--peer", action="store_true")
    group.add_argument("--find", metavar="TEXT")
    group.add_argument("--dump", nargs=2, metavar=("START", "END"))
    parser.add_argument("--span", type=lambda v: int(v, 0), default=0x4000)
    args = parser.parse_args()

    pid, handle = open_process()
    base = module_base(handle)
    print("pid               : %d" % pid)
    if args.peer:
        show_peer(handle, base)
    elif args.find:
        show_find(handle, base, args.find, args.span)
    else:
        show_dump(handle, base, int(args.dump[0], 0), int(args.dump[1], 0))


if __name__ == "__main__":
    main()
