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
CRITICAL = ['root_motion','pelvis','spine_0','spine_1','spine_2','spine_3','neck_0','head_0',
            'clavicle_L','clavicle_R','arm_upper_L','arm_upper_R','arm_lower_L','arm_lower_R',
            'hand_L','hand_R','leg_upper_L','leg_upper_R','leg_lower_L','leg_lower_R',
            'ankle_L','ankle_R','wpnPivot','wpn']
IMPORTANT = ['ball_L','ball_R']
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
CANON_SIDED = [b for b in PARENT if b.endswith(('_L','_R'))]

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
    pp = re.search(r'm_bonePosParent\s*=\s*\[(.*?)\n\t\t\]', text, re.S)
    if pp and 'pelvis' in bones:
        v = re.findall(r'\[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]', pp.group(1))
        i = bones.index('pelvis')
        if i < len(v): pos = [float(x) for x in v[i]]
    return bones, hier, pos


# ── ModelDoc source editing ──────────────────────────────────────────────────
def angle_matrix(p, y, r):
    p, y, r = map(math.radians, (p, y, r))
    sp, cp = math.sin(p), math.cos(p)
    sy, cy = math.sin(y), math.cos(y)
    sr, cr = math.sin(r), math.cos(r)
    return [[cp*cy, sr*sp*cy-cr*sy, cr*sp*cy+sr*sy],
            [cp*sy, sr*sp*sy+cr*cy, cr*sp*sy-sr*cy],
            [-sp,   sr*cp,          cr*cp]]


def to_root_motion_space(origin, angles):
    """root_motion sits at [0,90,90] in every model seen, and its matrix is the
    permutation [[0,0,1],[1,0,0],[0,1,0]]. Re-express a former root in that
    space: origin cycles, angles get the transpose applied (a row cycle).
    Skip this and the model compiles perfectly and comes out on its side."""
    m = angle_matrix(*angles)
    n = [m[1], m[2], m[0]]
    d = 180.0/math.pi
    yaw   = math.atan2(n[1][0], n[0][0]) * d
    pitch = math.atan2(-n[2][0], math.hypot(n[0][0], n[1][0])) * d
    roll  = math.atan2(n[2][1], n[2][2]) * d
    return [origin[1], origin[2], origin[0]], [pitch, yaw, roll]


def find_block(lines, idx):
    """Given the index of a '_class = ...' line, return (start, end) of the
    enclosing { ... } object, inclusive."""
    s = idx
    while s >= 0 and lines[s].strip() != '{': s -= 1
    depth, e = 0, s
    while e < len(lines):
        depth += lines[e].count('{') - lines[e].count('}')
        if depth == 0: return s, e
        e += 1
    raise RuntimeError("unbalanced braces")


AG2_NODES = '''{i}{{
{i}\t_class = "NmSkeletonList"
{i}\tchildren = 
{i}\t[
{i}\t\t{{
{i}\t\t\t_class = "NmSkeletonReference"
{i}\t\t\tfilename = "animation/skeletons/characters/worldmodel.vnmskel"
{i}\t\t}},
{i}\t\t{{
{i}\t\t\t_class = "NmSkeletonReference"
{i}\t\t\tfilename = "animation/skeletons/characters/viewmodel.vnmskel"
{i}\t\t}},
{i}\t]
{i}}},
{i}{{
{i}\t_class = "AnimGraph2List"
{i}\tchildren = 
{i}\t[
{i}\t\t{{
{i}\t\t\t_class = "DefaultAnimGraph2"
{i}\t\t\tfilename = "animation/graphs/worldmodel/worldmodel.vnmgraph"
{i}\t\t}},
{i}\t\t{{
{i}\t\t\t_class = "AnimGraph2"
{i}\t\t\tname = "uimodel"
{i}\t\t\tfilename = "animation/graphs/ui/uimodel.vnmgraph"
{i}\t\t}},
{i}\t\t{{
{i}\t\t\t_class = "AnimGraph2"
{i}\t\t\tname = "hudmodel"
{i}\t\t\tfilename = "animation/graphs/viewmodel/viewmodel.vnmgraph"
{i}\t\t}},
{i}\t\t{{
{i}\t\t\t_class = "AnimGraph2"
{i}\t\t\tname = "worldmodel"
{i}\t\t\tfilename = "animation/graphs/worldmodel/worldmodel.vnmgraph"
{i}\t\t}},
{i}\t]
{i}}},
'''

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


