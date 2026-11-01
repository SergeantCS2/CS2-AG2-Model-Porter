# Changelog

## v1.3.0

Fixes from a full audit plus a new test suite, and a route for models from
other games. On the packs this was built against, ported output is
byte-identical to 1.2.0 — the test suite pins it.

**FIXED:** on a Windows set to a language that writes decimals with a comma
(German, French, Spanish, Portuguese, Russian, Polish and many more), every
converted bone transform was written as `[ 0,000000, 42,123554, 0,458082 ]`,
which the model format reads as six numbers instead of three. Rebuilt materials
had the same problem with colour vectors. Numbers are now always written with
`.`. **If you ported on such a system, re-port with `-Force`.**

**FIXED:** Workshop packs were only looked for in the `C:` Steam library, so
with CS2 on any other drive Setup reported the pack missing and porting failed
with "source VPK not found", even with `-CS2Path`. The pack is now found in the
library CS2 is installed in. The wizard also finds Steam itself when it isn't on
`C:`.

**FIXED:** a model whose `root_motion` bone had no children had its pelvis
grafted into the next node that did — a bodygroup — while the log said it went
under `root_motion`. The search now stays inside `root_motion`'s own block.

**FIXED:** `Verify-Model.ps1` compared bone names case-insensitively, so a model
with `hand_l` passed as though it had `hand_L` — exactly the difference AG2
binds on. Bone checks are now case-sensitive, a case-only mismatch is reported
by name, and bones left outside `root_motion` are flagged.

**FIXED:** in a pack where most models use `<name>/<name>.vmdl_c`, models laid
out differently were silently left out of porting, `-CompileOnly` and Verify.
They're now included when their skeleton shows they're player models; props and
other files stay out.

**FIXED:** materials in Workshop and `.vpk` packs were only looked for in a
folder called `materials`, so packs using `mat/`, nested folders or materials
beside the model failed with "could not rebuild any materials". The model's own
resource list is now used in every mode. Materials are also rebuilt one at a
time, so a pack where Source2Viewer could decompile *some* materials no longer
ends up with placeholders for the rest.

**FIXED:** materials a model borrows from CS2 itself were copied — or, failing
that, stubbed with a placeholder — into the addon at CS2's own path, where a
mounted addon can stand in for the game's file. They're now left to the game.

**FIXED:** `Cleanup-AG2.ps1` restored `gameinfo.gi` from a backup that could be
from an older CS2 build, rolling the file back. Setup now edits only the one
line and backs up the current file each time; Cleanup restores the backup only
if it still matches, and otherwise removes just the added line.

