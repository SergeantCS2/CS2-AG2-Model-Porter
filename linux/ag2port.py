#!/usr/bin/env python3
"""
ag2port.py — port pre-AnimGraph2 CS2 player models, on Linux.

Same pipeline as the Windows scripts. Everything runs natively except the
final compile: resourcecompiler is a Windows binary and has no Linux build,
so that step goes through Wine or Proton. Everything up to it — extraction,
the model edits, materials, verification — is native.

    ./ag2port.py list    --vpk PACK.vpk
    ./ag2port.py port    --vpk PACK.vpk --model eula
    ./ag2port.py port    --vpk PACK.vpk --all
    ./ag2port.py port    --source ~/models --all
    ./ag2port.py verify  --all

Python 3.8+, standard library only.
"""

import argparse, json, math, os, re, shutil, struct, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
CFG_FILE = HOME / ".config" / "ag2port" / "settings.json"

# ── canonical AG2 skeleton ───────────────────────────────────────────────────
# Same tiers as Verify-Model.ps1. spine/neck are optional: one model runs
# pelvis straight to spine_1 and animates fine.
CRITICAL = ['root_motion','pelvis','head_0',
            'clavicle_L','clavicle_R','arm_upper_L','arm_upper_R','arm_lower_L','arm_lower_R',
            'hand_L','hand_R','leg_upper_L','leg_upper_R','leg_lower_L','leg_lower_R',
            'ankle_L','ankle_R','wpnPivot','wpn']
IMPORTANT = ['spine_0','spine_1','spine_2','spine_3','neck_0','ball_L','ball_R']
PARENT = {
    'root_motion':'',        'pelvis':'root_motion',   'spine_0':'pelvis',
    'spine_1':'spine_0',     'spine_2':'spine_1',      'spine_3':'spine_2',
    'neck_0':'spine_3',      'head_0':'neck_0',
    'clavicle_L':'spine_3',  'arm_upper_L':'clavicle_L','arm_lower_L':'arm_upper_L','hand_L':'arm_lower_L',
    'clavicle_R':'spine_3',  'arm_upper_R':'clavicle_R','arm_lower_R':'arm_upper_R','hand_R':'arm_lower_R',
    'leg_upper_L':'pelvis',  'leg_lower_L':'leg_upper_L','ankle_L':'leg_lower_L','ball_L':'ankle_L',
    'leg_upper_R':'pelvis',  'leg_lower_R':'leg_upper_R','ankle_R':'leg_lower_R','ball_R':'ankle_R',
    'wpnPivot':'root_motion','wpn':'wpnPivot',
}
# canonical bones carrying a side suffix — only these are ever case-flipped
# canonical bones carrying a side suffix - only these are ever case-flipped.
# Same list as AG2-All.ps1.
CANON = ['ankle_L','ankle_R','arm_lower_L','arm_lower_R','arm_upper_L','arm_upper_R','attachFoot_L','attachFoot_R',
         'attachHand_L','attachHand_R','ball_L','ball_R','clavicle_L','clavicle_R','finger_index_0_L','finger_index_0_R',
         'finger_index_1_L','finger_index_1_R','finger_index_2_L','finger_index_2_R','finger_index_meta_L',
         'finger_index_meta_R','finger_middle_0_L','finger_middle_0_R','finger_middle_1_L','finger_middle_1_R',
         'finger_middle_2_L','finger_middle_2_R','finger_middle_meta_L','finger_middle_meta_R','finger_pinky_0_L',
         'finger_pinky_0_R','finger_pinky_1_L','finger_pinky_1_R','finger_pinky_2_L','finger_pinky_2_R',
         'finger_pinky_meta_L','finger_pinky_meta_R','finger_ring_0_L','finger_ring_0_R','finger_ring_1_L',
         'finger_ring_1_R','finger_ring_2_L','finger_ring_2_R','finger_ring_meta_L','finger_ring_meta_R',
         'finger_thumb_0_L','finger_thumb_0_R','finger_thumb_1_L','finger_thumb_1_R','finger_thumb_2_L',
         'finger_thumb_2_R','hand_L','hand_R','leg_lower_L','leg_lower_R','leg_upper_L','leg_upper_R',
         'wpnHand_L','wpnHand_R']

PHYS_BODIES = ['hand_l','ankle_r','ankle_l','hand_r','arm_upper_r','arm_lower_r',
               'arm_lower_l','leg_lower_r','arm_upper_l','head_0','leg_upper_L',
               'leg_lower_l','leg_upper_r','spine_2','pelvis']

C = dict(r='\033[31m', g='\033[32m', y='\033[33m', b='\033[36m', d='\033[90m', x='\033[0m')
def say(m, c='x'): print(f"{C[c]}{m}{C['x']}")
def die(m): say(f"error: {m}", 'r'); sys.exit(1)


# ── settings ─────────────────────────────────────────────────────────────────
def load_cfg():
    try: return json.loads(CFG_FILE.read_text())
    except Exception: return {}

def save_cfg(cfg):
    CFG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CFG_FILE.write_text(json.dumps(cfg, indent=2))


# ── environment discovery ────────────────────────────────────────────────────
def find_cs2():
    """Steam moves around a lot on Linux. Check the usual spots and any extra
    library folders declared in libraryfolders.vdf."""
    roots = [HOME/".steam/steam", HOME/".local/share/Steam", HOME/".steam/root",
             HOME/".var/app/com.valvesoftware.Steam/.local/share/Steam"]
    seen = []
    for r in roots:
        vdf = r/"steamapps/libraryfolders.vdf"
        if vdf.exists():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors='replace')):
                seen.append(Path(m.group(1)))
        seen.append(r)
    for s in seen:
        p = s/"steamapps/common/Counter-Strike Global Offensive"
        if (p/"game/csgo/gameinfo.gi").exists():
            return p
    return None


def find_s2v():
    for c in [HOME/"s2v/Source2Viewer-CLI", HOME/".local/bin/Source2Viewer-CLI",
              Path("/usr/local/bin/Source2Viewer-CLI")]:
        if c.exists(): return c
    w = shutil.which("Source2Viewer-CLI")
    return Path(w) if w else None


def find_wine(cs2):
    """resourcecompiler.exe is a Windows binary. Prefer Proton if CS2 is already
    running under it, since the prefix will match; fall back to system wine."""
    steam_roots = [HOME/".steam/steam", HOME/".local/share/Steam"]
    for r in steam_roots:
        common = r/"steamapps/common"
        if not common.exists(): continue
        protons = sorted([d for d in common.iterdir()
                          if d.is_dir() and d.name.startswith(("Proton", "SteamLinuxRuntime"))],
                         reverse=True)
        for p in protons:
            exe = p/"proton"
            if exe.exists(): return ("proton", exe, r)
    w = shutil.which("wine")
    if w: return ("wine", Path(w), None)
    return (None, None, None)


def run(cmd, **kw):
    """Native command. Never let a tool's stderr chatter be treated as failure —
    judge by the files produced."""
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    return (r.stdout or "") + "\n" + (r.stderr or "")


# ── Source 2 helpers ─────────────────────────────────────────────────────────
def s2v_data(s2v, path, block="DATA"):
    return run([s2v, "-i", path, "--block", block])


def model_skeleton(text):
    m = re.search(r'm_modelSkeleton\s*=\s*\{\s*m_boneName\s*=\s*\[(.*?)\]', text, re.S)
    if not m: return [], {}, None
    bones = re.findall(r'"([^"]+)"', m.group(1))
    pm = re.search(r'm_nParent\s*=\s*\[(.*?)\]', text, re.S)
    par = [int(x) for x in re.findall(r'-?\d+', pm.group(1))] if pm else []
    hier = {bones[i]: (bones[par[i]] if par[i] >= 0 else '')
            for i in range(min(len(bones), len(par)))}
    pos = None
    pp = re.search(r'm_bonePosParent\s*=\s*\[(.*?)\r?\n[ \t]*\]', text, re.S)
    if pp and 'pelvis' in bones:
        v = re.findall(r'\[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]', pp.group(1))
        i = bones.index('pelvis')
        if i < len(v): pos = [float(x) for x in v[i]]
    return bones, hier, pos


