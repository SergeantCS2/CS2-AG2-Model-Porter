# CS2 AG2 Port — Linux

**Experimental. The Windows version is the one that's known to work.**

Fixes custom CS2 player models that T-pose after the AnimGraph2 update. This is
a rewrite of the Windows pipeline in Python and bash.

If you have access to a Windows machine, use the Windows package instead —
it's tested, and it can publish to the Workshop, which this cannot.

## Install

Download **`CS2-AG2-Model-Porter-linux.zip`** from the Releases page — not the green
"Code" button.

```bash
unzip CS2-AG2-Model-Porter-linux.zip
cd CS2-AG2-Model-Porter-linux
chmod +x start.sh ag2port.py
./start.sh
```

---

> [!IMPORTANT]
> **This tool does not give you rights to anyone's models.** It documents a
> repair process and grants no permission over anyone's assets. Ask the original
> author before publishing anything. See the Windows package's README for the
> full position.

> [!CAUTION]
> **Read this before you start.**
>
> `resourcecompiler` — the step that actually builds the model — is a Windows
> binary. Valve never shipped a Linux build. Worse, it isn't a plain CLI tool:
> it creates a **D3D graphics device** and does GPU texture encoding (BC7,
> DXT1). You can see it in any compile log:
>
> ```
> Creating device for graphics adapter 0 'NVIDIA GeForce RTX 4070'
>        Encoding 1024x1024x1 texture to DXT1 (Q=3): 61ms
> ```
>
> That means running it under Wine needs working D3D11 in the prefix, which is
> a much bigger ask than a console program. It may work under Proton, which
> bundles DXVK. **It has not been verified.** Nobody has tested this end to end
> on Linux yet.
>
> Everything *else* — extraction, the model edits, materials, verification —
> runs natively and is verified to produce output identical to Windows.

**So there are two ways to use this**, and the second one always works.

---

## Path A — try compiling locally

`./ag2port.py setup` will actually invoke the compiler and tell you whether it
runs, rather than assuming:

```
  ...  testing whether the compiler runs (this is the risky bit)
  [ok]   compiler runs under proton
```

or

```
  [FAIL] compiler did not run correctly under wine
         It needs a working D3D device for texture encoding.
         Port with --no-compile and finish on Windows instead.
```

If it passes, everything works locally:

```bash
./start.sh                       # or:
./ag2port.py port --pack 1234567890 --all
./ag2port.py verify --all
```

## Path B — port on Linux, compile on Windows

Guaranteed to work. All the interesting work happens on Linux; Windows just
runs the compiler.

**On Linux:**

```bash
./ag2port.py port --pack 1234567890 --all --no-compile
```

Full pipeline minus the compile. You end up with prepared ModelDoc sources
under:

```
<CS2>/content/csgo_addons/<addon>/
```

**Copy that folder to a Windows machine** with CS2 + the Workshop Tools, into
the same path. Then there:

```powershell
.\Port-Model.ps1 -CompileOnly
```

That only compiles what you prepared. It doesn't re-port anything and doesn't
need the original pack on that machine.

Publishing has to happen there too — the Workshop Manager is GUI-only.

---

## Quick start

```bash
chmod +x start.sh ag2port.py
./start.sh
```

Menu: **1** set up → **4** port everything → **5** verify.

Or directly:

```bash
./ag2port.py setup
./ag2port.py list   --pack 1234567890
./ag2port.py port   --pack 1234567890 --all
./ag2port.py verify --all
```

## What you need

| | |
|---|---|
| Python 3.8+ | already on every distro |
| CS2 | Steam Play / Proton install is fine |
| CS2 Workshop Tools DLC | Steam Library → right-click CS2 → Properties → DLC → tick it (~10 GB) |
| Source2Viewer CLI | `./ag2port.py setup` downloads it to `~/s2v` |
| Wine or Proton | **only** for Path A |

> [!WARNING]
> If you install Source2Viewer by hand, **extract the whole zip**. The binary
> needs `libSkiaSharp.so` and friends beside it. Copy just the executable and
> decompiling fails with a SkiaSharp error that doesn't mention the real cause.

CS2 is found automatically — it checks `~/.steam/steam`, `~/.local/share/Steam`,
the Flatpak path, and any libraries in `libraryfolders.vdf`. Override with
`--cs2`.

