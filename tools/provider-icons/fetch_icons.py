#!/usr/bin/env python3
"""
Source provider logomarks for the OmniRoute providers that resolve to no icon
at any ProviderIcon tier.

Order of preference, most defensible provenance first:
  1. Simple Icons (CC0-1.0) for recognisable brands -- explicit slug map only,
     never a guess, so we cannot silently ship the wrong company's mark.
  2. The provider's own site: <link rel="...icon...">, then the well-known
     /favicon.svg, /apple-touch-icon.png, /favicon.ico paths.

Every file written gets a provenance row. Anything we cannot source cleanly is
left alone and keeps rendering the generic icon -- an unattributed logo is worse
than no logo.
"""
import csv
import io
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urljoin, urlparse

import requests
from PIL import Image

OUT = "/var/www/omniroute/src/public/providers"
REPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon-provenance.tsv")
TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "iconless-urls.tsv")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"
HDRS = {"User-Agent": UA, "Accept": "text/html,image/*,*/*"}
T = 8

# Explicit brand -> Simple Icons slug. Only entries whose identity is
# unambiguous from the registry's own baseUrl / provider name.
SIMPLEICONS = {
    "cloudflare-playground": "cloudflare",
    "notion-web": "notion",
    "raycast": "raycast",
    "writer": "writer",
    "deepai": "deepai",
    "lmarena": "lmarena",
    "aihorde": "aihorde",
    "codex-app-server": "openai",
    "xiaomi-mimo-token-plan": "xiaomi",
    "clova-studio": "naver",
    "internlm": "internetcomputer",  # placeholder-risk: dropped below
}
# Slugs above that are NOT actually the right brand -- keep the map honest.
SIMPLEICONS.pop("internlm", None)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def get(url, **kw):
    return requests.get(url, headers=HDRS, timeout=T, allow_redirects=True, **kw)


def hosts_for(base):
    """Candidate site origins to try, most likely to carry a logo first."""
    if not base or not base.startswith("http"):
        return []
    p = urlparse(base)
    host = p.netloc
    out = []
    bare = re.sub(r"^(api|apihub|backend|router|models|oai|chat|data|app|playground)\.", "", host)
    parts = bare.split(".")
    apex = ".".join(parts[-2:]) if len(parts) >= 2 else bare
    for h in (bare, host, "www." + apex, apex):
        u = f"https://{h}"
        if u not in out:
            out.append(u)
    return out


ICON_RE = re.compile(
    r"""<link[^>]+rel=["'][^"']*\bicon\b[^"']*["'][^>]*>""", re.I)
HREF_RE = re.compile(r"""href=["']([^"']+)["']""", re.I)
SIZES_RE = re.compile(r"""sizes=["'](\d+)x\d+["']""", re.I)


def icon_candidates(origin):
    """(url, rank) pairs; lower rank = preferred."""
    cands = []
    try:
        r = get(origin)
        if r.ok and "html" in r.headers.get("content-type", ""):
            for tag in ICON_RE.findall(r.text[:400_000]):
                m = HREF_RE.search(tag)
                if not m:
                    continue
                href = urljoin(r.url, m.group(1))
                if href.startswith("data:"):
                    continue
                low = href.lower()
                sz = SIZES_RE.search(tag)
                if low.endswith(".svg") or "image/svg" in tag.lower():
                    rank = 0
                elif sz:
                    rank = 1 if int(sz.group(1)) >= 128 else 2
                elif "apple-touch" in low:
                    rank = 1
                elif low.endswith(".png"):
                    rank = 2
                else:
                    rank = 3
                cands.append((href, rank))
    except Exception:
        pass
    for path, rank in (("/favicon.svg", 0), ("/apple-touch-icon.png", 1),
                       ("/icon.svg", 0), ("/logo.svg", 0), ("/favicon.ico", 4)):
        cands.append((urljoin(origin + "/", path.lstrip("/")), rank))
    seen, out = set(), []
    for u, rk in sorted(cands, key=lambda x: x[1]):
        if u not in seen:
            seen.add(u)
            out.append((u, rk))
    return out


def save_svg(data, pid):
    txt = data.decode("utf-8", "ignore")
    if "<svg" not in txt.lower():
        return None
    if len(data) > 400_000:
        return None
    path = os.path.join(OUT, pid + ".svg")
    with open(path, "wb") as f:
        f.write(data)
    return path


def save_raster(data, pid, ext):
    try:
        if ext == "ico":
            with tempfile.NamedTemporaryFile(suffix=".ico", delete=False) as t:
                t.write(data)
                src = t.name
            dst = os.path.join(OUT, pid + ".png")
            # pick the largest frame ImageMagick finds
            subprocess.run(["convert", src + "[0]", "-resize", "256x256>", dst],
                           check=True, capture_output=True, timeout=30)
            os.unlink(src)
            im = Image.open(dst)
            if min(im.size) < 16:
                os.unlink(dst)
                return None
            return dst
        im = Image.open(io.BytesIO(data))
        if min(im.size) < 16:
            return None
        im = im.convert("RGBA")
        im.thumbnail((256, 256))
        path = os.path.join(OUT, pid + ".png")
        im.save(path, "PNG", optimize=True)
        return path
    except Exception:
        return None


def try_url(url, pid):
    try:
        r = get(url)
    except Exception:
        return None
    if not r.ok or not r.content:
        return None
    ct = r.headers.get("content-type", "").lower()
    low = url.lower().split("?")[0]
    if "svg" in ct or low.endswith(".svg"):
        p = save_svg(r.content, pid)
        return (p, "svg") if p else None
    if low.endswith(".ico") or "icon" in ct and "png" not in ct:
        p = save_raster(r.content, pid, "ico")
        return (p, "png") if p else None
    p = save_raster(r.content, pid, "png")
    return (p, "png") if p else None


def work(row):
    pid, base = row
    slug = SIMPLEICONS.get(pid)
    if slug:
        try:
            r = get(f"https://cdn.simpleicons.org/{slug}")
            if r.ok and b"<svg" in r.content:
                p = save_svg(r.content, pid)
                if p:
                    return (pid, "svg", f"https://cdn.simpleicons.org/{slug}",
                            "Simple Icons, CC0-1.0")
        except Exception:
            pass
    for origin in hosts_for(base):
        for url, _ in icon_candidates(origin)[:6]:
            got = try_url(url, pid)
            if got:
                return (pid, got[1], url, f"provider's own site ({urlparse(origin).netloc})")
    return (pid, "", "", "NOT SOURCED")


def main():
    rows = []
    with open(TSV) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2:
                rows.append((parts[0], parts[1] if parts[1] != "?" else ""))
    os.makedirs(OUT, exist_ok=True)
    results = []
    with ThreadPoolExecutor(max_workers=12) as ex:
        for res in ex.map(work, rows):
            results.append(res)
            log(f"  {res[0]:24} {res[1] or '-':4} {res[3]}")
    with open(REPORT, "w", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["provider", "ext", "source_url", "provenance"])
        w.writerows(results)
    ok = [r for r in results if r[1]]
    print(f"\nsourced {len(ok)}/{len(results)}  "
          f"(svg={sum(1 for r in ok if r[1]=='svg')} png={sum(1 for r in ok if r[1]=='png')})")


if __name__ == "__main__":
    main()
