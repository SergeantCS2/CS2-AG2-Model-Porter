"""
Rename a mesh's vertex groups from one skeleton's bone names to another's,
using a two-column map such as valvebiped_to_cs2.txt. Part of the re-rig step
in PORTING-OTHER-GAMES.md; it does not touch armatures or geometry.

    blender yourfile.blend --python tools/blender_remap_weights.py -- valvebiped_to_cs2.txt

or open it in Blender's Text Editor, set MAP_FILE below, select the mesh(es)
and Run Script.

For each vertex group named in the map:
  - if no group with the new name exists yet, it is renamed;
  - if one does (a helper bone mapped onto a main bone), its weights are
    added into that group and the helper group removed.
Groups not in the map are left alone and listed, so nothing changes silently.
Afterwards run Weights > Normalize All on the mesh.
"""
import os
import sys

import bpy

MAP_FILE = ""   # optional: full path to the map when run from the Text Editor


def find_map():
    if "--" in sys.argv:
        args = sys.argv[sys.argv.index("--") + 1:]
        if args:
            return args[0]
    if MAP_FILE:
        return MAP_FILE
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else ""
    for cand in (os.path.join(here, "..", "valvebiped_to_cs2.txt"), os.path.join(here, "valvebiped_to_cs2.txt")):
        if os.path.isfile(cand):
            return cand
    raise SystemExit("map file not found - pass it after '--' or set MAP_FILE")


def load_map(path):
    mapping = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                mapping[parts[0]] = parts[1]
    return mapping


def remap(obj, mapping):
    renamed, merged, unmapped = [], [], []
    for group in list(obj.vertex_groups):
        target_name = mapping.get(group.name)
        if target_name is None:
            if group.name not in mapping.values():
                unmapped.append(group.name)
            continue
        target = obj.vertex_groups.get(target_name)
        if target is None:
            renamed.append(f"{group.name} -> {target_name}")
            group.name = target_name
            continue
        index = group.index
        for vert in obj.data.vertices:
            for g in vert.groups:
                if g.group == index and g.weight > 0.0:
                    target.add([vert.index], g.weight, "ADD")
        merged.append(f"{group.name} -> {target_name}")
        obj.vertex_groups.remove(group)
    return renamed, merged, unmapped


def main():
    path = find_map()
    mapping = load_map(path)
    meshes = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    if not meshes:
        meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    print(f"\nremapping vertex groups with {os.path.basename(path)} ({len(mapping)} entries)")
    for obj in meshes:
        renamed, merged, unmapped = remap(obj, mapping)
        print(f"\n{obj.name}: {len(renamed)} renamed, {len(merged)} merged")
        for line in merged:
            print(f"   merged  {line}")
        if unmapped:
            print(f"   NOT in the map, left as they are: {', '.join(sorted(unmapped))}")
    print("\nnext: Weights > Normalize All, then bind to the CS2 armature")


if __name__ == "__main__":
    main()
