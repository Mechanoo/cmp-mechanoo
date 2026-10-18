#!/usr/bin/env python3
"""Generate manifest.json: every .lua file in bin/, lib/ and apps/ with its size.

The version is a hash of the contents, so it only changes when a file changes.
Run from anywhere:  python scripts/make_manifest.py
"""
import hashlib
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ["bin", "lib", "apps"]


def main():
    files = []
    digest = hashlib.sha256()
    for d in DIRS:
        for base, _, names in sorted(os.walk(os.path.join(ROOT, d))):
            for n in sorted(names):
                if not n.endswith(".lua"):
                    continue
                full = os.path.join(base, n)
                rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
                data = open(full, "rb").read().replace(b"\r\n", b"\n")
                files.append({"path": rel, "size": len(data)})
                digest.update(rel.encode() + b"\0" + data)
    files.sort(key=lambda f: f["path"])
    manifest = {"version": digest.hexdigest()[:10], "files": files}
    with open(os.path.join(ROOT, "manifest.json"), "w", newline="\n") as fh:
        json.dump(manifest, fh, indent=1)
        fh.write("\n")
    print("manifest.json: version %s, %d files" % (manifest["version"], len(files)))


if __name__ == "__main__":
    main()
