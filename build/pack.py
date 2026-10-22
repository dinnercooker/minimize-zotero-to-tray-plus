#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 src/addon 打包成可安装的 .xpi（ZIP，manifest.json 位于归档根）。"""
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "addon")
DIST = os.path.join(ROOT, "dist")

EXCLUDE_NAMES = {"_preview.png"}
EXCLUDE_DIRS = {".git", "__pycache__"}

ORDER_FIRST = ["manifest.json", "bootstrap.js", "prefs.js"]


def collect():
    files = []
    for base, dirs, names in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for n in names:
            if n in EXCLUDE_NAMES or n.endswith(".log"):
                continue
            full = os.path.join(base, n)
            rel = os.path.relpath(full, SRC).replace("\\", "/")
            files.append((rel, full))
    files.sort(key=lambda x: (x[0] not in ORDER_FIRST, ORDER_FIRST.index(x[0]) if x[0] in ORDER_FIRST else 0, x[0]))
    return files


def main():
    with open(os.path.join(SRC, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    version = manifest["version"]
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, "minimize-to-tray-plus-%s.xpi" % version)

    files = collect()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel, full in files:
            z.write(full, rel)

    print("built:", out, os.path.getsize(out), "bytes")
    print("entries:")
    with zipfile.ZipFile(out) as z:
        for info in z.infolist():
            print("  %-42s %8d  %s" % (info.filename, info.file_size, "deflate" if info.compress_type else "store"))

    # 自检
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        assert "manifest.json" in names, "manifest.json must be at archive root"
        assert "content/bin/tray-helper.ps1" in names
        ps1 = z.read("content/bin/tray-helper.ps1")
        assert ps1.startswith(b"\xef\xbb\xbf"), "tray-helper.ps1 must keep UTF-8 BOM"
        json.loads(z.read("manifest.json").decode("utf-8"))
        bad = z.testzip()
        assert bad is None, "corrupt entry: %s" % bad
    print("self-check: OK")


if __name__ == "__main__":
    main()
