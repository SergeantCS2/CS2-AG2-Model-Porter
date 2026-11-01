<#
    Test suite. Runs the real scripts against synthetic models and stand-ins
    for Source2Viewer and resourcecompiler - no game files, no CS2 install,
    nothing touched outside a temporary folder (apart from logs\, which
    Port-Model.ps1 always writes next to itself).

        powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1     (Windows)
        pwsh tests/Run-Tests.ps1                                         (Linux/macOS)

    Needs Python 3 on PATH (the stand-ins are Python). On Windows run it with
    Windows PowerShell 5.1 - the version the scripts ship for - which can also
    build the small launcher the stand-ins need.

    This proves the scripts do what they say on known input. It does not
    prove a model animates: that is still only testable in game.
#>
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$Repo  = Split-Path -Parent $PSScriptRoot
$OnWin = ($env:OS -eq 'Windows_NT')
$PSExe = (Get-Process -Id $PID).Path
. (Join-Path $PSScriptRoot 'Fixtures.ps1')

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("ag2tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Section([string]$t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Check([bool]$cond, [string]$msg, [string]$detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok    $msg" -ForegroundColor Green }
    else {
        $script:Fail++; Write-Host "  FAIL  $msg" -ForegroundColor Red
        if ($detail) { Write-Host ($detail -split "`n" | Select-Object -Last 25 | ForEach-Object { "        $_" } | Out-String) -ForegroundColor DarkGray }
    }
}
function Read-Text([string]$p) { if (-not (Test-Path -LiteralPath $p)) { return '' }; return ([IO.File]::ReadAllText($p) -replace "`r`n", "`n") }
function Get-B64([string]$p) { if (-not (Test-Path -LiteralPath $p)) { return '' }; return [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }
function Get-TextHash([string]$t) {
    $sha = [Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($Utf8.GetBytes($t)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Write-Json([string]$path, $obj) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 12), $Utf8)
}
function Invoke-Script([string]$name, [string[]]$arguments) {
    $out = & $PSExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo $name) @arguments 2>&1 | Out-String
    return @{ Out = $out; Exit = $LASTEXITCODE }
}
# parent of each bone, read from ModelDoc text by brace depth - the way a
# KV3 parser sees it. (Not indentation: a grafted bone has always been written
# one tab short of its new siblings, which KV3 ignores.)
function Get-BoneParents([string]$text) {
    $lines = $text -split "`n"; $parents = @{}; $stack = New-Object System.Collections.ArrayList
    $depth = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '_class = "Bone"') {
            while ($stack.Count -and $stack[$stack.Count - 1].Depth -ge $depth) { $stack.RemoveAt($stack.Count - 1) }
            $nm = [regex]::Match($lines[$i + 1], 'name = "([^"]+)"').Groups[1].Value
            $parents[$nm] = $(if ($stack.Count) { $stack[$stack.Count - 1].Name } else { '' })
            [void]$stack.Add(@{ Depth = $depth; Name = $nm })
        }
        $depth += ([regex]::Matches($lines[$i], '\{')).Count - ([regex]::Matches($lines[$i], '\}')).Count
    }
    return $parents
}

