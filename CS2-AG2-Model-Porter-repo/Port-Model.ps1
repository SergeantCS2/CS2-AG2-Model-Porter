param(
    [string]$Model,                                       # e.g. eula   (or -All)
    [switch]$All,                                         # port every model in the pack
    [switch]$ListOnly,                                    # just list what's in the pack
    [string]$Addon   = "ag2port",

    # --- where the models come from. Pick one. ---
    [string]$Pack    = "3186973222",   # a workshop id you are subscribed to
    [string]$Vpk     = "",             # any .vpk on disk (delisted pack, backup, manual download)
    [string]$Source  = "",             # a folder of loose .vmdl_c files
    [string]$S2V     = "$env:USERPROFILE\s2v\Source2Viewer-CLI.exe",
    [switch]$KeepAG1Nodes,   # retain MovementSettings/Feet/character_arm_config (off by default)
    [switch]$Force,          # re-port models that are already compiled
    [switch]$CompileOnly,    # compile .vmdl sources already in the addon (Linux handoff)
    # CS2 lives elsewhere if your Steam library is on another drive
    [string]$CS2Path = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"
)

# End-to-end: pull a model out of the workshop VPK, port it to AnimGraph2,
# fix its materials, and compile. No GUI at any step.
#
#   .\Port-Model.ps1 -ListOnly
#   .\Port-Model.ps1 -Model eula
#   .\Port-Model.ps1 -All
#
# Requires (one-time): CS2 Workshop Tools, Source2Viewer-CLI at $S2V,
# "include" "characters" in gameinfo.gi, and an addon created named $Addon.

$ErrorActionPreference = "Stop"
$SCRIPT_VERSION = "1.2.0"

# Native stderr handling differs between Windows PowerShell 5.1 and PowerShell 7:
# 5.1 promotes a native program's stderr into terminating errors when combined
# with $ErrorActionPreference = "Stop". Start-Process with file redirection
# sidesteps the conversion entirely and behaves identically on both.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        # Start-Process joins ArgumentList with spaces and does NOT quote, so any
        # argument containing a space (e.g. "C:\Program Files (x86)\...") must be
        # quoted here or the native command receives it split into pieces.
        $q = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        Start-Process -FilePath $Exe -ArgumentList $q -NoNewWindow -Wait `
                      -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
        return ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + "`n" +
                (Get-Content $e -Raw -ErrorAction SilentlyContinue))
    } finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

# VRF cannot decompile CS2 materials on a machine that HAS CS2 installed: it
# locates csgo_character.vfx, tries to parse it, and CS2 ships shader version 71
# while VRF supports up to 70. It then writes no .vmat at all. (On a machine
# without CS2 it fails to find the shader and degrades to a generic .vmat, which
# is why this does not reproduce in a bare sandbox.)
#
# The compiled .vmat_c DATA block carries the shader name and every parameter,
# and reading it needs no shader introspection. Rebuild the source from that.
function Rebuild-Vmat {
    param([string]$VmatC, [string]$S2V)
    $t = Invoke-Native $S2V @("-i", $VmatC, "--block", "DATA")
    $sh = [regex]::Match($t, 'm_shaderName\s*=\s*"([^"]*)"')
    if (-not $sh.Success) { return $false }
    $out = @("// rebuilt from $(Split-Path -Leaf $VmatC)", "", "Layer0", "{",
             "`tshader `"$($sh.Groups[1].Value)`"", "")
    foreach ($grp in @(
        @{k='m_intParams';     q=$false}, @{k='m_floatParams';   q=$false},
        @{k='m_vectorParams';  q=$true },  @{k='m_textureParams'; q=$true },
        @{k='m_intAttributes'; q=$false})) {
        $m = [regex]::Match($t, [regex]::Escape($grp.k) + '\s*=\s*\r?\n?\s*\[(.*?)\r?\n\t\]', 'Singleline')
        if (-not $m.Success) { continue }
        foreach ($e in [regex]::Matches($m.Groups[1].Value, '\{(.*?)\}', 'Singleline')) {
            $n = [regex]::Match($e.Groups[1].Value, 'm_name\s*=\s*"([^"]*)"')
            $v = [regex]::Match($e.Groups[1].Value, 'm_(?:nValue|flValue|pValue|value)\s*=\s*(.+)')
            if (-not ($n.Success -and $v.Success)) { continue }
            $name = $n.Groups[1].Value
            $val  = $v.Groups[1].Value.Trim().TrimEnd(',').Trim('"')
            if ($grp.k -eq 'm_vectorParams') {
                $nums = ($val -replace '[\[\]]','').Split(',') | ForEach-Object { "{0:F6}" -f [double]$_.Trim() }
                $val = "[" + ($nums -join " ") + "]"
            }
            if ($grp.k -eq 'm_textureParams') {
                $val  = $val -replace '^resource:"?','' -replace '"$',''
                $val  = $val -replace '\.vtex$', '.png'
                $name = $name -replace '^g_t', 'Texture'
            }
            $out += $(if ($grp.q) { "`t$name `"$val`"" } else { "`t$name $val" })
        }
        $out += ""
    }
    $out += @("}", "")
    Set-Content ($VmatC -replace '_c$','') -Value $out
    return $true
}

