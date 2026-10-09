#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Publish a GitHub release for AutoChat with explicitly selected assets.

The credential is retrieved from Git Credential Manager for the selected account;
it is never accepted on the command line or written to output. Build artifacts are
read from dist/ and uploaded as-is.
"""
import argparse
import hashlib
import io
import json
import mimetypes
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
DIST = os.path.join(REPO_ROOT, "dist")
OWNER, NAME = "Puipipi", "HD2-AutoChat"
API = "https://api.github.com"


class ReleaseError(RuntimeError):
    pass


def git_run(args, check=False):
    return subprocess.run(["git", "-C", REPO_ROOT] + list(args),
                          capture_output=True, text=True, check=check)


def git_output(args):
    try:
        return git_run(args, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        raise ReleaseError("git check failed; release creation aborted")


def token_from_git(username):
    """Retrieve only the selected GCM account's OAuth credential in memory."""
    if not isinstance(username, str) or not re.match(r"^[A-Za-z0-9-]{1,39}$", username):
        raise ReleaseError("a valid --credential-user is required")
    command = ["git", "-C", REPO_ROOT,
               "-c", "credential.helper=",
               "-c", "credential.helper=manager",
               "-c", "credential.username=" + username,
               "credential", "fill"]
    try:
        result = subprocess.run(command,
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True, text=True, check=False)
    except OSError:
        raise ReleaseError("Git Credential Manager could not be started")
    if result.returncode != 0:
        raise ReleaseError("Git Credential Manager lookup failed")
    for line in result.stdout.splitlines():
        if line.startswith("password="):
            token = line.split("=", 1)[1].strip()
            if token:
                return token
    raise ReleaseError("no GCM OAuth credential was returned for the selected account")