# ---------------------------------------------------------------- stand-ins
# The scripts call `powershell`; on Linux/macOS point that at pwsh.
if (-not $OnWin) {
    $shimDir = Join-Path $Tmp 'bin'; New-Item -ItemType Directory -Path $shimDir | Out-Null
    $shim = Join-Path $shimDir 'powershell'
    [IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh `"`$@`"`n")
    & chmod +x $shim
    $env:PATH = "$shimDir" + [IO.Path]::PathSeparator + $env:PATH
}
$launcherSrc = @'
using System; using System.Diagnostics; using System.IO; using System.Text;
public static class Launcher {
    public static int Main(string[] args) {
        string self = Process.GetCurrentProcess().MainModule.FileName;
        StringBuilder sb = new StringBuilder(Quote(File.ReadAllText(self + ".target").Trim()));
        foreach (string a in args) { sb.Append(' '); sb.Append(Quote(a)); }
        ProcessStartInfo psi = new ProcessStartInfo("python", sb.ToString());
        psi.UseShellExecute = false;
        Process p = Process.Start(psi); p.WaitForExit(); return p.ExitCode;
    }
    static string Quote(string s) {
        StringBuilder sb = new StringBuilder("\""); int bs = 0;
        foreach (char c in s) {
            if (c == '\\') { bs++; continue; }
            if (c == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); bs = 0; continue; }
            sb.Append('\\', bs); bs = 0; sb.Append(c);
        }
        sb.Append('\\', bs * 2); sb.Append('"'); return sb.ToString();
    }
}
'@
$script:LauncherProto = $null
function New-Launcher([string]$ExePath, [string]$Script) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ExePath) | Out-Null
    if ($OnWin) {
        if (-not $script:LauncherProto) {
            $script:LauncherProto = Join-Path $Tmp 'launcher.exe'
            Add-Type -TypeDefinition $launcherSrc -OutputAssembly $script:LauncherProto -OutputType ConsoleApplication
        }
        Copy-Item $script:LauncherProto $ExePath
        [IO.File]::WriteAllText("$ExePath.target", $Script)
    } else {
        [IO.File]::WriteAllText($ExePath, "#!/bin/sh`nexec python3 `"$Script`" `"`$@`"`n")
        & chmod +x $ExePath
    }
}
$FakeS2V = Join-Path $PSScriptRoot 'fakes/fake_s2v.py'
$FakeRC  = Join-Path $PSScriptRoot 'fakes/fake_rc.py'
$S2VDir  = Join-Path $Tmp 's2v'
$S2VExe  = Join-Path $S2VDir 'Source2Viewer-CLI.exe'
New-Launcher $S2VExe $FakeS2V

# A CS2 install in a Steam library that is NOT C:\Program Files (x86)\Steam
function New-FakeCS2([string]$Root, [string]$GameinfoText) {
    $lib = Join-Path $Root 'SteamLibrary/steamapps'
    $cs2 = Join-Path $lib 'common/Counter-Strike Global Offensive'
    New-Item -ItemType Directory -Force -Path (Join-Path $cs2 'game/csgo') | Out-Null
    [IO.File]::WriteAllText((Join-Path $cs2 'game/csgo/gameinfo.gi'), $GameinfoText, $Utf8)
    New-Launcher (Join-Path $cs2 'game/bin/win64/resourcecompiler.exe') $FakeRC
    Write-Json (Join-Path $cs2 'game/csgo/pak01_dir.vpk') @{ files = [ordered]@{
        'materials/default/default.vmat_c' = @{ size = 900; data = 'm_shaderName = "csgo_complex.vfx"' } } }
    return @{ Lib = $lib; CS2 = $cs2 }
}
$GameinfoLF = "`"GameInfo`"`n{`n`tFileSystem`n`t{`n`t`tAddonConfig`n`t`t{`n`t`t`t`"VpkDirectories`"`n`t`t`t{`n" +
              "`t`t`t`t`"include`"`t`"maps`"`n`t`t`t`t`"include`"`t`"materials`"`n`t`t`t}`n`t`t}`n`t}`n}`n"

# ===================================================================== tests
try {

Section "AG2-All.ps1 - output unchanged where it should be"
$golden = [ordered]@{
    standard       = 'c6ea1d48430dadb27a14e07ae4c51caf545d4b4add86184373704bf6b31344e0'
    lowercase      = '06f5c7855c0c1f74b42e230bccfe28903ad076694b9bcc2771685c3113b4f53e'
    no_root_motion = '5b12bf1805860f02fe39297d10c281984a50f12cdd84727fe2c1158b745922d8'
    x_up           = '2801cf0a4eca14929ba1058558a366f9c909883f71d4f57dde2c56a2a342420e'
    unicode        = '4c71233b0212898ec803a81259816fe1ba3acdb777bd24e9014bb30710b72245'
}
$fx = Get-Fixtures
$res = @{}
foreach ($k in $fx.Keys) {
    $p = Write-Fixture (Join-Path $Tmp "ag2/$k") $k $fx[$k]
    $r = Invoke-Script 'AG2-All.ps1' @('-Path', $p)
    $res[$k] = @{ Path = $p; Exit = $r.Exit; Out = $r.Out; Text = (Read-Text $p) }
}
foreach ($k in $golden.Keys) {
    $h = Get-TextHash $res[$k].Text
    if ($h -ne $golden[$k]) { [IO.File]::WriteAllText((Join-Path $Tmp "$k.actual.vmdl"), $res[$k].Text, $Utf8) }
    Check ($h -eq $golden[$k]) "$k - identical to v1.2.0 output" $res[$k].Out
}
$dmxDir = Split-Path $res['lowercase'].Path
$own   = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $dmxDir 'lowercase_body.dmx')))
$other = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $dmxDir 'other_body.dmx')))
Check ($own.Contains([char]0 + 'hand_L' + [char]0) -and -not $own.Contains([char]0 + 'hand_l' + [char]0)) "lowercase - its own DMX joints renamed with the bones"
Check ($other.Contains([char]0 + 'hand_l' + [char]0)) "lowercase - another model's DMX in the same folder left alone"

Section "AG2-All.ps1 - fixed behaviour"
foreach ($k in @($fx.Keys | Where-Object { $_ -ne 'no_pelvis' })) {
    $par = Get-BoneParents $res[$k].Text
    Check ($res[$k].Exit -eq 0 -and $par['pelvis'] -ceq 'root_motion' -and $par['root_motion'] -eq '') `
          "$k - exit 0, pelvis under root_motion, root_motion the root" $res[$k].Out
    Check (([regex]::Matches($res[$k].Text, 'name = "wpnPivot"')).Count -eq 1) "$k - exactly one wpnPivot"
    Check (([regex]::Matches($res[$k].Text, '_class = "NmSkeletonList"')).Count -eq 1 -and
           ([regex]::Matches($res[$k].Text, '_class = "AnimGraph2List"')).Count -eq 1) "$k - one of each AG2 list"
    Check (-not ($res[$k].Text -match '(origin|angles) = \[ *-?\d+,\d')) "$k - no comma decimals"
}
Check ($res['no_pelvis'].Exit -eq 3) "no_pelvis - exit 3 (not a player model)"
Check (-not ($res['parented_stray'].Out -match 'correcting orientation')) "parented_stray - no false orientation correction"
Check ($res['parented_stray'].Text -match 'name = "helper_root"\s+origin = \[ 2\.000000, 3\.000000, 1\.000000 \]') `
      "parented_stray - stray root converted without an extra 90 degree turn"
Check ($res['odd_root_motion'].Text -match 'name = "lean_root"\s+origin = \[[^\]]+\]\s+angles = \[ -89\.531300, -180\.000000, 90\.000000 \]') `
      "odd_root_motion - stray root converted with root_motion's real angles"
