# CS2 AG2 Port

**Fixes custom player models that T-pose after CS2's AnimGraph2 update.**

They still load, textures are fine - they just stand there like a scarecrow in the classic T pose. This fixes that — PowerShell scripts, no
Blender, no re-rigging.

Works with Workshop packs, `.vpk` files on disk, or loose model files. Delisted
packs are the whole point, or those lost to time.

> [!IMPORTANT]
> **This tool does not give you rights to anyone's models.**
>
> It documents and automates a repair process. Nothing more. Whether you're
> allowed to touch a given pack is between you and whoever made it — this
> project takes no position and grants no permission.
>
> Repairing a pack you made or lost media for your own use is one thing,
> **publishing it is another.** Steam's Subscriber Agreement (§6.D) makes you
> warrant that a Workshop Contribution "was originally created by you," or that
> you have the right to submit it on behalf of the people who did. Uploading
> someone else's models without asking makes that warranty false.
>
> **Ask the original author first.** Most are glad someone fixed their pack.
> Some would rather you didn't republish it — that's their call to make, not
> yours or mine.

> [!WARNING]
> Custom player models are a grey area for server operators. Valve's
> [server guidelines](https://blog.counter-strike.net/server_guidelines/) target
> mods that falsify inventories, skins or rank — the line about custom models
> specifically was struck through by Valve shortly after it was posted, and
> never clarified since.
>
> That leaves it unsettled rather than banned.
> [PlayerModelChanger](https://github.com/samyycX/CS2-PlayerModelChanger)'s own
> README still warns it can get your GSLT banned, which is worth respecting.
> Either way this changes nothing — the same models, the same plugin, just
> animating instead of frozen.

---

## See it working

These models are running live on my server — it's what I built this against for testing.

```
connect 20.106.131.225
```

**Subscribe to my collection first or AG2 models** — it has everything the server mounts, maps
included:

**→ [Server collection](https://steamcommunity.com/sharedfiles/filedetails/?id=3771699759)**
**→ [AG2 Anime Model test collection](https://steamcommunity.com/sharedfiles/filedetails/?id=3772008982)**
· original models by
[nozb1](https://steamcommunity.com/sharedfiles/filedetails/?id=3186973222)

Subscribing beforehand makes joining smoother, but my server pushes what you're
missing on your first map change either way.

**What I run on it:** 30+ modes — surf, bhop, KZ, deathmatch, PropHunt and more,
switchable in-game. Timer, leaderboards, the usual.

### Trying a model

In chat:

| | |
|---|---|
| `!models` | open the model picker |
| `!model <name> all` | set a model for both teams |
| `!model <name> t` / `ct` | set it for one side |
| `!tp` | third person, so you can actually see it |

> [!NOTE]
> Models only appear after your client has the addon. If everything shows as an
> error model, change map once (`!rtv`) and rejoin — that's what triggers the
> download.

---

## How this works

You don't patch the original pack — you can't, it isn't yours. Instead:

```
   broken pack                    fixed copy
   (Workshop, or a .vpk)   ──►    (compiled into a CS2 addon)
                                          │
                                          ▼
                                  server mounts the fixed copy
                                  instead of the broken one
```

The scripts pull the models out, repair the AnimGraph binding, and compile them
into a CS2 addon.

**Roughly what it costs you:** the Workshop Tools DLC is a ~10 GB download,
once. Porting is unattended and takes a couple of minutes per model. Steam
moderation on your new item takes a few hours.

**This assumes you run a CS2 server.** The models only reach players through a
server-side plugin. If you just want custom models in your own game, this isn't
the tool.

If you'd rather know *why* they broke and exactly what gets changed before
installing anything, skip to [What broke](#what-broke) and
[What the scripts do](#what-the-scripts-do).

## Install

> [!IMPORTANT]
> Download **`CS2-AG2-Model-Porter-windows.zip`** from
> [Releases](../../releases) — not the green "Code" button. That gives you the
> source tree.

1. Extract the zip anywhere (Desktop is fine)
2. Subscribe to the broken pack in the Steam Workshop, then **launch CS2 once**
   so Steam downloads it
3. Install the Workshop Tools DLC — Steam → CS2 → gear in the game banner, bottom right or right click → **Properties** →
   **DLC** → tick **Counter-Strike 2 Workshop Tools** (~10 GB)
4. **Double-click `RUN-ME.bat`**

That's it. `RUN-ME.bat` handles the PowerShell permissions and starts the
wizard. Source2Viewer CLI is downloaded for you during setup. PowerShell 5.1,
which ships with Windows, is all you need.

If you'd rather do it by hand:

```powershell
Get-ChildItem *.ps1 | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Start.ps1
```

### Then

```
Wizard menu:  1 (set up)  ->  4 (port all)  ->  5 (verify)
Publish the addon from the Workshop Manager, wait for Steam moderation.
Put your new Workshop ID in mm_extra_addons.
Restart the server, join, CHANGE MAP ONCE, pick a model.
```

Each of those has a section below.

## Steps

**1. Run the wizard** — double-click `RUN-ME.bat`. It finds CS2 (including
other drives), checks the DLC, asks where your models are, and remembers your
answers.

**2. Set up** — menu option 1. One-time. Patches `gameinfo.gi` with a backup,
downloads Source2Viewer, creates the addon folders.

> [!IMPORTANT]
> That `gameinfo.gi` line matters more than it looks. Without it the Workshop
> Manager builds a VPK with no models in it. Publishes fine. Mounts fine. Does
> absolutely nothing.

**3. Port** — option 3 for one model, 4 for all. Expect per model:

```
[4/26] eula
counts  vanmgrph=0 vnmgraph=4 wpnPivot=1 vnmskel=2  (want 0 4 1 2)
OK  329183 bytes
```

Already-compiled models are skipped, so you can stop and resume. `-Force` redoes
them.

**4. Verify** — option 5. **Don't publish anything that doesn't pass.**

```
core 24/24   toes 2/2   fingers 38   bones 74   refs 13g/8s
pelvis [0.00, 42.12, 0.46] (height should be the middle value)
[PASS]
```

Tiered — a missing finger joint isn't a failure, a missing `hand_L` is.

**5. Publish.** This is the only part with a GUI, and the only part the scripts
can't do for you.

1. Steam → Counter-Strike 2 → **Play** dropdown → **Counter-Strike 2 Workshop
   Tools**
2. On the launcher, pick your addon (the name you gave the wizard) and open it
3. **Asset Browser** → **Tools** (top right) → **Counter-Strike 2 Workshop
   Manager**
4. Create a new item. Title, description, and any image as the preview — all
   editable later
5. Set visibility. **Hidden** until posted, then change to unlisted in steam afterwards.
6. Submit, then **subscribe to your own item** — hidden and unlisted items
   aren't auto-subscribed, and your client needs it
7. Grab the ID from the item's URL: `.../filedetails/?id=XXXXXXXXXX`

> [!TIP]
> If the Asset Browser shows thousands of assets and none of them are yours,
> the tools opened a different addon. Check the **Mods** filter button — it
> should show 1 of N, not all of them. Close and relaunch, picking your addon
> on the launcher screen.

> [!IMPORTANT]
> Steam holds new items for moderation, usually a few hours. Until approved
> **nobody can download it, including your own server**. Point a server at an
> unapproved item and MultiAddonManager will fetch, fail, reload the map, and
> repeat forever — kicking everyone each time. "Unlisted" is fine.

Join → **change map once** → switch models.

---

## Testing it

Two ways, both need a server — models only reach players through a server-side
plugin.

**Locally**, on the same PC: run a CS2 dedicated server on `localhost` and
`connect 127.0.0.1`. Same setup as a remote one, fastest loop for iterating, and
nobody else sees the broken attempts.

**On a remote server**, if you already run one — same steps

Either way the server needs:

| plugin | why |
|---|---|
| [Metamod:Source](https://www.sourcemm.net/downloads.php/?branch=master) | loads everything else |
| [CounterStrikeSharp](https://github.com/roflmuffin/CounterStrikeSharp) | plugin runtime |
| [MultiAddonManager](https://github.com/Source2ZE/MultiAddonManager) | mounts Workshop addons and pushes them to clients |
| [PlayerModelChanger](https://github.com/samyycX/CS2-PlayerModelChanger) | the `!model` command |

[kus/cs2-modded-server](https://github.com/kus/cs2-modded-server) ships all four
preconfigured — easiest starting point if you don't have a server yet.

Then:

1. Add your Workshop ID to `mm_extra_addons`, remove the broken pack's
2. Add the models to PlayerModelChanger's config, or edit the existing entries
   if they're already listed
3. Restart, then **before joining** confirm it mounted:

```bash
docker logs <container> 2>&1 | grep -i "Mounting addon"
```

| output | meaning |
|---|---|
| `Mounting addon '<id>'` | good, join |
| `Addon download started` repeating | can't fetch it — still in moderation, or the item is Hidden. Pull it out before it loops and kicks everyone |
| nothing | the ID isn't in `mm_extra_addons` |

4. Join, **change map once**, `!model <name> all`, `!tp`

> [!CAUTION]
> Launch CS2 from Steam's **Play** button, not the Workshop Tools. The tools run
> the game insecure and VAC servers refuse the connection with a message about
> file signatures. Harmless, but alarming if you don't know what it is.

> [!NOTE]
> Without a server you can still open the compiled `.vmdl_c` in Source2Viewer to
> confirm the mesh, skeleton and materials are intact — but it renders the bind
> pose, so it can't show you animation. AG2 only runs against a live player
> entity.

---

## Where models can come from

```powershell
.\Port-Model.ps1 -Pack 1234567890            -All   # Workshop, subscribed
.\Port-Model.ps1 -Vpk "D:\old_dir.vpk"       -All   # any .vpk on disk
.\Port-Model.ps1 -Source "D:\extracted"      -All   # loose .vmdl_c files
```

Split VPKs: hand it any part, it finds the `_dir` index. For loose files:

```
D:\extracted\                          <- point here, name doesn't matter
  coolmodel_player_model\
    coolmodel_player_model.vmdl_c      <- required
    materials\
      body.vmat_c                      <- else no textures
      body_color.vtex_c
```

Subfolders are searched. Folder names are irrelevant — each model records its
own intended path internally. Files ending `_c` are compiled; that's what you
want. Decompiled `.vmdl`/`.dmx` sources won't work, nor will CS:GO `.mdl`.

---

# Reference

Everything below is background. You don't need it to use the tool.

## What broke

Old models point at AnimGraph 1. Valve deleted it.

```
characters/models/shared/animgraphs/player_ct.vanmgrph   <- AG1, gone
animation/graphs/worldmodel/worldmodel.vnmgraph          <- AG2, what CS2 uses
```

Different file formats, not a moved path. Your server log has been saying so:

```
Failed loading resource "...player_ct.vanmgrph_c" (ERROR_FILEOPEN: File not found)
Failed loading resource "...animset_ct.vmdl_c" (ERROR_FILEOPEN: File not found)
```

Nothing binds, so you get the bind pose. Hence the T-pose.

## What the scripts do

I worked this out by pulling apart Valve's own agents (`ctm_fbi`, `ctm_sas`),
comparing them to broken community models, and fixing differences until none
were left. Every rule is measured against something that provably animates.

Per model:

- **Delete `anim_graph_name`** — the `.vanmgrph` reference Valve removed
- **Delete the `AnimIncludeModel`** pointing at `animsets/animset_*.vmdl`
- **Add `AnimGraph2List`** — 4 entries: `DefaultAnimGraph2` → worldmodel, plus
  named `uimodel` / `hudmodel` / `worldmodel`
- **Add `NmSkeletonList`** — `worldmodel.vnmskel` + `viewmodel.vnmskel`
- **Re-parent `pelvis` under `root_motion` and convert its transform** —
  root_motion sits at angles `[0,90,90]`, so skipping the conversion compiles
  fine and the model lies on its side
- **Add `wpnPivot` + `wpn`** under root_motion at CS2's canonical rest values
- **Strip `MovementSettings`, `Feet`, `character_arm_config`** — Valve's agents
  have none of them
- **Add `CPhysicsBodyGameMarkupData`** (15 bodies)
- **Case-flip bones to `_L`/`_R`** if the model predates that convention —
  including the DMX `jointList`, or the mesh detaches from the skeleton
- **Fix decompiler artefacts** — empty `BodyGroupChoice` name, and rebuild
  materials from `.vmat_c` (Source2Viewer can't decompile CS2 materials on a PC
  that *has* CS2 installed)
- **Recompile** with `resourcecompiler`, pack as an addon, publish, mount by ID

Measurements and the traps behind each of these: [NOTES.md](NOTES.md).

## Troubleshooting

<details>
<summary><b>Is this safe or I'm getting a VAC error when joining a Server after running!!!!</b></summary>

Ensure you run the cleanup within the program - then launch your game. Verify 
game files if that doesn't work - then reinstall. If you cleanup properly, you 
shouldn't have to do anything.
</details>

<details>
<summary><b>I downloaded it and there's just a folder of code</b></summary>

You clicked the green **Code** button, which gives you the source tree. Go to
[Releases](../../releases) and download `CS2-AG2-Model-Porter-windows.zip` instead, then
extract it and double-click `RUN-ME.bat`.
</details>

<details>
<summary><b>RUN-ME.bat flashes and closes</b></summary>

It shouldn't — it pauses at the end. If it closes instantly, PowerShell is
missing or blocked by policy. Open PowerShell in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start.ps1
```

The error will be visible there.
</details>

<details>
<summary><b>PowerShell says "is not digitally signed"</b></summary>

Windows blocking unsigned scripts. Run both:

```powershell
Get-ChildItem *.ps1 | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Start.ps1
```

The bypass is per-process — nothing changes system-wide.
</details>

<details>
<summary><b>A script vanished after downloading</b></summary>

Windows Defender. A fresh unsigned script that reads Program Files and writes
binaries hits the heuristic almost perfectly. Restore it from Protection
History, or unblock the folder before running anything.
</details>

<details>
<summary><b>"Workshop Tools not installed" but I'm sure they are</b></summary>

```powershell
Test-Path "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\resourcecompiler.exe"
```

`False` means the DLC isn't installed, or CS2 is on another drive — pass
`-CS2Path`.
</details>

<details>
<summary><b>My pack isn't in the workshop content folder</b></summary>

Steam doesn't download workshop content until the game runs. Subscribe, launch
CS2, quit, retry. If the item was removed from the Workshop you can't subscribe
— use `-Vpk` or `-Source` with a local copy. Worse case, unsub and launch, then sub & launch again.
</details>

<details>
<summary><b>Compile fails on missing materials</b></summary>

Source2Viewer can't decompile CS2 materials on a PC that *has* CS2 installed —
it finds the shader, chokes on the version, writes nothing. Works fine without
CS2, which made this take embarrassingly long to find. The scripts detect it and
rebuild from the compiled files. `rebuilt 0 material(s)` means the raw extract
failed — check your pack ID.

Materials don't always sit beside the model. Valve's own agents keep the model
under `agents/models/<name>/` and its materials under
`characters/models/<name>/materials/`. The scripts read the compiled model's
resource list and pull in anything outside the model folder — you'll see
`materials live elsewhere: <path>` when that happens.
</details>

<details>
<summary><b>Error models / models missing in game</b></summary>

The addon didn't mount, or your client doesn't have it. Check the mount output
above, and confirm you're subscribed to your own item.
</details>

<details>
<summary><b>Still T-posing</b></summary>

In this order — the first two are far more likely than the third:

1. **Client console.** `developer 1` before switching models, then look for a
   failed load of your `.vmdl_c`. Can't find it? That's delivery, not porting.
   Did you change map after joining?
2. **Old pack still mounted?** Remove its ID from `mm_extra_addons`.
3. Only then is it the model. Try
   `.\Port-Model.ps1 -Model <name> -KeepAG1Nodes`, which flips one of the
   riskier calls.
</details>

<details>
<summary><b>Model is sideways or upside down</b></summary>

The pelvis transform didn't apply. `Verify-Model.ps1` catches this — look for
`pelvis position ... is Z-up`. Height should be the **middle** of three numbers.
</details>

<details>
<summary><b>Elbows and knees mangle when they bend</b></summary>

Missing twist constraints. Valve's agents have sixteen driving the twist bones;
ported models have none. Cosmetic, and not fixable from a text edit —
see [NOTES.md](NOTES.md).
</details>

<details>
<summary><b>First-person arms aren't the model's arms</b></summary>

Working as intended. AG2 splits arms from the player model — Valve ships them
under `agents/models/shared/arms/glove_*`. Ported models get CS2's standard
arms, same as Valve's own agents. The pack's `*_pm_arm.vmdl` files are a
separate job.
</details>

<details>
<summary><b>Put my PC back how it was</b></summary>

```powershell
.\Cleanup-AG2.ps1            # shows what it would delete
.\Cleanup-AG2.ps1 -Remove    # deletes it, restores gameinfo.gi
```
</details>

## Files

| | |
|---|---|
| `RUN-ME.bat` | double-click this |
| `Start.ps1` | the wizard `RUN-ME.bat` launches |
| `Setup-AG2.ps1` | one-time setup |
| `Port-Model.ps1` | extract → materials → port → compile |
| `AG2-All.ps1` | the model edits |
| `Fix-Materials.ps1` | material cleanup |
| `Verify-Model.ps1` | check before publishing |
| `Cleanup-AG2.ps1` | undo everything |
| [`NOTES.md`](NOTES.md) | technical writeup |

Every script runs standalone if you'd rather skip the wizard:
`-Pack` / `-Vpk` / `-Source`, `-ListOnly`, `-Model` / `-All`, `-Force`,
`-CS2Path`, `-Addon`, `-KeepAG1Nodes`, `-CompileOnly`.

## Linux

> [!WARNING]
> **Experimental and untested. Use this Windows version.**

There's a Linux port as a separate download. The porting logic is verified
identical, but `resourcecompiler` creates a **D3D graphics device** for GPU
texture encoding, so running it under Wine is uncertain and unconfirmed. It has
a `--no-compile` mode; `Port-Model.ps1 -CompileOnly` here finishes the job on a
Windows box. Publishing needs Windows regardless — the Workshop Manager is
GUI-only.

## Thanks

- **[ValveResourceFormat / Source2Viewer](https://github.com/ValveResourceFormat/ValveResourceFormat)**
  — does the actual heavy lifting; this is largely a wrapper around it
- **[B_CANSIN](https://steamcommunity.com/sharedfiles/filedetails/?id=3196629717)**
  — ported the first AG2 model by hand and left both the before and after in the
  same archive. Without that I'd have had nothing to compare against
- **[samyycX/CS2-PlayerModelChanger](https://github.com/samyycX/CS2-PlayerModelChanger)**
  — the plugin that loads these, and the README noting you must change map once
- **[nozb1](https://steamcommunity.com/profiles/76561198084596314/myworkshopfiles/?appid=730)**
  — I used his player model packs as the test base for all of this. Good models,
  properly rigged on CS2's own skeleton, which is a large part of why porting
  them turned out to be tractable at all
- **[kus/cs2-modded-server](https://github.com/kus/cs2-modded-server)** — the
  server stack I run this on

## On other people's work

I wrote this to fix a pack on my own server and documented the process so others
could do the same. It is a repair technique, not a redistribution tool, and I'd
rather it didn't become one.

The scripts don't check who made anything — they can't. That check is yours:

- **Ask before you publish.** A message costs nothing and settles it.
- **No answer isn't a yes.** If you can't reach the author, keeping it to your
  own server is the safe read.
- **"They abandoned it" isn't permission.** An inactive account still owns the
  work.
- **Credit them prominently** if you do publish, and link the original.

If you're the author of a pack and someone has republished it using this, that's
between you and them — but I'd want to know, so open an issue.

## Licence

MIT ([LICENSE](LICENSE)) — **for the scripts only.**

That licence covers the code in this repository. It grants you nothing over the
game assets the scripts operate on. Those belong to their original authors and
to Valve, and no amount of processing by this tool changes that.
