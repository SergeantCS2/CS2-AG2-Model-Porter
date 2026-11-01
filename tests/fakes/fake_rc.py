#!/usr/bin/env python3
"""
Stand-in for resourcecompiler.exe, used only by the test suite.

"Compiles" a ModelDoc .vmdl from content/csgo_addons/<addon>/ into
game/csgo_addons/<addon>/ as a JSON entry the fake Source2Viewer can answer
--block DATA / RERL for. It reads the skeleton the way the real compiler
would need to, and fails the way the real one does on input it cannot use:
unbalanced braces, or a transform that is not exactly three numbers (what a
comma-decimal locale used to produce).
"""
import json, os, re, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def norm(p):
    return p if os.name == "nt" else p.replace("\\", "/")


def fail(msg):
    print(f"RESOURCE COMPILE ERROR: {msg}")
    print("ERROR: 0 compiled, 1 failed, 0 skipped")
    return 1


def main():
    argv = sys.argv[1:]
    if "-i" not in argv:
        print("usage: resourcecompiler -i <file>")
        return 0
    src = norm(argv[argv.index("-i") + 1])
    text = open(src, encoding="utf-8-sig").read()
    if text.count("{") != text.count("}") or text.count("[") != text.count("]"):
        return fail("unbalanced braces")

    lines = text.split("\n")
    bones, parents, pos = [], [], []
    stack = []  # (brace depth, bone index) - nesting by braces, as KV3 reads it
    depth = 0
    for i, ln in enumerate(lines):
        here = depth
        depth += ln.count("{") - ln.count("}")
        if '_class = "Bone"' not in ln:
            continue
        ind = here
        while stack and stack[-1][0] >= ind:
            stack.pop()
        name = origin = None
        for j in range(i + 1, min(i + 6, len(lines))):
            m = re.match(r'^\s*name = "([^"]+)"', lines[j])
            if m and name is None:
                name = m.group(1)
            m = re.match(r"^\s*origin = \[(.*)\]", lines[j])
            if m and origin is None:
                parts = [x.strip() for x in m.group(1).split(",") if x.strip()]
                if len(parts) != 3:
                    return fail(f"bone origin needs 3 values, got {len(parts)}: [{m.group(1).strip()}]")
                origin = [float(x) for x in parts]
        if name is None:
            return fail("bone without a name")
        parents.append(stack[-1][1] if stack else -1)
        bones.append(name)
        pos.append(origin or [0.0, 0.0, 0.0])
        stack.append((ind, len(bones) - 1))

    refs = re.findall(r'"([^"]+\.(?:vnmgraph|vnmskel|vmat|vanmgrph|vmdl))"', text)
    rel = re.split(r"[\\/]content[\\/]csgo_addons[\\/][^\\/]+[\\/]", src, maxsplit=1)[-1].replace("\\", "/")
    data = ["{", f'\tm_name = "{rel}"', "\tm_modelSkeleton = ", "\t{", "\t\tm_boneName = ", "\t\t["]
    data += [f'\t\t\t"{b}",' for b in bones]
    data += ["\t\t]", "\t\tm_nParent = ", "\t\t["] + [f"\t\t\t{p}," for p in parents] + ["\t\t]"]
    data += ["\t\tm_bonePosParent = ", "\t\t["]
    data += ["\t\t\t[ %.6f, %.6f, %.6f ]," % tuple(p) for p in pos]
    data += ["\t\t]", "\t}", "\tm_refs = ", "\t["] + [f'\t\t"{r}",' for r in refs] + ["\t]", "}"]
    rerl = "\n".join(f'\t"{r}"' for r in sorted(set(refs)))

    out = re.sub(r"([\\/])content([\\/])csgo_addons([\\/])", r"\1game\2csgo_addons\3", src)
    out = re.sub(r"\.vmdl$", ".vmdl_c", out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        # real compiled player models are hundreds of KB; Verify skips small files
        json.dump({"size": 300000, "data": "\n".join(data), "rerl": rerl, "pad": "x" * 120000}, fh)
    print(f"Compiling {rel}")
    print("OK: 1 compiled, 0 failed, 0 skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
