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
$SCRIPT_VERSION = "1.3.0"

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
        # Source2Viewer prints UTF-8; read it as such so non-ASCII paths survive
        return ((Get-Content $o -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) + "`n" +
                (Get-Content $e -Raw -Encoding UTF8 -ErrorAction SilentlyContinue))
    } finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

# Numbers written into source files must use '.' whatever the Windows region
# setting - the -f operator would write "1,000000" on a German or French install.
function Format-Invariant([string]$Format, [object[]]$Values) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $Format, $Values)
}

# CS2's own materials, listed once from pak01 the first time one is needed.
# A model may reference these freely - they resolve from the game at runtime.
$script:StockMats = $null
function Test-StockMaterial([string]$Path) {
    if ($null -eq $script:StockMats) {
        $script:StockMats = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $pak = "$CS\game\csgo\pak01_dir.vpk"
        if (Test-Path $pak) {
            $lst = Invoke-Native $S2V @("-i", $pak, "-l", "-e", "vmat_c")
            foreach ($mm in [regex]::Matches($lst, '[a-zA-Z0-9_/.\-]+\.vmat_c')) { [void]$script:StockMats.Add($mm.Value) }
        }
        if (-not $script:StockMats.Count) {
            Write-Warning "  could not list CS2's own materials from $pak - any missing material gets a placeholder"
        }
    }
    return $script:StockMats.Contains(($Path -replace '\\', '/') + "_c")
}

