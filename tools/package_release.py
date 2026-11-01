#!/usr/bin/env python3
"""
Build the two release downloads from the repository:

    CS2-AG2-Model-Porter-windows.zip   ->  CS2-AG2-Model-Porter-windows/...
    CS2-AG2-Model-Porter-linux.zip     ->  CS2-AG2-Model-Porter-linux/...

    python3 tools/package_release.py <out-dir> [--version v1.3.0] [--notes notes.md]

The file lists below ARE the release - add any new user-facing file here.
With --version it refuses to build unless every script's $SCRIPT_VERSION and
the top CHANGELOG section match the tag, and --notes writes that CHANGELOG
section out for the release text. Run by .github/workflows/release.yml.
"""
import re
import stat
import sys
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

WINDOWS = [
    "RUN-ME.bat", "Start.ps1", "Setup-AG2.ps1", "Port-Model.ps1", "AG2-All.ps1",
    "Fix-Materials.ps1", "Verify-Model.ps1", "Cleanup-AG2.ps1",
    "README.md", "NOTES.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE", ".gitignore",
    "PORTING-OTHER-GAMES.md", "canonical_skeleton.txt", "valvebiped_to_cs2.txt",
    "tools/blender_remap_weights.py",
]
# name in the zip -> file in the repository
LINUX = {
    "README.md": "linux/README.md",
    "start.sh": "linux/start.sh",
    "ag2port.py": "linux/ag2port.py",
    "NOTES.md": "NOTES.md",
    "LICENSE": "LICENSE",
    "canonical_skeleton.txt": "canonical_skeleton.txt",
}
EXECUTABLE = {"start.sh", "ag2port.py"}
SCRIPTS = ["Start.ps1", "Setup-AG2.ps1", "Port-Model.ps1", "AG2-All.ps1",
           "Fix-Materials.ps1", "Verify-Model.ps1", "Cleanup-AG2.ps1"]


def build(out: Path, top: str, files: dict):
    stamp = time.localtime()[:6]
    dirs = {top + "/"}
    for name in files:
        parts = name.split("/")[:-1]
        for i in range(len(parts)):
            dirs.add(top + "/" + "/".join(parts[:i + 1]) + "/")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for d in sorted(dirs):
            info = zipfile.ZipInfo(d, date_time=stamp)
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            z.writestr(info, b"")
        for name, src in files.items():
            info = zipfile.ZipInfo(f"{top}/{name}", date_time=stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if name in EXECUTABLE else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            z.writestr(info, (REPO / src).read_bytes())
    print(f"{out.name}: {len(files)} files")


def changelog_section(version: str):
    text = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(rf"^## {re.escape(version)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else None


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    out = Path(args[0])
    version = args[args.index("--version") + 1] if "--version" in args else None
    notes = args[args.index("--notes") + 1] if "--notes" in args else None

    missing = [f for f in WINDOWS + list(LINUX.values()) if not (REPO / f).is_file()]
    if missing:
        print("missing from the repository: " + ", ".join(missing))
        return 1

    if version:
        want = version.lstrip("v")
        wrong = []
        for s in SCRIPTS:
            m = re.search(r'^\$SCRIPT_VERSION = "([^"]+)"', (REPO / s).read_text(encoding="utf-8"), re.M)
            if not m or m.group(1) != want:
                wrong.append(f"{s} ({m.group(1) if m else 'no version'})")
        if wrong:
            print(f"tag {version} does not match $SCRIPT_VERSION in: " + ", ".join(wrong))
            return 1
        section = changelog_section(version)
        if section is None:
            print(f"CHANGELOG.md has no '## {version}' section")
            return 1
        if notes:
            Path(notes).parent.mkdir(parents=True, exist_ok=True)
            Path(notes).write_text(section + "\n", encoding="utf-8")

    out.mkdir(parents=True, exist_ok=True)
    build(out / "CS2-AG2-Model-Porter-windows.zip", "CS2-AG2-Model-Porter-windows", {f: f for f in WINDOWS})
    build(out / "CS2-AG2-Model-Porter-linux.zip", "CS2-AG2-Model-Porter-linux", LINUX)
    return 0


if __name__ == "__main__":
    sys.exit(main())
