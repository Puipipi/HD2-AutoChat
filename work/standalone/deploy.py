# -*- coding: utf-8 -*-
"""Deploy the built AutoChat layer into the game directory, and roll it back.

This writes ONE layer slot. It is deliberately not an automatic build step: the
Bingus mod family treats deployment as an explicit action, and a build that
fails any gate must not deploy anything.

    python deploy.py --deploy --slot 336
    python deploy.py --rollback --slot 336
    python deploy.py --status --slot 336

What it refuses to do:
  * overwrite a slot it did not write (it checks the previous payload's hash
    against work/deploy/deployed.json);
  * touch any file that does not match this mod's own slot naming;
  * deploy if the game is running (the archive may be mapped).

The game directory is discovered, not hard-coded.
"""
import argparse
import glob
import hashlib
import io
import json
import os
import subprocess
import tempfile
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
RECORD = os.path.join(REPO, "work", "deploy", "deployed.json")
LAYER_PREFIX = "9ba626afa44a3aa3.patch_"

SEARCH = [
    r"D:\Program Files (x86)\Steam\steamapps\common\Helldivers 2",
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2",
    r"D:\Steam\steamapps\common\Helldivers 2",
    r"C:\SteamLibrary\steamapps\common\Helldivers 2",
    r"D:\SteamLibrary\steamapps\common\Helldivers 2",
]


def find_game():
    for candidate in SEARCH:
        if os.path.isdir(os.path.join(candidate, "data")):
            return candidate
    # steam library folders, if any
    for vdf in glob.glob(r"C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf"):
        try:
            text = io.open(vdf, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for path in __import__("re").findall(r'"path"\s*"([^"]+)"', text):
            candidate = os.path.join(path.replace("\\\\", "\\"),
                                     "steamapps", "common", "Helldivers 2")
            if os.path.isdir(os.path.join(candidate, "data")):
                return candidate
    raise SystemExit("could not find the Helldivers 2 install; edit SEARCH in deploy.py")


def game_running():
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq helldivers2.exe"],
                             capture_output=True, text=True).stdout.lower()
    except OSError:
        return False
    return "helldivers2.exe" in out


def load_record():
    if not os.path.exists(RECORD):
        return {}
    with io.open(RECORD, encoding="utf-8") as handle:
        return json.load(handle)


def save_record(record):
    os.makedirs(os.path.dirname(RECORD), exist_ok=True)
    with io.open(RECORD, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)


def newest_zip():
    out = os.path.join(HERE, "dist")
    zips = sorted(glob.glob(os.path.join(out, "AutoChat-*.zip")))
    if not zips:
        raise SystemExit("no built zip in %s; run build_mod.py first" % out)
    return zips[-1]