**FIXED:** smaller things the test suite turned up — a model with a graph list
but no skeleton list got no skeleton references, and the reverse got a second
skeleton list; the case flip patched other models' `.dmx` files in a shared
folder; stray roots were turned 90° on models whose pelvis was already
parented, and converted with an assumed rather than the actual `root_motion`
angle; non-ASCII text (bodygroup names in anime packs) was garbled by Windows
PowerShell; viewmodel arms in a pack were reported as failures rather than
skipped; a compile that reported no error but wrote no file was counted as a
success; in a pack keeping several models in one folder, porting one model
re-extracted the folder over the others' already-ported sources, so a later
`-CompileOnly` could build them T-posing; a CS2 path typed into the wizard with
a trailing `\` garbled the arguments of every script it ran.

**FIXED:** `-CompileOnly` compiled every `<name>/<name>.vmdl` left in the
addon, ported or not, so viewmodel arms extracted alongside a model were
compiled too and then failed Verify. It now compiles every ported model
(wherever it sits) and lists the rest without touching them.

**CHANGED:** the experimental Linux port's model edits now match the Windows
version's — the test suite runs both on the same models and requires the same
`.vmdl` — including everything since 1.0.0 it was missing: any `root_motion`
angle, creating `root_motion`, adopting stray roots, the up-axis correction,
the weapon attachments and the fixes above. Its loose-file paths, material
handling, Verify and `gameinfo.gi` handling are fixed too. It is still
experimental and does less than Windows around the edits;
[linux/README.md](linux/README.md) now says exactly what.

**ADDED:** [PORTING-OTHER-GAMES.md](PORTING-OTHER-GAMES.md) — what it takes to
bring Garry's Mod, SFM, HL2, TF2, CS:GO and other Source games' models to CS2,
step by step, with `valvebiped_to_cs2.txt` (the full ValveBiped → CS2 bone map)
and `tools\blender_remap_weights.py` for the re-rig. Menu option 9 in the wizard
summarises it.

**ADDED:** `tests\Run-Tests.ps1` — runs every script against synthetic models
and stand-ins for Source2Viewer and `resourcecompiler`; no game files needed.
Runs in GitHub Actions on Windows PowerShell 5.1.

**ADDED:** release packaging. Pushing a version tag builds both downloads
from a fixed file list and attaches them to a draft release, after checking
the tag against every script's version and the CHANGELOG.

**ADDED:** the Source2Viewer version is printed in every port log, and
`Setup-AG2.ps1 -S2VVersion <release>` installs a specific release if a new one
ever breaks porting.


## v1.2.0

**ADDED:** weapon attachments are matched to Valve's own agents. Community
models inherited an AnimGraph1 layout - `weapon_hand_l`/`weapon_hand_r` parented
to a legacy helper bone with no offset, and no `weapon_center` at all - which is
why the weapon sat at the entity origin, on the floor between the feet. They are
now parented to `hand_L`/`hand_R` with the exact offsets and rotations read from
`ctm_fbi.vmdl`, and a `weapon_center` is added when missing.

This is pre-existing in every pack tested, not something the port introduced.
The weapon bones themselves were always correct: Valve's agents carry only
`wpnPivot` and `wpn`, matching what this tool grafts to five decimal places.


## v1.1.3

**FIXED:** models authored on an axis other than +Z came out lying down. The
conversion preserves world position exactly, so a model built with its spine
along -X was faithfully preserved lying on its back. The up axis is now detected
from the pelvis and corrected before conversion. Verified against three packs:
23 of 24 models are +Z-up and unaffected; the one outlier now matches


## v1.1.2

**FIXED:** `Verify-Model.ps1` failed models it should only have flagged. The
pelvis orientation test now fails only when the bone is genuinely still outside
`root_motion`, and warns when a model is simply authored in a different
orientation

**FIXED:** `spine_0`, `spine_1`, `spine_2`, `spine_3` and `neck_0` moved from
critical to optional - one model runs pelvis straight to spine_1, compiles and
animates fine. Parent checks are skipped when the expected parent is absent, so
a shorter spine chain is no longer reported as wrong parenting


## v1.1.1

Fixes from a failing run against a hand-assembled zip of loose models.

**FIXED:** in `-Source` mode the output folder was rebuilt as `<root>/<model
name>`, which is wrong whenever the folder is not named after the model - one
pack has `zombie.vmdl_c` inside a folder called `zombiertx`. The model, its DMX
meshes and its materials all landed where the compiler never looked. The
directory now comes from the model's own recorded path

**FIXED:** materials were flattened into a folder called `materials` regardless
of where the model expects them. The source folder layout is now mirrored, so
packs using `mat` or nested folders resolve

**FIXED:** compiled textures were copied in, then swept away before the compiler
ran, leaving rebuilt materials pointing at images that were not there. Textures
are decompiled to `.png` first

**ADDED:** materials a model references but the source does not contain are
pulled from CS2's own files, or stubbed with a placeholder and a warning, rather
than failing the whole model

**FIXED:** `$matDirs` was built with `$x = if (...) { @($y) }`, which PowerShell
unwraps to a string - `+=` then concatenated paths instead of appending them.
This broke material discovery for every model in the VPK path

**FIXED:** `-ListOnly` refused to run unless the addon already existed


## v1.1.0

Fixes from a report against a mixed pack of loose model files.

**FIXED:** `-Source` mode ported viewmodel arms, map stubs and props as if they
were player models. Detection is now by skeleton content - pelvis plus a leg -
so it works whatever the files are named

**FIXED:** materials were only found in a folder called `materials`. Some packs
use `mat`, some nest deeper. Every `.vmat_c`/`.vtex_c` under the model's folder
is now collected, wherever it sits

**ADDED:** models with no `root_motion` bone get one created, with every
existing root adopted under it and its transform converted so nothing moves.
Previously these failed outright with "need both pelvis and root_motion"

**ADDED:** stray root bones beside `root_motion` are adopted into it. Canonical
skeletons have exactly one root, and a bone left outside is never animated

**FIXED:** half-ported models with an existing `AnimGraph2List` were skipped
wholesale. Missing entries are now topped up individually - one model had a
skeleton list containing only the viewmodel, leaving the worldmodel graph
nothing to animate against

**FIXED:** the pelvis orientation check failed models authored in a different
orientation. It now only fails when pelvis is genuinely unparented, and warns
otherwise


## v1.0.0

First release.

**ADDED:** AnimGraph1 → AnimGraph2 migration for pre-AG2 CS2 player models —
graph and skeleton references, pelvis re-parent with transform conversion,
canonical weapon bones, AnimGraph1-era node removal, physics body markup

**ADDED:** bone case-flip to `_L`/`_R` for models predating that convention,
patching the DMX `jointList` in the same pass so the mesh stays bound

**ADDED:** material rebuild from compiled `.vmat_c` — Source2Viewer cannot
decompile CS2 materials on a machine that has CS2 installed

**ADDED:** each model's own folder root is tracked rather than assuming one per
pack, with a warning if two models share a name in different folders

**ADDED:** log rotation — the last 20 runs are kept

**ADDED:** materials are located from the compiled model's resource list, so
packs that store them outside the model folder work — Valve's own agents do
exactly that

**ADDED:** `RUN-ME.bat` — double-click entry point that clears the downloaded
file block and execution policy, so no PowerShell knowledge is needed

**ADDED:** three model sources — Workshop pack id, any `.vpk` on disk, or a
folder of loose `.vmdl_c` files. Delisted packs work the same as live ones

**ADDED:** `Start.ps1` wizard — finds CS2 across Steam libraries, checks the
Workshop Tools DLC, remembers settings

**ADDED:** `Verify-Model.ps1` — tiered pre-publish check against the properties
that separate a working AG2 model from a broken one

**ADDED:** `Cleanup-AG2.ps1` — removes everything the tool adds and restores
`gameinfo.gi`

**ADDED:** `-CompileOnly`, so models prepared elsewhere can be compiled on any
Windows machine with the Workshop Tools

**ADDED:** experimental Linux port as a separate download. Porting verified
identical; the compile step is not verified, since `resourcecompiler` needs a
D3D device for texture encoding

**FIXED:** split Workshop packs — the ones that ship as `<id>_dir.vpk` plus
`<id>_000.vpk` — were reported as "not downloaded" by setup, and would then have
failed to port. Both now resolve to the `_dir` index

**FIXED:** the pelvis transform only accepted a `root_motion` rotation of
exactly `[0, 90, 90]`. It now computes `R^T * M` from whatever rotation the
model actually has — one pack in the wild sits at `[0, 90.4687, 90]` and every
model in it was silently left unconverted

**FIXED:** required exactly 4 graph references. Valve ships 4 but the fourth
duplicates the worldmodel graph; ports by other authors use 3. The floor is now 3

**FIXED:** model discovery required a `<name>/<name>.vmdl_c` layout and found
nothing in packs that lay out differently. Falls back to scanning every model,
filtering arms and anything too small to be a player model

**ADDED:** models that are already fully AnimGraph2 are reported as such instead
of being re-processed

**FIXED:** `Verify-Model.ps1` had the same layout assumption as discovery and
found nothing in packs that name files differently from their folders

Seven audit passes and testing against three real packs found twenty-four bugs, including a
loop counter clobbered by an inner counter of the same name - visible only in
the progress display, and only spotted because a real run log showed [15/11], including an early exit that
silently skipped the entire port on models whose hierarchy was already correct,
and unguarded inserts that duplicated nodes on a second run. Details in
[NOTES.md](NOTES.md).
