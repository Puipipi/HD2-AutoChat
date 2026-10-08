# -*- coding: utf-8 -*-
"""Build the AutoChat release zip, with the gates that prevent a bad release.

This is `hd2-addon-build/scripts/build_mod.py` with the CONFIG block filled in
for this mod. Only CONFIG is changed; the five gates are the upstream ones:

  1. the source compiles under **LuaJIT**, not just Lua 5.1 -- LuaJIT's
     65535-instruction-per-function cap makes the loader SILENTLY SKIP an
     oversized mod while a plain-Lua compile says "OK";
  2. no **user32** symbol is declared (LuaJIT's C namespace is process-global and
     `ffi.cdef` keeps the FIRST declaration, so re-declaring `GetCursorPos`
     disables every mod that declared it first);
  3. every C symbol actually CALLED is declared
     (`missing declaration for symbol 'X'` is a hard error at the call site);
  4. the in-game README block exists, and README.txt is extracted FROM the
     source so the guide cannot drift from the code;
  5. no script-like file inside the published archive (mod sites quarantine
     archives containing .bat/.ps1/.exe).

Usage:
    python build_mod.py --validate-only        # gates only, no packaging
    python build_mod.py                        # build dist/<Name>-<version>.zip

Requires: python3 + lupa  (`python -m pip install lupa`)
"""
import argparse
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path

import lupa.luajit21 as luajit

# ----------------------------------------------------------------- CONFIG ----
W = str(Path(__file__).resolve().parent)

MOD_SOURCE = os.path.join(W, "..", "..", "src", "auto_chat.lua")
RESOURCE = "mods/codex/auto_chat"                 # mods/<author>/<entry>, underscore only
GUID = "a1000000-0000-4000-8000-000000000022"     # reused across every release
DISPLAY_NAME = "AutoChat"
ICON = None                                       # no icon shipped; a manifest pointing
                                                  # at a missing IconPath shows blank
README_MARKER = "[===[AutoChat"
VENDOR = os.path.join(W, "vendor", "bingus")
OUTPUT_DIR = None                                 # None = ./dist next to this script

USER32 = {"GetCursorPos", "GetClientRect", "ScreenToClient", "GetForegroundWindow",
          "GetAsyncKeyState", "GetWindowThreadProcessId", "GetCurrentProcessId"}
# ------------------------------------------------------------------------------

default_out = Path(OUTPUT_DIR) if OUTPUT_DIR else Path(W) / "dist"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-dir", type=Path, default=default_out)
parser.add_argument("--validate-only", action="store_true",
                    help="run the gates without packaging")
args = parser.parse_args()
OUT = str(args.output_dir.resolve())
Path(OUT).mkdir(parents=True, exist_ok=True)

src = io.open(MOD_SOURCE, encoding="utf-8").read()
input_fragment = Path(MOD_SOURCE).with_name('panel_input.lua').read_text(encoding='utf-8').rstrip()
if ('-- BEGIN ARMORY INPUT\n' + input_fragment + '\n-- END ARMORY INPUT') not in src:
    raise SystemExit('FAIL embedded panel input differs from independently tested source fragment')
automation_fragment = Path(MOD_SOURCE).with_name('chat_automation.lua').read_text(encoding='utf-8').rstrip()
if ('-- BEGIN CHAT AUTOMATION\n' + automation_fragment + '\n-- END CHAT AUTOMATION') not in src:
    raise SystemExit('FAIL embedded chat automation differs from independently tested source fragment')
ping_fragment = Path(MOD_SOURCE).with_name('ping_events.lua').read_text(encoding='utf-8').rstrip()
if ('-- BEGIN NATIVE PING EVENTS\n' + ping_fragment + '\n-- END NATIVE PING EVENTS') not in src:
    raise SystemExit('FAIL embedded native ping adapter differs from independently tested source fragment')
