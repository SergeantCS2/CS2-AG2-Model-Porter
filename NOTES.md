# Technical notes

How the AnimGraph2 migration was worked out, what was measured, and the traps
that cost the most time.

The community pack I used as a test base was nozb1's, whose models are rigged on
CS2's own skeleton — every canonical bone sits within 0.73 units of Valve's
agents. That is a large part of why this was solvable with text edits rather
than 3D work, and a pack rigged from scratch may not port as cleanly.

Reference set: Valve's shipped agents (`ctm_fbi`, `ctm_sas`), one custom model
that had been hand-ported to AG2, and 26 unported models from a 2024-era
community pack. Every rule in the scripts comes from a difference between those
groups, not from guesswork.

**Confirmed working in game.** All 26 models from the test pack animate.

Four bugs turned up while auditing, two of which would have silently shipped
broken models — those are section 2, and they're the most useful part of this
document if you're doing something similar.

---

## 1. Bone hierarchy — the thing that actually matters

CS2's canonical AG2 skeleton (`worldmodel.vnmskel`) has 74 bones rooted at
`root_motion`, with `pelvis` as its child.

| | canonical bones present | parent mismatches |
|---|---|---|
| reference model (**animates**) | 64 / 74 | **0** |
| a ported model | 64 / 74 | **0** |

Every shared bone has an identical parent in both. The 10 absent bones
(`wpnHand_L/R`, `wpnTip`, `wpnEnd`, `attachHand_L/R`, `attachFoot_L/R`,
`wpnAimIntent`, `attachWorld`) are absent from the reference model too, so they are optional.

**Across all 26 models after porting:** `root_motion` is the sole skeleton root
in every one, and `wpnPivot`/`wpn` are present in every one. 22 of 26 have zero
parent mismatches. The other four differ only in finger metacarpal parenting — e.g.
`finger_ring_0_L` attached to `hand_L` instead of `finger_ring_meta_L`. That is
a rigging quirk in the source pack's originals, affects finger posing only, and does not
prevent body animation.

`romasha` has an extra custom root called `lean_root`. Harmless — `pelvis` is
correctly re-parented regardless.

## 2. Traps that cost the most time

**(a) one model in the test pack would have shipped broken.** It is the only model in the
pack with lowercase `_l`/`_r` bones. Without a case flip it cannot bind to the
AG2 graph. Now auto-detected and flipped — 52 bones.

**(b) The case flip was renaming physics shapes.** Physics bodies, hitboxes and
attachments carry their own `name =` fields with their own conventions — a test model
has `leg_upper_l` as a *physics shape* while its skeleton bone is
`leg_upper_L`. Renaming those breaks physics binding. Now scoped to `Bone`
nodes only; verified byte-identical before/after on that model's physics names.

**(c) The case flip desynchronised the mesh — this one was serious.** The mesh
binds to bones **by name**, through a `jointList` in the DMX. Renaming only the
`.vmdl` left the DMX pointing at names that no longer existed, which produces
`Invalid skinning bone index :: -1` for every joint and a mesh that does not
deform. The flip is length-preserving, so the DMX string table is now patched
in place — 5 DMX files for the affected model, byte-identical file sizes, **0 unresolved
joints** afterwards.

**(d) Three PowerShell case-insensitivity traps.** `-ne`, `-eq` and
`Hashtable.ContainsKey` all ignore case by default, which is precisely the
distinction this work depends on. Each silently made a fix into a no-op that
still reported success. Now uses `-cne` / `-ccontains`.

## 3. Mesh binding

| check | result |
|---|---|
| a test model DMX `jointList` casing | uppercase — matches its `.vmdl` skeleton |
| a test model DMX joints unresolved against skeleton | **0 of 70** |
| that model after flip + DMX patch | **0 unresolved** across all 3 body meshes |
| `.vmdl`↔DMX casing consistency, all 26 | consistent in every model |
| `m_remappingTable` in our compile | present and regenerated correctly |

## 4. The skinning warnings are cosmetic

Investigated properly rather than assumed:

