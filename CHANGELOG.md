# Changelog

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