for fragment, marker in [('peer_identity', 'PEER IDENTITY'), ('plugin_registry', 'PLUGIN REGISTRY'),
                         ('marker_localization', 'MARKER LOCALIZATION')]:
    content = Path(MOD_SOURCE).with_name(fragment + '.lua').read_text(encoding='utf-8').rstrip()
    if ('-- BEGIN ' + marker + '\n' + content + '\n-- END ' + marker) not in src:
        raise SystemExit('FAIL embedded ' + fragment + ' differs from independently tested source fragment')
ver = re.search(r"version\s*=\s*['\"]([\d.]+)['\"]", src).group(1)

# --- gate 1: compiles under LuaJIT (65535 instructions per function) ---------
try:
    luajit.LuaRuntime().compile(src)
except Exception as exc:
    raise SystemExit("FAIL LuaJIT compile: %s" % exc)
print("LuaJIT compile: OK (%d bytes)" % len(src))

# --- gates 2, 3 and the read-only gate live in gates.py ---------------------
# They are a separate module so that tests/test_build_gates.py can prove each one
# rejects a violating source. Inline gates cannot be shown to fail, and three of
# these were measured incapable of failing before they were moved here.
sys.path.insert(0, W)
import gates                                                    # noqa: E402

_declared = gates.declared_symbols(src)
_called = gates.called_symbols(src)
print("ffi.cdef symbols: %s" % (", ".join(sorted(_declared)) or "none"))
print("called symbols: %s" % (", ".join(sorted(_called)) or "none"))

_gate_failures = []
for _check in (gates.check_user32, gates.check_called_are_declared,
               gates.check_no_memory_writes, gates.check_detection_is_live):
    _gate_failures.extend(_check(src))
if _gate_failures:
    raise SystemExit("FAIL refusing to build:\n  - " + "\n  - ".join(_gate_failures))
print("gates: approved shared user32 prototypes, every call declared, no memory writes, detection live")

# --- gate 4: the in-game README block exists --------------------------------
r0 = src.find(README_MARKER)
r1 = src.find("]===]", r0) if r0 > 0 else -1
readme_txt = src[r0 + 5:r1] if r0 > 0 and r1 > 0 else ""
if not readme_txt:
    raise SystemExit("FAIL README block missing from the source: expected %r ... ]===]"
                     % README_MARKER)
print("README block: %d chars (extracted from the source)" % len(readme_txt))

# --- gate 5: no script-like file inside the published archive ---------------
if args.validate_only:
    print("Source validation complete; no in-game claim.")
    raise SystemExit(0)

# --- packaging: the official addon envelope ---------------------------------
have_icon = bool(ICON) and os.path.exists(ICON)

sys.path.insert(0, VENDOR)
import build_addon as official                                  # noqa: E402

target = os.path.join(OUT, "%s-%s.zip" % (DISPLAY_NAME.replace(" ", "-"), ver))
official.build_addon(RESOURCE, src.encode("utf-8"), GUID, target, DISPLAY_NAME)

tmp = target + ".tmp"
with zipfile.ZipFile(target) as zin:
    SCRIPT_EXT = (".bat", ".cmd", ".ps1", ".vbs", ".js", ".exe", ".dll")
    offenders = [i.filename for i in zin.infolist()
                 if i.filename.lower().endswith(SCRIPT_EXT)]
    if offenders:
        os.remove(target)
        raise SystemExit(
            "FAIL refusing to publish: script-like file(s) in the archive: %s\n"
            "     Mod sites quarantine these." % ", ".join(offenders))
    print("archive contents: no script-like files")

    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            if info.filename == "manifest.json" and have_icon:
                m = json.loads(data)
                m["IconPath"] = os.path.basename(ICON)
                for opt in m.get("Options", []):
                    opt.setdefault("Image", os.path.basename(ICON))
                data = (json.dumps(m, indent=2) + "\n").encode()
            zout.writestr(info, data)
        if have_icon:
            zout.write(ICON, os.path.basename(ICON))
        zout.writestr("README.txt", readme_txt.replace("\n", "\r\n"))
os.replace(tmp, target)
print("built %s: %d bytes" % (os.path.basename(target), os.path.getsize(target)))
print("version: %s" % ver)
