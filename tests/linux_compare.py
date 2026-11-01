#!/usr/bin/env python3
"""
Run linux/ag2port.py's model edits on a .vmdl and compare the result with the
.vmdl the Windows AG2-All.ps1 produced from the same input. Used by
Run-Tests.ps1; the two implementations must agree.

    linux_compare.py <ag2port.py> <input.vmdl> <windows-output.vmdl>
    linux_compare.py <ag2port.py> <input.vmdl> --expect-not-player-model

Numbers are compared to 2e-6 and -0 equals 0: Python, .NET Framework and .NET
can round the last digit of the same value differently. Exit 0 when they
agree, 1 with the first difference printed, 3 for a model with no pelvis.
"""
import importlib.util
import re
import sys
from pathlib import Path

NUM = re.compile(r'-?\d+\.\d+(?:[eE][-+]?\d+)?')


def load(path):
    spec = importlib.util.spec_from_file_location("ag2port", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def lines(text):
    return text.replace("\r\n", "\n").rstrip("\n").split("\n")


def same_line(a, b):
    if NUM.sub("#", a) != NUM.sub("#", b):
        return False
    return all(abs(float(x) - float(y)) <= 2e-6 for x, y in zip(NUM.findall(a), NUM.findall(b)))


def main():
    mod = load(sys.argv[1])
    src = Path(sys.argv[2])
    try:
        mod.port_vmdl(src)
    except mod.NotPlayerModel:
        return 3
    if sys.argv[3] == "--expect-not-player-model":
        print("ported a model with no pelvis")
        return 1
    ours = lines(src.read_text(encoding="utf-8-sig"))
    theirs = lines(Path(sys.argv[3]).read_text(encoding="utf-8-sig"))
    for n, (a, b) in enumerate(zip(ours, theirs), 1):
        if not same_line(a, b):
            print(f"line {n} differs\n  linux:   {a.strip()}\n  windows: {b.strip()}")
            return 1
    if len(ours) != len(theirs):
        print(f"length differs: linux {len(ours)} lines, windows {len(theirs)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
