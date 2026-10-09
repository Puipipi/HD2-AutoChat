#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Import AutoChat into the HD2 Arsenal (mod manager) library and index.

Background -- why this exists at all:

The mod was originally installed by hand, by dropping the layer file straight into
the game's `data` directory. That works for playing, and is invisible to the
manager: the manager only knows about mods that live in its own library and appear
in its index. So AutoChat never showed up in the UI, and the UI is where a user
manages enable/disable/deploy. Two independent deployment mechanisms for one mod is
the actual bug; this makes the manager the single source of truth.

What it does:
  1. builds the library directory the manager expects, from the SAME verified ZIP
     the release publishes (never a rebuild, so what is imported is what was tested);
  2. adds one entry to `hd2a_data.json` under the default profile;
  3. refuses to touch anything while the manager is running, because the manager
     holds the index in memory and would write its copy back over these edits --
     the change would vanish silently and look like the mod was never installed.

Run:
    python -B work/standalone/import_to_manager.py --check
    python -B work/standalone/import_to_manager.py --import
    python -B work/standalone/import_to_manager.py --remove
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
DIST = os.path.join(REPO_ROOT, "dist")
LOCALAPPDATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~"))
ARSENAL = os.path.join(LOCALAPPDATA, "hd2arsenal")
LIBRARY = os.path.join(ARSENAL, "mods")
INDEX = os.path.join(ARSENAL, "hd2a_data.json")
PROFILE = "default"

LABEL = "AutoChat"
GUID = "a1000000-0000-4000-8000-000000000022"
# The manager names library directories <name>_<source><id>; _MANUAL is the suffix
# it uses for a mod the user added by hand, which is exactly what this is.
LIB_DIR_NAME = "AutoChat_MANUAL"


def manager_running():
    """True when HD2Arsenal is running. Its index must not be edited while it is.

    The comparison is CASE-INSENSITIVE on purpose. tasklist prints the image name as
    it was launched -- `HD2Arsenal.exe` -- and Python's `in` on strings is
    case-sensitive, so an earlier version of this check searched for the lowercase
    spelling, found nothing, and cheerfully reported "not running" while the manager
    was very much open. That is the one failure this guard exists to prevent, so the
    check must not depend on how Windows happens to capitalise the name.
    """
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq HD2Arsenal.exe"],
                             capture_output=True, text=True, check=False).stdout
    except OSError:
        return False
    lowered = out.lower()
    if "hd2arsenal.exe" not in lowered:
        return False
    # tasklist echoes the filter line even when nothing matches, so a bare substring
    # test would always say "running". A real match has a PID on the same line.
    for line in out.splitlines():
        if "hd2arsenal.exe" in line.lower():
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                return True
    return False


def newest_zip():
    if not os.path.isdir(DIST):
        sys.exit("no dist/ directory; run build_mod.py first")
    zips = [os.path.join(DIST, f) for f in os.listdir(DIST)
            if re.match(r"AutoChat-[0-9].*\.zip$", f)]
    if not zips:
        sys.exit("no AutoChat-*.zip in %s" % DIST)
    return max(zips, key=os.path.getmtime)


def load_index():
    if not os.path.exists(INDEX):
        sys.exit("manager index not found: %s" % INDEX)
    with io.open(INDEX, encoding="utf-8") as handle:
        return json.load(handle)


def find_entry(data):
    mods = data.get("modsList", {}).get(PROFILE, {}).get("mods", [])
    for index, entry in enumerate(mods):
        if entry.get("uuid") == GUID or entry.get("label") == LABEL:
            return index, entry
    return None, None


def build_library(zip_path, target_dir):
    """Lay the ZIP out the way the manager's library expects."""
    if os.path.isdir(target_dir):
        shutil.rmtree(target_dir)
    os.makedirs(target_dir)
    with zipfile.ZipFile(zip_path) as archive:
        for name in archive.namelist():
            if name.endswith("/"):
                continue
            # The manager stores the layer under Addon/, which is how the ZIP is
            # already laid out, so the paths carry over unchanged.
            destination = os.path.join(target_dir, name.replace("/", os.sep))
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            with archive.open(name) as source, open(destination, "wb") as out:
                shutil.copyfileobj(source, out)
    return target_dir


def content_hash(target_dir):
    """A stable hash of the library contents, for the manager's contentHash field."""
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(target_dir):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            digest.update(os.path.relpath(path, target_dir).replace(os.sep, "/").encode())
            with open(path, "rb") as handle:
                digest.update(handle.read())
    return digest.hexdigest()


def check(args):
    data = load_index()
    index, entry = find_entry(data)
    print("manager running : %s" % manager_running())
    print("index           : %s" % INDEX)
    print("library dir     : %s" % os.path.join(LIBRARY, LIB_DIR_NAME))
    print("library exists  : %s" % os.path.isdir(os.path.join(LIBRARY, LIB_DIR_NAME)))
    print("indexed         : %s" % ("yes (position %d)" % index if entry else "NO"))
    if entry:
        for key in ("label", "enabled", "deployed", "path"):
            print("  %-10s: %s" % (key, entry.get(key)))
    print("profiles        : %s" % list(data.get("modsList", {}).keys()))
    return 0