# ── ModelDoc source editing ──────────────────────────────────────────────────
# A step-for-step port of AG2-All.ps1. The two must produce the same .vmdl -
# tests/linux_compare.py checks that on every synthetic model in the test
# suite - so when one changes, change the other.

class NotPlayerModel(Exception):
    """No pelvis bone: viewmodel arms or a prop. Skipped, not failed."""


ORIGIN_RE = r'origin = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]'
ANGLES_RE = r'angles = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]'

# rotation that brings a model authored on another axis onto +Z
AXES = {
    "-X": [[0, 0, 1], [0, 1, 0], [-1, 0, 0]],
    "+X": [[0, 0, -1], [0, 1, 0], [1, 0, 0]],
    "+Y": [[1, 0, 0], [0, 0, -1], [0, 1, 0]],
    "-Y": [[1, 0, 0], [0, 0, 1], [0, -1, 0]],
    "-Z": [[1, 0, 0], [0, -1, 0], [0, 0, -1]],
    "+Z": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
}


def angle_matrix(p, y, r):
    d = math.pi / 180.0
    p, y, r = p * d, y * d, r * d
    sp, cp = math.sin(p), math.cos(p)
    sy, cy = math.sin(y), math.cos(y)
    sr, cr = math.sin(r), math.cos(r)
    return [[cp*cy, sr*sp*cy-cr*sy, cr*sp*cy+sr*sy],
            [cp*sy, sr*sp*sy+cr*cy, cr*sp*sy-sr*cy],
            [-sp,   sr*cp,          cr*cp]]


def to_root_motion_space(origin, angles, rm_angles, up="+Z"):
    """Re-express a former root bone in root_motion's space: new = R^T * (A * M),
    where R is root_motion's own rotation (any angles - packs are not all at a
    clean [0, 90, 90]) and A turns a model authored on another axis onto +Z.
    Skip this and the model compiles perfectly and comes out on its side.
    Same operations in the same order as AG2-All.ps1."""
    d = math.pi / 180.0
    m = angle_matrix(*angles)
    r = angle_matrix(*rm_angles)
    a = AXES.get(up, AXES["+Z"])
    m = [[a[i][0]*m[0][j] + a[i][1]*m[1][j] + a[i][2]*m[2][j] for j in range(3)] for i in range(3)]
    o = [a[i][0]*origin[0] + a[i][1]*origin[1] + a[i][2]*origin[2] for i in range(3)]
    n = [[r[0][i]*m[0][j] + r[1][i]*m[1][j] + r[2][i]*m[2][j] for j in range(3)] for i in range(3)]
    no = [r[0][i]*o[0] + r[1][i]*o[1] + r[2][i]*o[2] for i in range(3)]
    yaw = math.atan2(n[1][0], n[0][0]) / d
    pitch = math.atan2(-n[2][0], math.sqrt(n[0][0]*n[0][0] + n[1][0]*n[1][0])) / d
    roll = math.atan2(n[2][1], n[2][2]) / d
    return no, [pitch, yaw, roll]


def find_block(lines, idx):
    """Given the index of a line inside a { ... } object, return (start, end)
    of that object, inclusive: walk back to the '{', then brace-match."""
    s = idx
    while s >= 0 and lines[s].strip() != '{': s -= 1
    depth, e = 0, s
    while e < len(lines):
        depth += lines[e].count('{') - lines[e].count('}')
        if depth == 0: return s, e
        e += 1
    raise RuntimeError("unbalanced braces")


def _prefix(line, key):
    """The text before the first occurrence of key (its indentation)."""
    i = line.find(key)
    return line[:i] if i >= 0 else line


def _vec(line, regex):
    m = re.search(regex, line)
    return [float(x) for x in m.groups()] if m else None


def _replace_transform(lines, oi, ai, c):
    no, na = c
    lines[oi] = re.sub(r'origin = \[[^\]]*\]', 'origin = [ %.6f, %.6f, %.6f ]' % tuple(no), lines[oi])
    lines[ai] = re.sub(r'angles = \[[^\]]*\]', 'angles = [ %.6f, %.6f, %.6f ]' % tuple(na), lines[ai])


def _convert_block(blk, rm_angles, up):
    """Convert a lifted root bone's own origin/angles (within its first lines)."""
    for i in range(min(8, len(blk))):
        if not _vec(blk[i], ORIGIN_RE): continue
        ai = next((j for j in range(min(8, len(blk))) if _vec(blk[j], ANGLES_RE)), -1)
        if ai < 0: break
        _replace_transform(blk, i, ai, to_root_motion_space(_vec(blk[i], ORIGIN_RE), _vec(blk[ai], ANGLES_RE), rm_angles, up))
        break
    return blk


def find_bone_children(lines, name_idx):
    """The 'children =' of the bone named on line name_idx, or -1 for a leaf.
    Searched only inside the bone's own block - an open-ended scan runs past a
    leaf bone and finds some later node's children array instead."""
    ind = _prefix(lines[name_idx], 'name')
    _, e = find_block(lines, name_idx)
    for i in range(name_idx + 1, e):
        if lines[i].strip() == 'children =' and _prefix(lines[i], 'children') == ind:
            return i
    return -1


def add_first_child(lines, name_idx, block):
    ind = _prefix(lines[name_idx], 'name')
    k = find_bone_children(lines, name_idx)
    if k >= 0:
        lines[k+2:k+2] = block
        return "first child"
    _, e = find_block(lines, name_idx)
    lines[e:e] = [ind + 'children = ', ind + '['] + block + [ind + ']']
    return "new children array"


def bone_angles(lines, name_idx):
    _, e = find_block(lines, name_idx)
    for i in range(name_idx, min(name_idx + 6, e)):
        v = _vec(lines[i], ANGLES_RE)
        if v: return v
    return [0.0, 0.0, 0.0]


def _balanced(lines):
    t = '\n'.join(lines)
    return t.count('{') == t.count('}') and t.count('[') == t.count(']')


def ag2_list_block(ind, which):
    if which == 'skeleton':
        blk = [f'{ind}{{', f'{ind}\t_class = "NmSkeletonList"', f'{ind}\tchildren = ', f'{ind}\t[']
        for s in ('worldmodel', 'viewmodel'):
            blk += [f'{ind}\t\t{{', f'{ind}\t\t\t_class = "NmSkeletonReference"',
                    f'{ind}\t\t\tfilename = "animation/skeletons/characters/{s}.vnmskel"', f'{ind}\t\t}},']
        return blk + [f'{ind}\t]', f'{ind}}},']
    graphs = [('DefaultAnimGraph2', None, 'animation/graphs/worldmodel/worldmodel.vnmgraph'),
              ('AnimGraph2', 'uimodel', 'animation/graphs/ui/uimodel.vnmgraph'),
              ('AnimGraph2', 'hudmodel', 'animation/graphs/viewmodel/viewmodel.vnmgraph'),
              ('AnimGraph2', 'worldmodel', 'animation/graphs/worldmodel/worldmodel.vnmgraph')]
    blk = [f'{ind}{{', f'{ind}\t_class = "AnimGraph2List"', f'{ind}\tchildren = ', f'{ind}\t[']
    for cls, name, fn in graphs:
        blk += [f'{ind}\t\t{{', f'{ind}\t\t\t_class = "{cls}"']
        if name: blk.append(f'{ind}\t\t\tname = "{name}"')
        blk += [f'{ind}\t\t\tfilename = "{fn}"', f'{ind}\t\t}},']
    return blk + [f'{ind}\t]', f'{ind}}},']


WPN_BONES = '''{i}{{
{i}\t_class = "Bone"
{i}\tname = "wpnPivot"
{i}\torigin = [ 0.0, 58.781631, -3.471687 ]
{i}\tangles = [ 0.0, 0.0, 0.0 ]
{i}\tdo_not_discard = true
{i}\tchildren = 
{i}\t[
{i}\t\t{{
{i}\t\t\t_class = "Bone"
{i}\t\t\tname = "wpn"
{i}\t\t\torigin = [ 0.0, -58.781662, 3.471689 ]
{i}\t\t\tangles = [ 0.0, 0.0, 0.0 ]
{i}\t\t\tdo_not_discard = true
{i}\t\t}},
{i}\t]
{i}}},
'''


