---
name: A model won't port
about: Compile fails, or the script errors out
title: ''
labels: ''
---

**Which model, and where did it come from?**
Workshop pack ID / a `.vpk` on disk / loose files / converted from another game
(Garry's Mod, CS:GO... - say which, and how far through PORTING-OTHER-GAMES.md
you got).

**Versions**
The first lines of the `Port-Model.ps1` log: the script version and the
Source2Viewer-CLI version.

**Where did it stop?**
Extract, materials, port, or compile.

**Paste the relevant part of the log**
`Port-Model.ps1` writes a transcript to `logs\` plus a per-model compiler log.
Those two usually answer it outright.

```
paste here
```

**Counts line, if it got that far**
```
counts  vanmgrph=? vnmgraph=? wpnPivot=? vnmskel=?     (want 0 4 1 2)
```