def request(url, token, method="GET", payload=None, raw=None, content_type=None):
    data = None
    headers = {
        "Authorization": "token " + token,
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
        raise ReleaseError("no dist/ directory; run build_mod.py first")
    zips = [os.path.join(DIST, f) for f in os.listdir(DIST)
            if re.match(r"AutoChat-[0-9].*\.zip$", f)]
    if not zips:
        raise ReleaseError("no AutoChat-*.zip in dist/; run build_mod.py first")
    return max(zips, key=os.path.getmtime)


def version_from(zip_path):
    match = re.search(r"AutoChat-(.+)\.zip$", os.path.basename(zip_path))
    return match.group(1) if match else None


def collect_assets(zip_path, extra_paths):
    """Default to the main ZIP; append every explicitly requested --asset."""
    paths = [zip_path] + list(extra_paths or [])
    assets, names = [], set()
    for path in paths:
        full_path = os.path.abspath(path)
        if not os.path.isfile(full_path):
            raise ReleaseError("release asset is missing: " + os.path.basename(full_path))
        name = os.path.basename(full_path)
        folded_name = name.casefold()
        if folded_name in names:
            raise ReleaseError("duplicate release asset name: " + name)
        names.add(folded_name)
        content_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
        assets.append({"path": full_path, "name": name,
                       "size": os.path.getsize(full_path),
                       "sha256": file_sha256(full_path),
                       "content_type": content_type})
    return assets


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def remote_tag_commit(tag):
    output = git_output(["ls-remote", "--tags", "origin",
                         "refs/tags/" + tag, "refs/tags/" + tag + "^{}"])
    refs = {}
    for line in output.splitlines():
        fields = line.split("\t", 1)
        if len(fields) == 2:
            refs[fields[1]] = fields[0]
    peeled = refs.get("refs/tags/" + tag + "^{}")
    direct = refs.get("refs/tags/" + tag)
    return peeled or direct


def ensure_tag_pushed(tag, version, credential_user):
    if not re.match(r"^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$", tag):
        raise ReleaseError("invalid release tag")
    head = git_output(["rev-parse", "HEAD"])
    local = git_run(["rev-parse", "--verify", "refs/tags/" + tag + "^{}"], check=False)
    local_commit = local.stdout.strip() if local.returncode == 0 else None
    if local_commit and local_commit != head:
        raise ReleaseError("local tag points to a different commit; refusing to overwrite")

    remote_commit = remote_tag_commit(tag)
    if remote_commit and remote_commit != head:
        raise ReleaseError("remote tag points to a different commit; refusing to overwrite")
    if remote_commit:
        return head

    if not local_commit:
        try:
            git_run(["tag", "-a", tag, "-m", "AutoChat " + version], check=True)
        except subprocess.CalledProcessError:
            raise ReleaseError("local tag creation failed; release creation aborted")
    try:
        git_run(["-c", "credential.helper=", "-c", "credential.helper=manager",
                 "-c", "credential.username=" + credential_user,
                 "push", "origin", tag], check=True)
    except subprocess.CalledProcessError:
        raise ReleaseError("tag push failed; release creation aborted")
    return head


def upload_assets(upload_url, assets, existing_assets, token):
    existing = {asset.get("name"): asset for asset in existing_assets or []
                if isinstance(asset, dict) and isinstance(asset.get("name"), str)}
    for asset in assets:
        prior = existing.get(asset["name"])
        if prior:
            if prior.get("size") != asset["size"]:
                raise ReleaseError("existing asset has a different size: " + asset["name"])
            digest = prior.get("digest")
            if not digest:
                raise ReleaseError("cannot verify existing asset digest: " + asset["name"])
            if digest != "sha256:" + asset["sha256"]:
                raise ReleaseError("existing asset has a different digest: " + asset["name"])
            print("asset already attached: %s" % asset["name"])
            continue
        with open(asset["path"], "rb") as handle:
            blob = handle.read()
        url = upload_url + "?name=" + urllib.parse.quote(asset["name"], safe="")
        status, response = request(url, token, method="POST", raw=blob,
                                   content_type=asset["content_type"])
        if status not in (200, 201):
            raise ReleaseError("asset upload failed (%s): %s" %
                               (status, response.get("error", "unknown error")))
        existing[asset["name"]] = response
        print("asset    : %s (%d bytes)" %
              (response.get("name", asset["name"]), response.get("size", asset["size"])))


def publish_release(tag, name, body, prerelease, draft, assets, token):
    payload = {"tag_name": tag, "name": name, "body": body,
               "draft": draft, "prerelease": prerelease}
    status, response = request("%s/repos/%s/%s/releases" % (API, OWNER, NAME), token,
                               method="POST", payload=payload)
    if status == 422:
        print("release for %s already exists; checking attached assets" % tag)
        status, response = request("%s/repos/%s/%s/releases/tags/%s" %
            (API, OWNER, NAME, urllib.parse.quote(tag, safe="")), token)
    if status not in (200, 201):
        raise ReleaseError("release lookup/create failed (%s): %s" %
                           (status, response.get("error", "unknown error")))
    upload_url = response.get("upload_url", "").split("{")[0]
    if not upload_url:
        raise ReleaseError("release response has no upload URL")
    print("release  : %s" % response.get("html_url", ""))
    upload_assets(upload_url, assets, response.get("assets"), token)
    return response.get("html_url")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="e.g. v1.0.0")
    parser.add_argument("--name", default=None, help="release title")
    parser.add_argument("--notes-file", default=None)
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("--draft", action="store_true")
    parser.add_argument("--zip", default=None, help="main AutoChat ZIP artifact")
    parser.add_argument("--asset", action="append", default=[],
                        help="additional release asset; may be repeated")
    parser.add_argument("--credential-user", default=None,
                        help="Git Credential Manager account name (for example YC426)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        zip_path = os.path.abspath(args.zip or newest_zip())
        assets = collect_assets(zip_path, args.asset)
        version = version_from(zip_path)
        tag_version = args.tag[1:] if args.tag.startswith("v") else args.tag
        if not version or tag_version != version:
            raise ReleaseError("tag version %s does not match main ZIP version %s" %
                               (tag_version, version or "unknown"))

        if args.notes_file:
            with io.open(args.notes_file, encoding="utf-8") as handle:
                body = handle.read()
        else:
            body = "AutoChat %s" % version

        print("repo      : %s/%s" % (OWNER, NAME))
        print("tag       : %s" % args.tag)
        for asset in assets:
            print("asset     : %s (%d bytes)" % (asset["name"], asset["size"]))
        print("prerelease: %s   draft: %s" % (args.prerelease, args.draft))
        print()

        if args.dry_run:
            print("--- release body ---")
            print(body)
            print("(dry run: nothing sent)")
            return 0
        if not args.credential_user:
            raise ReleaseError("--credential-user is required for live publishing")

        token = token_from_git(args.credential_user)
        ensure_tag_pushed(args.tag, version, args.credential_user)
        name = args.name or ("AutoChat %s (beta)" % version if args.prerelease
                             else "AutoChat %s" % version)
        release_url = publish_release(args.tag, name, body, args.prerelease,
                                      args.draft, assets, token)
        print("DONE: %s" % release_url)
        return 0
    except ReleaseError as exc:
        parser.exit(1, "release aborted: %s\n" % exc)


if __name__ == "__main__":
    raise SystemExit(main())