# --- logging -----------------------------------------------------------------
# Everything below, including sub-script output and compiler output, is captured
# to a timestamped log next to this script. Send me the log when something fails.
$LogDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("port-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
# keep the last 20 runs; a long session otherwise leaves hundreds behind
Get-ChildItem $LogDir -Filter "port-*.log" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
    Remove-Item -Force -EA SilentlyContinue
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}
Write-Host "Port-Model $SCRIPT_VERSION   log: $LogFile" -ForegroundColor DarkGray

$CS  = $CS2Path
$VPK = if ($Vpk) { $Vpk }
       else { "C:\Program Files (x86)\Steam\steamapps\workshop\content\730\$Pack\$Pack.vpk" }
# Large packs ship split: <id>_dir.vpk (the index) plus <id>_000.vpk and so on.
# There is no plain <id>.vpk in that case, so the path built above will not
# exist. Always address the _dir index - handing the CLI an archive part, or a
# name that does not exist, both fail.
if ($VPK -and $VPK -notmatch '_dir\.vpk$') {
    $stem = [IO.Path]::ChangeExtension($VPK, $null).TrimEnd('.') -replace '_\d{3}$', ''
    if (Test-Path "${stem}_dir.vpk") {
        $VPK = "${stem}_dir.vpk"
    } elseif (-not (Test-Path $VPK)) {
        # last resort: any .vpk in the folder, index first
        $alt = Get-ChildItem (Split-Path $VPK -Parent) -Filter *.vpk -EA SilentlyContinue |
               Sort-Object { $_.Name -notlike "*_dir.vpk" } | Select-Object -First 1
        if ($alt) { $VPK = $alt.FullName }
    }
}
$OUT = "$CS\content\csgo_addons\$Addon"
$RC  = "$CS\game\bin\win64\resourcecompiler.exe"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$need = @(@{p=$RC; n="resourcecompiler"})
if (-not $CompileOnly) {
    $need += @{p=$S2V; n="Source2Viewer-CLI"}
    if (-not $Source) { $need += @{p=$VPK; n="source VPK"} }
}
foreach ($p in $need) {
    if (-not (Test-Path $p.p)) { Write-Error "$($p.n) not found: $($p.p)"; exit 1 }
}
if ($Source -and -not (Test-Path $Source)) { Write-Error "source folder not found: $Source"; exit 1 }
# Listing does not write anything, so it should not demand an addon exists.
if (-not $ListOnly -and -not (Test-Path $OUT)) {
    Write-Error "addon '$Addon' not created yet - run Setup-AG2.ps1 -Addon $Addon"
    exit 1
}
$gi = (Select-String -Path "$CS\game\csgo\gameinfo.gi" -Pattern '"include"\s+"characters"' -EA SilentlyContinue).Count
if ($gi -eq 0) { Write-Warning "gameinfo.gi has no 'characters' include - your published VPK will be empty. Run Setup-AG2.ps1." }