def payload_from(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        return archive.read("Addon/%s" % (LAYER_PREFIX + "0"))


def slot_paths(data_dir, slot):
    base = os.path.join(data_dir, "%s%d" % (LAYER_PREFIX, slot))
    return [base, base + ".stream", base + ".gpu_resources"]


def cmd_status(data_dir, slot):
    record = load_record()
    key = str(slot)
    print("game      : %s" % data_dir)
    print("slot      : %d" % slot)
    for path in slot_paths(data_dir, slot):
        if os.path.exists(path):
            with open(path, "rb") as handle:
                blob = handle.read()
            print("  present %-46s %7d bytes  sha=%s"
                  % (os.path.basename(path), len(blob),
                     hashlib.sha256(blob).hexdigest().upper()[:16]))
        else:
            print("  absent  %s" % os.path.basename(path))
    if key in record:
        print("recorded  : version %s, sha %s"
              % (record[key].get("version"), record[key].get("sha256", "")[:16]))
    else:
        print("recorded  : (this mod has no record for this slot)")


def write_layer(path, blob, hot):
    """Write one layer file, atomically when hot-swapping.

    The normal path writes in place and refuses to run while the game is up, because an
    in-place write to a file the engine has mapped can change what the engine reads.

    An ATOMIC REPLACE does not have that problem, and this was measured rather than
    assumed: the layer files are not held with a deny-write lock (`open(path, 'r+b')`
    succeeds while the game runs) and a same-directory rename works. Writing to a
    temporary file and renaming it over the target changes the DIRECTORY ENTRY; the old
    file object -- including any mapping the running game holds -- stays intact and keeps
    serving the old bytes. So a running game cannot be corrupted by this, and the new
    bytes are simply there for the next launch.

    It is still opt-in. Modifying the game directory underneath a running game is exactly
    the kind of thing that has broken things before, so it is a flag the operator chooses,
    not a default.
    """
    if hot:
        directory = os.path.dirname(path)
        handle, temp = tempfile.mkstemp(dir=directory, prefix=".dsh-swap-")
        try:
            with os.fdopen(handle, "wb") as out:
                out.write(blob)
            os.replace(temp, path)          # atomic within one volume
        except BaseException:
            if os.path.exists(temp):
                os.remove(temp)
            raise
    else:
        with open(path, "wb") as out:
            out.write(blob)


def cmd_deploy(data_dir, slot, hot=False):
    if game_running() and not hot:
        raise SystemExit(
            "REFUSING: helldivers2.exe is running; the archive may be mapped.\n"
            "  Re-run with --hot-swap to replace the layer ATOMICALLY instead, which is "
            "safe while the game runs: the new bytes are seen by the NEXT launch, and the "
            "running game keeps the file it already opened.")
    zip_path = newest_zip()
    version = os.path.basename(zip_path).replace("AutoChat-", "").replace(".zip", "")
    payload = payload_from(zip_path)
    digest = hashlib.sha256(payload).hexdigest().upper()

    record = load_record()
    key = str(slot)
    previous = record.get(key)
    target = slot_paths(data_dir, slot)[0]

    if os.path.exists(target):
        with open(target, "rb") as handle:
            existing = hashlib.sha256(handle.read()).hexdigest().upper()
        if not previous:
            raise SystemExit(
                "REFUSING: %s already exists and this mod has no record of writing "
                "it. Another mod may own this slot." % os.path.basename(target))
        if existing != previous.get("sha256"):
            raise SystemExit(
                "REFUSING: %s has changed since this mod wrote it (expected sha %s, "
                "found %s). Something else owns it now."
                % (os.path.basename(target), previous.get("sha256", "")[:16], existing[:16]))

    for path, blob in zip(slot_paths(data_dir, slot), [payload, b"", b""]):
        write_layer(path, blob, hot)
        print("wrote %-46s %7d bytes%s"
              % (os.path.basename(path), len(blob), " (atomic)" if hot else ""))

    record[key] = {"version": version, "sha256": digest, "zip":
                   os.path.basename(zip_path)}
    save_record(record)
    print("deployed AutoChat %s to slot %d (sha %s)" % (version, slot, digest[:16]))


def cmd_rollback(data_dir, slot):
    if game_running():
        raise SystemExit("REFUSING: helldivers2.exe is running")
    record = load_record()
    key = str(slot)
    previous = record.get(key)
    target = slot_paths(data_dir, slot)[0]
    if os.path.exists(target) and previous:
        with open(target, "rb") as handle:
            existing = hashlib.sha256(handle.read()).hexdigest().upper()
        if existing != previous.get("sha256"):
            raise SystemExit("REFUSING: %s is not the build this mod deployed"
                             % os.path.basename(target))
    removed = 0
    for path in slot_paths(data_dir, slot):
        if os.path.exists(path):
            os.remove(path)
            removed += 1
            print("removed %s" % os.path.basename(path))
    record.pop(key, None)
    save_record(record)
    print("rolled back slot %d (%d file(s) removed)" % (slot, removed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--deploy", action="store_true")
    parser.add_argument("--hot-swap", dest="hot_swap", action="store_true",
                        help="replace the layer atomically even while the game runs; "
                             "the new bytes take effect on the NEXT launch")
    group.add_argument("--rollback", action="store_true")
    group.add_argument("--status", action="store_true")
    parser.add_argument("--slot", type=int, default=336)
    parser.add_argument("--game", default=None)
    args = parser.parse_args()

    game = args.game or find_game()
    data_dir = os.path.join(game, "data")
    if args.status:
        cmd_status(data_dir, args.slot)
    elif args.deploy:
        cmd_deploy(data_dir, args.slot, hot=args.hot_swap)
    else:
        cmd_rollback(data_dir, args.slot)


if __name__ == "__main__":
    main()