def port_vmdl(path: Path, strip_ag1=True):
    """Apply every AG2 edit to a decompiled ModelDoc source, in place."""
    L = path.read_text(encoding='utf-8-sig').split('\n')
    log = []
    find = lambda pat, start=0, flags=re.I: next((i for i in range(start, len(L)) if re.search(pat, L[i], flags)), -1)

    # ---- part 1: the skeleton ------------------------------------------------
    sk = find(r'_class = "Skeleton"')
    if sk < 0: raise RuntimeError("no Skeleton node")
    pel, rm = find(r'name = "pelvis"', sk), find(r'name = "root_motion"', sk)
    if pel < 0: raise NotPlayerModel("no pelvis bone - is this a player model?")

    # up axis, read from pelvis only when it is not already inside root_motion
    # (there its origin is root_motion-relative and would read as +Y)
    up = "+Z"
    pel_under_rm = False
    if rm >= 0:
        s, e = find_block(L, rm)
        pel_under_rm = s < pel < e
    if not pel_under_rm:
        for i in range(pel, min(pel + 8, len(L))):
            pv = _vec(L[i], ORIGIN_RE)
            if not pv: continue
            bi = 0
            for k in (1, 2):
                if abs(pv[k]) > abs(pv[bi]): bi = k
            up = ('+' if pv[bi] >= 0 else '-') + "XYZ"[bi]
            if up != "+Z": log.append(f"model is authored {up}-up rather than +Z - correcting orientation")
            break

    # no root_motion: create one and adopt every existing root under it
    if rm < 0:
        sk_ind = _prefix(L[sk], '_class')
        sk_kids = next((i for i in range(sk + 1, len(L))
                        if L[i].strip() == 'children =' and _prefix(L[i], 'children') == sk_ind), -1)
        if sk_kids < 0: raise RuntimeError("Skeleton node has no children array")
        bi = sk_ind + '\t'
        roots, depth = [], 0
        for i in range(sk_kids + 1, len(L)):
            depth += len(re.findall(r'\[|\{', L[i])) - len(re.findall(r'\]|\}', L[i]))
            if depth <= 0: break
            if re.search(r'_class = "Bone"', L[i], re.I) and _prefix(L[i], '_class') == bi + '\t':
                roots.append(i)
        if not roots: raise RuntimeError("Skeleton has no top-level bones")
        adopted = []
        for r in sorted(roots, reverse=True):
            s, e = find_block(L, r)
            adopted = _convert_block(['\t' + x for x in L[s:e+1]], [0, 90, 90], up) + adopted
            del L[s:e+1]
        sk_kids = next(i for i in range(sk + 1, len(L))
                       if L[i].strip() == 'children =' and _prefix(L[i], 'children') == sk_ind)
        L[sk_kids+2:sk_kids+2] = ([f'{bi}{{', f'{bi}\t_class = "Bone"', f'{bi}\tname = "root_motion"',
                                   f'{bi}\torigin = [ 0.0, 0.0, 0.0 ]', f'{bi}\tangles = [ 0.0, 90.0, 90.0 ]',
                                   f'{bi}\tdo_not_discard = true', f'{bi}\tchildren = ', f'{bi}\t[']
                                  + adopted + [f'{bi}\t]', f'{bi}}},'])
        log.append(f"created root_motion and adopted {len(roots)} existing root(s)")
        pel, rm = find(r'name = "pelvis"', sk), find(r'name = "root_motion"', sk)

    # pelvis and root_motion as siblings: convert pelvis, move it under root_motion
    if len(_prefix(L[pel], 'name')) == len(_prefix(L[rm], 'name')):
        ps, pe = find_block(L, pel)
        rm_ang = next((v for v in (_vec(L[i], ANGLES_RE) for i in range(rm, min(rm + 6, len(L)))) if v), [0.0, 0.0, 0.0])
        oi = next((i for i in range(pel, min(pel + 8, pe)) if _vec(L[i], ORIGIN_RE)), -1)
        ai = next((i for i in range(pel, min(pel + 8, pe)) if _vec(L[i], ANGLES_RE)), -1)
        if oi >= 0 and ai >= 0:
            c = to_root_motion_space(_vec(L[oi], ORIGIN_RE), _vec(L[ai], ANGLES_RE), rm_ang, up)
            _replace_transform(L, oi, ai, c)
            log.append("pelvis transform -> origin [%.4f, %.4f, %.4f]" % tuple(c[0]))
        else:
            log.append("!! could not read pelvis origin/angles - transform NOT applied")
        block = ['\t' + x for x in L[ps:pe+1]]
        del L[ps:pe+1]
        rm = find(r'name = "root_motion"', sk)
        if rm < 0: raise RuntimeError("lost root_motion after removal")
        how = add_first_child(L, rm, block)
        log.append("pelvis re-parented under root_motion" + (" (new children array)" if how != "first child" else ""))
        if not _balanced(L): raise RuntimeError("brace mismatch after re-parent - not written")

    # stray roots beside root_motion: adopt them, converting each transform
    sk2 = find(r'_class = "Skeleton"')
    sk_ind2 = _prefix(L[sk2], '_class')
    kids2 = next((i for i in range(sk2 + 1, min(sk2 + 6, len(L)))
                  if L[i].strip() == 'children =' and _prefix(L[i], 'children') == sk_ind2), -1)
    if kids2 >= 0:
        bi2 = sk_ind2 + '\t\t'
        strays, depth, rm_name2 = [], 0, -1
        for i in range(kids2 + 1, len(L)):
            depth += len(re.findall(r'\[|\{', L[i])) - len(re.findall(r'\]|\}', L[i]))
            if depth <= 0: break
            if re.search(r'_class = "Bone"', L[i], re.I) and _prefix(L[i], '_class') == bi2:
                nm = nm_idx = None
                for j in range(i + 1, min(i + 4, len(L))):
                    mm = re.match(r'^\s*name = "([^"]+)"', L[j])
                    if mm: nm, nm_idx = mm.group(1), j; break
                if nm and nm.lower() == 'root_motion': rm_name2 = nm_idx
                elif nm: strays.append((i, nm))
        if rm_name2 >= 0 and strays:
            before = list(L)
            rm_ang2 = bone_angles(L, rm_name2)
            moved = []
            for idx, _ in sorted(strays, reverse=True):
                s, e = find_block(L, idx)
                moved = _convert_block(['\t' + x for x in L[s:e+1]], rm_ang2, up) + moved
                del L[s:e+1]
            rmn = next((i for i in range(1, len(L)) if re.match(r'^\s*name = "root_motion"\s*$', L[i], re.I)
                        and any(re.search(r'_class = "Bone"', L[j], re.I) for j in range(i - 1, max(0, i - 3) - 1, -1))), -1)
            if rmn >= 0:
                add_first_child(L, rmn, moved)
            if rmn >= 0 and _balanced(L):
                log.append("adopted %d stray root(s) under root_motion: %s" % (len(strays), ', '.join(n for _, n in strays)))
            else:
                L = before
                log.append("!! stray roots NOT adopted")

    # ---- part 2: names, references and AG2 nodes -----------------------------
    # case-flip side suffixes if this model predates the uppercase convention
    if any(re.search(r'name = "\w+_(l|r)"', l, re.I) for l in L):
        pairs = []
        for i in range(1, len(L)):
            if not re.search(r'_class = "Bone"', L[i-1], re.I): continue
            m = re.search(r'name = "([A-Za-z0-9_]+)"', L[i])
            if not m: continue
            n = m.group(1)
            c = n
            for pat, rep in ((r'_twist1$', '_TWIST1'), (r'_twist$', '_TWIST'), (r'_l$', '_L'), (r'_r$', '_R'),
                             (r'_l(?=_TWIST)', '_L'), (r'_r(?=_TWIST)', '_R')):
                c = re.sub(pat, rep, c, flags=re.I)
            if c != n and c in CANON:
                L[i] = re.sub('name = "' + re.escape(n) + '"', 'name = "' + c + '"', L[i], flags=re.I)
                pairs.append((n, c))
        if pairs:
            log.append(f"case-flipped {len(pairs)} bone name(s) to _L/_R")
            # the mesh binds by name through the DMX jointList; patch only the
            # DMX files this model references (length-preserving, in place)
            dmx_files = []
            for ref in sorted(set(re.findall(r'filename = "([^"]+\.dmx)"', '\n'.join(L), re.I))):
                up_dir = path.parent
                for _ in range(12):
                    cand = up_dir / ref
                    if cand.exists(): dmx_files.append(cand); break
                    if up_dir.parent == up_dir: break
                    up_dir = up_dir.parent
            if not dmx_files: dmx_files = sorted(path.parent.glob('*.dmx'))
            n_dmx = 0
            for dmx in dmx_files:
                b = dmx.read_bytes(); orig = b
                for o, c in pairs:
                    b = b.replace(b'\x00' + o.encode() + b'\x00', b'\x00' + c.encode() + b'\x00')
                if b != orig: dmx.write_bytes(b); n_dmx += 1
            log.append(f"patched {n_dmx} DMX file(s) to match" if n_dmx else "!! no DMX patched - mesh binding may be broken")
            fields = r'parent_bone|bone|bone_name|anklebone|toebone|start_bone|end_bone|attachment_bone'
            for i, l in enumerate(L):
                m = re.match(rf'^\s*({fields}) = "([A-Za-z0-9_]+)"', l)
                if not m: continue
                for o, c in pairs:
                    if m.group(2) == o:
                        L[i] = l.replace(f'"{o}"', f'"{c}"'); break

    # Feet references that only differ in case from a real bone
    skel = [re.search(r'name = "([A-Za-z0-9_]+)"', L[i]).group(1) for i in range(1, len(L))
            if re.search(r'_class = "Bone"', L[i-1], re.I) and re.search(r'name = "([A-Za-z0-9_]+)"', L[i], re.I)]
    for i, l in enumerate(L):
        m = re.search(r'(anklebone|toebone) = "([A-Za-z0-9_]+)"', l)
        if not m or m.group(2) in skel: continue
        alt = next((s for s in skel if s.lower() == m.group(2).lower()), None)
        if alt and alt != m.group(2):
            L[i] = l.replace(f'"{m.group(2)}"', f'"{alt}"')

    # drop the AnimGraph1 binding and the animset include
    L = [l for l in L if not (re.search('anim_graph_name', l, re.I) and re.search('vanmgrph', l, re.I))]
    for i in range(len(L) - 1, -1, -1):
        if i >= len(L) or not re.search(r'_class = "AnimIncludeModel"', L[i], re.I): continue
        if re.search('animsets/', '\n'.join(L[i:min(i + 3, len(L) - 1) + 1]), re.I):
            s, e = find_block(L, i)
            del L[s:e+1]

    # the AG2 node lists - each checked on its own
    sk = find(r'_class = "Skeleton"')
    if sk < 0: raise RuntimeError("no Skeleton node")
    opn = sk - 1
    while opn >= 0 and L[opn].strip() != '{': opn -= 1
    ind = _prefix(L[opn], '{')
    joined = '\n'.join(L)
    has_skel = bool(re.search(r'_class = "NmSkeletonList"', joined, re.I))
    has_graph = bool(re.search(r'_class = "AnimGraph2List"', joined, re.I))
    if not has_skel and not has_graph:
        L[opn:opn] = ag2_list_block(ind, 'skeleton') + ag2_list_block(ind, 'graph')
        log.append("inserted NmSkeletonList + AnimGraph2List")
    else:
        new = []
        if not has_skel: new += ag2_list_block(ind, 'skeleton')
        if not has_graph: new += ag2_list_block(ind, 'graph')
        if new: L[opn:opn] = new
        want = [('NmSkeletonList', 'NmSkeletonReference', None, 'animation/skeletons/characters/worldmodel.vnmskel'),
                ('NmSkeletonList', 'NmSkeletonReference', None, 'animation/skeletons/characters/viewmodel.vnmskel'),
                ('AnimGraph2List', 'DefaultAnimGraph2', None, 'animation/graphs/worldmodel/worldmodel.vnmgraph'),
                ('AnimGraph2List', 'AnimGraph2', 'uimodel', 'animation/graphs/ui/uimodel.vnmgraph'),
                ('AnimGraph2List', 'AnimGraph2', 'hudmodel', 'animation/graphs/viewmodel/viewmodel.vnmgraph')]
        added = 0
        for lst, cls, name, fn in want:
            if re.search(re.escape(fn), '\n'.join(L), re.I): continue
            li = find(f'_class = "{lst}"')
            if li < 0: continue
            l_ind = _prefix(L[li], '_class')
            lk = next((i for i in range(li + 1, min(li + 6, len(L)))
                       if L[i].strip() == 'children =' and _prefix(L[i], 'children') == l_ind), -1)
            if lk < 0: continue
            ei = l_ind + '\t'
            entry = [f'{ei}{{', f'{ei}\t_class = "{cls}"'] + ([f'{ei}\tname = "{name}"'] if name else [])
            L[lk+2:lk+2] = entry + [f'{ei}\tfilename = "{fn}"', f'{ei}}},']
            added += 1
        if new or added: log.append("AnimGraph2 lists topped up")

    # graft wpnPivot -> wpn under root_motion (CS2's canonical rest values)
    rm = find(r'name = "root_motion"')
    if re.search(r'name = "wpnPivot"', '\n'.join(L), re.I):
        pass
    elif rm < 0:
        log.append("!! no root_motion bone - wpnPivot NOT added")
    else:
        rm_ind = _prefix(L[rm], 'name')
        kids = -1
        for i in range(rm + 1, len(L)):
            t = L[i].strip()
            if t == 'children =' and _prefix(L[i], 'children') == rm_ind: kids = i; break
            if re.match(r'^_class = ', t, re.I) and len(_prefix(L[i], '_class')) <= len(rm_ind): break
        if kids < 0:
            log.append("!! root_motion has no children array - wpnPivot NOT added")
        else:
            L[kids+2:kids+2] = WPN_BONES.format(i=_prefix(L[kids + 1], '[') + '\t').rstrip('\n').split('\n')
            log.append("grafted wpnPivot/wpn")

    # name any BodyGroupChoice the decompiler left unnamed
    fixed, i = 0, 0
    while i < len(L):
        if re.search(r'_class = "BodyGroupChoice"', L[i], re.I):
            d, e = 0, i
            while e < len(L):
                d += L[e].count('{') - L[e].count('}')
                if d < 0: break
                e += 1
            seg = '\n'.join(L[i:min(e, len(L) - 1) + 1])
            if not re.search('name = ', seg, re.I):
                mesh = re.search(r'"([^"]+)"\s*,', seg)
                L.insert(i + 1, _prefix(L[i], '_class') + 'name = "' + (mesh.group(1) if mesh else f"choice{fixed}") + '"')
                fixed += 1
        i += 1

    # strip AnimGraph1-era nodes, then match Valve's weapon attachments
    if strip_ag1:
        for pat in (r'_class = "MovementSettings"', r'_class = "Feet"', r'game_class = "character_arm_config"'):
            while True:
                hit = find(pat)
                if hit < 0: break
                s, e = find_block(L, hit); del L[s:e+1]

        al = find(r'_class = "AttachmentList"')
        if al >= 0:
            bones_now = [re.match(r'^\s*name = "([^"]+)"', L[i]).group(1) for i in range(1, len(L))
                         if re.search(r'_class = "Bone"', L[i-1], re.I) and re.match(r'^\s*name = "([^"]+)"', L[i])]
            for att, bone, org, ang in (('weapon_hand_r', 'hand_R', '-2.6, -1.4, 0.0', '0.0, -179.999985, 0.0'),
                                        ('weapon_hand_l', 'hand_L', '2.6, 1.4, 0.0', '0.0, 0.0, 179.999985')):
                rb = next((b for b in bones_now if b.lower() == bone.lower()), None)
                if not rb: continue
                for i in range(al, len(L)):
                    if not re.search(rf'^\s*name = "{att}"\s*$', L[i], re.I): continue
                    for j in range(i + 1, min(i + 8, len(L))):
                        if re.search(r'^\s*parent_bone = ', L[j], re.I):
                            L[j] = _prefix(L[j], 'parent_bone') + 'parent_bone = "' + rb + '"'
                        if re.search(r'^\s*relative_origin = ', L[j], re.I):
                            L[j] = _prefix(L[j], 'relative_origin') + 'relative_origin = [ ' + org + ' ]'
                        if re.search(r'^\s*relative_angles = ', L[j], re.I):
                            L[j] = _prefix(L[j], 'relative_angles') + 'relative_angles = [ ' + ang + ' ]'
                        if L[j].strip() == '},': break
                    log.append(f"repointed {att} to {rb}")
                    break
            if not re.search(r'name = "weapon_center"', '\n'.join(L), re.I):
                al_ind = _prefix(L[al], '_class')
                ak = next((i for i in range(al + 1, min(al + 6, len(L)))
                           if L[i].strip() == 'children =' and _prefix(L[i], 'children') == al_ind), -1)
                if ak >= 0:
                    ei = al_ind + '\t'
                    L[ak+2:ak+2] = [f'{ei}{{', f'{ei}\t_class = "Attachment"', f'{ei}\tname = "weapon_center"',
                                    f'{ei}\tignore_rotation = false', f'{ei}\tparent_bone = ""',
                                    f'{ei}\trelative_origin = [ 0.0, 0.0, 40.0 ]',
                                    f'{ei}\trelative_angles = [ 0.0, 0.0, 0.0 ]', f'{ei}\tweight = 1.0', f'{ei}}},']

    # the physics body markup Valve's agents carry
    if strip_ag1 and not re.search('CPhysicsBodyGameMarkupData', '\n'.join(L), re.I):
        gd = find(r'_class = "GameDataList"')
        k = next((i for i in range(gd + 1, min(gd + 6, len(L))) if L[i].strip() == 'children ='), -1) if gd >= 0 else -1
        if k >= 0:
            ind = _prefix(L[k], 'children') + '\t'
            blk = [f'{ind}{{', f'{ind}\t_class = "GenericGameData"', f'{ind}\tname = ""',
                   f'{ind}\tgame_class = "CPhysicsBodyGameMarkupData"', f'{ind}\tgame_keys = ',
                   f'{ind}\t{{', f'{ind}\t\tm_PhysicsBodyMarkupByBoneName = ', f'{ind}\t\t{{']
            for b in PHYS_BODIES:
                blk += [f'{ind}\t\t\t{b} = ', f'{ind}\t\t\t{{',
                        f'{ind}\t\t\t\tm_TargetBody = "{b}"', f'{ind}\t\t\t\tm_Tag = ""',
                        f'{ind}\t\t\t}}']
            blk += [f'{ind}\t\t}}', f'{ind}\t}}', f'{ind}}},']
            L[k+2:k+2] = blk
            log.append(f"added CPhysicsBodyGameMarkupData ({len(PHYS_BODIES)} bodies)")

    if not _balanced(L):
        raise RuntimeError("brace mismatch - refusing to write")
    shutil.copy(path, str(path) + '.bak')
    path.write_text('\n'.join(L), encoding='utf-8')
    return log


