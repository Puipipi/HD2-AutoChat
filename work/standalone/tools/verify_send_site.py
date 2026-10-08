# -*- coding: utf-8 -*-
"""Prove AutoChat uses the GAME'S OWN sender, not a lookalike.

The mod's central claim is "we call the same function the chat box calls, so a
message goes out exactly as if you had typed it." That is a claim about machine
code and it should be checkable, not asserted. This resolves the chat box's own
`call` instruction and compares its destination against the RVA AutoChat uses.

It needs an IN-MEMORY dump of game.dll (the installed file is packed: blanked
section names, ~7.9998 entropy, code signatures absent -- scanning it finds
nothing and produces the false conclusion "the game updated").

    python -B verify_send_site.py --dump <section0.bin> --headers <headers.bin>

Expected output on build 25480438:

    chat box calls : game.dll+0x1097560
    AutoChat calls : game.dll+0x1097560
    same function  : True

A mismatch means the mod is calling something other than the sender the chat box
uses, and the "everyone sees it" claim would be unsupported.
"""
import argparse
import os
import struct
import sys

import capstone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inspect_code as IC  # noqa: E402

# The chat box's call to the sender lives inside the code at this RVA; the call
# itself is the instruction at +0x15 (verified by disassembling it -- see the
# output of this tool for the surrounding sequence).
CHAT_BOX_SITE = 0x186025D
CHAT_BOX_CALL_OFFSET = 0x15
# What AutoChat resolves and calls, after its 32-byte signature check.
AUTOChat_SEND = 0x1097560
# The chat object is reached as context+0xC418 in the chat box's own setup.
CHAT_OBJECT_OFFSET = 0xC418
# The chat box loads the network context from a global; AutoChat reads the same
# one. Resolving this RIP-relative load is what ties the two together: it shows
# the chat box's `add rcx, 0xc418` is applied to EXACTLY the pointer AutoChat
# dereferences, rather than to some other object that merely looks similar.
CONTEXT_PTR_RVA = 0x347CEF0


def resolve_rip_relative(blob, sections, dumped_index, rva):
    """Resolve `mov reg, qword ptr [rip + disp32]` at `rva` to an absolute RVA.

    The displacement is relative to the END of the instruction (7 bytes here), not
    to its start -- getting that wrong yields a plausible-looking address that is
    off by seven, which is exactly the kind of error that would quietly invalidate
    a "these are the same" claim.
    """
    offset = IC.map_rva(rva, sections, dumped_index)
    if offset is None:
        raise SystemExit("0x%X is not in the dumped section" % rva)
    # 48 8B 0D <disp32>
    if blob[offset] != 0x48 or blob[offset + 1] != 0x8B or blob[offset + 2] != 0x0D:
        raise SystemExit("expected `mov rcx, [rip+disp32]` at 0x%X, found %s"
                         % (rva, blob[offset:offset + 3].hex().upper()))
    disp = struct.unpack_from("<i", blob, offset + 3)[0]
    return rva + 7 + disp


def find_section_holding(rva, sections, dumped_index):
    sec = sections[dumped_index]
    if sec["va"] <= rva < sec["va"] + sec["vsize"]:
        return True
    return False


def rel32_call_target(blob, sections, dumped_index, rva):
    offset = IC.map_rva(rva, sections, dumped_index)
    if offset is None:
        raise SystemExit("0x%X is not in the dumped section" % rva)
    if blob[offset] != 0xE8:
        raise SystemExit("expected a rel32 call at 0x%X, found 0x%02X"
                         % (rva, blob[offset]))
    rel = struct.unpack_from("<i", blob, offset + 1)[0]
    return rva + 5 + rel


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True)
    parser.add_argument("--headers", required=True)
    parser.add_argument("--section", type=int, default=0)
    args = parser.parse_args()

    image_base, sections = IC.load_sections(args.headers)
    with open(args.dump, "rb") as handle:
        blob = handle.read()

    sec = sections[args.section]
    print("dump     : %s (%d bytes)" % (os.path.basename(args.dump), len(blob)))
    print("section  : VA 0x%X VSize 0x%X" % (sec["va"], sec["vsize"]))
    print()

    call_rva = CHAT_BOX_SITE + CHAT_BOX_CALL_OFFSET
    target = rel32_call_target(blob, sections, args.section, call_rva)
    context_global = resolve_rip_relative(blob, sections, args.section, CHAT_BOX_SITE)
    same_sender = target == AUTOChat_SEND
    same_context = context_global == CONTEXT_PTR_RVA

    print("chat box calls        : game.dll+0x%X" % target)
    print("AutoChat calls        : game.dll+0x%X" % AUTOChat_SEND)
    print("same function         : %s" % same_sender)
    print()
    print("chat box context load : game.dll+0x%X" % context_global)
    print("AutoChat context ptr  : game.dll+0x%X" % CONTEXT_PTR_RVA)
    print("same context global   : %s" % same_context)
    print()

    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    print("the chat box's own argument setup, immediately before that call:")
    at = CHAT_BOX_SITE
    for insn in IC.disassemble(blob, IC.map_rva(CHAT_BOX_SITE, sections, args.section),
                               6, md):
        note = ""
        if insn.mnemonic == "mov" and at == CHAT_BOX_SITE:
            note = "   <- the network context global AutoChat reads too"
        elif insn.mnemonic == "add" and "0xc418" in insn.op_str:
            note = "   <- the chat object, at context+0x%X" % CHAT_OBJECT_OFFSET
        elif insn.mnemonic == "call" and at == call_rva:
            note = ("   <- the sender AutoChat also calls" if same_sender
                    else "   <- NOT our target")
        print("   %-22s %s %s%s" % (insn.bytes.hex().upper()[:20],
                                    insn.mnemonic, insn.op_str, note))
        at += insn.size
    print()

    if same_sender and same_context:
        print("PASS: the chat box builds the call as")
        print("          rcx = [network context global] + 0x%X" % CHAT_OBJECT_OFFSET)
        print("          r8  = the typed-text buffer")
        print("          call game.dll+0x%X" % AUTOChat_SEND)
        print("      and AutoChat supplies the same context global, the same offset")
        print("      and the same function -- so the message leaves through the path")
        print("      a typed message takes, not a local-only display path.")
        print()
        print("      This does NOT establish that other clients receive it. That")
        print("      needs a second player; see tools/watch_for_squad.py.")
        return 0
    print("FAIL: AutoChat's call is not identical to the chat box's.")
    if not same_sender:
        print("      sender differs: 0x%X vs 0x%X" % (target, AUTOChat_SEND))
    if not same_context:
        print("      context global differs: 0x%X vs 0x%X"
              % (context_global, CONTEXT_PTR_RVA))
    print("      Until both match, the 'everyone sees it' claim is unsupported.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