- Every DMX joint resolves to a skeleton bone by name (0 unresolved)
- The compiler still emits `m_remappingTable` correctly
- The untouched original decompile produces the identical count, so it is a
  VRF round-trip artefact rather than anything the port introduces
- ModelDoc loads the compiled result with *"No Errors or Warnings"* and renders
  the mesh with all materials bound

Not a blocker. Worth watching if the model renders visibly deformed.

## 5. Differences left alone deliberately

Community models often carry three AnimGraph1-era nodes the reference does not: `MovementSettings`,
`Feet`/`Foot`, and `character_arm_config`. The compiler accepts all three and
AG2 appears not to read them — none of the three known-working AG2 models
(Valve's `ctm_fbi` and `ctm_sas`, and the hand-ported reference) carries any of
them. They are **stripped by default** to match those models. In AG2 first-person
arms come from Valve's shared `glove_*` models, so `character_arm_config`
pointing at an unported `*_pm_arm.vmdl` is dead weight. `-KeepAG1Nodes` keeps
all three (and also skips the weapon-attachment and physics-markup edits) for
anyone who needs to compare.

The `Feet` node did reference lowercase bones (`ankle_l`) that do not exist on
uppercase skeletons — a latent bug in the source pack's originals. Now corrected to match
the actual skeleton, 4 references per model.

Valve's agents and the reference both carry `AnimConstraint*` nodes (aim constraints, tilt-twist,
jigglebone drivers) and 526 bones to a test model's 72. Those are authoring richness,
not AG2 requirements.

## 6. Compiled output vs the original

| block | original | ours | note |
|---|---|---|---|
| mesh | `MBUF` 255,826 | `MVTX` 224,243 + `MIDX` 18,764 | newer compiler splits the buffer |
| `MDAT` | 10,184 | 10,273 | comparable |
| `PHYS` | 6,324 | 2,879 | **ours is smaller — see below** |
| `m_remappingTable` | 88 entries | 91 entries | ours has 2 extra bones, so expected |

The `PHYS` shrinkage is unexplained. It affects hitboxes and collision, not
animation. Flagged rather than solved.

## 7. What static analysis couldn't answer

Everything below was unknown until the models were loaded in game. Recorded
because the same limits apply to anyone repeating this work:

1. **Whether AG2 binds.** Static structure said it should. Only the game could
   confirm it. It does.
2. **Weapon placement.** `wpnPivot`/`wpn` are grafted at CS2's canonical rest
   values from `worldmodel.vnmskel` — `wpnPivot` at `[0, 58.78, -3.47]` in
   ModelDoc's axis order, `wpn` its exact negation, netting to the root. That
   matches the reference to five decimal places. The weapon itself hangs off
   the `weapon_hand_*` attachments, which v1.2.0 re-parents to `hand_L`/`hand_R`
   with Valve's offsets — community models had them on a legacy helper bone,
   which is why guns sat on the floor between the feet.
3. **Whether `PHYS` shrinkage matters.** Hit registration, not animation. Still
   unmeasured.
4. **First-person arms.** A separate port entirely — `*_pm_arm.vmdl_c` carries
   no animgraph reference at all. Even the reference model's arms were never conformed by her
   author.

## 8. Still open

**Twist constraints.** Valve's agents carry 16 `CTiltTwistConstraint` lists
driving forearm and leg twist bones. Ported models have none, so limbs deform
poorly under rotation. The ModelDoc source format takes bone *names*, so the
bone hash isn't the obstacle — for the record it's MurmurHash2 with seed
`0x31415926`, Valve's standard. The obstacle is `relative_origin` and
`relative_angles`, which encode each model's own geometry. Get them wrong and
limbs look worse than leaving the constraints out.

**Sample size.** Every rule here is inferred from three models of one lineage:
two Valve agents, plus one custom model that had been conformed to match them.
A working AG2 port by an unrelated author would be worth more than any further
static analysis.

**Viewmodel arms.** `*_pm_arm.vmdl` files carry no animgraph reference at all
and are a separate port. AG2 decouples arms from the player model — Valve ships
them under `agents/models/shared/arms/glove_*` — so ported models fall back to
CS2's standard arms, which is what Valve's own agents do.