# ── materials ────────────────────────────────────────────────────────────────
def rebuild_vmat(s2v, vmat_c: Path):
    """Source2Viewer cannot decompile CS2 materials when CS2 is installed — it
    finds the shader and hits a version it does not support. The compiled DATA
    block has everything needed, and reading it needs no shader."""
    t = s2v_data(s2v, vmat_c)
    sh = re.search(r'm_shaderName\s*=\s*"([^"]*)"', t)
    if not sh: return False
    out = ['// rebuilt from ' + vmat_c.name, '', 'Layer0', '{', f'\tshader "{sh.group(1)}"', '']
    groups = [('m_intParams', False), ('m_floatParams', False), ('m_vectorParams', True),
              ('m_textureParams', True), ('m_intAttributes', False)]
    for key, quote in groups:
        m = re.search(re.escape(key) + r'\s*=\s*\r?\n?\s*\[(.*?)\r?\n[ \t]*\]', t, re.S)
        if not m: continue
        for e in re.finditer(r'\{(.*?)\}', m.group(1), re.S):
            n = re.search(r'm_name\s*=\s*"([^"]*)"', e.group(1))
            v = re.search(r'm_(?:nValue|flValue|pValue|value)\s*=\s*(.+)', e.group(1))
            if not (n and v): continue
            name = n.group(1); val = v.group(1).strip().rstrip(',').strip('"')
            if key == 'm_vectorParams':
                nums = re.sub(r'[\[\]]', '', val).split(',')
                val = '[' + ' '.join('%.6f' % float(x) for x in nums) + ']'
            if key == 'm_textureParams':
                val = re.sub(r'^resource:"?', '', val).rstrip('"')
                val = re.sub(r'\.vtex$', '.png', val)
                name = re.sub(r'^g_t', 'Texture', name)
            out.append(f'\t{name} "{val}"' if quote else f'\t{name} {val}')
        out.append('')
    out += ['}', '']
    Path(str(vmat_c)[:-2]).write_text('\n'.join(out))
    return True


