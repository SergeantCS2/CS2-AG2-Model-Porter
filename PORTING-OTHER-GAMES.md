# Porting models from other games

The porter repairs **CS2** player models: compiled `.vmdl_c` files from a
Workshop pack, a `.vpk`, or a loose folder. Models from other Source games can
be brought to CS2 too, but they need converting first, and for most games that
means a re-rig in Blender. This page covers what works, what doesn't, and the
exact route for each.

> [!IMPORTANT]
> The same rules apply as for any pack — see the README. Many Garry's Mod
> playermodels are themselves ports of characters from commercial games, so
> the person who uploaded one may not have had the right to share it either.
> Ask before you publish, and keep it to your own server if you can't.

## What is supported

| source | files | what you do | what this tool does |
|---|---|---|---|
| CS2, pre-AnimGraph2 | `.vmdl_c` | nothing | everything — this is what it was built for |
| CS:GO player models | `.mdl` | convert to a CS2 model | compile, verify |
| Garry's Mod, SFM, HL2, TF2 | `.mdl` | convert, **re-rig in Blender** | compile, verify |
| Other Source 2 games (HL:A, Deadlock, s&box) | `.vmdl_c` | re-rig in Blender | compile, verify |

The tool can't do the re-rig for you, and no script can do it reliably.
Everything before it and after it is either a standard community tool or this
tool.

## Why a re-rig is needed

AnimGraph2 drives a **fixed skeleton**: CS2's `worldmodel.vnmskel`, 74 bones
rooted at `root_motion`, listed in [`canonical_skeleton.txt`](canonical_skeleton.txt).
A model animates when its bones match those **by name** (case-sensitively:
`hand_L`, never `hand_l`) **and** sit in the same rest pose, so a rotation
authored for CS2's forearm turns your forearm the same way.

The community CS2 packs this tool was built on were rigged on CS2's own
skeleton. Every canonical bone sits within 0.73 units of Valve's agents, which
is why those can be fixed with text edits ([NOTES.md](NOTES.md)). A model rigged
for another game has neither property:

- **Different names.** Garry's Mod uses Valve's HL2 skeleton, *ValveBiped*:
  `ValveBiped.Bip01_L_Forearm` where CS2 has `arm_lower_L`. Renaming is easy
  ([`valvebiped_to_cs2.txt`](valvebiped_to_cs2.txt) has the full map).
- **A different rest pose and different bone axes.** This is the part
  renaming can't fix. Bind a renamed ValveBiped mesh straight to CS2's skeleton
  and every limb twists, because the animation rotates each bone around CS2's
  axes, not the ones the mesh was weighted against.

The fix is the standard modder's re-rig. Pose the old mesh to match CS2's rest
pose, then bind it to CS2's skeleton.

## CS:GO player models

CS2's skeleton is CS:GO's. Agent-era CS:GO player models (bones named
`pelvis`, `spine_0`…`spine_3`, `clavicle_L`, `hand_L`, `ankle_L` and so on) are
usually rigged on the right skeleton already, so no re-rig is needed.