def port_vmdl(path: Path, strip_ag1=True, add_phys=True):
    """Apply every AG2 edit to a decompiled ModelDoc source, in place."""
    L = path.read_text(encoding='utf-8', errors='replace').split('\n')
    log = []

    # ---- 1. re-parent pelvis under root_motion, converting its transform ----
    # Physics shapes and attachments carry their own name fields, often reusing
    # bone names. Only ever match an actual Bone node.
    def find_bone(name, lines=None):
        lines = lines if lines is not None else L
        for i in range(1, len(lines)):
            if '_class = "Bone"' in lines[i-1] and re.match(rf'^\s*name = "{name}"\s*$', lines[i]):
                return i
        return None
    pel = find_bone('pelvis')
    rm  = find_bone('root_motion')
    if pel is not None and rm is not None:
        ind_p = len(L[pel]) - len(L[pel].lstrip('\t'))
        ind_r = len(L[rm])  - len(L[rm].lstrip('\t'))
        if ind_p == ind_r:                       # both are roots -> needs the move
            rm_ang = None
            for i in range(rm, min(rm+6, len(L))):
                m = re.search(r'angles = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]', L[i])
                if m: rm_ang = [float(x) for x in m.groups()]; break
            if rm_ang and abs(rm_ang[0]) < .01 and abs(rm_ang[1]-90) < .01 and abs(rm_ang[2]-90) < .01:
                ps, pe = find_block(L, pel)
                oi = ai = -1; po = pa = None
                for i in range(pel, min(pel+8, pe)):
                    mo = re.search(r'origin = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]', L[i])
                    if mo and oi < 0: oi, po = i, [float(x) for x in mo.groups()]
                    ma = re.search(r'angles = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]', L[i])
                    if ma and ai < 0: ai, pa = i, [float(x) for x in ma.groups()]
                if oi >= 0 and ai >= 0:
                    no, na = to_root_motion_space(po, pa)
                    L[oi] = re.sub(r'origin = \[[^\]]*\]',
                                   'origin = [ %.6f, %.6f, %.6f ]' % tuple(no), L[oi])
                    L[ai] = re.sub(r'angles = \[[^\]]*\]',
                                   'angles = [ %.6f, %.6f, %.6f ]' % tuple(na), L[ai])
                    log.append("pelvis transform -> origin [%.4f, %.4f, %.4f]" % tuple(no))
                ps, pe = find_block(L, pel)
                block = ['\t' + x for x in L[ps:pe+1]]
                del L[ps:pe+1]
                rm = find_bone('root_motion')
                ind = L[rm][:len(L[rm]) - len(L[rm].lstrip('\t'))]
                k = -1
                for i in range(rm+1, len(L)):
                    if L[i].strip() == 'children =' and L[i][:len(L[i])-len(L[i].lstrip('\t'))] == ind:
                        k = i; break
                if k >= 0:
                    L[k+2:k+2] = block
                    log.append("pelvis re-parented under root_motion")
            else:
                log.append("!! root_motion angles unexpected - transform skipped")

    text = '\n'.join(L)

    # ---- 2. case flip, only for canonical bones, with the DMX ---------------
    pairs = []
    for i, l in enumerate(L):
        if i < 1 or '_class = "Bone"' not in L[i-1]: continue
        m = re.match(r'^\s*name = "([A-Za-z0-9_]+)"', l)
        if not m: continue
        n = m.group(1)
        c = re.sub(r'_twist1$', '_TWIST1', n)
        c = re.sub(r'_twist$', '_TWIST', c)
        c = re.sub(r'_l$', '_L', c); c = re.sub(r'_r$', '_R', c)
        if c != n and c in CANON_SIDED:
            L[i] = l.replace(f'"{n}"', f'"{c}"')
            pairs.append((n, c))
    if pairs:
        log.append(f"case-flipped {len(pairs)} bone name(s)")
        # attachments / hitboxes / physics reference bones by name too
        fields = r'parent_bone|bone|bone_name|anklebone|toebone|start_bone|end_bone'
        fixed = 0
        for i, l in enumerate(L):
            m = re.match(rf'^\s*({fields}) = "([A-Za-z0-9_]+)"', l)
            if not m: continue
            for o, c in pairs:
                if m.group(2) == o:
                    L[i] = l.replace(f'"{o}"', f'"{c}"'); fixed += 1; break
        if fixed: log.append(f"repointed {fixed} bone reference(s)")
        # the mesh binds by name through the DMX jointList. Length-preserving,
        # so patch the string table in place or the mesh detaches.
        n_dmx = 0
        for dmx in path.parent.glob('*.dmx'):
            b = dmx.read_bytes(); orig = b
            for o, c in pairs:
                b = b.replace(b'\x00' + o.encode() + b'\x00', b'\x00' + c.encode() + b'\x00')
            if b != orig: dmx.write_bytes(b); n_dmx += 1
        log.append(f"patched {n_dmx} DMX file(s)" if n_dmx else "!! no DMX patched")

    # ---- 3. Feet references that no longer resolve -------------------------
    skel = [re.match(r'^\s*name = "([A-Za-z0-9_]+)"', L[i]).group(1)
            for i in range(1, len(L))
            if '_class = "Bone"' in L[i-1] and re.match(r'^\s*name = "([A-Za-z0-9_]+)"', L[i])]
    ff = 0
    for i, l in enumerate(L):
        m = re.match(r'^\s*(anklebone|toebone) = "([A-Za-z0-9_]+)"', l)
        if not m: continue
        b = m.group(2)
        if b in skel: continue
        alt = next((s for s in skel if s.lower() == b.lower()), None)
        if alt: L[i] = l.replace(f'"{b}"', f'"{alt}"'); ff += 1
    if ff: log.append(f"corrected {ff} Feet reference(s)")

    # ---- 4. drop the AnimGraph1 binding ------------------------------------
    before = len(L)
    L = [l for l in L if not ('anim_graph_name' in l and 'vanmgrph' in l)]
    if len(L) != before: log.append("removed anim_graph_name")

    while True:
        hit = next((i for i,l in enumerate(L) if '_class = "AnimIncludeModel"' in l
                    and any('animsets/' in L[j] for j in range(i, min(i+4, len(L))))), None)
        if hit is None: break
        s, e = find_block(L, hit); del L[s:e+1]
        log.append("removed AnimIncludeModel")

    # ---- 5. add the AG2 node lists -----------------------------------------
    if 'AnimGraph2List' not in '\n'.join(L):
        sk = next((i for i,l in enumerate(L) if '_class = "Skeleton"' in l), None)
        if sk is None: raise RuntimeError("no Skeleton node")
        s, _ = find_block(L, sk)
        ind = L[s][:len(L[s]) - len(L[s].lstrip('\t'))]
        L[s:s] = AG2_NODES.format(i=ind).rstrip('\n').split('\n')
        log.append("inserted NmSkeletonList + AnimGraph2List")

    # ---- 6. graft wpnPivot -> wpn ------------------------------------------
    if 'wpnPivot' not in '\n'.join(L):
        rm = next((i for i in range(1, len(L))
                   if '_class = "Bone"' in L[i-1]
                   and re.match(r'^\s*name = "root_motion"\s*$', L[i])), None)
        if rm is not None:
            ind = L[rm][:len(L[rm]) - len(L[rm].lstrip('\t'))]
            k = next((i for i in range(rm+1, len(L))
                      if L[i].strip() == 'children =' and
                         L[i][:len(L[i])-len(L[i].lstrip('\t'))] == ind), None)
            if k is not None:
                bi = L[k+1][:len(L[k+1]) - len(L[k+1].lstrip('\t'))] + '\t'
                L[k+2:k+2] = WPN_BONES.format(i=bi).rstrip('\n').split('\n')
                log.append("grafted wpnPivot/wpn")

    # ---- 7. name any empty BodyGroupChoice ---------------------------------
    fixed = 0
    for i in range(len(L)-1, -1, -1):
        if '_class = "BodyGroupChoice"' not in L[i]: continue
        s, e = find_block(L, i)
        seg = '\n'.join(L[i:e+1])
        if re.search(r'^\s*name = ', seg, re.M): continue
        mesh = re.search(r'"([^"]+)"\s*,', seg)
        ind = L[i][:len(L[i]) - len(L[i].lstrip('\t'))]
        L.insert(i+1, f'{ind}name = "{mesh.group(1) if mesh else "choice"}"')
        fixed += 1
    if fixed: log.append(f"named {fixed} BodyGroupChoice entries")

    # ---- 8. strip AnimGraph1-era nodes -------------------------------------
    if strip_ag1:
        removed = 0
        for cls in ('MovementSettings', 'Feet'):
            while True:
                hit = next((i for i,l in enumerate(L) if f'_class = "{cls}"' in l), None)
                if hit is None: break
                s, e = find_block(L, hit); del L[s:e+1]; removed += 1
        while True:
            hit = next((i for i,l in enumerate(L) if 'game_class = "character_arm_config"' in l), None)
            if hit is None: break
            s, e = find_block(L, hit); del L[s:e+1]; removed += 1
        if removed: log.append(f"stripped {removed} AnimGraph1-era node(s)")

    # ---- 9. physics body markup --------------------------------------------
    if add_phys and 'CPhysicsBodyGameMarkupData' not in '\n'.join(L):
        gd = next((i for i,l in enumerate(L) if '_class = "GameDataList"' in l), None)
        if gd is not None:
            k = next((i for i in range(gd+1, min(gd+6, len(L)))
                      if L[i].strip() == 'children ='), None)
            if k is not None:
                ind = L[k][:len(L[k]) - len(L[k].lstrip('\t'))] + '\t'
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

    out = '\n'.join(L)
    if out.count('{') != out.count('}') or out.count('[') != out.count(']'):
        raise RuntimeError(f"brace mismatch {{{out.count('{')}/{out.count('}')}}} "
                           f"[{out.count('[')}/{out.count(']')}] - refusing to write")
    shutil.copy(path, str(path) + '.bak')
    path.write_text(out, encoding='utf-8')
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
        m = re.search(re.escape(key) + r'\s*=\s*\n?\s*\[(.*?)\n\t\]', t, re.S)
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
def discover(s2v, vpk=None, source=None):
    """Returns {name: {'root': path, 'file': Path|None}}."""
    out = {}
    if source:
        for f in Path(source).rglob('*.vmdl_c'):
            d = s2v_data(s2v, f)
            mn = re.search(r'm_name\s*=\s*"([^"]+)"', d)
            if not mn or 'm_modelSkeleton' not in d: continue
            intern = re.sub(r'\.vmdl$', '', mn.group(1))
            out[Path(intern).name] = {'root': str(Path(intern).parent.parent), 'file': f}
    else:
        if not Path(vpk).exists():
            die(f"vpk not found: {vpk}")
        listing = run([s2v, "-i", vpk, "-l", "-e", "vmdl_c"])
        for m in re.finditer(r'([a-zA-Z0-9_/]+)/([a-zA-Z0-9_]+)/\2\.vmdl_c', listing):
            out[m.group(2)] = {'root': m.group(1), 'file': None}
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

    ok, bad = [], []
    started = time.time()
    for n, m in enumerate(todo, 1):
        label = re.sub(r'_player_model$', '', m)
        print(f"\n{C['b']}=== [{n}/{len(todo)}] {label} ==={C['x']}")
        try:
            root = models[m]['root']
            d = out_root/root/m
            vmdl = d/f"{m}.vmdl"
            mat = d/"materials"
            done = cs2/"game/csgo_addons"/a.addon/root/m/f"{m}.vmdl_c"
            if done.exists() and not a.force:
                say("  already compiled - skipping (--force to redo)", 'd'); ok.append(m); continue

            print("  extracting...")
            if a.source:
                run([s2v, "-i", models[m]['file'], "-o", vmdl, "-d"])
                src_mat = models[m]['file'].parent/"materials"
                if src_mat.exists():
                    mat.mkdir(parents=True, exist_ok=True)
                    for f in src_mat.iterdir():
                        if f.is_file(): shutil.copy(f, mat/f.name)
            else:
                run([s2v, "-i", a.vpk, "-o", out_root, "-f", f"{root}/{m}/", "-d"])
            if not vmdl.exists(): raise RuntimeError("no .vmdl produced")

            have_vmat = list(mat.glob('*.vmat')) if mat.exists() else []
            if not have_vmat:
                print("  no .vmat from decompile - rebuilding from compiled data")
                if not a.source:
                    run([s2v, "-i", a.vpk, "-o", out_root, "-f", f"{root}/{m}/", "-e", "vmat_c"])
                nr = sum(rebuild_vmat(s2v, v) for v in mat.glob('*.vmat_c')) if mat.exists() else 0
                print(f"  rebuilt {nr} material(s)")
                if nr == 0: raise RuntimeError("could not rebuild any materials")

            for stray in d.rglob('*_c'):
                if stray.is_file(): stray.unlink()

            ren, fx = fix_materials(mat)
            print(f"  materials: {fx} fixed, {ren} textures renamed")

            for line in port_vmdl(vmdl, strip_ag1=not a.keep_ag1):
                print(f"  {line}")

            txt = vmdl.read_text(errors='replace')
            counts = {k: txt.count(k) for k in ('vanmgrph', 'vnmgraph', 'wpnPivot', 'vnmskel')}
            print("  counts  " + " ".join(f"{k}={v}" for k, v in counts.items()) +
                  "  (want 0 4 1 2)")
            if counts['vanmgrph'] or counts['vnmgraph'] != 4:
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
            sz = done.stat().st_size if done.exists() else '?'
            say(f"  OK  {sz} bytes", 'g')
            ok.append(m)
        except Exception as ex:
            say(f"  FAILED: {ex}", 'r'); bad.append(f"{label} ({ex})")

    el = time.time() - started
    print(f"\n{C['b']}================ SUMMARY ================{C['x']}")
    verb = "prepared" if not kind else "ported"
    print(f"{verb} : {len(ok)}   failed : {len(bad)}   took : {int(el//60)}m{int(el%60):02d}s")
    for b in bad: say("   " + b, 'r')
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
    files = [f for f in root.rglob('*.vmdl_c') if f.stem == f.parent.name]
    if a.model:
        files = [f for f in files if f.stem in (a.model, f"{a.model}_player_model")]
    if not files: die(f"no compiled models under {root}")

    npass = nwarn = nfail = 0
    for f in sorted(files):
        label = re.sub(r'_player_model$', '', f.stem)
        d = s2v_data(s2v, f); r = s2v_data(s2v, f, "RERL")
        refs = d + r
        bad, warn = [], []
        if refs.count('.vanmgrph'): bad.append("still references AnimGraph1")
        if 'animsets/' in refs: bad.append("still references a legacy animset")
        if refs.count('.vnmgraph') < 4: bad.append("fewer than 4 vnmgraph refs")
        if refs.count('.vnmskel') < 2: bad.append("fewer than 2 vnmskel refs")

        bones, hier, pos = model_skeleton(d)
        missC = [b for b in CRITICAL if b not in bones]
        missI = [b for b in IMPORTANT if b not in bones]
        if missC: bad.append("missing critical bone(s): " + ", ".join(missC))
        if missI: warn.append("no toe bones: " + ", ".join(missI))
        if hier:
            mism = [b for b in PARENT if b in bones and hier.get(b) != PARENT[b]]
            if mism: bad.append("wrong parent on: " + ", ".join(mism))
            if 'root_motion' not in [b for b in bones if hier.get(b) == '']:
                bad.append("root_motion is not a root")
        if pos and abs(pos[2]) > abs(pos[1]):
            bad.append(f"pelvis {pos} is Z-up - not converted into root_motion space, "
                       "model will be rotated")

        fingers = len([b for b in bones if b.startswith('finger_')])
        print(f"\n{C['b']}=== {label} ==={C['x']}")
        print(f"  core {len(CRITICAL)-len(missC)}/{len(CRITICAL)}   "
              f"toes {len(IMPORTANT)-len(missI)}/2   fingers {fingers}   bones {len(bones)}")
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
            bak = Path(str(gi) + '.bak')
            if not bak.exists(): shutil.copy(gi, bak)
            lines = txt.split('\n')
            idx = next((i for i,l in enumerate(lines)
                        if re.search(r'"include"\s+"maps"\s*$', l)), -1)
            if idx < 0:
                ok(False, "could not find VpkDirectories - add the include by hand")
            else:
                ind = re.sub(r'"include".*$', '', lines[idx])
                lines.insert(idx+1, f'{ind}"include"       "characters"')
                try:
                    gi.write_text('\n'.join(lines))
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
        if bak.exists():
            shutil.copy(bak, gi); bak.unlink(); say("  restored gameinfo.gi from backup", 'g')
        else:
            keep = [l for l in gi.read_text(errors='replace').split('\n')
                    if not re.search(r'"include"\s+"characters"', l)]
            gi.write_text('\n'.join(keep)); say("  removed the characters include", 'y')
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
