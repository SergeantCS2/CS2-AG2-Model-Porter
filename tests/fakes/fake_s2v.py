#!/usr/bin/env python3
"""
Stand-in for Source2Viewer-CLI, used only by the test suite.

A "VPK" here is a JSON file: {"files": {"<path inside the vpk>": entry}}.
A compiled file extracted from it (or written by a test) holds that entry as
JSON, so --block can answer for it later. Entry fields:

    size        listed size (bytes)
    data, rerl  text printed for --block DATA / RERL
    decompiled  {"<file name>": "<text>"} written beside it by -d. Leave it
                empty to act like a real decompile that produced nothing
                (a material whose shader version is unsupported).

Only the flags the scripts use are implemented: -i -o -d -l -e -f --block
--version. Output is UTF-8, as the real tool's is.
"""
import json, os, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def norm(p):
    # PowerShell builds Windows-style paths; on Linux they arrive with '\'
    return p if os.name == "nt" else p.replace("\\", "/")


def parse(argv):
    a = {"i": None, "o": None, "d": False, "l": False, "e": None, "f": None, "block": None, "version": False}
    i = 0
    while i < len(argv):
        k = argv[i]
        if k in ("-i", "--input"): a["i"] = norm(argv[i + 1]); i += 2; continue
        if k in ("-o", "--output"): a["o"] = norm(argv[i + 1]); i += 2; continue
        if k in ("-e", "--vpk_extensions"): a["e"] = argv[i + 1]; i += 2; continue
        if k in ("-f", "--vpk_filepath"): a["f"] = argv[i + 1].replace("\\", "/"); i += 2; continue
        if k in ("-b", "--block"): a["block"] = argv[i + 1]; i += 2; continue
        if k in ("-d", "--vpk_decompile"): a["d"] = True; i += 1; continue
        if k in ("-l", "--vpk_list"): a["l"] = True; i += 1; continue
        if k == "--version": a["version"] = True; i += 1; continue
        i += 1
    return a


def load_entry(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_text(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def matches(path, exts, filt):
    if exts:
        allowed = [x.strip().lower() for x in exts.split(",")]
        if path.rsplit(".", 1)[-1].lower() not in allowed:
            return False
    if filt and not path.lower().startswith(filt.lower()):
        return False
    return True


def main():
    a = parse(sys.argv[1:])
    if a["version"]:
        print("Source2Viewer-CLI 20.1.0+fake")
        return 0
    src = a["i"]
    if not src or not os.path.exists(src):
        print(f"Input \"{src}\" does not exist.", file=sys.stderr)
        return 1

    if src.lower().endswith(".vpk"):
        files = load_entry(src)["files"]
        hits = [p for p in sorted(files) if matches(p, a["e"], a["f"])]
        if a["l"]:
            for p in hits:
                print(f"{p} CRC:00000000 size:{files[p].get('size', 1000)}")
            return 0
        if a["o"]:
            for p in hits:
                entry = files[p]
                target_dir = os.path.join(a["o"], os.path.dirname(p))
                if a["d"]:
                    for name, text in entry.get("decompiled", {}).items():
                        write_text(os.path.join(target_dir, name), text)
                else:
                    write_text(os.path.join(a["o"], p), json.dumps(entry))
            return 0
        return 0

    # a single compiled file
    entry = load_entry(src)
    if a["block"]:
        print(entry.get(a["block"].lower(), ""))
        return 0
    if a["o"] and a["d"]:
        out = a["o"]
        dec = entry.get("decompiled", {})
        if src.lower().endswith(".vtex_c"):
            if dec:
                write_text(out, next(iter(dec.values())))
            return 0
        for name, text in dec.items():
            write_text(os.path.join(os.path.dirname(out), name), text)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
