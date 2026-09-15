# Contributing

> **On other people's models:** this project documents a repair process and
> grants no rights over anyone's assets. Don't open PRs or issues that amount to
> "help me republish someone's pack" — ask the author instead. See the README.


## Before opening an issue

Include the log. `Port-Model.ps1` writes a full transcript to `logs\` plus a
per-model compiler log — those two answer most questions immediately.

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

**Sample size.** Every rule here is inferred from three models of one lineage:
two Valve agents, plus one custom model that was conformed to match them. A
working AG2 port by an unrelated author would be the single most valuable thing
anyone could contribute. If you have one, open an issue with its structure.

## Model sources

Three input paths, all going through the same pipeline after discovery:

| mode | flag | notes |
|---|---|---|
| Workshop | `-Pack <id>` | must be subscribed and downloaded |
| loose VPK | `-Vpk <path>` | any `.vpk`; split archives resolve via `_dir` |
| loose files | `-Source <folder>` | recursive scan for `.vmdl_c` |

Loose files are placed by reading `m_name` from the compiled model, which holds
the path the model was originally compiled for. Anything without an
`m_modelSkeleton` is skipped — that filters viewmodel arms and props without
needing a name heuristic.

If you add a fourth source, the only contract is: produce a `.vmdl` and its
`.dmx` files under the content addon at the model's intended path, with
materials alongside. Everything downstream is shared.

## Testing a change

There is no automated test suite; the only real test is in-game. At minimum:

1. `Port-Model.ps1 -All` on a full pack, no failures
2. `Verify-Model.ps1 -All` clean
3. At least one model loaded on a server and observed animating

Syntax-checking PowerShell is not testing. An undefined variable parses fine and
silently does nothing — that specific mistake cost several hours during
development.
