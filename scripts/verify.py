#!/usr/bin/env python3
"""Check a downloaded APK, XAPK or APKM.

Usage: verify.py <file> <package> <version> [pin-sha256]

Prints JSON: file kind, every APK's signer certificates, whether the pin is among
the signers of every APK, and package/version from the base APK.
Needs apksigner and aapt2 on PATH.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile


def certs(apk):
    out = subprocess.run(["apksigner", "verify", "--print-certs", apk], capture_output=True, text=True)
    found = re.findall(r"^(?!Source Stamp)[^\n]*certificate SHA-256 digest: ([0-9a-f]{64})", out.stdout, re.M)
    return out.returncode == 0, sorted(set(found))


def badging(apk):
    out = subprocess.run(["aapt2", "dump", "badging", apk], capture_output=True, text=True).stdout
    m = re.search(r"package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'", out)
    return m.groups() if m else (None, None, None)


def main():
    path, package, version = sys.argv[1:4]
    pin = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] not in ("", "null") else None
    r = {"size": os.path.getsize(path)}
    with open(path, "rb") as f:
        if f.read(2) != b"PK":
            r.update(kind="not-a-zip", ok=False)
            print(json.dumps(r))
            return
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if "AndroidManifest.xml" in names:
            r["kind"] = "apk"
            apks, base = [path], path
            tmp = None
        else:
            r["kind"] = "apkm" if "info.json" in names else "xapk" if "manifest.json" in names else "zip"
            tmp = tempfile.mkdtemp(prefix="verify-")
            members = [n for n in names if n.endswith(".apk") and "/" not in n]
            z.extractall(tmp, members)
            apks = [os.path.join(tmp, n) for n in members]
            base = next((a for a in apks if os.path.basename(a) in ("base.apk", f"{package}.apk")), apks[0] if apks else None)
    r["apks"] = len(apks)
    per = [certs(a) for a in apks]
    r["signatures_valid"] = all(ok for ok, _ in per)
    r["certs"] = sorted({c for _, cs in per for c in cs})
    r["pin_ok"] = (all(pin in cs for _, cs in per) and bool(per)) if pin else None
    pkg, code, name = badging(base) if base else (None, None, None)
    r.update(package=pkg, versionCode=code, versionName=name)
    r["package_ok"] = pkg == package
    r["version_ok"] = name == version
    r["ok"] = r["signatures_valid"] and r["package_ok"] and r["version_ok"] and r["pin_ok"] is not False
    print(json.dumps(r))


if __name__ == "__main__":
    main()
