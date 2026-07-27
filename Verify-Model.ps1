param(
    [string]$Model,
    [switch]$All,
    [string]$Addon = "ag2port",
    [string]$S2V   = "$env:USERPROFILE\s2v\Source2Viewer-CLI.exe",
    # CS2 lives elsewhere if your Steam library is on another drive
    [string]$CS2Path = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"
)

$SCRIPT_VERSION = "1.0.0"

# Verify a COMPILED .vmdl_c before publishing. Reads only; changes nothing.
#
#   .\Verify-Model.ps1 -Model eula
#   .\Verify-Model.ps1 -All
#
# Checks are TIERED, because a model does not have to match Hatsune Miku
# bone-for-bone to animate - it has to carry the chain AnimGraph2 drives.
#
#   CRITICAL  the locomotion chain plus the weapon anchor. Anything missing
#             here and the graph has nothing to drive -> FAIL.
#   IMPORTANT ball_L / ball_R, the toe bones. Miku has them and the Feet node
#             references them, so foot IK likely wants them -> WARN.
#   COSMETIC  fingers. Reported, never fatal. Miku herself is missing 10
#             canonical bones and animates; several models in a typical community pack
#             were simply rigged with fewer finger joints.
#
# Also verifies the pelvis transform, which is the failure mode that produces a
# model rotated on its side: once pelvis is a child of root_motion its position
# must be expressed in root_motion's space, where height lands in Y, not Z.

$ErrorActionPreference = "Stop"

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $q = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        Start-Process -FilePath $Exe -ArgumentList $q -NoNewWindow -Wait `
                      -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
        return ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + "`n" +
                (Get-Content $e -Raw -ErrorAction SilentlyContinue))
    } finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

$CS   = $CS2Path
$ADDON = "$CS\game\csgo_addons\$Addon"

$CRITICAL = @('root_motion','pelvis','spine_0','spine_1','spine_2','spine_3','neck_0','head_0',
              'clavicle_L','clavicle_R','arm_upper_L','arm_upper_R','arm_lower_L','arm_lower_R',
              'hand_L','hand_R','leg_upper_L','leg_upper_R','leg_lower_L','leg_lower_R',
              'ankle_L','ankle_R','wpnPivot','wpn')
$IMPORTANT = @('ball_L','ball_R')

# canonical parents for the critical chain, from worldmodel.vnmskel
$PARENT = @{
    'root_motion'='';           'pelvis'='root_motion';     'spine_0'='pelvis'
    'spine_1'='spine_0';        'spine_2'='spine_1';        'spine_3'='spine_2'
    'neck_0'='spine_3';         'head_0'='neck_0'
    'clavicle_L'='spine_3';     'arm_upper_L'='clavicle_L'; 'arm_lower_L'='arm_upper_L'; 'hand_L'='arm_lower_L'
    'clavicle_R'='spine_3';     'arm_upper_R'='clavicle_R'; 'arm_lower_R'='arm_upper_R'; 'hand_R'='arm_lower_R'
    'leg_upper_L'='pelvis';     'leg_lower_L'='leg_upper_L';'ankle_L'='leg_lower_L';     'ball_L'='ankle_L'
    'leg_upper_R'='pelvis';     'leg_lower_R'='leg_upper_R';'ankle_R'='leg_lower_R';     'ball_R'='ankle_R'
    'wpnPivot'='root_motion';   'wpn'='wpnPivot'
}

foreach ($p in @(@{p=$S2V;n="Source2Viewer-CLI"}, @{p=$ADDON;n="addon output dir"})) {
    if (-not (Test-Path $p.p)) { Write-Error "$($p.n) not found: $($p.p)"; exit 1 }
}

