---
name: Ported model still T-poses
about: It compiled and verified, but doesn't animate in game
title: ''
labels: ''
---

**Please check these first — they're the answer more often than the port is.**

- [ ] `Verify-Model.ps1` passes for this model
- [ ] Server log shows `Mounting addon '<your id>'`, not `Addon download started` on repeat
- [ ] The original pack's ID is **removed** from `mm_extra_addons`
- [ ] I'm subscribed to my own published item
- [ ] I changed map at least once after joining
- [ ] I launched CS2 from Steam's Play button, not the Workshop Tools

**Verify output for the model**
```
paste here
```

**Client console with `developer 1` set before switching models**
Look for a failed load of your `.vmdl_c`. If the client can't find the file,
it's delivery, not the port.

```
paste here
```

**Anything unusual about the model?**
Missing fingers or toes, odd bone names, unusual rig — `Verify-Model.ps1`
reports all of this.
