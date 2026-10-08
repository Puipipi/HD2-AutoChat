#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compile-check a mod source against the LuaJIT limits that fail SILENTLY.

Why this exists:

Some LuaJIT limits do not fail loudly at run time -- the Bingus loader skips the whole
mod and there is no log line saying why. A mod that "installed fine" and does nothing,
with no log at all, is the symptom. The only way to catch it before shipping is to
compile the source and see whether the compiler refuses it.

WHAT THIS TOOL MEASURED, rather than assumed. The workspace failure catalog says
"65535 bytecode instructions per function". On the LuaJIT that lupa links here that
number does NOT bind: a synthetic function with 200,004 instructions compiled
successfully. What actually refused, reproducibly, was the CONSTANT limit:

    n=50000 constants  -> compiled, bc=99747
    n=70000 constants  -> "[string]:70003: main function has more than 65536 constants"

So the checked limit is 65536 constants per function, and the instruction figure is
recorded as "not binding on this build" instead of being asserted as if it were
measured. Both are compile-time failures, so a successful load is real evidence that
neither was tripped anywhere in the file -- which is the property that matters.

WHAT IT CANNOT DO: report per-function counts. LuaJIT exposes nested prototypes only
through `debug.getconstant`, which this build does not provide, and `string.dump` does
not recurse into children. An earlier version of this tool "walked prototypes" and
reported exactly ONE function for a 1280-line file -- a measurement that looked like a
result and was meaningless. It now reports what it can prove and says so.

    python -B work/standalone/tools/bytecode_budget.py src/auto_chat.lua

Exit code is non-zero when the source does not compile, or when the limit self-check
fails to reproduce -- the latter means the tool has stopped being able to detect the
failure it exists for.
"""
import argparse
import os
import sys

try:
    import lupa.luajit21 as luajit
except ImportError:  # pragma: no cover
    sys.exit("lupa is required: python -m pip install lupa")

# Verified on this build by the self-check below, not copied from the catalog.
CONST_LIMIT = 65536
INSTRUCTION_LIMIT = 65535   # documented; measured NOT to bind on this build

PROBE = r"""
return function(path)
    local out = {}

    local chunk, err = loadfile(path)
    out.loaded = chunk ~= nil
    out.error = tostring(err)
    if chunk then
        local ok, util = pcall(require, 'jit.util')
        if ok and util.funcinfo then
            local info = util.funcinfo(chunk)
            out.main_bytecodes = info.bytecodes or 0
            out.main_slots = info.stackslots or 0
            out.main_constants = info.gconsts or 0
        end
    end

    -- Self-check 1: the CONSTANT limit must reproduce, or this tool cannot detect the
    -- one failure that actually occurs here.
    local function build(n, with_constants)
        local body
        if with_constants then
            local parts = {}
            for i = 1, n do parts[#parts + 1] = 'x = x + ' .. i end
            body = table.concat(parts, '\n')
        else
            body = string.rep('x = x + y\n', n)
        end
        return 'local x, y = 0, 1\n' .. body .. '\nreturn x\n'
    end

    local f_const, e_const = loadstring(build(70000, true))
    out.const_reproduced = f_const == nil
    out.const_error = tostring(e_const)

    local f_small, e_small = loadstring(build(50000, true))
    out.under_limit_ok = f_small ~= nil
    out.under_limit_error = tostring(e_small)

    -- Self-check 2: how many INSTRUCTIONS this build actually tolerates. Recorded so
    -- the documented 65535 is not asserted as if it had been measured.
    local f_big = loadstring(build(200000, false))
    if f_big then
        local ok, util = pcall(require, 'jit.util')
        out.instructions_tolerated = ok and (util.funcinfo(f_big).bytecodes or 0) or -1
    else
        out.instructions_tolerated = 0
    end

    return out
end
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source")
    args = parser.parse_args()

    path = os.path.abspath(args.source)
    if not os.path.exists(path):
        sys.exit("no such file: %s" % path)

    lua = luajit.LuaRuntime(unpack_returned_tuples=True)
    result = lua.execute(PROBE)(path)
    if result is None:
        sys.exit("probe returned nothing")

    def get(key, default=None):
        try:
            return result[key]
        except (KeyError, TypeError):
            return default

    print("source             : %s" % os.path.relpath(path))
    print("compiles           : %s" % get("loaded"))
    if not get("loaded"):
        print("compile error      : %s" % get("error"))
        print()
        print("FAIL: the loader would skip this mod silently. Fix the compile error.")
        return 1

    print("top-level chunk    : %s instructions, %s stack slots, %s constants"
          % (get("main_bytecodes"), get("main_slots"), get("main_constants")))
    print()

    ok = True
    if not get("const_reproduced"):
        print("FAIL: the %d-constant limit did not reproduce, so this tool can no "
              "longer detect the failure it exists for." % CONST_LIMIT)
        ok = False
    else:
        print("constant limit     : reproduced (%s)" % str(get("const_error"))[:66])
    if not get("under_limit_ok"):
        print("FAIL: a 50000-constant function, which should compile, was refused: %s"
              % get("under_limit_error"))
        ok = False
    else:
        print("below the limit    : a 50000-constant function compiles, as expected")

    tolerated = get("instructions_tolerated")
    if tolerated == 0:
        print("NOTE: this build refused a 200000-instruction function, so the "
              "instruction cap DOES bind here.")
    elif tolerated and tolerated > INSTRUCTION_LIMIT:
        print("instruction limit  : NOT binding on this build -- a synthetic function "
              "with %s instructions compiled, above the documented %d. The documented "
              "figure is recorded, not asserted." % (tolerated, INSTRUCTION_LIMIT))
    print()

    if not ok:
        return 1
    print("VERDICT: the file compiles, so neither the %d-constant cap nor the" % CONST_LIMIT)
    print("         documented instruction cap was tripped anywhere in it -- both are")
    print("         compile-time failures, and a failed compile is exactly what makes")
    print("         the loader skip a mod with no log line.")
    print()
    print("         Per-function counts are NOT available with this LuaJIT build")
    print("         (see the module docstring). The top-level figure above is the")
    print("         only exact number this tool can give.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