Check (([regex]::Matches($res['graph_only'].Text, '\.vnmskel"')).Count -eq 2) "graph_only - missing skeleton list added"
Check (([regex]::Matches($res['skeleton_only'].Text, '\.vnmgraph"')).Count -ge 3) "skeleton_only - missing graph list added"
$lp = Get-BoneParents $res['leaf_root_motion'].Text
Check ($lp['pelvis'] -eq 'root_motion' -and $res['leaf_root_motion'].Text.IndexOf('name = "pelvis"') -lt $res['leaf_root_motion'].Text.IndexOf('_class = "BodyGroupList"')) `
      "leaf_root_motion - pelvis given to root_motion, not to a later node"
Check ($res['unicode'].Text.Contains([string][char]0x30D5 + [char]0x30A3 + [char]0x30C3 + [char]0x30B7 + [char]0x30E5)) "unicode - non-ASCII text survives"

Section "AG2-All.ps1 - comma-decimal Windows region (de-DE)"
$p = Write-Fixture (Join-Path $Tmp 'ag2-de/standard') 'standard' $fx['standard']
$probe = & {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'de-DE'
    $x = "{0:F1}" -f 1.5
    & (Join-Path $Repo 'AG2-All.ps1') -Path $p *> $null
    $x
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
Check ($probe -eq '1,5') "culture really was switched for the run (probe printed '$probe')"
Check ((Get-TextHash (Read-Text $p)) -eq $golden['standard']) "output identical to an English-locale run"

Section "Rebuild-Vmat - comma-decimal Windows region (de-DE)"
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Port-Model.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Name -in 'Invoke-Native', 'Format-Invariant', 'Rebuild-Vmat') { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$vmatData = "{`n`tm_shaderName = `"csgo_character.vfx`"`n`tm_vectorParams = `n`t[`n`t`t{`n`t`t`tm_name = `"g_vColorTint`"`n`t`t`tm_value = [ 1.000000, 0.500000, 0.250000, 0.000000 ]`n`t`t},`n`t]`n}"
$vc = Join-Path $Tmp 'vmat-de/body.vmat_c'
Write-Json $vc @{ data = $vmatData }
& {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'de-DE'
    $null = Rebuild-Vmat $vc $S2VExe
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
Check ((Read-Text ($vc -replace '_c$', '')) -match 'g_vColorTint "\[1\.000000 0\.500000 0\.250000 0\.000000\]"') "vector parameters keep '.' decimals"

# ---------------------------------------------------------------- full port
Section "Port-Model.ps1 - a split Workshop pack in a Steam library on another drive"
$giPatched = $GameinfoLF -replace '("maps"\n)', "`$1`t`t`t`t`"include`"`t`"characters`"`n"
$env1 = New-FakeCS2 (Join-Path $Tmp 'port') $giPatched
$cs2 = $env1.CS2
$addonContent = Join-Path $cs2 'content/csgo_addons/ag2port'
$addonGame    = Join-Path $cs2 'game/csgo_addons/ag2port'
New-Item -ItemType Directory -Force -Path $addonContent, $addonGame | Out-Null

function New-ModelData([string]$name, [string[]]$bones) {
    $b = ($bones | ForEach-Object { "`t`t`t`"$_`"," }) -join "`n"
    return "{`n`tm_name = `"$name`"`n`tm_modelSkeleton = `n`t{`n`t`tm_boneName = `n`t`t[`n$b`n`t`t]`n`t}`n}"
}
$body = @('root_motion','pelvis','leg_upper_L','leg_upper_R')
$T = 'characters/models/test'
$vmatDataPlain = "{`n`tm_shaderName = `"csgo_character.vfx`"`n`tm_textureParams = `n`t[`n`t`t{`n`t`t`tm_name = `"g_tColor`"`n" +
                 "`t`t`tm_pValue = resource:`"__TEX__`"`n`t`t},`n`t]`n}"
$files = [ordered]@{
    # tidy; its material Source2Viewer cannot decompile (old VRF + CS2 installed)
    "$T/alpha/alpha.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/alpha/alpha.vmdl" $body)
        rerl = "`t`"$T/alpha/materials/body.vmat`"`n`t`"materials/default/default.vmat`""
        decompiled = @{ 'alpha.vmdl' = (New-FixtureVmdl -Name 'alpha' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90) @((New-Bone 'ik_foot_L'))))); 'alpha_body.dmx' = 'dmx' } }
    "$T/alpha/materials/body.vmat_c" = @{ size = 2000; data = ($vmatDataPlain -replace '__TEX__', "$T/alpha/materials/body_color_png_1a2b3c4d.vtex"); decompiled = @{} }
    "$T/alpha/materials/body_color_png_1a2b3c4d.vtex_c" = @{ size = 9000; decompiled = @{ 'body_color_png_1a2b3c4d.png' = 'PNG' } }
    # tidy, materials in mat/ - one decompiles, one does not
    "$T/beta/beta.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/beta/beta.vmdl" $body)
        rerl = "`t`"$T/beta/mat/skin.vmat`"`n`t`"$T/beta/mat/cloth.vmat`""
        decompiled = @{ 'beta.vmdl' = (New-FixtureVmdl -Name 'beta' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90) @((New-Bone 'ik_foot_L'))))) } }
    "$T/beta/mat/skin.vmat_c"  = @{ size = 2000; data = ($vmatDataPlain -replace '__TEX__', "$T/beta/mat/skin_color_png_00aa11bb.vtex")
        decompiled = @{ 'skin.vmat' = "Layer0`n{`n`tshader `"csgo_character.vfx`"`n`tTextureColor `"$T/beta/mat/skin_color_png_00aa11bb.png`"`n}`n" } }
    "$T/beta/mat/skin_color_png_00aa11bb.vtex_c" = @{ size = 9000; decompiled = @{ 'skin_color_png_00aa11bb.png' = 'PNG' } }
    "$T/beta/mat/cloth.vmat_c" = @{ size = 2000; data = ($vmatDataPlain -replace '__TEX__', "$T/beta/mat/cloth_color_png_22cc33dd.vtex"); decompiled = @{} }
    "$T/beta/mat/cloth_color_png_22cc33dd.vtex_c" = @{ size = 9000; decompiled = @{ 'cloth_color_png_22cc33dd.png' = 'PNG' } }
    # tidy; one own material, one the pack forgot, one of CS2's
    "$T/gamma/gamma.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/gamma/gamma.vmdl" $body)
        rerl = "`t`"$T/gamma/materials/gamma.vmat`"`n`t`"$T/shared/missing.vmat`"`n`t`"materials/default/default.vmat`""
        decompiled = @{ 'gamma.vmdl' = (New-FixtureVmdl -Name 'gamma' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90) @((New-Bone 'ik_foot_L'))))) } }
    "$T/gamma/materials/gamma.vmat_c" = @{ size = 2000; data = ($vmatDataPlain -replace '__TEX__', "$T/gamma/materials/g_png_44ee55ff.vtex"); decompiled = @{} }
    # NOT in the tidy layout - zombie.vmdl_c in a folder called zombiertx
    "$T/zombiertx/zombie.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/zombiertx/zombie.vmdl" $body)
        rerl = "`t`"materials/default/default.vmat`""
        decompiled = @{ 'zombie.vmdl' = (New-FixtureVmdl -Name 'zombie' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90) @((New-Bone 'ik_foot_L'))))) } }
    # big, untidy, not a body - must stay out
    "$T/props/crate.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/props/crate.vmdl" @('root','lid')); rerl = ''; decompiled = @{} }
    # tidy layout but viewmodel arms - no pelvis
    "$T/alpha_arms/alpha_arms.vmdl_c" = @{ size = 300000; data = (New-ModelData "$T/alpha_arms/alpha_arms.vmdl" @('root','hand_L')); rerl = ''
        decompiled = @{ 'alpha_arms.vmdl' = $fx['no_pelvis'].Text } }
}
$packDir = Join-Path $env1.Lib 'workshop/content/730/1234567890'
Write-Json (Join-Path $packDir '1234567890_dir.vpk') @{ files = $files }
[IO.File]::WriteAllText((Join-Path $packDir '1234567890_000.vpk'), '', $Utf8)

$r = Invoke-Script 'Port-Model.ps1' @('-Pack', '1234567890', '-All', '-CS2Path', $cs2, '-S2V', $S2VExe)
$o = $r.Out
Check ($r.Exit -eq 0) "runs to the end (exit 0)" $o
Check ($o -match 'Source2Viewer-CLI 20\.1\.0') "logs the Source2Viewer version"
foreach ($mdl in @("alpha/alpha", "beta/beta", "gamma/gamma", "zombiertx/zombie")) {
    Check (Test-Path (Join-Path $addonGame "$T/$mdl.vmdl_c")) "compiled $mdl.vmdl_c" $o
}
Check ($o -match 'also found 1 model\(s\) outside the <name>/<name> layout: zombie') "reports the model outside the tidy layout"
Check (-not (Test-Path (Join-Path $addonGame "$T/props/crate.vmdl_c")) -and ($o -match 'without a body skeleton: crate')) "leaves out a non-body model"
Check (($o -match 'skipped: 1 file\(s\) with no pelvis bone') -and -not ($o -match 'FAILED: .*alpha_arms')) "arms skipped, not failed"
Check ($o -match 'ported : 4\s+failed : 0') "summary: 4 ported, 0 failed" $o
Check (Test-Path (Join-Path $addonContent "$T/beta/mat/cloth.vmat")) "material in mat/ rebuilt (used to fail the model)"
Check ((Read-Text (Join-Path $addonContent "$T/beta/mat/skin.vmat")) -match 'skin_color\.png') "decompiled material kept, texture name fixed"
Check (Test-Path (Join-Path $addonContent "$T/beta/mat/skin_color.png")) "texture beside it renamed in step"
Check ((Read-Text (Join-Path $addonContent "$T/alpha/materials/body.vmat")) -match 'TextureColor "characters/models/test/alpha/materials/body_color\.png"') "rebuilt material points at the renamed texture"
Check (Test-Path (Join-Path $addonContent "$T/shared/missing.vmat")) "placeholder for a material the pack does not have"
Check (-not (Test-Path (Join-Path $addonContent 'materials/default/default.vmat'))) "nothing written at CS2's own material path"
Check ($o -match "uses 1 of CS2's own material") "says CS2's own material is left to the game"
Check (@(Get-ChildItem $addonContent -Recurse -File -Include *_c).Count -eq 0) "no compiled files left in content/"

$r2 = Invoke-Script 'Port-Model.ps1' @('-Pack', '1234567890', '-All', '-CS2Path', $cs2, '-S2V', $S2VExe)
Check (([regex]::Matches($r2.Out, 'already compiled - skipping')).Count -eq 4) "second run skips all four" $r2.Out

Section "Verify-Model.ps1"
$v = Invoke-Script 'Verify-Model.ps1' @('-All', '-CS2Path', $cs2, '-S2V', $S2VExe)
Check ($v.Exit -eq 0) "all ported models pass" $v.Out
Check ($v.Out -match '=== zombie ===') "verifies the model outside the tidy layout" $v.Out

# a model whose side suffixes were never flipped must FAIL - it will not bind
$caseText = $res['standard'].Text -replace 'name = "hand_L"', 'name = "hand_l"'
$caseDir = Join-Path $cs2 'content/csgo_addons/casetest/characters/models/test/casey'
New-Item -ItemType Directory -Force -Path $caseDir, (Join-Path $cs2 'game/csgo_addons/casetest') | Out-Null
[IO.File]::WriteAllText((Join-Path $caseDir 'casey.vmdl'), $caseText, $Utf8)
& (Join-Path $cs2 'game/bin/win64/resourcecompiler.exe') -i (Join-Path $caseDir 'casey.vmdl') | Out-Null
$vc2 = Invoke-Script 'Verify-Model.ps1' @('-Model', 'casey', '-Addon', 'casetest', '-CS2Path', $cs2, '-S2V', $S2VExe)
Check ($vc2.Exit -eq 1 -and $vc2.Out -match 'hand_l \(needs hand_L\)') "lowercase hand_l fails, named precisely" $vc2.Out

Section "Port-Model.ps1 -CompileOnly"
Remove-Item (Join-Path $addonGame 'characters') -Recurse -Force
$c = Invoke-Script 'Port-Model.ps1' @('-CompileOnly', '-CS2Path', $cs2, '-S2V', $S2VExe)
Check ($c.Exit -eq 0) "exit 0" $c.Out
Check (Test-Path (Join-Path $addonGame "$T/zombiertx/zombie.vmdl_c")) "compiles the ported model outside the tidy layout" $c.Out

Section "Port-Model.ps1 -Source (loose files)"
# folder named zombiertx, model compiled for characters/models/loose/undead/
$src = Join-Path $Tmp 'loose'
$L = 'characters/models/loose/undead'
Write-Json (Join-Path $src 'zombiertx/zombie.vmdl_c') @{ data = (New-ModelData "$L/zombie.vmdl" $body)
    rerl = "`t`"$L/materials/skin.vmat`""
    decompiled = @{ 'zombie.vmdl' = (New-FixtureVmdl -Name 'zombie' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90) @((New-Bone 'ik_foot_L'))))) } }