def fix_materials(mat: Path):
    if not mat.exists(): return 0, 0
    renamed = 0
    for f in list(mat.glob('*.png')) + list(mat.glob('*.tga')):
        if '_vmat_g_' in f.name: continue
        n = re.sub(r'_(png|tga|jpg)_[0-9a-f]{8}(\.\w+)$', r'\2', f.name)
        if n != f.name:
            tgt = f.parent / n
            if tgt.exists(): f.unlink()
            else: f.rename(tgt)
            renamed += 1
    dropped = 0; fixed = 0
    for f in mat.glob('*.vmat'):
        out, skip, depth = [], False, 0
        for line in f.read_text(errors='replace').split('\n'):
            if '"Compiled Textures"' in line: skip, depth = True, 0; continue
            if skip:
                depth += line.count('{') - line.count('}')
                if depth <= 0 and '}' in line: skip = False
                continue
            if '_vmat_g_' in line or 'materials/default/' in line: dropped += 1; continue
            line = re.sub(r'_(png|tga|jpg)_[0-9a-f]{8}(\.\w+)', r'\2', line)
            line = re.sub(r'^(\s*)"?g_t(\w+)"?(\s+")', r'\1"Texture\2"\3', line)
            out.append(line)
        f.write_text('\n'.join(out)); fixed += 1
    return renamed, fixed


# ── commands ─────────────────────────────────────────────────────────────────
def is_body(data):
    """pelvis plus a leg: the minimal signature of a player model's skeleton.
    Filters viewmodel arms, props and map stubs whatever they are called."""
    m = re.search(r'm_modelSkeleton\s*=\s*\{\s*m_boneName\s*=\s*\[(.*?)\]', data, re.S)
    if not m: return False
    bones = [b.lower() for b in re.findall(r'"([^"]+)"', m.group(1))]
    return 'pelvis' in bones and ('leg_upper_l' in bones or 'leg_upper_r' in bones)


def discover(s2v, vpk=None, source=None):
    """Returns {name: {'dir': folder inside the addon, 'file': Path|None}}."""
    out = {}
    if source:
        for f in Path(source).rglob('*.vmdl_c'):
            d = s2v_data(s2v, f)
            mn = re.search(r'm_name\s*=\s*"([^"]+)"', d)
            if not mn or not is_body(d): continue
            intern = re.sub(r'\.vmdl$', '', mn.group(1))
            # the model's OWN folder from m_name - not <root>/<name>; packs do
            # not always name the folder after the model
            out[Path(intern).name] = {'dir': str(Path(intern).parent).replace('\\', '/'), 'file': f}
    else:
        if not Path(vpk).exists():
            die(f"vpk not found: {vpk}")
        listing = run([s2v, "-i", vpk, "-l", "-e", "vmdl_c"])
        for m in re.finditer(r'([a-zA-Z0-9_/]+)/([a-zA-Z0-9_]+)/\2\.vmdl_c', listing):
            out.setdefault(m.group(2), {'dir': f"{m.group(1)}/{m.group(2)}", 'file': None})
        if not out:
            # no <name>/<name>.vmdl_c layout at all: every large, non-arms model
            for ln in listing.split('\n'):
                m = re.search(r'([a-zA-Z0-9_/\-]+)/([a-zA-Z0-9_\-]+)\.vmdl_c', ln)
                if not m: continue
                nm = m.group(2)
                if re.search(r'(_arms?|_pm_arm|viewmodel)$', nm) or re.search(r'_arms?_', nm) or nm.startswith('v_'):
                    continue
                sz = re.search(r'size:(\d+)', ln)
                if sz and int(sz.group(1)) < 100000: continue
                out.setdefault(nm, {'dir': m.group(1), 'file': None})
    return out


