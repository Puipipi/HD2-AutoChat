#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Publish a GitHub release for AutoChat with the importable addon ZIP attached.

Why a script instead of `gh`: `gh` is not installed on this machine, and doing
multipart uploads through PowerShell's Invoke-RestMethod is painful and fragile.
This uses only the standard library.

The token comes from git's own credential store (the same one `git push` uses), so
there is no second place to keep a secret.

    python -B work/standalone/release.py --tag v0.2.8-beta.1 --prerelease
    python -B work/standalone/release.py --tag v0.3.0 --notes-file notes.md

The ZIP is taken from work/standalone/dist -- the SAME artifact the build gates
produced, never a rebuilt one, so what is published is exactly what was validated.
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
DIST = os.path.join(HERE, "dist")
OWNER, NAME = "Puipipi", "HD2-AutoChat"
API = "https://api.github.com"


def git(*args):
    return subprocess.run(["git", "-C", REPO_ROOT] + list(args),
                          capture_output=True, text=True, check=False).stdout.strip()


def token_from_git():
    """Read the same credential `git push` uses, so secrets live in one place."""
    for helper in ("store",):
        try:
            out = subprocess.run(
                ["git", "credential", "fill"],
                input="protocol=https\nhost=github.com\n\n",
                capture_output=True, text=True, check=False).stdout
        except OSError as exc:
            sys.exit("could not run git credential: %s" % exc)
        for line in out.splitlines():
            if line.startswith("password="):
                return line.split("=", 1)[1].strip()
    sys.exit("no GitHub token found in git's credential store. Run `git push` once "
             "so the credential helper populates it, or set one up.")


def request(url, token, method="GET", payload=None, raw=None, content_type=None):
    data = None
    headers = {
        "Authorization": "token %s" % token,
        "User-Agent": "auto-chat-release",
        "Accept": "application/vnd.github+json",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif raw is not None:
        data = raw
        if content_type:
            headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        return exc.code, {"error": body}


def newest_zip():
    if not os.path.isdir(DIST):
        sys.exit("no dist/ directory; run build_mod.py first")
    zips = [os.path.join(DIST, f) for f in os.listdir(DIST)
            if re.match(r"AutoChat-.*\.zip$", f)]
    if not zips:
        sys.exit("no AutoChat-*.zip in %s; run build_mod.py first" % DIST)
    return max(zips, key=os.path.getmtime)


def version_from(zip_path):
    m = re.search(r"AutoChat-(.+)\.zip$", os.path.basename(zip_path))
    return m.group(1) if m else None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="e.g. v0.2.8-beta.1")
    parser.add_argument("--name", default=None, help="release title")
    parser.add_argument("--notes-file", default=None)
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("--draft", action="store_true")
    parser.add_argument("--zip", default=None, help="override the artifact")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    zip_path = args.zip or newest_zip()
    zip_path = os.path.abspath(zip_path)
    version = version_from(zip_path)
    if version and args.tag.lstrip("v").split("-")[0] != version.split("-")[0]:
        print("NOTE: tag %s does not match artifact version %s" % (args.tag, version))

    body = "AutoChat %s" % version
    if args.notes_file:
        with io.open(args.notes_file, encoding="utf-8") as handle:
            body = handle.read()
    else:
        body = ("AutoChat %s\n\n"
                "Helldivers 2 Bingus/MDL addon: sends a squad chat line by calling the\n"
                "game's own chat sender, so the chat box never opens and the keyboard and\n"
                "mouse are never taken. Verified in a real two-player session: the other\n"
                "player saw the messages, host-sent and client-sent.\n\n"
                "Install: import the ZIP below with the mod manager, enable AutoChat and\n"
                "Bingus Shared Loader, then deploy.\n\n"
                "See README.md for the verified / unverified split. This is a BETA: the\n"
                "mod is under active development.\n"
                % version)

    print("repo      : %s/%s" % (OWNER, NAME))
    print("tag       : %s" % args.tag)
    print("artifact  : %s (%d bytes)" % (os.path.basename(zip_path), os.path.getsize(zip_path)))
    print("prerelease: %s   draft: %s" % (args.prerelease, args.draft))
    print()

    if args.dry_run:
        print("--- release body ---")
        print(body)
        print("(dry run: nothing sent)")
        return 0

    token = token_from_git()

    # The tag must exist on the remote, or the release API will refuse / mis-tag.
    head = git("rev-parse", "HEAD")
    local_tag = git("rev-parse", "-q", "--verify", "refs/tags/%s" % args.tag)
    if not local_tag:
        print("creating tag %s at %s" % (args.tag, head[:8]))
        subprocess.run(["git", "-C", REPO_ROOT, "tag", "-a", args.tag, "-m",
                        "AutoChat %s" % version], check=True)
    print("pushing tag ...")
    subprocess.run(["git", "-C", REPO_ROOT, "push", "origin", args.tag], check=False)

    payload = {
        "tag_name": args.tag,
        "name": args.name or ("AutoChat %s (beta)" % version if args.prerelease
                              else "AutoChat %s" % version),
        "body": body,
        "draft": args.draft,
        "prerelease": args.prerelease,
    }
    status, resp = request("%s/repos/%s/%s/releases" % (API, OWNER, NAME), token,
                           method="POST", payload=payload)
    if status not in (200, 201):
        # An existing release for this tag is fine to reuse.
        if status == 422:
            print("release for %s already exists; looking it up" % args.tag)
            status, resp = request(
                "%s/repos/%s/%s/releases/tags/%s" % (API, OWNER, NAME, args.tag), token)
        if status not in (200, 201):
            sys.exit("release create failed (%s): %s" % (status, resp.get("error")))
    print("release  : %s" % resp.get("html_url"))

    upload = resp.get("upload_url", "").split("{")[0]
    if not upload:
        sys.exit("no upload_url in the response")
    with open(zip_path, "rb") as handle:
        blob = handle.read()
    status, up = request("%s?name=%s" % (upload, os.path.basename(zip_path)), token,
                         method="POST", raw=blob, content_type="application/zip")
    if status not in (200, 201):
        sys.exit("asset upload failed (%s): %s" % (status, up.get("error")))
    print("asset    : %s (%d bytes)" % (up.get("name"), up.get("size", 0)))
    print()
    print("DONE: %s" % resp.get("html_url"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
