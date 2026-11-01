# Contributing

> **On other people's models:** this project documents a repair process and
> grants no rights over anyone's assets. Don't open PRs or issues that amount to
> "help me republish someone's pack" — ask the author instead. See the README.


## Before opening an issue

Include the log. `Port-Model.ps1` writes a full transcript to `logs\` plus a
per-model compiler log — those two answer most questions immediately. The
transcript's first lines give the script and Source2Viewer versions; include
them.

State whether the model **compiled**, **verified**, and **mounted**, in that
order. Most reports that look like "the port failed" turn out to be the addon
never reaching the client.

## Known open problems

**Twist constraints.** Valve's agents carry 16 `CTiltTwistConstraint` lists
driving forearm and leg twist bones; ported models have none, so limbs deform
poorly under rotation. The ModelDoc source format takes bone *names*, so the
bone hash is not the obstacle — the obstacle is `relative_origin` and
`relative_angles`, which encode per-model geometry. Deriving them wrong makes
limbs worse than leaving them out. Wants someone with a rigging background.

**Viewmodel arms.** `*_pm_arm.vmdl` files have no animgraph reference at all and
are a separate port this tool does not attempt. AG2 decouples arms from the
player model, so ported models fall back to CS2's standard arms — which is what
Valve's own agents do, and is arguably correct.

**Models from other games.** Garry's Mod and other ValveBiped models need a
re-rig onto CS2's skeleton before this tool can finish them
([PORTING-OTHER-GAMES.md](PORTING-OTHER-GAMES.md)). Unpacking, decompiling and
material conversion could be automated around Crowbar and Blender; matching the
rest pose is the part that takes judgement. Anyone who automates a reliable
piece of that route is very welcome.

**Sample size.** Every rule here is inferred from three models of one lineage:
two Valve agents, plus one custom model that was conformed to match them. A
working AG2 port by an unrelated author would be the single most valuable thing
anyone could contribute. If you have one, open an issue with its structure.

## Model sources

Three input paths, all going through the same pipeline after discovery:

| mode | flag | notes |
|---|---|---|
| Workshop | `-Pack <id>` | must be subscribed and downloaded; looked for in CS2's own Steam library |
| loose VPK | `-Vpk <path>` | any `.vpk`; split archives resolve via `_dir` |
| loose files | `-Source <folder>` | recursive scan for `.vmdl_c` |
| prepared sources | `-CompileOnly` | `.vmdl` already in the content addon — the Linux handoff, and models re-rigged from other games |

Loose files are placed by reading `m_name` from the compiled model, which holds
the path the model was originally compiled for. A model is only treated as a
player model if its skeleton has a body — `pelvis` plus a leg — which filters
viewmodel arms and props without a name heuristic. VPKs are listed: models in
the usual `<name>/<name>.vmdl_c` layout are taken as they are, and any other
large model file is taken if its skeleton passes the same body test.

If you add a fourth source, the only contract is: produce a `.vmdl` and its
`.dmx` files under the content addon at the model's intended path, with
materials alongside. Everything downstream is shared.

## Testing a change

Run the test suite first. It needs Python 3 on PATH and nothing else — no CS2,
no game files:

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1    # Windows PowerShell 5.1
```

```bash
pwsh tests/Run-Tests.ps1                                       # Linux / macOS
```

It runs the real scripts against synthetic models (`tests\Fixtures.ps1`) and
small stand-ins for Source2Viewer and `resourcecompiler` (`tests\fakes\`). It
covers the model edits, a full port of a fake Workshop pack, Verify, Setup and
Cleanup, and a run under a comma-decimal Windows region. For the common cases
it checks the edited `.vmdl` is byte-identical to the last release's (ignoring
the sign of zero: PowerShell 5.1 writes `0.000000` where 7 writes
`-0.000000`) — if you change those edits on purpose, update the hashes and say
why in the PR. The
same suite runs on every push and pull request (GitHub Actions, Windows
PowerShell 5.1).

The suite proves the scripts do what they say on known input. It cannot prove
a model animates; that is still only testable in game. Before a release:

1. the test suite passes
2. `Port-Model.ps1 -All` on a full real pack, no failures
3. `Verify-Model.ps1 -All` clean
4. at least one model loaded on a server and observed animating

Syntax-checking PowerShell is not testing. An undefined variable parses fine and
silently does nothing — that specific mistake cost several hours during
development. So did `,` binding tighter than `+` in an array literal:
`@("$a" + "b", "c")` is not two lines, it is one.