def cmd_port(a, cfg):
    cs2 = Path(cfg['cs2']); s2v = Path(cfg['s2v'])
    out_root = cs2/"content/csgo_addons"/a.addon
    if not out_root.exists(): die(f"addon not created: {out_root}\nrun: ag2port.py setup")

    models = discover(s2v, a.vpk, a.source)
    if not models: die("no player models found")
    todo = list(models) if a.all else [m for m in models
                                        if m == a.model or m == f"{a.model}_player_model"]
    if not todo: die(f"'{a.model}' not found. try: ag2port.py list")

    rc = cs2/"game/bin/win64/resourcecompiler.exe"
    kind, runner, sroot = find_wine(cs2)
    if a.no_compile:
        kind = None
        say("--no-compile: sources will be prepared but not compiled", 'y')
    elif not rc.exists():
        say("Workshop Tools DLC not installed - cannot compile", 'r')
        say("  Steam Library > right-click CS2 > Properties > DLC >", 'y')
        say("  tick 'Counter-Strike 2 Workshop Tools'", 'y')
        sys.exit(1)
    elif not kind:
        say("no wine or proton found - cannot run resourcecompiler.exe", 'r')
        say("  install wine, or install CS2 through Proton, or use --no-compile", 'y')
        sys.exit(1)
    if kind: say(f"compiler will run via {kind}", 'd')

    ver = next((l.strip() for l in run([s2v, "--version"]).split('\n') if re.search(r'\d+\.\d+', l)), '')
    if ver: say(f"Source2Viewer-CLI {ver}", 'd')

    ok, bad, skipped = [], [], []
    started = time.time()
    for n, m in enumerate(todo, 1):
        label = re.sub(r'_player_model$', '', m)
        print(f"\n{C['b']}=== [{n}/{len(todo)}] {label} ==={C['x']}")
        try:
            d = out_root/models[m]['dir']
            vmdl = d/f"{m}.vmdl"
            done = cs2/"game/csgo_addons"/a.addon/models[m]['dir']/f"{m}.vmdl_c"
            if done.exists() and not a.force:
                say("  already compiled - skipping (--force to redo)", 'd'); ok.append(m); continue

            print("  extracting...")
            if a.source:
                src = models[m]['file']
                run([s2v, "-i", src, "-o", vmdl, "-d"])
                # every compiled material and texture under the model's folder,
                # mirrored - packs use materials/, mat/, or nest deeper
                for f in src.parent.rglob('*'):
                    if f.is_file() and f.name.endswith(('.vmat_c', '.vtex_c')):
                        tgt = d/f.relative_to(src.parent)
                        tgt.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy(f, tgt)
                # textures to .png BEFORE the sweep below, or the materials
                # point at images that are not there
                for vt in d.rglob('*.vtex_c'):
                    png = vt.with_name(vt.name[:-len('.vtex_c')] + '.png')
                    if not png.exists(): run([s2v, "-i", vt, "-o", png, "-d"])
            else:
                run([s2v, "-i", a.vpk, "-o", out_root, "-f", f"{models[m]['dir']}/", "-d"])
                run([s2v, "-i", a.vpk, "-o", out_root, "-f", f"{models[m]['dir']}/", "-e", "vmat_c"])
            if not vmdl.exists(): raise RuntimeError("no .vmdl produced")

            # rebuild, one at a time, every material Source2Viewer could not
            # decompile (its shader version is newer than it supports)
            vmat_c = sorted(d.rglob('*.vmat_c'))
            missing = [v for v in vmat_c if not v.with_suffix('.vmat').exists()]
            if missing:
                print(f"  no .vmat from decompile for {len(missing)} material(s) - rebuilding from compiled data")
                print(f"  rebuilt {sum(rebuild_vmat(s2v, v) for v in missing)} material(s)")
            if vmat_c and not list(d.rglob('*.vmat')):
                raise RuntimeError("could not rebuild any materials")

            for stray in d.rglob('*_c'):
                if stray.is_file(): stray.unlink()

            ren = fx = 0
            for md in sorted({p.parent for p in d.rglob('*') if p.suffix in ('.vmat', '.png', '.tga')}):
                r1, f1 = fix_materials(md); ren += r1; fx += f1
            print(f"  materials: {fx} fixed, {ren} textures renamed")

            try:
                for line in port_vmdl(vmdl, strip_ag1=not a.keep_ag1):
                    print(f"  {line}")
            except NotPlayerModel:
                say("  not a player model (no pelvis bone) - skipped", 'd'); skipped.append(m); continue

            txt = vmdl.read_text(encoding='utf-8-sig', errors='replace')
            counts = {k: txt.count(k) for k in ('vanmgrph', 'vnmgraph', 'wpnPivot', 'vnmskel')}
            print("  counts  " + " ".join(f"{k}={v}" for k, v in counts.items()) +
                  "  (want 0 4 1 2)")
            # Valve ships 4 graph references, the fourth a duplicate of the
            # worldmodel graph; ports by other authors use 3 and work
            if counts['vanmgrph'] or counts['vnmgraph'] < 3 or counts['vnmskel'] < 2:
                raise RuntimeError("port did not apply cleanly")

            if not kind:
                say("  prepared (not compiled)", 'y')
                ok.append(m)
                continue
            print("  compiling...")
            if kind == "proton":
                env = dict(os.environ,
                           STEAM_COMPAT_DATA_PATH=str(HOME/".ag2port-prefix"),
                           STEAM_COMPAT_CLIENT_INSTALL_PATH=str(sroot))
                Path(env["STEAM_COMPAT_DATA_PATH"]).mkdir(parents=True, exist_ok=True)
                log = run([runner, "run", rc, "-i", vmdl], env=env)
            else:
                log = run([runner, str(rc), "-i", str(vmdl)])
            if 'ERROR: 0 compiled' in log or ('RESOURCE COMPILE ERROR' in log and 'OK:' not in log):
                for l in log.split('\n'):
                    if 'ERROR' in l or 'Error!' in l: say("    " + l.strip(), 'r')
                raise RuntimeError("compile failed")
            if not done.exists():
                raise RuntimeError("compiler reported no error but wrote no .vmdl_c")
            say(f"  OK  {done.stat().st_size} bytes", 'g')
            ok.append(m)
        except Exception as ex:
            say(f"  FAILED: {ex}", 'r'); bad.append(f"{label} ({ex})")

    el = time.time() - started
    print(f"\n{C['b']}================ SUMMARY ================{C['x']}")
    verb = "prepared" if not kind else "ported"
    print(f"{verb} : {len(ok)}   failed : {len(bad)}   took : {int(el//60)}m{int(el%60):02d}s")
    for b in bad: say("   " + b, 'r')
    if skipped: say(f"skipped: {len(skipped)} file(s) with no pelvis bone - not player models: {', '.join(skipped)}", 'd')
    if ok and not kind:
        print()
        say("Sources are ready but not compiled. To finish on a Windows machine:", 'y')
        say(f"  1. copy  {cs2}/content/csgo_addons/{a.addon}", 'y')
        say("     to the same path on a box with the CS2 Workshop Tools", 'y')
        say("  2. there, run:  .\\Port-Model.ps1 -CompileOnly", 'y')
        say("     That only compiles what you prepared - no re-porting, and it", 'y')
        say("     does not need the original pack on that machine.", 'y')
    return 1 if bad else 0