## Where models can come from

```bash
./ag2port.py port --pack 1234567890         --all    # workshop, subscribed
./ag2port.py port --vpk ~/packs/old_dir.vpk --all    # any .vpk on disk
./ag2port.py port --source ~/extracted      --all    # loose .vmdl_c files
```

Loose files want this shape, though folder names don't matter — each model
records its own intended path internally:

```
~/extracted/
  somemodel_player_model/
    somemodel_player_model.vmdl_c        <- required
    materials/
      whatever.vmat_c                    <- strongly recommended
      whatever.vtex_c                    <- strongly recommended
```

Subfolders are searched. Anything without a skeleton is skipped, which filters
viewmodel arms automatically.

## Flags

| | |
|---|---|
| `--cs2 <path>` | CS2 install, if auto-detect fails |
| `--addon <name>` | addon name (default `ag2port`) |
| `--pack` / `--vpk` / `--source` | where models come from |
| `--model <name>` / `--all` | one or everything |
| `--no-compile` | prepare sources, skip the compile (Path B) |
| `--force` | re-port models already compiled |
| `--keep-ag1` | keep `MovementSettings`/`Feet`/`character_arm_config` |

Settings persist in `~/.config/ag2port/settings.json`.

## Troubleshooting

<details>
<summary><b>Compiler fails or hangs under Wine</b></summary>

Most likely outcome, honestly. It needs a D3D device. Options:

1. Use Proton instead of plain Wine — it bundles DXVK. Installing CS2 through
   Steam Play is enough; it gets detected automatically.
2. Try it by hand to see the real error:
   ```bash
   wine "<CS2>/game/bin/win64/resourcecompiler.exe" -h
   ```
3. Give up on local compiling and use `--no-compile` (Path B above). Nothing is
   lost — the ported sources are identical either way.
</details>

<details>
<summary><b>Decompiling fails with a SkiaSharp error</b></summary>

Source2Viewer is missing its native libraries. Extract the whole
`cli-linux-x64.zip` into `~/s2v` — the `.so` files must live beside the binary.
</details>

<details>
<summary><b>"could not find CS2"</b></summary>

```bash
./ag2port.py --cs2 "/mnt/games/SteamLibrary/steamapps/common/Counter-Strike Global Offensive" setup
```

Saved after the first run.
</details>

<details>
<summary><b>gameinfo.gi not writable</b></summary>

A Flatpak Steam install may sandbox it. Check ownership — if CS2 is on a mount
without write permission, that has to be fixed before setup can patch it.
</details>

<details>
<summary><b>"no player models found"</b></summary>

The tool skips any `.vmdl_c` without a skeleton, which filters out viewmodel
arms and props. If it skips everything, you probably have arms-only files, or
decompiled `.vmdl` sources rather than compiled `.vmdl_c`.

```bash
find ~/your/folder -name '*.vmdl_c' -size +100k
```

Player models are usually 200 KB and up.
</details>

## Is the output the same as Windows?

Yes, and this part *is* verified. The same model through both implementations:

```
pelvis_origin     linux=-0.000000, 42.123554, 0.458082    windows=same
pelvis_angles     linux=0.000000, 90.000000, 86.490982    windows=same
wpn_origin        linux=0.0, -58.781662, 3.471689         windows=same
counts            vanmgrph=0 vnmgraph=4 wpnPivot=1 vnmskel=2
```

Identical on every checked property, pelvis transform matching to six decimal
places. Two independent implementations agreeing is a decent check on both.

The *compile* is the unverified part, not the porting.

---

## Honestly, should you use this?

**Use the Windows package if you can.** It's tested end to end, it publishes,
and it has no uncertainty around the compile step.

This package makes sense if:

- You have no Windows machine at all, and want to at least prepare the models
- You're comfortable troubleshooting Wine
- You want to help confirm whether the compile works, and report back

It does not make sense if you just want working models and have a Windows PC
available.

## For what's being changed and why

See [`NOTES.md`](NOTES.md) — the technical writeup, shared with the Windows
package.
For publishing and server setup, see the Windows package's README — that side
of the process is the same, and the Workshop Manager only exists there.