# ---------------------------------------------------------------- compile only
# For the Linux workflow: models were ported there with --no-compile and the
# content folder copied across. Nothing to extract or edit, just compile.
if ($CompileOnly) {
    $srcs = @(Get-ChildItem $OUT -Recurse -Filter *.vmdl -EA SilentlyContinue |
              Where-Object { $_.BaseName -eq $_.Directory.Name })
    if (-not $srcs) { Write-Error "no .vmdl sources under $OUT"; exit 1 }
    Write-Host "compiling $($srcs.Count) prepared model(s)`n" -ForegroundColor Cyan
    $cok = 0; $cbad = @()
    $i = 0
    foreach ($f in $srcs) {
        $i++
        Write-Host "[$i/$($srcs.Count)] $($f.BaseName)" -ForegroundColor Cyan
        $log = Invoke-Native $RC @("-i", $f.FullName)
        Set-Content (Join-Path $LogDir "compile-$($f.BaseName).log") -Value $log
        if ($log -match 'ERROR: 0 compiled' -or ($log -match 'RESOURCE COMPILE ERROR' -and $log -notmatch 'OK:')) {
            ($log -split "`n" | Select-String 'RESOURCE COMPILE ERROR|Error!' | Select-Object -First 4) | Out-Host
            $cbad += $f.BaseName
        } else { Write-Host "  OK" -ForegroundColor Green; $cok++ }
    }
    Write-Host "`ncompiled : $cok   failed : $($cbad.Count)"
    $cbad | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    try { Stop-Transcript | Out-Null } catch {}
    exit $(if ($cbad.Count) { 1 } else { 0 })
}

