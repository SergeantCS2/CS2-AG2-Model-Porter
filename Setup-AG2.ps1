param(
    [string]$Addon = "ag2port",
    # workshop id of the pre-AG2 pack you want to port
    [string]$Pack  = "3186973222",
    # accepted so the wizard can pass one set of source flags to every
    # script. Setup only needs to know whether to check a workshop pack.
    [string]$Vpk    = "",
    [string]$Source = "",
    [switch]$Force,   # re-download the CLI even if present
    # CS2 lives elsewhere if your Steam library is on another drive
    [string]$CS2Path = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive",
    # Source2Viewer release to install, e.g. "20.1". Empty = the newest. Only
    # needed if a new release changes its output and porting breaks - pin the
    # last one that worked and re-run with -Force.
    [string]$S2VVersion = "",
    # where Source2Viewer-CLI lives; Port-Model and Verify look here by default
    [string]$S2VDir = "$env:USERPROFILE\s2v"
)

$SCRIPT_VERSION = "1.3.0"
Write-Host "Setup-AG2 $SCRIPT_VERSION" -ForegroundColor DarkGray

# One-time setup. Idempotent - safe to re-run.
#
#   .\Setup-AG2.ps1
#
# Does: verifies Workshop Tools, patches gameinfo.gi (with backup), downloads
# Source2Viewer-CLI, creates the addon folders, unblocks the scripts.
#
# The ONLY thing it cannot do is install the Workshop Tools DLC - that is a
# Steam UI action. It will tell you if it is missing.

$ErrorActionPreference = "Stop"
$CS   = $CS2Path
$GI   = "$CS\game\csgo\gameinfo.gi"
$RC   = "$CS\game\bin\win64\resourcecompiler.exe"
$S2V  = $S2VDir
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fail = 0