1. Decompile the `.mdl` with [Crowbar](https://steamcommunity.com/groups/CrowbarTool)
   (*Decompile* tab) to get its meshes as SMD and its `.qc`. Open the reference
   SMD in a text editor and check the bone names against
   [`canonical_skeleton.txt`](canonical_skeleton.txt). If they are ValveBiped
   names instead, follow the Garry's Mod route below.
2. Build a CS2 model from those meshes with steps 3, 5, 6 and 7 below (template,
   materials, assemble, compile). Skip the Blender re-rig. Just export the
   reference mesh to DMX, or use the SMD directly if ModelDoc accepts it for
   your file.
3. Check that the mesh really binds. Verify checks the model's structure, but
   with the template that structure is Valve's, so it passes regardless. The
   mesh binding shows in the compile log (`Port-Model.ps1` prints its path): a
   mesh joint with no matching skeleton bone is reported there. The final word
   is a local server. If limbs twist, the rest pose differs and the model needs
   the re-rig after all.

The community tool [source1import](https://github.com/kristiker/source1import)
can convert CS:GO materials (`.vmt`/`.vtf`) and `.qc` files to their Source 2
equivalents and may save some of this work. It is a separate project, not
part of this tool and not tested with it.

## Garry's Mod, SFM, HL2 and TF2 playermodels (ValveBiped)

You'll need, all free:

- **[Crowbar](https://steamcommunity.com/groups/CrowbarTool)** to unpack
  `.gma` files and decompile `.mdl`
- **[Blender](https://www.blender.org/)** with
  **[Blender Source Tools](http://steamreview.org/BlenderSourceTools/)** to
  import SMD/DMX and export DMX
- **VTFEdit** (or any VTF converter) for textures
- this tool, already set up (menu option 1), and the CS2 Workshop Tools

### 1. Get the files out

Garry's Mod Workshop items are `.gma` archives. If you're subscribed, they're
in `steamapps\workshop\content\4000\<id>\`; older items may be in
`garrysmod\cache\workshop\`. Unpack with Crowbar's *Unpack* tab, or with the
`gmad.exe` that ships with Garry's Mod:

```bat
"<Steam>\steamapps\common\GarrysMod\bin\gmad.exe" extract -file "<path>\item.gma"
```

A playermodel is a group of files under `models\` (`.mdl`, `.vvd`, `.vtx`,
`.phy`) plus its `materials\` (`.vmt`, `.vtf`). An item that has been removed
from the Workshop can no longer be downloaded, so this only works if you still
have a copy.

### 2. Decompile the model

In Crowbar's *Decompile* tab, point it at the playermodel's `.mdl`. You get a
`.qc`, a reference mesh SMD (sometimes several, one per bodygroup) and a
physics SMD. Open the reference SMD in a text editor: the bone list at the top
should read `ValveBiped.Bip01_Pelvis`, `ValveBiped.Bip01_Spine`… If it
doesn't, the model uses its own skeleton and the bone map won't fit. You'll
have to match bones by eye in step 4.

### 3. Get CS2's skeleton, from your own install

The re-rig needs CS2's skeleton in its rest pose, and the easiest source is
one of Valve's agents. Both commands read your local CS2 install, and nothing
of Valve's is redistributed. Find an agent's model path:

```bat
"%USERPROFILE%\s2v\Source2Viewer-CLI.exe" -i "<CS2>\game\csgo\pak01_dir.vpk" -l -e vmdl_c | findstr /i ctm_fbi
```

Then decompile it, using the path from that list, into a scratch folder:

```bat
"%USERPROFILE%\s2v\Source2Viewer-CLI.exe" -i "<CS2>\game\csgo\pak01_dir.vpk" -f "<path from the list>" -d -o C:\ag2-template
```

That gives you a `.vmdl` (the ModelDoc source) and its `.dmx` meshes. The
`.vmdl` already has everything AnimGraph2 needs: the skeleton, both
AnimGraph2 lists, hitboxes, physics and weapon attachments. Step 6 reuses it
as the template for your model.

### 4. Re-rig in Blender

1. **Import both.** With Blender Source Tools, import the GMod reference SMD
   (step 2) and the agent's body DMX (step 3). You now have two armatures. Hide
   the agent's mesh; you only need its armature.
2. **Line them up.** Both games use the same units, so a playermodel is
   usually close to the agent's size already. Move and scale the GMod mesh and
   armature *together* until feet, hips and head line up with the agent's.
3. **Match the rest pose.** Pose the GMod armature (Pose Mode) so every limb
   points the same way as the agent's: arm angle, elbow bend, leg spread,
   fingers. Then, on the GMod mesh, apply the Armature modifier to bake that
   pose into the mesh. This is the step that decides whether limbs twist in
   game; take your time on the arms and hands.
4. **Rename the weights.** Select the GMod mesh and run the helper that ships
   with this tool:
   ```bat
   blender yourfile.blend --python tools\blender_remap_weights.py -- valvebiped_to_cs2.txt
   ```
   It renames every ValveBiped vertex group to its CS2 bone, merges helper
   bones (ulna, bicep, trapezius…) into the bone they sit on, and lists
   anything it didn't recognise. Then run *Weights → Normalize All*.
5. **Bind to CS2's skeleton.** Delete the GMod armature. Give the mesh an
   Armature modifier pointing at the agent's armature. The renamed vertex
   groups now bind it to CS2's bones. Pose the agent armature to check: limbs
   should bend cleanly.
6. **Export** the mesh as DMX with Blender Source Tools.

### 5. Materials

Convert each `.vtf` to `.tga` or `.png` (VTFEdit: *Tools → Convert Folder*). For
each material write a small `.vmat` using CS2's character shader. The
`$basetexture` from the `.vmt` becomes the colour texture, and `$bumpmap`
becomes the normal map:

```
Layer0
{
	shader "csgo_character.vfx"
	TextureColor "characters/models/<addon>/<name>/materials/body_color.tga"
	TextureNormal "characters/models/<addon>/<name>/materials/body_normal.tga"
}
```

Paths are relative to your addon's content folder. Source 1 normal maps were
authored for a different engine; if bumps look lit from the wrong side in game,
flip the normal map's green channel. Transparent parts (`$alphatest`,
`$translucent` in the `.vmt`) need the matching option set in the Material
Editor.

### 6. Assemble the model in your addon

Copy the template `.vmdl` from step 3 into your addon under a path of your own.
**Never** use Valve's path: a file there would replace Valve's agent for
everyone on your server.

```
<CS2>\content\csgo_addons\<addon>\characters\models\<addon>\<name>\<name>.vmdl
                                                              \<name>_body.dmx      <- from step 4
                                                              \materials\...        <- from step 5
```

Keep it under `characters\`. That's the folder Setup's `gameinfo.gi` line adds
to the published VPK.

Open the `.vmdl` in ModelDoc (Workshop Tools) or a text editor and:

- point the `RenderMeshFile` at your DMX, and delete the agent's other meshes
  and bodygroup choices
- remap the agent's materials to yours in the material group
- **leave** the Skeleton, `NmSkeletonList`, `AnimGraph2List`, attachments,
  hitboxes and physics alone. They are what make it a working CS2 player
  model. Hitboxes and physics are sized for Valve's agent, which is fine for a
  similar-sized character.

### 7. Compile and verify with this tool

```powershell
.\Port-Model.ps1   -CompileOnly -Addon <addon>
.\Verify-Model.ps1 -Model <name> -Addon <addon>
```

`-CompileOnly` compiles every prepared model in the addon, yours included,
without re-extracting anything. Verify checks the bone names, parents and
AnimGraph2 references exactly as it does for a ported pack. Don't publish
anything that fails. A pass means the model is *built* right; whether the mesh
follows the skeleton well is down to the re-rig, and only shows in game.

### 8. Test, then publish

As for any ported model: run it on a local server first (README, *Testing it*),
then publish from the Workshop Manager and add the ID to `mm_extra_addons`.

## When it doesn't look right

| symptom | cause |
|---|---|
| T-pose, but Verify passes | delivery, not the model — see the README's *Still T-posing* |
| limbs twisted or bent backwards when animating | rest pose not matched (step 4.3): compare arm and leg angles to the agent's |
| part of the mesh stays put while the body moves | its vertex group wasn't renamed (step 4.4 lists those) or has no weight |
| fingers wrong, body fine | finger rest pose, or a rig with different finger bones — cosmetic |
| Verify: `bone name case does not match` | a bone was named `hand_l` instead of `hand_L` |
| compile log reports mesh joints it cannot find | the mesh still has its old bone names — step 4.4 |
| weapon floats away from the hand | the hand bone's axes differ from CS2's — the rest-pose match again |

## Could this be automated?

Partly. Unpacking, decompiling, materials and assembly are mechanical, and
could be scripted around the community tools named above. The rest-pose match
in step 4.3 is the hard part: deciding how a given character's arms should
line up with CS2's takes judgement, and it differs per model. If you want to
work on this, CONTRIBUTING.md has the contract a new source has to meet.