def cmd_verify(a, cfg):
    cs2 = Path(cfg['cs2']); s2v = Path(cfg['s2v'])
    root = cs2/"game/csgo_addons"/a.addon
    every = list(root.rglob('*.vmdl_c'))
    tidy = [f for f in every if f.stem == f.parent.name]
    other = [f for f in every if f.stem != f.parent.name and f.stat().st_size >= 100000
             and not re.search(r'(_arms?|_pm_arm|viewmodel)$', f.stem) and not re.search(r'_arms?_', f.stem)
             and not f.stem.startswith('v_')]
    files = tidy + other
    if a.model:
        files = [f for f in files if f.stem in (a.model, f"{a.model}_player_model")]
    if not files: die(f"no compiled models under {root}")

    npass = nwarn = nfail = 0
    for f in sorted(files):
        label = re.sub(r'_player_model$', '', f.stem)
        d = s2v_data(s2v, f)
        # in a mixed addon, a non-tidy file whose skeleton has no body is not a
        # player model; one whose skeleton cannot be read is still checked
        if tidy and f in other and re.search(r'm_modelSkeleton', d) and not is_body(d):
            continue
        r = s2v_data(s2v, f, "RERL")
        refs = d + r
        bad, warn = [], []
        if refs.count('.vanmgrph'): bad.append("still references AnimGraph1")
        if 'animsets/' in refs: bad.append("still references a legacy animset")
        vg = refs.count('.vnmgraph')
        if vg < 3: bad.append(f"{vg} graph reference(s), expected at least 3")
        elif vg == 3: warn.append("3 graph references, not the 4 Valve ships - probably fine")
        if refs.count('.vnmskel') < 2: bad.append("fewer than 2 vnmskel refs")

        bones, hier, pos = model_skeleton(d)
        if not bones: bad.append("no m_modelSkeleton in DATA")
        # names are case-sensitive to AG2: hand_l does not bind as hand_L
        case = lambda want: next((b for b in bones if b.lower() == want.lower() and b != want), None)
        case_c = [f"{case(b)} (needs {b})" for b in CRITICAL if b not in bones and case(b)]
        case_i = [f"{case(b)} (needs {b})" for b in IMPORTANT if b not in bones and case(b)]
        miss_c = [b for b in CRITICAL if b not in bones and not case(b)]
        miss_i = [b for b in IMPORTANT if b not in bones and not case(b)]
        if case_c: bad.append("bone name case does not match the AG2 skeleton: " + ", ".join(case_c))
        if case_i: warn.append("optional bone name case does not match: " + ", ".join(case_i))
        if bones and miss_c: bad.append("missing critical bone(s): " + ", ".join(miss_c))
        if miss_i: warn.append("optional bone(s) missing: " + ", ".join(miss_i))
        if hier:
            mism = [b for b in PARENT if b in bones and PARENT[b] in bones and hier.get(b) != PARENT[b]]
            if mism: bad.append("wrong parent on: " + ", ".join(mism))
            roots = [b for b in bones if hier.get(b) == '']
            if 'root_motion' not in roots: bad.append("root_motion is not a root")
            extra = [b for b in roots if b != 'root_motion']
            if extra: warn.append("bone(s) outside root_motion, never animated: " + ", ".join(extra))
        if pos and abs(pos[2]) > abs(pos[1]):
            warn.append("pelvis [%.2f, %.2f, %.2f] - unusual orientation, check it stands upright" % tuple(pos))

        fingers = len([b for b in bones if b.startswith('finger_')])
        print(f"\n{C['b']}=== {label} ==={C['x']}")
        print(f"  core {len([b for b in CRITICAL if b in bones])}/{len(CRITICAL)}   "
              f"optional {len([b for b in IMPORTANT if b in bones])}/{len(IMPORTANT)}   fingers {fingers}   bones {len(bones)}")
        if pos: print("  pelvis [%.2f, %.2f, %.2f] (height should be the middle value)" % tuple(pos))
        if bad:
            say("  [FAIL]", 'r'); [say("     - " + b, 'r') for b in bad]; nfail += 1
        elif warn:
            say("  [PASS with warnings]", 'y'); [say("     ! " + w, 'y') for w in warn]; nwarn += 1
        else:
            say("  [PASS]", 'g'); npass += 1

    print(f"\n{C['b']}================================{C['x']}")
    print(f"PASS {npass}   WARN {nwarn}   FAIL {nfail}")
    if not nfail: say("\nNo critical failures - safe to publish.", 'g')
    return 1 if nfail else 0


def cmd_setup(a, cfg):
    cs2 = Path(cfg['cs2'])
    fails = 0
    def ok(c, m):
        nonlocal fails
        if c: say(f"  [ok]   {m}", 'g')
        else: say(f"  [FAIL] {m}", 'r'); fails += 1

    print(f"\n{C['b']}=== setup ==={C['x']}")
    ok((cs2/"game/csgo/gameinfo.gi").exists(), f"CS2 found: {cs2}")

    rc = cs2/"game/bin/win64/resourcecompiler.exe"
    if rc.exists():
        ok(True, "Workshop Tools DLC installed")
    else:
        ok(False, "Workshop Tools DLC not installed - required")
        say("         Steam Library > right-click Counter-Strike 2 > Properties", 'y')
        say("         > DLC tab > tick 'Counter-Strike 2 Workshop Tools' (~10 GB)", 'y')

    kind, runner, sroot = find_wine(cs2)
    if not kind:
        ok(False, "no wine or proton found")
        say("         resourcecompiler.exe is a Windows binary. Without wine or", 'y')
        say("         proton you can still port with --no-compile and finish on", 'y')
        say("         a Windows machine.", 'y')
        say("         apt install wine   (or dnf / pacman equivalent)", 'y')
    elif rc.exists():
        # Actually try it. resourcecompiler creates a D3D device and does GPU
        # texture encoding, so it is far from guaranteed to work under wine -
        # better to find out now than after porting 26 models.
        say("  ...  testing whether the compiler runs (this is the risky bit)", 'd')
        try:
            if kind == "proton":
                env = dict(os.environ,
                           STEAM_COMPAT_DATA_PATH=str(HOME/".ag2port-prefix"),
                           STEAM_COMPAT_CLIENT_INSTALL_PATH=str(sroot))
                Path(env["STEAM_COMPAT_DATA_PATH"]).mkdir(parents=True, exist_ok=True)
                out = subprocess.run([str(runner), "run", str(rc), "-h"],
                                     capture_output=True, text=True, timeout=180, env=env)
            else:
                out = subprocess.run([str(runner), str(rc), "-h"],
                                     capture_output=True, text=True, timeout=180)
            blob = (out.stdout or "") + (out.stderr or "")
            if re.search(r'resourcecompiler|Usage|-i <', blob, re.I):
                ok(True, f"compiler runs under {kind}")
            else:
                ok(False, f"compiler did not run correctly under {kind}")
                say("         It needs a working D3D device for texture encoding.", 'y')
                say("         Port with --no-compile and finish on Windows instead.", 'y')
                say(f"         (output was: {blob.strip()[:120]})", 'd')
        except subprocess.TimeoutExpired:
            ok(False, f"compiler timed out under {kind}")
            say("         Use --no-compile and finish on Windows.", 'y')
        except Exception as ex:
            ok(False, f"could not test the compiler: {ex}")
    else:
        say(f"  [--]   {kind} found, but no compiler to test yet", 'd')

    # gameinfo.gi
    gi = cs2/"game/csgo/gameinfo.gi"
    if gi.exists():
        txt = gi.read_text(errors='replace')
        if re.search(r'"include"\s+"characters"', txt):
            ok(True, "gameinfo.gi already has the characters include")
        else:
            # edited as raw text - same line endings and encoding, one line
            # added - so clean can take exactly that line out again
            raw = gi.read_bytes()
            bom = raw.startswith(b'\xef\xbb\xbf')
            text = raw.decode('utf-8-sig')
            nl = '\r\n' if '\r\n' in text else '\n'
            lines = re.split(r'\r?\n', text)
            idx = next((i for i,l in enumerate(lines)
                        if re.search(r'"include"\s+"maps"\s*$', l)), -1)
            if idx < 0:
                ok(False, "could not find VpkDirectories in gameinfo.gi")
                say('         add this line by hand, inside VpkDirectories, below "include" "maps":', 'y')
                say('             "include"       "characters"', 'y')
            else:
                ind = re.sub(r'"include".*$', '', lines[idx])
                lines.insert(idx+1, f'{ind}"include"       "characters"')
                try:
                    # back up what is there NOW - one from an older CS2 build
                    # would roll the file back on clean
                    Path(str(gi) + '.bak').write_bytes(raw)
                    gi.write_bytes((b'\xef\xbb\xbf' if bom else b'') + nl.join(lines).encode('utf-8'))
                    ok(True, "gameinfo.gi patched (backup at gameinfo.gi.bak)")
                except PermissionError:
                    ok(False, f"gameinfo.gi not writable - check permissions on {gi}")

    # Source2Viewer
    s2v = find_s2v()
    if s2v:
        ok(True, f"Source2Viewer-CLI at {s2v}")
    else:
        tgt = HOME/"s2v"
        say("  ...  downloading Source2Viewer-CLI", 'd')
        try:
            import urllib.request, zipfile, io
            url = ("https://github.com/ValveResourceFormat/ValveResourceFormat"
                   "/releases/latest/download/cli-linux-x64.zip")
            tgt.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(url, timeout=60) as r:
                zipfile.ZipFile(io.BytesIO(r.read())).extractall(tgt)
            exe = tgt/"Source2Viewer-CLI"
            if exe.exists():
                exe.chmod(0o755); s2v = exe
                ok(True, f"Source2Viewer-CLI installed to {tgt}")
            else:
                ok(False, "downloaded, but Source2Viewer-CLI not in the zip")
        except Exception as ex:
            ok(False, f"Source2Viewer download failed: {ex}")
            say("         grab cli-linux-x64.zip from", 'y')
            say("         https://github.com/ValveResourceFormat/ValveResourceFormat/releases", 'y')
            say(f"         and extract so {HOME}/s2v/Source2Viewer-CLI exists", 'y')
    if s2v: cfg['s2v'] = str(s2v)

    for d in (cs2/"content/csgo_addons"/a.addon, cs2/"game/csgo_addons"/a.addon):
        d.mkdir(parents=True, exist_ok=True)
    ai = cs2/"content/csgo_addons"/a.addon/"addoninfo.txt"
    if not ai.exists():
        ai.write_text('"addoninfo"\n{\n\t"addontitle"\t\t"%s"\n\t"addonauthor"\t\t""\n'
                      '\t"addonversion"\t\t"1.0"\n}\n' % a.addon)
    ok(True, f"addon '{a.addon}' folders ready")

    save_cfg(cfg)
    print()
    if fails: say(f"{fails} item(s) above need attention.\n", 'r')
    else: say("Setup complete. Next: ag2port.py list --vpk <pack.vpk>\n", 'g')
    return 1 if fails else 0