function Say($ok, $msg) {
    if ($ok) { Write-Host "  [ok]   $msg" -ForegroundColor Green }
    else     { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n=== AG2 setup ===" -ForegroundColor Cyan

# --- 1. CS2 + Workshop Tools ---
Say (Test-Path $CS) "CS2 install found"
if (Test-Path $RC) {
    Say $true "Workshop Tools installed (resourcecompiler present)"
} else {
    Say $false "Workshop Tools DLC not installed - this is required"
    Write-Host ""
    Write-Host "         1. Steam Library -> right-click Counter-Strike 2 -> Properties" -ForegroundColor Yellow
    Write-Host "            (or select it and click the gear icon)" -ForegroundColor DarkYellow
    Write-Host "         2. Click the DLC tab on the left" -ForegroundColor Yellow
    Write-Host "         3. Tick 'Counter-Strike 2 Workshop Tools' (~10 GB)" -ForegroundColor Yellow
    Write-Host "         4. Wait for the download, then re-run this" -ForegroundColor Yellow
    Write-Host ""
}

# --- 2. gameinfo.gi ---
# The file is edited as raw text: same line endings, same encoding, one line
# added. That way Cleanup can take exactly that line out again and leave the
# file byte-for-byte as CS2 shipped it.
if (Test-Path $GI) {
    $GI = (Resolve-Path -LiteralPath $GI).ProviderPath     # .NET calls below need a real path
    $giBytes = [IO.File]::ReadAllBytes($GI)
    $giBom   = ($giBytes.Length -ge 3 -and $giBytes[0] -eq 0xEF -and $giBytes[1] -eq 0xBB -and $giBytes[2] -eq 0xBF)
    $giText  = [IO.File]::ReadAllText($GI)
    if ($giText -match '"include"\s+"characters"') {
        Say $true "gameinfo.gi already has the 'characters' include"
    } else {
        $nl    = if ($giText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = [regex]::Split($giText, '\r?\n')
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '"include"\s+"maps"\s*$') { $idx = $i; break }
        }
        if ($idx -lt 0) {
            Say $false "could not find the VpkDirectories block - add manually, see QUICKSTART"
        } else {
            $ind = ($lines[$idx] -replace '"include".*$', '')
            $new = @($lines[0..$idx]) + @("$ind`"include`"       `"characters`"")
            if ($idx + 1 -le $lines.Count - 1) { $new += @($lines[($idx+1)..($lines.Count-1)]) }
            try {
                # Back up what is there NOW. A backup kept from an older CS2
                # build would roll gameinfo.gi back to that build on cleanup.
                [IO.File]::WriteAllBytes("$GI.bak", $giBytes)
                [IO.File]::WriteAllText($GI, ($new -join $nl), (New-Object Text.UTF8Encoding($giBom)))
                Say $true "gameinfo.gi patched (backup at gameinfo.gi.bak)"
            } catch {
                Say $false "gameinfo.gi is LOCKED - close CS2 and the Workshop Tools, then re-run"
            }
        }
    }
} else { Say $false "gameinfo.gi not found" }

# --- 3. Source2Viewer CLI ---
$exe = "$S2V\Source2Viewer-CLI.exe"
if ((Test-Path $exe) -and -not $Force) {
    Say $true "Source2Viewer-CLI already at $exe"
} else {
    try {
        New-Item -ItemType Directory -Force -Path $S2V | Out-Null
        $url = if ($S2VVersion) {
                   "https://github.com/ValveResourceFormat/ValveResourceFormat/releases/download/$S2VVersion/cli-windows-x64.zip"
               } else {
                   "https://github.com/ValveResourceFormat/ValveResourceFormat/releases/latest/download/cli-windows-x64.zip"
               }
        $zip = "$env:TEMP\s2v-cli.zip"
        Write-Host "  ...  downloading Source2Viewer-CLI $(if ($S2VVersion) { $S2VVersion } else { '(newest release)' })" -ForegroundColor DarkGray
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $S2V -Force
        Remove-Item $zip -Force
        if (Test-Path $exe) { Say $true "Source2Viewer-CLI installed to $S2V" }
        else { Say $false "download succeeded but Source2Viewer-CLI.exe not found in the zip" }
    } catch {
        Say $false "Source2Viewer download failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "         Grab it by hand instead:" -ForegroundColor Yellow
        Write-Host "         1. https://github.com/ValveResourceFormat/ValveResourceFormat/releases" -ForegroundColor Yellow
        Write-Host "         2. Download cli-windows-x64.zip from the newest release" -ForegroundColor Yellow
        Write-Host "         3. Extract so this file exists:" -ForegroundColor Yellow
        Write-Host "            $S2V\Source2Viewer-CLI.exe" -ForegroundColor DarkYellow
        Write-Host "         4. Re-run this" -ForegroundColor Yellow
        Write-Host ""
    }
}

# Which release is installed? Its output format is what the porting relies on,
# so it is worth having in the log when something changes.
if (Test-Path $exe) {
    try {
        $verOut = & $exe --version 2>&1 | Out-String
        $ver = ($verOut -split "`n" | Where-Object { $_ -match '\d+\.\d+' } | Select-Object -First 1)
        if ($ver) { Write-Host "         version: $($ver.Trim())" -ForegroundColor DarkGray }
    } catch {}
}

# --- 4. addon folders ---
foreach ($d in @("$CS\content\csgo_addons\$Addon", "$CS\game\csgo_addons\$Addon")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$ai = "$CS\content\csgo_addons\$Addon\addoninfo.txt"
if (-not (Test-Path $ai)) {
    @('"addoninfo"', '{', "`t`"addontitle`"`t`t`"$Addon`"", "`t`"addonauthor`"`t`t`"`"",
      "`t`"addonversion`"`t`t`"1.0`"", '}') | Set-Content $ai
}
Say $true "addon '$Addon' folders ready"
Write-Host "         if the Workshop Manager does not list it, use" -ForegroundColor DarkGray
Write-Host "         Workshop Tools -> Create New Addon -> $Addon" -ForegroundColor DarkGray

# --- 5. unblock the scripts ---
if ($env:OS -eq 'Windows_NT') {        # downloaded-file marks are a Windows thing
    Get-ChildItem "$here\*.ps1" | Unblock-File
}
Say $true "scripts unblocked in $here"

# --- 6. is the source actually available? ---
if ($Vpk) {
    if (Test-Path $Vpk) { Say $true "source vpk present: $(Split-Path $Vpk -Leaf)" }
    else { Say $false "vpk not found: $Vpk" }
} elseif ($Source) {
    $n = @(Get-ChildItem $Source -Recurse -Filter *.vmdl_c -EA SilentlyContinue).Count
    if ($n -gt 0) { Say $true "$n model file(s) found under $Source" }
    else { Say $false "no .vmdl_c files under $Source" }
} else {
    # Large packs are split into <id>_dir.vpk plus <id>_000.vpk, _001.vpk and so
    # on - there is no plain <id>.vpk. Look for any .vpk in the folder.
    # Workshop content lands in the same Steam library as CS2 itself
    $steamapps = Split-Path (Split-Path $CS.TrimEnd('\', '/') -Parent) -Parent
    $packDir = Join-Path $steamapps "workshop\content\730\$Pack"
    if (-not (Test-Path $packDir)) {
        $defDir = "C:\Program Files (x86)\Steam\steamapps\workshop\content\730\$Pack"
        if (Test-Path $defDir) { $packDir = $defDir }
    }
    $packVpk = Get-ChildItem $packDir -Filter *.vpk -EA SilentlyContinue |
               Sort-Object { $_.Name -notlike "*_dir.vpk" } | Select-Object -First 1
    if ($packVpk) {
        Say $true ("source pack $Pack present ({0}, {1:N0} MB)" -f $packVpk.Name, ($packVpk.Length / 1MB))
    }
    else {
        Say $false "pack $Pack not downloaded"
        Write-Host "         Subscribe in the Steam Workshop, then LAUNCH CS2 ONCE." -ForegroundColor Yellow
        Write-Host "         Steam does not download workshop content until the game runs." -ForegroundColor DarkYellow
        Write-Host "         (Removed from the Workshop? Use -Vpk or -Source instead.)" -ForegroundColor DarkYellow
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "Setup complete." -ForegroundColor Green
    Write-Host "  next:  .\Port-Model.ps1 -ListOnly     see what is in the pack"
    Write-Host "         .\Port-Model.ps1 -All          port everything`n"
} else {
    Write-Host "$fail item(s) above need attention before porting will work.`n" -ForegroundColor Red
    exit 1
}
