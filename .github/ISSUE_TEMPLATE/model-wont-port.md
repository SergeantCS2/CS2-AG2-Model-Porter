---
name: A model won't port
about: Compile fails, or the script errors out
title: ''
labels: ''
---

**Which model, and where did it come from?**
Workshop pack ID / a `.vpk` on disk / loose files.

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