# ---------------------------------------------------------------- discover
# Two ways in. A VPK gets listed; a folder of loose .vmdl_c files gets scanned.
# Either way each model tells us its own intended path via m_name, so the user
# never has to know where things are supposed to live.
$LooseFiles = @{}
if ($Source) {
    $ModelRoot = $null
    $skipped = @()
    foreach ($f in (Get-ChildItem $Source -Recurse -Filter *.vmdl_c -ErrorAction SilentlyContinue)) {
        $d = Invoke-Native $S2V @("-i", $f.FullName, "--block", "DATA")
        $mn = [regex]::Match($d, 'm_name\s*=\s*"([^"]+)"')
        if (-not $mn.Success) { continue }
        $intern = $mn.Groups[1].Value -replace '\.vmdl$', ''      # e.g. characters/models/pack/foo/foo
        $name = Split-Path $intern -Leaf

        # A player model has a full body skeleton. Viewmodel arms, props and map
        # stubs do not, whatever they are called - so test the bones rather than
        # guessing from the filename. Arms carry 20-40 bones and no pelvis.
        $bm = [regex]::Match($d, 'm_modelSkeleton\s*=\s*\{\s*m_boneName\s*=\s*\[(.*?)\]', 'Singleline')
        if (-not $bm.Success) { $skipped += "$name (no skeleton)"; continue }
        $bones = @([regex]::Matches($bm.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToLower() })
        # pelvis + a leg is the minimal signature of a body. Deliberately not
        # requiring spine_0 - some models run pelvis straight to spine_1 - nor
        # root_motion, which plenty of models are missing and we can add.
        $hasBody = ($bones -contains 'pelvis') -and
                   (($bones -contains 'leg_upper_l') -or ($bones -contains 'leg_upper_r'))
        if (-not $hasBody) { $skipped += "$name ($($bones.Count) bones, no body skeleton)"; continue }

        # Use the model's OWN directory from m_name. Reconstructing it as
        # <root>/<name> assumes the folder is named after the model, and plenty
        # are not - one pack has zombie.vmdl_c inside a folder called zombiertx.
        # Getting this wrong puts the .vmdl, its .dmx meshes and its materials
        # somewhere the compiler never looks.
        $LooseFiles[$name] = @{ File = $f.FullName; Dir = (Split-Path $intern -Parent) -replace '\\','/' }
    }
    if ($skipped.Count) {
        Write-Host "skipped $($skipped.Count) non-player-model file(s):" -ForegroundColor DarkGray
        $skipped | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }
    $models = $LooseFiles.Keys | Sort-Object
    if (-not $models) { Write-Error "no player models found in $Source"; exit 1 }
    Write-Host "found $($models.Count) model(s) in $Source" -ForegroundColor DarkGray
} else {
    $listing = Invoke-Native $S2V @("-i", $VPK, "-l", "-e", "vmdl_c")
    # Player models follow <path>/<name>/<name>.vmdl_c. Discover that shape rather
    # than hardcoding one pack's folder, so this works on any pre-AG2 pack.
    # Most packs use <path>/<name>/<name>.vmdl_c, but plenty do not - some put
    # several models in one folder, some put a single model directly under
    # models/. Store each model's own DIRECTORY rather than assuming a naming
    # convention, and fall back to every .vmdl_c if the tidy pattern matches
    # nothing.
    $ModelDirs = @{}
    foreach ($f in [regex]::Matches($listing, '([a-zA-Z0-9_/]+)/([a-zA-Z0-9_]+)/\2\.vmdl_c')) {
        $nm = $f.Groups[2].Value
        if (-not $ModelDirs.ContainsKey($nm)) { $ModelDirs[$nm] = "$($f.Groups[1].Value)/$nm" }
        elseif ($ModelDirs[$nm] -ne "$($f.Groups[1].Value)/$nm") {
            Write-Warning "two models named '$nm' in different folders - using $($ModelDirs[$nm])"
        }
    }
    if (-not $ModelDirs.Count) {
        Write-Host "no <name>/<name>.vmdl_c layout - scanning every model instead" -ForegroundColor DarkGray
        # the listing carries a size per entry - use it to skip stubs, props and
        # arms without having to extract and inspect every file
        foreach ($ln in ($listing -split "`n")) {
            $f = [regex]::Match($ln, '([a-zA-Z0-9_/\-]+)/([a-zA-Z0-9_\-]+)\.vmdl_c')
            if (-not $f.Success) { continue }
            $nm = $f.Groups[2].Value
            # viewmodel arms have no animgraph and are a separate port
            if ($nm -match '(_arms?|_pm_arm|viewmodel)$' -or $nm -match '_arms?_' -or $nm -like 'v_*') { continue }
            $sz = [regex]::Match($ln, 'size:(\d+)')
            if ($sz.Success -and [int]$sz.Groups[1].Value -lt 100000) { continue }   # too small to be a player model
            if (-not $ModelDirs.ContainsKey($nm)) { $ModelDirs[$nm] = $f.Groups[1].Value }
        }
    }
    $models = @($ModelDirs.Keys | Sort-Object)
    if (-not $models) {
        Write-Error ("no player models found in $VPK`n" +
                     "Run this to see what is actually in it:`n" +
                     "  & `"$S2V`" -i `"$VPK`" -l -e vmdl_c")
        exit 1
    }
    $roots = @($ModelDirs.Values | ForEach-Object { Split-Path $_ -Parent } |
               ForEach-Object { $_ -replace '\\','/' } | Sort-Object -Unique)
    Write-Host ("model root: " + ($roots -join ', ')) -ForegroundColor DarkGray
}

if ($ListOnly -or (-not $Model -and -not $All)) {
    $src = if ($Source) { $Source } elseif ($Vpk) { Split-Path $Vpk -Leaf } else { "pack $Pack" }
    Write-Host "`n$($models.Count) models in $src :`n" -ForegroundColor Cyan
    $models | ForEach-Object { "  " + ($_ -replace '_player_model$','') }
    Write-Host "`nUsage:  .\Port-Model.ps1 -Model <name>   |   -All`n"
    try { Stop-Transcript | Out-Null } catch {}
    exit
}

$todo = if ($All) { $models } else {
    $m = $models | Where-Object { $_ -eq $Model -or $_ -eq "${Model}_player_model" }
    if (-not $m) { Write-Error "'$Model' not in pack. Run -ListOnly."; exit 1 }
    @($m)
}

# ---------------------------------------------------------------- per model
$ok = @(); $bad = @(); $sizes = @{}
$modelIndex = 0; $total = $todo.Count
$started = Get-Date
foreach ($m in $todo) {
    $modelIndex++
    $label = $m -replace '_player_model$', ''
    $prefix = if ($total -gt 1) { "[$modelIndex/$total] " } else { "" }
    Write-Host "`n=== $prefix$label ===" -ForegroundColor Cyan
    $ModelDir     = if ($Source) { $LooseFiles[$m].Dir } else { $ModelDirs[$m] }
    $ModelRoot    = (Split-Path $ModelDir -Parent) -replace '\\','/'
    $ModelDirWin  = $ModelDir.Replace("/", "\")
    $dir  = "$OUT\$ModelDirWin"
    $MAT  = "$dir\materials"
    $vmdl = "$dir\$m.vmdl"
    $filt = "$ModelDir/"

    try {
        # already done? skip unless asked to redo
        $done = "$CS\game\csgo_addons\$Addon\$ModelDirWin\$m.vmdl_c"
        if ((Test-Path $done) -and -not $Force) {
            Write-Host "already compiled - skipping (use -Force to redo)" -ForegroundColor DarkGray
            $sizes[$label] = (Get-Item $done).Length
            $ok += $m
            continue
        }

        # 1. get the source. From a VPK we extract; from loose files we decompile
        # the .vmdl_c in place. A single decompile pass yields .vmdl, .dmx, .png
        # and .vmat - the CLI handles CS2 materials fine even though the GUI cannot.
        Write-Host "extracting..."
        if ($Source) {
            $null = Invoke-Native $S2V @("-i", $LooseFiles[$m].File, "-o", $vmdl, "-d")
            # carry any sibling materials across so the rebuild can find them
            # Materials do not reliably live in a folder called "materials" -
            # some packs use "mat", some sit beside the model, some nest deeper.
            # Take every .vmat_c/.vtex_c under the model's folder, wherever it is.
            # Mirror the source folder structure rather than flattening into a
            # folder called "materials". Packs use "mat", "materials", or nest
            # deeper, and the model references whichever it was built with.
            $srcRoot = Split-Path $LooseFiles[$m].File -Parent
            $srcMats = @(Get-ChildItem $srcRoot -Recurse -File -EA SilentlyContinue |
                         Where-Object { $_.Extension -in '.vmat_c', '.vtex_c' })
            $matDirsFound = @()
            foreach ($sm in $srcMats) {
                $rel = $sm.FullName.Substring($srcRoot.Length).TrimStart('\','/')
                $tgt = Join-Path $dir $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $tgt -Parent) | Out-Null
                Copy-Item $sm.FullName $tgt -Force -EA SilentlyContinue
                $matDirsFound += (Split-Path $tgt -Parent)
            }
            $matDirsFound = @($matDirsFound | Sort-Object -Unique)
            if ($srcMats.Count) {
                Write-Host "  collected $($srcMats.Count) material file(s) into $($matDirsFound.Count) folder(s)"
            } else {
                Write-Warning "  no .vmat_c/.vtex_c found under $srcRoot - model will be untextured"
            }
        } else {
            $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", $filt, "-d")
        }
        if (-not (Test-Path $vmdl)) { throw "no .vmdl produced" }

        # Materials do not always live beside the model. Valve's own agents keep
        # the model under agents/models/<name>/ and its materials under
        # characters/models/<name>/materials/. Read the compiled model's resource
        # list and pull in anything that falls outside what we just extracted.
        # @(...) around the whole expression is load-bearing: PowerShell unwraps
        # a single-element array returned from an if, leaving a string, and then
        # += concatenates instead of appending.
        $matDirs = @(if ($Source -and $matDirsFound.Count) { $matDirsFound } else { $MAT })
        if (-not $Source) {
            $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$ModelDir/$m.vmdl_c", "-e", "vmdl_c")
            $rawC = "$dir\$m.vmdl_c"
            if (Test-Path $rawC) {
                $rerl = Invoke-Native $S2V @("-i", $rawC, "--block", "RERL")
                $extern = @([regex]::Matches($rerl, '([a-z0-9_/]+)/[a-z0-9_.]+\.vmat') |
                            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
                            Where-Object { $_ -notlike "$ModelDir/*" })
                foreach ($e in $extern) {
                    Write-Host "  materials live elsewhere: $e"
                    $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$e/", "-d")
                    $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$e/", "-e", "vmat_c")
                    $matDirs += "$OUT\$($e.Replace('/','\'))"
                }
            }
        }

        # If VRF produced no .vmat (CS2 present -> VCS v71 -> it throws), pull the
        # compiled .vmat_c and rebuild the sources from their DATA blocks.
        $haveVmat = @($matDirs | ForEach-Object { Get-ChildItem "$_\*.vmat" -EA SilentlyContinue }).Count
        if ($haveVmat -eq 0) {
            Write-Host "  no .vmat from VRF - rebuilding from compiled data"
            if ([string]::IsNullOrWhiteSpace($MAT)) { throw "internal: materials path empty" }
            if (-not $Source) { $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", $filt, "-e", "vmat_c") }
            # deliberately not $n - that is the outer loop's model counter
            $nRebuilt = 0
            foreach ($vc in ($matDirs | ForEach-Object { Get-ChildItem "$_\*.vmat_c" -EA SilentlyContinue })) {
                if (Rebuild-Vmat $vc.FullName $S2V) { $nRebuilt++ }
            }
            Write-Host "  rebuilt $nRebuilt material(s)"
            if ($nRebuilt -eq 0) { throw "could not rebuild any materials" }
        }

        # Textures arrive as compiled .vtex_c. The rebuilt .vmat files point at
        # image sources, so turn them into .png BEFORE the sweep below deletes
        # every _c file - otherwise the materials reference images that are not
        # there and the model renders black.
        if ($Source) {
            $nTex = 0
            foreach ($tc in ($matDirs | ForEach-Object { Get-ChildItem "$_\*.vtex_c" -EA SilentlyContinue })) {
                $png = [IO.Path]::ChangeExtension($tc.FullName, $null).TrimEnd('.')
                $png = ($png -replace '\.vtex$', '') + '.png'
                if (-not (Test-Path $png)) {
                    $null = Invoke-Native $S2V @("-i", $tc.FullName, "-o", $png, "-d")
                    if (Test-Path $png) { $nTex++ }
                }
            }
            if ($nTex) { Write-Host "  decompiled $nTex texture(s) to png" }
        }

        # A model can reference materials its source folder does not contain -
        # shared assets the pack normally supplies, missing from a hand-made zip.
        # Try CS2's own files first, then fall back to a minimal placeholder so
        # one absent texture does not fail the whole model.
        $srcModel = if ($Source) { $LooseFiles[$m].File } else { "$dir\$m.vmdl_c" }
        if (Test-Path $srcModel) {
            $rerl = Invoke-Native $S2V @("-i", $srcModel, "--block", "RERL")
            $needed = @([regex]::Matches($rerl, '[a-z0-9_/]+\.vmat') |
                        ForEach-Object { $_.Value } | Sort-Object -Unique)
            $pak = "$CS\game\csgo\pak01_dir.vpk"
            $made = 0; $pulled = 0
            foreach ($need in $needed) {
                $tgt = Join-Path $OUT ($need -replace '/','\')
                if (Test-Path $tgt) { continue }
                New-Item -ItemType Directory -Force -Path (Split-Path $tgt -Parent) | Out-Null
                if (Test-Path $pak) {
                    $null = Invoke-Native $S2V @("-i", $pak, "-o", $OUT, "-f", "$($need)_c", "-d")
                    if (Test-Path $tgt) { $pulled++; continue }
                }
                # minimal stand-in: compiles, renders with the shader default
                @("// placeholder - original not present in the source",
                  "Layer0", "{", "`tshader `"csgo_character.vfx`"", "}") | Set-Content $tgt
                $made++
            }
            if ($pulled) { Write-Host "  pulled $pulled missing material(s) from CS2" }
            if ($made)   { Write-Warning "  $made material(s) not in the source - placeholders used, those meshes will be untextured" }
        }

        # content/ holds SOURCES only. Any compiled artefact that lands here
        # confuses resourcecompiler, so sweep them.
        $sweepDirs = @($dir) + @($matDirs | Where-Object { $_ -notlike "$dir*" })
        $stray = @($sweepDirs | Sort-Object -Unique | ForEach-Object {
                    Get-ChildItem $_ -Recurse -File -Include *_c -EA SilentlyContinue })
        if ($stray.Count) { $stray | Remove-Item -Force; Write-Host "  swept $($stray.Count) stray compiled file(s)" }

        # 2. materials
        $fm = Join-Path $here "Fix-Materials.ps1"
        if (Test-Path $fm) {
            foreach ($md in ($matDirs | Sort-Object -Unique)) {
                if (Test-Path $md) { & powershell -ExecutionPolicy Bypass -File $fm -MaterialsDir $md | Out-Host }
            }
        }

        # Already ported? Say so plainly rather than running edits that all
        # no-op. Some packs were fixed by their own authors post-AG2.
        $pre = Get-Content $vmdl -Raw -EA SilentlyContinue
        if ($pre -and $pre -notmatch 'vanmgrph' -and
            ([regex]::Matches($pre, '\.vnmgraph')).Count -ge 3 -and
            ([regex]::Matches($pre, '\.vnmskel')).Count  -ge 2) {
            Write-Host "  already AnimGraph2 - nothing to port" -ForegroundColor DarkGray
            $alreadyAG2 = $true
        } else { $alreadyAG2 = $false }

        # 3. port
        $ag = Join-Path $here "AG2-All.ps1"
        if (-not (Test-Path $ag)) { throw "AG2-All.ps1 not next to this script" }
        $agArgs = @("-ExecutionPolicy","Bypass","-File",$ag,"-Path",$vmdl)
        if ($KeepAG1Nodes) { $agArgs += "-KeepAG1Nodes" }
        & powershell @agArgs | Out-Host

        $c = @{}
        foreach ($p in 'vanmgrph','vnmgraph','wpnPivot','vnmskel') {
            $c[$p] = (Select-String -Path $vmdl -Pattern $p -EA SilentlyContinue).Count
        }
        Write-Host ("counts  vanmgrph={0} vnmgraph={1} wpnPivot={2} vnmskel={3}" -f `
            $c['vanmgrph'],$c['vnmgraph'],$c['wpnPivot'],$c['vnmskel'])
        # What actually matters: no AnimGraph1 binding left, and a working AG2
        # one. Valve and B_CANSIN both ship 4 graph references, but the fourth
        # is a duplicate of the worldmodel graph - packs ported by other people
        # use 3 and work. Anything below 3 is missing a real binding.
        if ($c['vanmgrph'] -ne 0) { throw "still references AnimGraph1 - port did not apply" }
        if ($c['vnmgraph'] -lt 3) { throw "only $($c['vnmgraph']) graph reference(s) - port did not apply" }
        if ($c['vnmskel']  -lt 2) { throw "only $($c['vnmskel']) skeleton reference(s) - port did not apply" }
        if ($c['wpnPivot'] -lt 1) { Write-Warning "  no wpnPivot bone - weapon may be misplaced" }

        # 4. compile
        Write-Host "compiling..."
        $log = Invoke-Native $RC @("-i", $vmdl)
        $clog = Join-Path $LogDir "compile-$m.log"
        Set-Content $clog -Value $log
        $skin = ([regex]::Matches($log, 'Invalid skinning bone index')).Count
        Write-Host "  compiler: $skin skinning warning(s) (cosmetic) - full log: $clog"
        if ($log -match 'ERROR: 0 compiled') {
            ($log -split "`n" | Select-String 'RESOURCE COMPILE ERROR|Error!' | Select-Object -First 6) | Out-Host
            throw "compile failed"
        }
        $outf = "$CS\game\csgo_addons\$Addon\$ModelDirWin\$m.vmdl_c"
        $sz = if (Test-Path $outf) { (Get-Item $outf).Length } else { "?" }
        Write-Host "OK  $sz bytes" -ForegroundColor Green
        $sizes[$label] = $sz
        $ok += $m
    } catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $bad += "$m ($($_.Exception.Message))"
    }
}

$elapsed = (Get-Date) - $started
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("ported : {0}   failed : {1}   took : {2:mm}m{2:ss}s" -f $ok.Count, $bad.Count, $elapsed)
if ($sizes.Count -gt 1) {
    $mb = ($sizes.Values | Measure-Object -Sum).Sum / 1MB
    Write-Host ("total  : {0:N1} MB compiled" -f $mb) -ForegroundColor DarkGray
}
if ($bad.Count) {
    Write-Host "`nfailed:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    Write-Host "`nThe log has the full compiler output for each." -ForegroundColor DarkGray
}
Write-Host @"

Next:
  1. Verify before publishing:
       .\Verify-Model.ps1 -All
  2. Publish: Workshop Tools -> Asset Browser -> Tools ->
     Counter-Strike 2 Workshop Manager. Create an item and submit.
     New items wait for Steam moderation - nothing can download them,
     including your own server, until that clears.
  3. On the server, add your new workshop id to MultiAddonManager's
     mm_extra_addons and REMOVE the original pack's id, so the broken
     originals cannot shadow your port.
  4. Restart, join, CHANGE MAP ONCE so the addon reaches your client,
     then switch to a ported model.
"@