Write-Json (Join-Path $src 'zombiertx/materials/skin.vmat_c') @{ data = ($vmatDataPlain -replace '__TEX__', "$L/materials/skin_color_png_0a0b0c0d.vtex"); decompiled = @{} }
Write-Json (Join-Path $src 'zombiertx/materials/skin_color_png_0a0b0c0d.vtex_c') @{ decompiled = @{ 'skin_color_png_0a0b0c0d.png' = 'PNG' } }
Write-Json (Join-Path $src 'zombiertx/zombie_arms.vmdl_c') @{ data = (New-ModelData "$L/zombie_arms.vmdl" @('root', 'hand_L')) }
$looseContent = Join-Path $cs2 'content/csgo_addons/loosetest'
New-Item -ItemType Directory -Force -Path $looseContent, (Join-Path $cs2 'game/csgo_addons/loosetest') | Out-Null
$ls = Invoke-Script 'Port-Model.ps1' @('-Source', $src, '-All', '-Addon', 'loosetest', '-CS2Path', $cs2, '-S2V', $S2VExe)
Check ($ls.Exit -eq 0 -and $ls.Out -match 'ported : 1\s+failed : 0') "ports the loose model" $ls.Out
Check (Test-Path (Join-Path $cs2 "game/csgo_addons/loosetest/$L/zombie.vmdl_c")) "compiled at the path the model records, not the folder name"
Check ($ls.Out -match 'skipped 1 non-player-model file') "loose arms file skipped by skeleton"
Check ((Read-Text (Join-Path $looseContent "$L/materials/skin.vmat")) -match 'skin_color\.png') "loose material rebuilt, texture decompiled and renamed" $ls.Out
Check (Test-Path (Join-Path $looseContent "$L/materials/skin_color.png")) "loose texture present for the compiler"