def cmd_list(a, cfg):
    models = discover(Path(cfg['s2v']), a.vpk, a.source)
    if not models: die("no player models found")
    src = a.source or Path(a.vpk).name
    print(f"\n{len(models)} models in {src}:\n")
    for m in sorted(models):
        print("  " + re.sub(r'_player_model$', '', m))
    print()
    return 0


def cmd_clean(a, cfg):
    cs2 = Path(cfg['cs2'])
    targets = [cs2/"content/csgo_addons"/a.addon, cs2/"game/csgo_addons"/a.addon]
    gi = cs2/"game/csgo/gameinfo.gi"; bak = Path(str(gi) + '.bak')

    print(f"\n{C['b']}=== paths this tool created ==={C['x']}")
    for t in targets:
        n = len(list(t.rglob('*'))) if t.exists() else 0
        print(f"  {'EXISTS  %-5d items' % n if t.exists() else 'absent':<22} {t}")
    patched = gi.exists() and re.search(r'"include"\s+"characters"', gi.read_text(errors='replace'))
    print(f"\n  gameinfo.gi: {'MODIFIED by us' if patched else 'clean'}"
          f"{', backup present' if bak.exists() else ''}")

    if not a.remove:
        print(f"\n{C['b']}Dry run.{C['x']} Re-run with --remove to delete these and restore gameinfo.gi.\n")
        return 0
    for t in targets:
        if t.exists(): shutil.rmtree(t); say(f"  removed {t}", 'g')
    if patched:
        raw = gi.read_bytes()
        bom = raw.startswith(b'\xef\xbb\xbf')
        text = raw.decode('utf-8-sig')
        nl = '\r\n' if '\r\n' in text else '\n'
        unpatched = nl.join(l for l in re.split(r'\r?\n', text) if not re.search(r'"include"\s+"characters"', l))
        norm = lambda t: t.replace('\r\n', '\n').rstrip()
        if bak.exists() and norm(bak.read_bytes().decode('utf-8-sig')) == norm(unpatched):
            shutil.copy(bak, gi); say("  restored gameinfo.gi from backup", 'g')
        else:
            # no backup, or one from an older CS2 build: take out only our line
            gi.write_bytes((b'\xef\xbb\xbf' if bom else b'') + unpatched.encode('utf-8'))
            say("  removed the characters include from gameinfo.gi", 'g')
        if bak.exists(): bak.unlink()
    print()
    return 0


def main():
    p = argparse.ArgumentParser(prog='ag2port.py',
        description='Port pre-AnimGraph2 CS2 player models. Linux.')
    p.add_argument('--cs2', help='path to the Counter-Strike Global Offensive folder')
    p.add_argument('--addon', default='ag2port', help='addon name (default: ag2port)')
    sub = p.add_subparsers(dest='cmd', required=True)

    sp = sub.add_parser('setup', help='one-time setup')
    sp.set_defaults(fn=cmd_setup)

    for name, fn, helptext in (('list', cmd_list, 'list models in a pack'),
                               ('port', cmd_port, 'port models')):
        s = sub.add_parser(name, help=helptext)
        s.add_argument('--vpk', help='a .vpk file')
        s.add_argument('--pack', help='workshop id you are subscribed to')
        s.add_argument('--source', help='folder of loose .vmdl_c files')
        if name == 'port':
            s.add_argument('--model', help='one model by name')
            s.add_argument('--all', action='store_true', help='every model')
            s.add_argument('--force', action='store_true', help='re-port already-compiled models')
            s.add_argument('--keep-ag1', action='store_true',
                           help='keep MovementSettings/Feet/character_arm_config')
            s.add_argument('--no-compile', action='store_true',
                           help='prepare sources but skip the compile (hand off to Windows)')
        s.set_defaults(fn=fn)

    s = sub.add_parser('verify', help='check compiled models before publishing')
    s.add_argument('--model'); s.add_argument('--all', action='store_true')
    s.set_defaults(fn=cmd_verify)

    s = sub.add_parser('clean', help='remove everything this tool added')
    s.add_argument('--remove', action='store_true', help='actually delete')
    s.set_defaults(fn=cmd_clean)

    a = p.parse_args()
    cfg = load_cfg()

    cs2 = Path(a.cs2) if a.cs2 else (Path(cfg['cs2']) if cfg.get('cs2') else find_cs2())
    if not cs2 or not (cs2/"game/csgo/gameinfo.gi").exists():
        die("could not find CS2. pass --cs2 /path/to/Counter-Strike Global Offensive")
    cfg['cs2'] = str(cs2)

    if a.cmd != 'setup':
        s2v = Path(cfg['s2v']) if cfg.get('s2v') else find_s2v()
        if not s2v: die("Source2Viewer-CLI not found. run: ag2port.py setup")
        cfg['s2v'] = str(s2v)

    # a workshop id resolves to a vpk under the Steam library
    if getattr(a, 'pack', None) and not getattr(a, 'vpk', None):
        for base in (cs2.parent.parent, HOME/".steam/steam/steamapps",
                     HOME/".local/share/Steam/steamapps"):
            d = Path(base)/"workshop/content/730"/a.pack
            if d.exists():
                v = sorted(d.glob('*_dir.vpk')) or sorted(d.glob('*.vpk'))
                if v: a.vpk = str(v[0]); break
        if not getattr(a, 'vpk', None):
            die(f"pack {a.pack} not downloaded. subscribe and launch CS2 once, "
                "or use --vpk / --source with a local copy")

    # split archives must be addressed through the _dir index
    if getattr(a, 'vpk', None) and not a.vpk.endswith('_dir.vpk'):
        cand = re.sub(r'_\d{3}\.vpk$', '_dir.vpk', a.vpk)
        if cand != a.vpk and Path(cand).exists(): a.vpk = cand

    save_cfg(cfg)
    sys.exit(a.fn(a, cfg))


if __name__ == '__main__':
    main()