# A compiled player model is <name>/<name>.vmdl_c. Scan the whole addon rather
# than assuming one root - a pack may put models under more than one path, and
# nothing here should depend on a particular folder layout.
# Prefer the tidy <name>/<name>.vmdl_c layout, but do not require it - plenty of
# packs name the file and its folder differently. Fall back to every compiled
# model, skipping viewmodel arms and anything too small to be a player model.
$allC = @(Get-ChildItem $ADDON -Recurse -Filter *.vmdl_c -EA SilentlyContinue)
$compiled = @($allC | Where-Object { $_.BaseName -eq $_.Directory.Name })
if (-not $compiled) {
    $compiled = @($allC | Where-Object {
        $_.BaseName -notmatch '(_arms?|_pm_arm|viewmodel)$' -and
        $_.BaseName -notmatch '_arms?_' -and
        $_.BaseName -notlike 'v_*' -and
        $_.Length -ge 100000
    })
}
if (-not $compiled) { Write-Error "no compiled player models under $ADDON"; exit 1 }

# Match by exact folder name first, then by the common _player_model suffix.
# Never assume a naming convention - packs differ, and a pack that names models
# "foo" rather than "foo_player_model" should still verify.
$targets = if ($All) { $compiled }
           elseif ($Model) {
               $hit = @($compiled | Where-Object {
                   $_.BaseName -eq $Model -or $_.BaseName -eq "${Model}_player_model" -or
                   ($_.BaseName -replace '_player_model$','') -eq $Model })
               if (-not $hit) {
                   Write-Error ("'$Model' not compiled. Available: " +
                                (($compiled | ForEach-Object { $_.BaseName -replace '_player_model$','' }) -join ', '))
                   exit 1
               }
               $hit
           }
           else { Write-Host "usage: -Model <name> | -All"; exit }

Write-Host "Verify-Model $SCRIPT_VERSION`n" -ForegroundColor DarkGray
$pass = 0; $warn = 0; $fail = 0; $rows = @()

