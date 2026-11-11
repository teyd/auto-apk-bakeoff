#!/usr/bin/env python3
"""Download one app version from APKMirror.

Usage: fetch_apkmirror.py <app-page-url> <version> <arch> <outdir>

HTML pages go through trawl (TRAWL_URL, default http://127.0.0.1:8191).
The file itself is fetched directly with trawl's cookies and user agent.
Prints one JSON object on stdout; exits non-zero on failure.
"""
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TRAWL = os.environ.get("TRAWL_URL", "http://127.0.0.1:8191")
BASE = "https://www.apkmirror.com"
PAUSE = float(os.environ.get("APKMIRROR_PAUSE", "3"))
log = {"pages": 0, "tiers": [], "release_url": None, "variant": None}


def fail(msg):
    log["error"] = msg
    print(json.dumps(log))
    sys.exit(1)


def page(url):
    """Fetch a page through trawl. Returns (status, html, trawl response)."""
    time.sleep(PAUSE if log["pages"] else 0)
    body = json.dumps({"url": url, "solveEmbeddedCaptchas": False}).encode()
    req = urllib.request.Request(TRAWL + "/scrape", data=body, headers={"Content-Type": "application/json"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            d = json.loads(raw)
        except ValueError:
            d = {"trawl_http": e.code, "raw": raw[:300].decode(errors="replace")}
        d.setdefault("trawl_http", e.code)
    except Exception as e:  # timeout, connection refused
        d = {"exception": repr(e)[:300]}
    log["pages"] += 1
    log["tiers"].append(d.get("tier"))
    entry = {"url": url.replace(BASE, ""), "status": d.get("statusCode"), "tier": d.get("tier"),
             "s": round(time.time() - t, 1)}
    if d.get("statusCode") != 200:
        entry["detail"] = {k: v for k, v in d.items() if k not in ("html", "body", "cookies", "responseHeaders")}
    log.setdefault("trace", []).append(entry)
    return d.get("statusCode"), d.get("html") or "", d


def links(text, pattern):
    return [html.unescape(m) for m in re.findall(pattern, text)]


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def main():
    if len(sys.argv) != 5:
        fail("usage: fetch_apkmirror.py <app-page-url> <version> <arch> <outdir>")
    app_url, version, arch, outdir = sys.argv[1:]
    status, text, d = page(app_url)
    if status != 200:
        fail(f"app page: HTTP {status}")

    # Learn the release-slug prefixes from this app's own release links only;
    # the page also links other apps in its sidebars.
    app_path = urllib.parse.urlparse(d.get("url") or app_url).path
    if not app_path.endswith("/"):
        app_path += "/"
    found = [(p, s) for p, s in re.findall(r'href="(/apk/[^"/]+/[^"/]+/)([^"/]+)-release/"', text) if p == app_path]
    if not found:
        fail(f"app page: no release links under {app_path}")
    paths = [app_path]
    prefixes = []
    for _, s in found:
        m = re.match(r"^(.*?-)(?=\d)", s)
        if m and m.group(1) not in prefixes:
            prefixes.append(m.group(1))
    prefixes.sort(key=lambda p: -sum(1 for _, s in found if s.startswith(p)))

    vslugs = []
    for v in (version, version.split(" ")[0], version.split("-release")[0]):
        if slug(v) not in vslugs:
            vslugs.append(slug(v))

    release = None
    for path in paths:
        for pre in prefixes:
            for vs in vslugs:
                url = f"{BASE}{path}{pre}{vs}-release/"
                status, text, _ = page(url)
                if status == 200 and "variants-table" in text:
                    release = url
                    break
            if release:
                break
        if release:
            break
    if not release:
        fail(f"release page not found (tried {len(paths) * len(prefixes) * len(vslugs)} slugs)")
    log["release_url"] = release

    # Pick a variant: APK before BUNDLE, matching or universal arch, nodpi first.
    table = text[text.find("variants-table"):]
    rows = re.split(r'<div class="table-row headerFont">', table)[1:]
    best = None
    for row in rows:
        hrefs = links(row, r'href="([^"#]*-download/)"')
        if not hrefs:
            continue
        cells = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", row))).strip()
        kind = "bundle" if " BUNDLE " in f" {cells} " else "apk"
        arch_ok = arch in cells or "universal" in cells or "noarch" in cells
        if not arch_ok:
            continue
        score = (kind == "apk") * 4 + (arch in cells) * 1 + ("nodpi" in cells) * 2
        if best is None or score > best[0]:
            best = (score, hrefs[0], kind, cells[:160])
    if not best:
        fail("no variant for this arch")
    _, href, kind, cells = best
    log["variant"] = cells
    log["kind"] = kind

    status, text, _ = page(BASE + href)
    key = links(text, r'href="([^"]*/download/\?key=[^"]*)"')
    if status != 200 or not key:
        fail(f"variant page: HTTP {status}, no download button")
    status, text, d = page(BASE + key[0])
    final = links(text, r'href="([^"]*download\.php\?[^"]*)"')
    if status != 200 or not final:
        fail(f"download page: HTTP {status}, no file link")

    cookies = "; ".join(
        f"{c['name']}={c['value']}" for c in d.get("cookies", []) if "apkmirror.com" in c.get("domain", "")
    )
    req = urllib.request.Request(
        BASE + final[0],
        headers={"User-Agent": d.get("userAgent") or "Mozilla/5.0", "Cookie": cookies, "Referer": BASE + key[0]},
    )
    os.makedirs(outdir, exist_ok=True)
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            ctype = r.headers.get("Content-Type", "")
            cd = r.headers.get("Content-Disposition", "")
            name = (re.findall(r'filename="?([^";]+)', cd) or [f"download.{'apkm' if kind == 'bundle' else 'apk'}"])[0]
            name = os.path.basename(name)
            path = os.path.join(outdir, name)
            with open(path, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
    except urllib.error.HTTPError as e:
        fail(f"file: HTTP {e.code}")
    if "html" in ctype:
        fail(f"file: got {ctype}, probably a challenge page")
    log["file"] = os.path.abspath(path)
    log["file_seconds"] = round(time.time() - t, 1)
    print(json.dumps(log))


if __name__ == "__main__":
    main()