# ---------------------------------------------------------------- setup + cleanup
Section "Setup-AG2.ps1 / Cleanup-AG2.ps1"
$env2 = New-FakeCS2 (Join-Path $Tmp 'setup') $GameinfoLF
$cs2b = $env2.CS2
$gi = Join-Path $cs2b 'game/csgo/gameinfo.gi'
$orig = [IO.File]::ReadAllBytes($gi)
$pack2 = Join-Path $env2.Lib 'workshop/content/730/1234567890'
New-Item -ItemType Directory -Force -Path $pack2 | Out-Null
[IO.File]::WriteAllText((Join-Path $pack2 '1234567890_dir.vpk'), '{"files":{}}', $Utf8)

$s = Invoke-Script 'Setup-AG2.ps1' @('-CS2Path', $cs2b, '-Pack', '1234567890', '-S2VDir', $S2VDir, '-Addon', 'setuptest')
Check ($s.Exit -eq 0) "setup passes with CS2 and the pack in another Steam library" $s.Out
Check ($s.Out -match 'source pack 1234567890 present') "finds the Workshop pack in CS2's own library"
$patched = [IO.File]::ReadAllText($gi)
Check ($patched -match '"include"\s+"characters"' -and -not $patched.Contains("`r")) "gameinfo.gi patched, line endings kept"
Check ((Get-B64 "$gi.bak") -eq [Convert]::ToBase64String($orig)) "backup is the file as it was"

