# -*- coding: utf-8 -*-
"""Disassemble AutoChat's target functions out of an IN-MEMORY dump of game.dll.

Why a dump and not the installed file: the on-disk game.dll is packed. Its
section names are blanked, its entropy is ~7.9998, and code signatures present in
the running process are absent from the file. Scanning the installed file for
these bytes finds nothing and produces the false conclusion "the game updated".
So this reads a dump taken from the process (see melee-vehicle-rescue's
dump_range.py for how those are produced) and maps RVAs through the dumped PE
headers rather than assuming a fixed RVA-to-file-offset relationship.

    python inspect_code.py --dump <section0.bin> --headers <headers.bin> prog
    python inspect_code.py --dump ... --headers ... --rva 0x1097560 --count 60
    python inspect_code.py --dump ... --headers ... --find-callers 0x1097560

Purpose: the mod claims its send reaches other players. That claim comes from a
third-party comment. This tool exists to check it against the actual machine code
-- does the callee build an RPC with a broadcast destination, or is it a local
echo?
"""
import argparse
import os
import struct
import sys

import capstone

# The five signatures the mod gates on, and the two interesting ones.
PROGRAM = [
    ("chat send", 0x1097560),
    ("rpc send", 0xBDE430),
    ("chat box send", 0x186025D),
    ("chat message rpc", 0xBEB103),
    ("chat history", 0x1097A7C),
]

# The single u32 array argument the reference describes: {type, size, address}.
ARG_U64, ARG_U64_SIZE, ARGS_SIZE = 9, 8, 24
EVERY_PEER = -1


def load_sections(headers_path):
    with open(headers_path, "rb") as handle:
        raw = handle.read()
    if raw[:2] != b"MZ":
        raise SystemExit("%s is not a PE header dump" % headers_path)
    pe = struct.unpack_from("<I", raw, 0x3C)[0]
    if raw[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("no PE signature at 0x%X" % pe)
    count = struct.unpack_from("<H", raw, pe + 6)[0]
    opt = pe + 24
    opt_size = struct.unpack_from("<H", raw, pe + 20)[0]
    image_base = struct.unpack_from("<Q", raw, opt + 24)[0]
    table = opt + opt_size
    sections = []
    for i in range(count):
        off = table + i * 40
        name = raw[off:off + 8].rstrip(b"\x00").decode("latin1") or "(unnamed)"
        vsize, vaddr, rsize, rawptr = struct.unpack_from("<IIII", raw, off + 8)
        sections.append({"name": name, "vsize": vsize, "va": vaddr,
                         "rawsize": rsize, "rawptr": rawptr, "index": i})
    return image_base, sections


def map_rva(rva, sections, dumped_index):
    """RVA -> offset inside the dumped section file, or None.

    The dump holds ONE section's virtual contents, so a match requires the RVA to
    fall inside that section AND the dumped file to be the section named.
    """
    for sec in sections:
        if sec["index"] != dumped_index:
            continue
        if sec["va"] <= rva < sec["va"] + sec["vsize"]:
            return rva - sec["va"]
    return None


def disassemble(blob, offset, count, md):
    out = []
    code = blob[offset:offset + 16 * count]
    for insn in md.disasm(code, 0):
        out.append(insn)
        if len(out) >= count:
            break
    return out


def describe(insn):
    text = "%08X  %-22s %s %s" % (insn.address, insn.bytes.hex().upper()[:20],
                                  insn.mnemonic, insn.op_str)
    if insn.mnemonic == "call" and insn.op_str.startswith("0x"):
        # For a call with a relative operand capstone already resolved it against
        # address 0, so report it as a delta the caller can add ImageBase to.
        text += "        ; relative call, target = insn_end + rel32"
    return text


def find_callers(blob, sections, dumped_index, target_rva, image_base, limit=40):
    """Scan the dumped section for `call rel32` instructions landing on target."""
    hits = []
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = False
    va = next(s["va"] for s in sections if s["index"] == dumped_index)
    for offset in range(0, len(blob) - 5):
        if blob[offset] != 0xE8:
            continue
        rel = struct.unpack_from("<i", blob, offset + 1)[0]
        insn_rva = va + offset
        destination = insn_rva + 5 + rel
        if destination == target_rva:
            hits.append(insn_rva)
            if len(hits) >= limit:
                break
    return hits


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True, help="in-memory section dump file")
    parser.add_argument("--headers", required=True, help="PE headers dumped from the process")
    parser.add_argument("--section", type=int, default=0, help="which section the dump holds")
    parser.add_argument("--rva", type=lambda v: int(v, 0), default=None)
    parser.add_argument("--count", type=int, default=40)
    parser.add_argument("--find-callers", type=lambda v: int(v, 0), default=None)
    parser.add_argument("--program", action="store_true", help="disassemble the mod's targets")
    args = parser.parse_args()

    image_base, sections = load_sections(args.headers)
    with open(args.dump, "rb") as handle:
        blob = handle.read()
    sec = next(s for s in sections if s["index"] == args.section)
    print("dump            : %s (%d bytes)" % (os.path.basename(args.dump), len(blob)))
    print("headers         : ImageBase 0x%X, %d sections" % (image_base, len(sections)))
    print("section %-8s: VA 0x%X VSize 0x%X  (dump covers 0x%X)"
          % (sec["index"], sec["va"], sec["vsize"], len(blob)))
    print()

    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)

    if args.program or args.rva is not None:
        targets = PROGRAM if args.program else [("target", args.rva)]
        for name, rva in targets:
            offset = map_rva(rva, sections, args.section)
            if offset is None or offset >= len(blob):
                print("== %s (0x%X): NOT in the dumped section" % (name, rva))
                continue
            print("== %s  game.dll+0x%X  (dump offset 0x%X)" % (name, rva, offset))
            for insn in disassemble(blob, offset, args.count, md):
                print("   " + describe(insn))
            print()

    if args.find_callers is not None:
        print("== callers of game.dll+0x%X ==" % args.find_callers)
        hits = find_callers(blob, sections, args.section, args.find_callers, image_base)
        if not hits:
            print("   none found in this section")
        for rva in hits:
            print("   call at game.dll+0x%X" % rva)


if __name__ == "__main__":
    main()