**Physics markup names.** The `CPhysicsBodyGameMarkupData` block is copied
verbatim from the working models, and its body names are lowercase except one,
`leg_upper_L`. Whether that is Valve's own quirk or a typo carried over has not
been checked against a fresh `ctm_fbi`, and the block is added whether or not
the model's physics shapes use those names. It governs ragdoll and hit
reactions, not animation.

---

## 9. Found by the test suite (1.3.0)

v1.3.0 added `tests\Run-Tests.ps1`: synthetic models in Source2Viewer's
layout, run through the real scripts, with stand-ins for Source2Viewer and
`resourcecompiler`. The first runs turned up these. Two were serious.

**(a) Comma-decimal Windows wrote broken transforms — serious.** PowerShell's
`-f` operator follows the Windows region setting. On German, French, Russian,
Brazilian and many other installs, every converted origin and angle came out as
`[ 0,000000, 42,123554, 0,458082 ]`, which KV3 reads as six numbers. The brace
check passes, so nothing flagged it. Rebuilt materials had the same problem
with colour vectors. All numbers are now written with the invariant culture,
and a test runs the port under `de-DE`.

**(b) A root_motion with no children received pelvis in the wrong place —
serious.** The scan for root_motion's `children =` stopped only at a bare `}`,
but a bone in an array closes with `},`. On a leaf root_motion it ran on and
found the next `children =` at the same indent — a BodyGroup's — and grafted
pelvis into that, while logging *grafted as first child of root_motion*. nozb1's
root_motion holds IK targets, so it never triggered there. The search is now
confined to the bone's own block.

**(c) The up-axis check read a parented pelvis.** Once pelvis is under
root_motion its origin is local, `[0, 42, 0]`, which reads as +Y-up. Any stray
root adopted afterwards was turned 90°. The check now only runs on a root
pelvis. Strays are also converted with root_motion's real angles rather than an
assumed `[0, 90, 90]`.

**(d) Half-ported models, either half.** A model with a graph list and no
skeleton list got no skeleton references; one with a skeleton list and no graph
list got a second skeleton list. Each list is now checked on its own.

**(e) DMX patching reached other models.** The case-flip patched every `.dmx`
in the folder, so in packs that share a folder it renamed joints in
neighbouring models' meshes too. Only the meshes this model references are
patched now.

The test suite also pins the output for the common cases: for a nozb1-style
model, the `.vmdl` written by 1.3.0 is byte-identical to 1.2.0's. The grafted
pelvis is still indented one tab short of its new siblings, as it always has
been — KV3 ignores whitespace, and changing it would only change every file.

## 10. Models from other games

The porter works because the community CS2 packs were rigged on CS2's own
skeleton (section 1): same names, same rest pose within a fraction of a unit,
so the edits are all about *references* and the bone hierarchy. A model from
another game breaks both assumptions.

- **Garry's Mod, SFM, HL2, TF2** use ValveBiped. Every bone has a different
  name (`ValveBiped.Bip01_L_Forearm` for `arm_lower_L`), and the rest pose and
  bone axes differ. A rename alone binds the mesh, then twists it as soon as
  the graph rotates a bone around CS2's axes rather than the ones the mesh was
  weighted against. The mesh has to be posed to CS2's rest pose and re-bound —
  a re-rig, which needs judgement per model and is not scriptable reliably.
- **CS:GO** agent-era player models already use CS2's names — CS2 inherited
  the skeleton — so they are usually close enough to need conversion only.
- **Other Source 2 games** have their own skeletons and need the same re-rig.

The practical route, using a decompiled Valve agent as the template so the
skeleton, AG2 lists, hitboxes and attachments are canonical from the start, is
in [PORTING-OTHER-GAMES.md](PORTING-OTHER-GAMES.md).
[`valvebiped_to_cs2.txt`](valvebiped_to_cs2.txt) maps every ValveBiped bone,
including the helper bones whose weights fold into the main ones.