def do_import(args):
    if manager_running():
        sys.exit("REFUSING: HD2Arsenal.exe is running. It holds the index in memory "
                 "and will write its copy back over these edits, so the import would "
                 "silently vanish. Close the manager and run this again.")
    zip_path = os.path.abspath(args.zip or newest_zip())
    target = os.path.join(LIBRARY, LIB_DIR_NAME)
    print("artifact : %s (%d bytes)" % (os.path.basename(zip_path),
                                        os.path.getsize(zip_path)))
    build_library(zip_path, target)
    print("library  : %s" % target)
    for root, dirs, files in os.walk(target):
        for name in sorted(files):
            path = os.path.join(root, name)
            print("   %-42s %8d" % (os.path.relpath(path, target), os.path.getsize(path)))

    data = load_index()
    profile = data.setdefault("modsList", {}).setdefault(PROFILE, {})
    profile.setdefault("label", "Default Profile")
    mods = profile.setdefault("mods", [])
    index, entry = find_entry(data)

    with zipfile.ZipFile(zip_path) as archive:
        manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
    label = manifest.get("Name") or LABEL

    new_entry = {
        "uuid": GUID,
        "path": target,
        "label": label,
        "description": "Send squad chat without opening the chat box, plus an "
                       "in-game panel on K.",
        "iconPath": None,
        "tags": ["misc"],
        "patchFileNames": [],
        "nexusData": None,
        "options": [],
        "contentHash": content_hash(target),
        "addedAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "previousVersions": [],
        "new": True,
        "enabled": True,
        # NOT deployed by this script. Two mechanisms writing game layers is the
        # bug being fixed, so the manager is left to place the layer itself; the
        # hand-placed layer is removed separately with deploy.py --rollback.
        "deployed": False,
        "changed": False,
        "copiedFiles": [],
        "renamedFiles": [],
    }

    if entry is None:
        mods.append(new_entry)
        print("index    : added %s" % label)
    else:
        new_entry["addedAt"] = entry.get("addedAt", new_entry["addedAt"])
        mods[index] = new_entry
        print("index    : updated existing entry for %s" % label)

    backup = INDEX + ".dsh-backup"
    shutil.copyfile(INDEX, backup)
    with io.open(INDEX, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
    print("backup   : %s" % backup)
    print()
    print("DONE. Open the manager: AutoChat appears in the list. Enable it and deploy")
    print("from the UI so the manager owns the layer.")
    return 0


def do_remove(args):
    if manager_running():
        sys.exit("REFUSING: HD2Arsenal.exe is running (see --import for why).")
    target = os.path.join(LIBRARY, LIB_DIR_NAME)
    data = load_index()
    index, entry = find_entry(data)
    if entry is not None:
        mods = data["modsList"][PROFILE]["mods"]
        removed = mods.pop(index)
        backup = INDEX + ".dsh-backup"
        shutil.copyfile(INDEX, backup)
        with io.open(INDEX, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
        print("index    : removed %s (backup %s)" % (removed.get("label"), backup))
    else:
        print("index    : no AutoChat entry to remove")
    if os.path.isdir(target):
        shutil.rmtree(target)
        print("library  : removed %s" % target)
    else:
        print("library  : not present")
    return 0


def do_library_only(args):
    """Refresh the library directory WITHOUT touching the manager's index.

    The library is just files on disk, so this is safe while the manager runs: nothing
    reads them until the manager next loads. The INDEX is the part that must not be
    edited underneath a running manager, because it holds that file in memory and writes
    its own copy back over any edit.

    Split out because of what actually happens: the manager is nearly always open, so
    "close it and run --import" kept not happening and the library sat at an old version.
    This gets the safe half done immediately.
    """
    zip_path = os.path.abspath(args.zip or newest_zip())
    target = os.path.join(LIBRARY, LIB_DIR_NAME)
    print("artifact : %s (%d bytes)" % (os.path.basename(zip_path),
                                        os.path.getsize(zip_path)))
    build_library(zip_path, target)
    print("library  : %s" % target)
    for root, dirs, files in os.walk(target):
        for name in sorted(files):
            path = os.path.join(root, name)
            print("   %-42s %8d" % (os.path.relpath(path, target), os.path.getsize(path)))
    data = load_index()
    index, entry = find_entry(data)
    print()
    if entry is None:
        print("index    : NOT indexed yet -- run --import with the manager CLOSED")
    else:
        print("index    : indexed at position %d" % index)
        print("           contentHash %s"
              % ("matches the refreshed library" if entry.get("contentHash") == content_hash(target)
                 else "is STALE -- run --import with the manager CLOSED"))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="report state, change nothing")
    group.add_argument("--import", dest="do_import", action="store_true",
                       help="build the library and index it (manager must be closed)")
    group.add_argument("--library-only", dest="library_only", action="store_true",
                       help="refresh library files only; safe while the manager runs")
    group.add_argument("--remove", action="store_true", help="undo the import")
    parser.add_argument("--zip", default=None, help="override the artifact")
    args = parser.parse_args()
    if args.check:
        return check(args)
    if args.library_only:
        return do_library_only(args)
    if args.do_import:
        return do_import(args)
    return do_remove(args)


if __name__ == "__main__":
    raise SystemExit(main())