foreach ($t in $targets) {
    $short = $t.BaseName -replace '_player_model$',''
    $f = $t.FullName

    $data = Invoke-Native $S2V @("-i", $f, "--block", "DATA")
    $rerl = Invoke-Native $S2V @("-i", $f, "--block", "RERL")
    $refs = $rerl + $data
    $bad = @(); $wrn = @()

    # ---- external references ----
    $ag1 = ([regex]::Matches($refs, '\.vanmgrph')).Count
    $ans = ([regex]::Matches($refs, 'animsets/')).Count
    $vg  = ([regex]::Matches($refs, '\.vnmgraph')).Count
    $vs  = ([regex]::Matches($refs, '\.vnmskel')).Count
    if ($ag1 -gt 0) { $bad += "still references AnimGraph1 (.vanmgrph x$ag1)" }
    if ($ans -gt 0) { $bad += "still references a legacy animset" }
    # Valve ships 4, but the fourth duplicates the worldmodel graph. Ports by
    # other authors use 3 and work, so 3 is the real floor.
    if ($vg -lt 3)  { $bad += "$vg graph reference(s), expected at least 3" }
    elseif ($vg -eq 3) { $wrn += "3 graph references, not the 4 Valve ships - probably fine" }
    if ($vs -lt 2)  { $bad += "$vs vnmskel reference(s), expected 2" }

    # ---- skeleton ----
    $bones = @(); $hier = @{}; $pelvisPos = $null
    $mm = [regex]::Match($data, 'm_modelSkeleton\s*=\s*\{\s*m_boneName\s*=\s*\[(.*?)\]', 'Singleline')
    if (-not $mm.Success) { $bad += "no m_modelSkeleton in DATA" }
    else {
        $bones = [regex]::Matches($mm.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $pm = [regex]::Match($data, 'm_nParent\s*=\s*\[(.*?)\]', 'Singleline')
        $par = if ($pm.Success) { [regex]::Matches($pm.Groups[1].Value, '-?\d+') | ForEach-Object { [int]$_.Value } } else { @() }
        if ($par.Count -eq $bones.Count) {
            for ($i = 0; $i -lt $bones.Count; $i++) {
                $hier[$bones[$i]] = $(if ($par[$i] -ge 0) { $bones[$par[$i]] } else { '' })
            }
        }
        # pelvis position relative to its parent
        $pp = [regex]::Match($data, 'm_bonePosParent\s*=\s*\[(.*?)\n\t\t\]', 'Singleline')
        if ($pp.Success) {
            $vecs = [regex]::Matches($pp.Groups[1].Value, '\[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]')
            $pi = [array]::IndexOf($bones, 'pelvis')
            if ($pi -ge 0 -and $pi -lt $vecs.Count) {
                $pelvisPos = @([double]$vecs[$pi].Groups[1].Value, [double]$vecs[$pi].Groups[2].Value, [double]$vecs[$pi].Groups[3].Value)
            }
        }
    }

    $missC = @($CRITICAL | Where-Object { $bones -notcontains $_ })
    $missI = @($IMPORTANT | Where-Object { $bones -notcontains $_ })
    if ($missC.Count) {
        # a model missing most of the skeleton is not a player model at all -
        # say that instead of listing twenty bones
        if ($missC.Count -gt 6) {
            $bad += ("$($missC.Count) of $($CRITICAL.Count) critical bones missing " +
                     "(incl. $(($missC | Select-Object -First 4) -join ', ')) - " +
                     "is this actually a player model?")
        } else {
            $bad += "CRITICAL bone(s) missing: $($missC -join ', ')"
        }
    }
    if ($missI.Count) { $wrn += "toe bone(s) missing: $($missI -join ', ') - foot IK may be off" }

    if ($hier.Count) {
        $mism = @($PARENT.Keys | Where-Object { $bones -contains $_ -and $hier[$_] -ne $PARENT[$_] })
        if ($mism.Count) { $bad += "wrong parent on: $($mism -join ', ')" }
        $roots = @($bones | Where-Object { $hier[$_] -eq '' })
        if ($roots -notcontains 'root_motion') { $bad += "root_motion is not a root" }
    }

    # pelvis must sit in root_motion's space: height in Y, not Z
    if ($pelvisPos) {
        if ([math]::Abs($pelvisPos[2]) -gt [math]::Abs($pelvisPos[1])) {
            $bad += ("pelvis position [{0:F2}, {1:F2}, {2:F2}] is Z-up - NOT converted into root_motion space, model will be rotated" -f $pelvisPos[0], $pelvisPos[1], $pelvisPos[2])
        }
    }

    $fingers = @($bones | Where-Object { $_ -like 'finger_*' }).Count

    $core = $CRITICAL.Count - $missC.Count
    Write-Host "=== $short ===" -ForegroundColor Cyan
    Write-Host ("  core {0}/{1}   toes {2}/2   fingers {3}   bones {4}   refs {5}g/{6}s" -f `
        $core, $CRITICAL.Count, ($IMPORTANT.Count - $missI.Count), $fingers, $bones.Count, $vg, $vs)
    if ($pelvisPos) { Write-Host ("  pelvis [{0:F2}, {1:F2}, {2:F2}] (height should be the middle value)" -f $pelvisPos[0],$pelvisPos[1],$pelvisPos[2]) }

    if ($bad.Count) {
        Write-Host "  [FAIL]" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
        $fail++; $res = 'FAIL'
    } elseif ($wrn.Count) {
        Write-Host "  [PASS with warnings]" -ForegroundColor Yellow
        $wrn | ForEach-Object { Write-Host "     ! $_" -ForegroundColor Yellow }
        $warn++; $res = 'WARN'
    } else {
        Write-Host "  [PASS]" -ForegroundColor Green
        $pass++; $res = 'PASS'
    }
    $rows += [pscustomobject]@{Model=$short; Result=$res; Core="$core/$($CRITICAL.Count)"; Fingers=$fingers; Note=(($bad + $wrn) -join '; ')}
}

Write-Host "`n================================" -ForegroundColor Cyan
$rows | Format-Table -AutoSize
Write-Host "PASS $pass   WARN $warn   FAIL $fail"
if ($fail -eq 0) {
    Write-Host "`nNo critical failures - safe to publish." -ForegroundColor Green
    if ($warn) { Write-Host "Warned models will animate; only foot IK is in question.`n" -ForegroundColor Yellow }
    Write-Host "This verifies structure, not in-game behaviour.`n"
}
# non-zero if anything failed, so this can gate a build script
exit $(if ($fail) { 1 } else { 0 })