# Bone names of a compiled model, from its DATA block. A player model has a body:
# pelvis plus a leg. Viewmodel arms (20-40 bones, no pelvis), props and map
# stubs do not, whatever they are called - so test the bones rather than
# guessing from the filename. Deliberately not requiring spine_0 (some models
# run pelvis straight to spine_1) nor root_motion (plenty lack it; we add it).
function Get-BodySkeleton([string]$Data) {
    $bm = [regex]::Match($Data, 'm_modelSkeleton\s*=\s*\{\s*m_boneName\s*=\s*\[(.*?)\]', 'Singleline')
    if (-not $bm.Success) { return @{ HasSkeleton = $false; IsBody = $false; Count = 0 } }
    $bones = @([regex]::Matches($bm.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToLower() })
    $isBody = ($bones -contains 'pelvis') -and (($bones -contains 'leg_upper_l') -or ($bones -contains 'leg_upper_r'))
    return @{ HasSkeleton = $true; IsBody = $isBody; Count = $bones.Count }
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
        # closing ']' matched at any indent: Source2Viewer's output layout is
        # not a stable interface, and a fixed one-tab match broke silently
        $m = [regex]::Match($t, [regex]::Escape($grp.k) + '\s*=\s*\r?\n?\s*\[(.*?)\r?\n[ \t]*\]', 'Singleline')
        if (-not $m.Success) { continue }
        foreach ($e in [regex]::Matches($m.Groups[1].Value, '\{(.*?)\}', 'Singleline')) {
            $n = [regex]::Match($e.Groups[1].Value, 'm_name\s*=\s*"([^"]*)"')
            $v = [regex]::Match($e.Groups[1].Value, 'm_(?:nValue|flValue|pValue|value)\s*=\s*(.+)')
            if (-not ($n.Success -and $v.Success)) { continue }
            $name = $n.Groups[1].Value
            $val  = $v.Groups[1].Value.Trim().TrimEnd(',').Trim('"')
            if ($grp.k -eq 'm_vectorParams') {
                $nums = ($val -replace '[\[\]]','').Split(',') | ForEach-Object { Format-Invariant "{0:F6}" @([double]$_.Trim()) }
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
    # UTF-8 without a BOM - byte-identical to the old Set-Content for ASCII,
    # and correct for anything else
    [IO.File]::WriteAllLines(($VmatC -replace '_c$',''), [string[]]$out, (New-Object Text.UTF8Encoding($false)))
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
# Workshop content is downloaded into the SAME Steam library as the game:
# <library>\steamapps\workshop\content\730\<id>. Building it from the default
# C:\ library failed for everyone with CS2 on another drive, even with -CS2Path.
# The default library stays as a fallback.
function Get-WorkshopPackDir([string]$cs2, [string]$id) {
    $def = "C:\Program Files (x86)\Steam\steamapps\workshop\content\730\$id"
    # a CS2 folder only one level deep (D:\CS2) has no library above it
    $steamapps = ''
    try { $steamapps = Split-Path (Split-Path $cs2.TrimEnd('\', '/') -Parent) -Parent } catch {}
    if (-not $steamapps) { return $def }
    $lib = Join-Path $steamapps "workshop\content\730\$id"
    if (Test-Path -LiteralPath $lib) { return $lib }
    if (Test-Path -LiteralPath $def) { return $def }
    return $lib
}
$VPK = if ($Vpk) { $Vpk }
       else { Join-Path (Get-WorkshopPackDir $CS2Path $Pack) "$Pack.vpk" }
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

# Record which Source2Viewer did the work. Its output format is what every
# parser below depends on, and Setup installs whatever release is newest.
if (-not $CompileOnly) {
    $s2vVer = @((Invoke-Native $S2V @("--version")) -split "`n" |
                Where-Object { $_ -match '^\s*(Source2Viewer\S*\s+)?v?\d+\.\d+' } | Select-Object -First 1)
    if ($s2vVer.Count) { Write-Host "Source2Viewer-CLI $($s2vVer[0].Trim())" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- compile only
# For the Linux workflow: models were ported there with --no-compile and the
# content folder copied across. Nothing to extract or edit, just compile.
if ($CompileOnly) {
    # Every .vmdl that has been ported (carries an AnimGraph2List), wherever it
    # sits - packs do not all name folders after models. An unported source
    # left in the addon (viewmodel arms extracted alongside a model, say)
    # would compile into a model that does not animate, so it is listed and
    # left alone.
    $allSrc = @(Get-ChildItem $OUT -Recurse -Filter *.vmdl -EA SilentlyContinue)
    $srcs = @($allSrc | Where-Object { Select-String -LiteralPath $_.FullName -Pattern '_class = "AnimGraph2List"' -Quiet })
    $notPorted = @($allSrc | Where-Object { $srcs.FullName -notcontains $_.FullName })
    if ($notPorted.Count) {
        Write-Host ("skipping $($notPorted.Count) .vmdl not ported yet (no AnimGraph2 lists): " +
                    (($notPorted | ForEach-Object { $_.BaseName }) -join ', ')) -ForegroundColor DarkGray
    }
    if (-not $srcs) { Write-Error "no ported .vmdl sources under $OUT"; exit 1 }
    Write-Host "compiling $($srcs.Count) prepared model(s)`n" -ForegroundColor Cyan
    $outFull = (Resolve-Path -LiteralPath $OUT).ProviderPath.TrimEnd('\', '/')
    $cok = 0; $cbad = @()
    $i = 0
    foreach ($f in $srcs) {
        $i++
        Write-Host "[$i/$($srcs.Count)] $($f.BaseName)" -ForegroundColor Cyan
        $log = Invoke-Native $RC @("-i", $f.FullName)
        Set-Content (Join-Path $LogDir "compile-$($f.BaseName).log") -Value $log
        $cOut = (Join-Path "$CS\game\csgo_addons\$Addon" $f.FullName.Substring($outFull.Length)) -replace '\.vmdl$', '.vmdl_c'
        if ($log -match 'ERROR: 0 compiled' -or ($log -match 'RESOURCE COMPILE ERROR' -and $log -notmatch 'OK:')) {
            ($log -split "`n" | Select-String 'RESOURCE COMPILE ERROR|Error!' | Select-Object -First 4) | Out-Host
            $cbad += $f.BaseName
        } elseif (-not (Test-Path -LiteralPath $cOut)) {
            Write-Host "  compiler reported no error but wrote no .vmdl_c - see the compile log" -ForegroundColor Red
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
    $skipped = @()
    foreach ($f in (Get-ChildItem $Source -Recurse -Filter *.vmdl_c -ErrorAction SilentlyContinue)) {
        $d = Invoke-Native $S2V @("-i", $f.FullName, "--block", "DATA")
        $mn = [regex]::Match($d, 'm_name\s*=\s*"([^"]+)"')
        if (-not $mn.Success) { continue }
        $intern = $mn.Groups[1].Value -replace '\.vmdl$', ''      # e.g. characters/models/pack/foo/foo
        $name = Split-Path $intern -Leaf

        # a player model has a full body skeleton - see Get-BodySkeleton
        $sk = Get-BodySkeleton $d
        if (-not $sk.HasSkeleton) { $skipped += "$name (no skeleton)"; continue }
        if (-not $sk.IsBody) { $skipped += "$name ($($sk.Count) bones, no body skeleton)"; continue }

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
    # Everything outside that layout, filtered cheaply by name and by the size
    # the listing carries - stubs, props and arms are small.
    $extra = [ordered]@{}
    foreach ($ln in ($listing -split "`n")) {
        $f = [regex]::Match($ln, '([a-zA-Z0-9_/\-]+)/([a-zA-Z0-9_\-]+)\.vmdl_c')
        if (-not $f.Success) { continue }
        $nm = $f.Groups[2].Value
        # viewmodel arms have no animgraph and are a separate port
        if ($nm -match '(_arms?|_pm_arm|viewmodel)$' -or $nm -match '_arms?_' -or $nm -like 'v_*') { continue }
        $sz = [regex]::Match($ln, 'size:(\d+)')
        if ($sz.Success -and [int]$sz.Groups[1].Value -lt 100000) { continue }   # too small to be a player model
        if (-not $ModelDirs.ContainsKey($nm) -and -not $extra.Contains($nm)) { $extra[$nm] = $f.Groups[1].Value }
    }
    if (-not $ModelDirs.Count) {
        # No tidy layout at all: take every candidate, exactly as before.
        Write-Host "no <name>/<name>.vmdl_c layout - scanning every model instead" -ForegroundColor DarkGray
        foreach ($k in $extra.Keys) { $ModelDirs[$k] = $extra[$k] }
    } elseif ($extra.Count) {
        # A MIXED pack - most models tidy, one or two not (zombie.vmdl_c in a
        # folder called zombiertx). These used to be dropped without a word.
        # Only take the ones whose skeleton proves they are player models, so
        # props and extras that were ignored before stay ignored.
        $probe = Join-Path ([IO.Path]::GetTempPath()) ("ag2probe-" + [guid]::NewGuid().ToString('N'))
        $found = @(); $notBody = @()
        try {
            foreach ($nm in @($extra.Keys)) {
                $rel = "$($extra[$nm])/$nm.vmdl_c"
                $null = Invoke-Native $S2V @("-i", $VPK, "-o", $probe, "-f", $rel, "-e", "vmdl_c")
                $pf = Join-Path $probe ($rel -replace '/', '\')
                if (-not (Test-Path -LiteralPath $pf)) { continue }
                if ((Get-BodySkeleton (Invoke-Native $S2V @("-i", $pf, "--block", "DATA"))).IsBody) {
                    $ModelDirs[$nm] = $extra[$nm]; $found += $nm
                } else { $notBody += $nm }
            }
        } finally { Remove-Item $probe -Recurse -Force -EA SilentlyContinue }
        if ($found.Count) {
            Write-Host ("also found $($found.Count) model(s) outside the <name>/<name> layout: " + ($found -join ', ')) -ForegroundColor DarkGray
        }
        if ($notBody.Count) {
            Write-Host ("skipped $($notBody.Count) other model file(s) without a body skeleton: " + ($notBody -join ', ')) -ForegroundColor DarkGray
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
$ok = @(); $bad = @(); $sizes = @{}; $skippedNotBody = @()
$modelIndex = 0; $total = $todo.Count
$started = Get-Date
foreach ($m in $todo) {
    $modelIndex++
    $label = $m -replace '_player_model$', ''
    $prefix = if ($total -gt 1) { "[$modelIndex/$total] " } else { "" }
    Write-Host "`n=== $prefix$label ===" -ForegroundColor Cyan
    $ModelDir     = if ($Source) { $LooseFiles[$m].Dir } else { $ModelDirs[$m] }
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
        $matDirsFound = @()
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
        } elseif (@($ModelDirs.Values | Where-Object { $_ -eq $ModelDir }).Count -gt 1) {
            # This model shares its folder with other models in the pack.
            # Decompiling the folder straight into the addon would also put
            # fresh, unported copies of THEIR .vmdl and .dmx over any already
            # ported - harmless to what is compiled, but -CompileOnly or a
            # Workshop Tools recompile would then build a T-posing model.
            # Stage it, and leave the other models' sources as they are.
            $stage = Join-Path ([IO.Path]::GetTempPath()) ("ag2stage-" + [guid]::NewGuid().ToString('N'))
            try {
                $null = Invoke-Native $S2V @("-i", $VPK, "-o", $stage, "-f", $filt, "-d")
                $null = Invoke-Native $S2V @("-i", $VPK, "-o", $stage, "-f", $filt, "-e", "vmat_c")
                if (Test-Path -LiteralPath $stage) {
                    $stageFull = (Get-Item -LiteralPath $stage).FullName.TrimEnd('\', '/')
                    $ownVmdl = Join-Path $stage "$ModelDirWin\$m.vmdl"
                    $ownDmx = @{}
                    if (Test-Path -LiteralPath $ownVmdl) {
                        foreach ($dm in [regex]::Matches((Get-Content -LiteralPath $ownVmdl -Raw -Encoding UTF8), 'filename = "([^"]+\.dmx)"', 'IgnoreCase')) {
                            $ownDmx[(($dm.Groups[1].Value -replace '\\', '/') -split '/')[-1]] = $true
                        }
                    }
                    $kept = 0
                    foreach ($sf in @(Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                        $tgt = Join-Path $OUT $sf.FullName.Substring($stageFull.Length).TrimStart('\', '/')
                        if (Test-Path -LiteralPath $tgt) {
                            if ($sf.Extension -eq '.vmdl' -and $sf.Name -ne "$m.vmdl") { $kept++; continue }
                            if ($sf.Extension -eq '.dmx' -and -not $ownDmx.ContainsKey($sf.Name)) { $kept++; continue }
                        }
                        New-Item -ItemType Directory -Force -Path (Split-Path $tgt -Parent) | Out-Null
                        Copy-Item -LiteralPath $sf.FullName -Destination $tgt -Force
                    }
                    if ($kept) { Write-Host "  shares its folder - kept the other models' $kept source file(s) as they were" }
                }
            } finally { Remove-Item $stage -Recurse -Force -EA SilentlyContinue }
        } else {
            $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", $filt, "-d")
            # the compiled materials too: any Source2Viewer cannot decompile are
            # rebuilt from these below (swept before the compile either way)
            $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", $filt, "-e", "vmat_c")
        }
        if (-not (Test-Path $vmdl)) { throw "no .vmdl produced" }

        # Which materials does the model actually use? The compiled model's
        # resource list (RERL) names every one. That beats guessing folder names:
        # packs use "materials", "mat", nest deeper, keep them beside the model,
        # or - like Valve's own agents - somewhere else entirely
        # (agents/models/<name>/ for the model, characters/models/<name>/materials/
        # for its materials).
        $srcModel = if ($Source) { $LooseFiles[$m].File } else { "$dir\$m.vmdl_c" }
        if (-not $Source) {
            $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$ModelDir/$m.vmdl_c", "-e", "vmdl_c")
        }
        $refMats = @()
        if (Test-Path $srcModel) {
            $rerl = Invoke-Native $S2V @("-i", $srcModel, "--block", "RERL")
            $refMats = @([regex]::Matches($rerl, '(?<![a-zA-Z0-9_/.\-])(?:[a-zA-Z0-9_.\-]+/)*[a-zA-Z0-9_.\-]+\.vmat(?![a-zA-Z0-9_])') |
                         ForEach-Object { $_.Value } | Sort-Object -Unique)
        }

        # @(...) around the whole expression is load-bearing: PowerShell unwraps
        # a single-element array returned from an if, leaving a string, and then
        # += concatenates instead of appending.
        $matDirs = @(if ($Source -and $matDirsFound.Count) { $matDirsFound } else { $MAT })
        if (-not $Source) {
            # material folders outside the model's own folder, pulled from the pack
            $extern = @($refMats | Where-Object { $_.Contains('/') } | ForEach-Object { $_ -replace '/[^/]+$', '' } | Sort-Object -Unique |
                        Where-Object { $_ -ne $ModelDir -and $_ -notlike "$ModelDir/*" })
            foreach ($e in $extern) {
                $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$e/", "-d")
                $null = Invoke-Native $S2V @("-i", $VPK, "-o", $OUT, "-f", "$e/", "-e", "vmat_c")
                $eDir = "$OUT\$($e.Replace('/','\'))"
                if (Test-Path $eDir) {
                    Write-Host "  materials live elsewhere: $e"
                    $matDirs += $eDir
                }
            }
        }
        # every folder that holds a material this model references
        foreach ($rm in @($refMats | Where-Object { $_.Contains('/') })) {   # never the addon root itself
            $rp = Join-Path $OUT ($rm -replace '/', '\')
            if ((Test-Path -LiteralPath $rp) -or (Test-Path -LiteralPath "$($rp)_c")) { $matDirs += (Split-Path $rp -Parent) }
        }
        # One spelling per folder: the same folder reached two ways (a trailing
        # slash on -CS2Path, mixed separators) would otherwise be swept twice.
        $matDirs = @($matDirs | Where-Object { Test-Path -LiteralPath $_ } |
                     ForEach-Object { (Get-Item -LiteralPath $_).FullName } | Sort-Object -Unique)
        $dirFull = (Get-Item -LiteralPath $dir).FullName

        # Rebuild, one material at a time, every .vmat Source2Viewer did not
        # write. It cannot decompile a material whose shader version it does
        # not support (CS2 installed + an older Source2Viewer: VCS v71 vs 70);
        # the compiled DATA block carries everything needed. Per material, so a
        # pack where only SOME failed no longer ends up with placeholders.
        $vmatC = @($matDirs | ForEach-Object { Get-ChildItem "$_\*.vmat_c" -EA SilentlyContinue })
        $toRebuild = @($vmatC | Where-Object { -not (Test-Path -LiteralPath ($_.FullName -replace '_c$', '')) })
        if ($toRebuild.Count) {
            Write-Host "  no .vmat from VRF for $($toRebuild.Count) material(s) - rebuilding from compiled data"
            # deliberately not $n - that is the outer loop's model counter
            $nRebuilt = 0
            foreach ($vc in $toRebuild) {
                if (Rebuild-Vmat $vc.FullName $S2V) { $nRebuilt++ }
            }
            Write-Host "  rebuilt $nRebuilt material(s)"
        }
        $haveVmat = @($matDirs | ForEach-Object { Get-ChildItem "$_\*.vmat" -EA SilentlyContinue }).Count

        # CS2's own materials (pak01) resolve from the game at runtime and must
        # NOT be copied or stubbed into the addon - a file at a stock path in a
        # mounted addon would stand in for Valve's on the whole server.
        $packRefs = @($refMats | Where-Object {
                        -not (Test-Path -LiteralPath (Join-Path $OUT ($_ -replace '/', '\'))) -and
                        -not (Test-StockMaterial $_) })
        if (-not $haveVmat) {
            # Compiled materials were there but none could be turned into
            # sources - stop, as before.
            if ($vmatC.Count) { throw "could not rebuild any materials" }
            # From a pack, nothing at all came out. Fine if the model only uses
            # CS2's own materials; otherwise the extract failed. (Loose files
            # with no materials carry on untextured, as warned above.)
            if (-not $Source) {
                $ownRefs = @($refMats | Where-Object { -not (Test-StockMaterial $_) })
                if ($ownRefs.Count) { throw "could not rebuild any materials" }
            }
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

        # A model can reference materials its source does not contain - shared
        # assets the pack normally supplies, missing from a hand-made zip. CS2's
        # own are left to the game (above); anything else gets a minimal
        # placeholder so one absent material does not fail the whole model.
        $stockUsed = @($refMats | Where-Object {
                         -not (Test-Path -LiteralPath (Join-Path $OUT ($_ -replace '/', '\'))) -and (Test-StockMaterial $_) }).Count
        $made = 0
        foreach ($need in $packRefs) {
            $tgt = Join-Path $OUT ($need -replace '/','\')
            if (Test-Path -LiteralPath $tgt) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $tgt -Parent) | Out-Null
            # minimal stand-in: compiles, renders with the shader default
            @("// placeholder - original not present in the source",
              "Layer0", "{", "`tshader `"csgo_character.vfx`"", "}") | Set-Content $tgt
            $made++
        }
        if ($stockUsed) { Write-Host "  uses $stockUsed of CS2's own material(s) - left to the game" }
        if ($made)      { Write-Warning "  $made material(s) not in the source - placeholders used, those meshes will be untextured" }

        # content/ holds SOURCES only. Any compiled artefact that lands here
        # confuses resourcecompiler, so sweep them.
        $sweepDirs = @($dirFull) + @($matDirs | Where-Object { $_ -notlike "$dirFull*" })
        $stray = @($sweepDirs | Sort-Object -Unique | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Recurse -File -EA SilentlyContinue | Where-Object { $_.Name -like '*_c' } } |
                   Sort-Object FullName -Unique)
        if ($stray.Count) { $stray | Remove-Item -Force; Write-Host "  swept $($stray.Count) stray compiled file(s)" }

        # 2. materials - each material folder, plus each folder holding a
        # texture those materials use, so a texture kept apart from its
        # material is renamed in step with it
        $texDirs = @()
        foreach ($md in $matDirs) {
            foreach ($vm in @(Get-ChildItem -LiteralPath $md -Filter *.vmat -File -EA SilentlyContinue)) {
                foreach ($tm in [regex]::Matches((Get-Content -LiteralPath $vm.FullName -Raw), '"([^"]+/[^"/]+\.(?:png|tga|jpg))"')) {
                    $td = Split-Path (Join-Path $OUT ($tm.Groups[1].Value -replace '/', '\')) -Parent
                    if (Test-Path -LiteralPath $td) { $texDirs += (Get-Item -LiteralPath $td).FullName }
                }
            }
        }
        $fixDirs = @(@($matDirs) + $texDirs | Sort-Object -Unique)
        $fm = Join-Path $here "Fix-Materials.ps1"
        if (Test-Path $fm) {
            foreach ($md in $fixDirs) {
                & powershell -ExecutionPolicy Bypass -File $fm -MaterialsDir $md | Out-Host
            }
        }

        # Already ported? Say so plainly. The edits still run: an AG2 model can
        # still need its weapon attachments or physics markup conforming.
        $pre = Get-Content $vmdl -Raw -Encoding UTF8 -EA SilentlyContinue
        if ($pre -and $pre -notmatch 'vanmgrph' -and
            ([regex]::Matches($pre, '\.vnmgraph')).Count -ge 3 -and
            ([regex]::Matches($pre, '\.vnmskel')).Count  -ge 2) {
            Write-Host "  already AnimGraph2 - checking the rest conforms" -ForegroundColor DarkGray
        }

        # 3. port
        $ag = Join-Path $here "AG2-All.ps1"
        if (-not (Test-Path $ag)) { throw "AG2-All.ps1 not next to this script" }
        $agArgs = @("-ExecutionPolicy","Bypass","-File",$ag,"-Path",$vmdl)
        if ($KeepAG1Nodes) { $agArgs += "-KeepAG1Nodes" }
        & powershell @agArgs | Out-Host
        $agExit = $LASTEXITCODE

        $c = @{}
        foreach ($p in 'vanmgrph','vnmgraph','wpnPivot','vnmskel') {
            $c[$p] = (Select-String -Path $vmdl -Pattern $p -EA SilentlyContinue).Count
        }
        Write-Host ("counts  vanmgrph={0} vnmgraph={1} wpnPivot={2} vnmskel={3}" -f `
            $c['vanmgrph'],$c['vnmgraph'],$c['wpnPivot'],$c['vnmskel'])
        $bound = ($c['vanmgrph'] -eq 0 -and $c['vnmgraph'] -ge 3 -and $c['vnmskel'] -ge 2)
        # exit 3: no pelvis bone - viewmodel arms or a prop, not a player model
        if ($agExit -eq 3 -and -not $bound) {
            Write-Host "  not a player model (no pelvis bone) - skipped" -ForegroundColor DarkGray
            $skippedNotBody += $m
            continue
        }
        if ($null -ne $agExit -and $agExit -ne 0) {
            if ($bound) {
                Write-Warning "  AG2-All.ps1 stopped early (exit $agExit) but the AnimGraph2 binding is complete - compiling anyway; read the messages above"
            } else {
                throw "AG2-All.ps1 failed (exit $agExit) - see the messages above"
            }
        }
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
        $compileStart = Get-Date
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
        if (-not (Test-Path $outf)) { throw "compiler reported no error but wrote no .vmdl_c - see $clog" }
        $outItem = Get-Item $outf
        if ($outItem.LastWriteTime -lt $compileStart.AddSeconds(-5)) {
            Write-Warning "  $m.vmdl_c was not rewritten by this compile - the compiler may have judged it up to date"
        }
        $sz = $outItem.Length
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
if ($skippedNotBody.Count) {
    Write-Host ("skipped: {0} file(s) with no pelvis bone - viewmodel arms or props, not player models: {1}" -f `
                $skippedNotBody.Count, ($skippedNotBody -join ', ')) -ForegroundColor DarkGray
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