$cl = Invoke-Script 'Cleanup-AG2.ps1' @('-CS2Path', $cs2b, '-Addon', 'setuptest', '-Remove')
Check ((Get-B64 $gi) -eq [Convert]::ToBase64String($orig)) "cleanup restores gameinfo.gi byte for byte" $cl.Out
Check (-not (Test-Path "$gi.bak") -and -not (Test-Path (Join-Path $cs2b 'content/csgo_addons/setuptest'))) "cleanup removes the backup and the addon"

# A backup left by an older version, from before a CS2 update. Restoring it
# would roll gameinfo.gi back - only our line should come out.
$updated = $GameinfoLF -replace '"materials"', "`"materials`"`n`t`t`t`t`"include`"`t`"panorama`""
$updatedPatched = $updated -replace '("maps"\n)', "`$1`t`t`t`t`"include`"`t`"characters`"`n"
[IO.File]::WriteAllText($gi, $updatedPatched, $Utf8)
[IO.File]::WriteAllBytes("$gi.bak", $orig)
$cl2 = Invoke-Script 'Cleanup-AG2.ps1' @('-CS2Path', $cs2b, '-Addon', 'setuptest', '-Remove')
Check ((Read-Text $gi) -ceq $updated) "stale backup: current file kept, only our line removed" $cl2.Out

} finally {
    Write-Host ""
    $col = if ($script:Fail) { 'Red' } else { 'Green' }
    Write-Host ("passed {0}   failed {1}" -f $script:Pass, $script:Fail) -ForegroundColor $col
    if ($KeepTemp -or $script:Fail) { Write-Host "work folder kept: $Tmp" -ForegroundColor DarkGray }
    else { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $(if ($script:Fail) { 1 } else { 0 })
