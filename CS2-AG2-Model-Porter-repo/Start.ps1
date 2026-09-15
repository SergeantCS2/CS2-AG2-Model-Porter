
$SCRIPT_VERSION = "1.2.0"
#requires -Version 5.1
<#
    CS2-AG2-Model-Porter — interactive launcher

    Run this and answer the prompts. Everything else in this folder can also be
    called directly with parameters if you prefer; see README.md.

        powershell -ExecutionPolicy Bypass -File .\Start.ps1
#>

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgFile = Join-Path $here "settings.json"


# ---------------------------------------------------------------- banner
function Show-Banner {
    $art = @(
        "  ___  ___ ___    _   ___ ___   ___  ___  ___ _____ ",
        " / __|/ __|_  )  /_\ / __|_  ) | _ \/ _ \| _ \_   _|",
        "| (__ \__ \/ /  / _ \ (_ |/ /  |  _/ (_) |   / | |  ",
        " \___||___/___|/_/ \_\___/___| |_|  \___/|_|_\ |_|  "
    )
    $cols = @("DarkCyan","Cyan","Cyan","DarkCyan")
    Clear-Host
    Write-Host ""
    for ($i = 0; $i -lt $art.Count; $i++) {
        Write-Host ("  " + $art[$i]) -ForegroundColor $cols[$i]
        Start-Sleep -Milliseconds 45
    }
    Write-Host ""
    $tag = "  make pre-AnimGraph2 player models animate again   v$SCRIPT_VERSION"
    foreach ($ch in $tag.ToCharArray()) { Write-Host $ch -NoNewline -ForegroundColor Gray; Start-Sleep -Milliseconds 6 }
    Write-Host "`n"
}

function Write-Head($t) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

function Ask($prompt, $default) {
    if ($default) { $r = Read-Host "$prompt [$default]"; if (-not $r) { return $default }; return $r }
    # bail rather than spin if stdin is closed (piped / non-interactive run)
    for ($i = 0; $i -lt 10; $i++) { $r = Read-Host $prompt; if ($r) { return $r } }
    Write-Host "  no input - exiting" -ForegroundColor Red; exit 1
}

function Ask-YesNo($prompt, $defaultYes = $true) {
    $hint = if ($defaultYes) { "Y/n" } else { "y/N" }
    $r = Read-Host "$prompt [$hint]"
    if (-not $r) { return $defaultYes }
    return $r -match '^[Yy]'
}

# ---------------------------------------------------------------- settings
$cfg = @{}
if (Test-Path $cfgFile) {
    try { (Get-Content $cfgFile -Raw | ConvertFrom-Json).PSObject.Properties |
          ForEach-Object { $cfg[$_.Name] = $_.Value } } catch {}
}
function Save-Settings { $cfg | ConvertTo-Json | Set-Content $cfgFile }

Show-Banner
Write-Host @"
Repairs CS2 player models broken by the AnimGraph2 update, so they animate
again instead of T-posing.

You will need: CS2 + the Workshop Tools DLC installed, and a subscription to
the workshop pack you want to port.
"@

# ---------------------------------------------------------------- CS2 path
Write-Head "1. Locate CS2"
$candidates = @()
if ($cfg.CS2Path) { $candidates += $cfg.CS2Path }
$candidates += "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"
# any other Steam libraries?
$lib = "C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf"
if (Test-Path $lib) {
    foreach ($m in [regex]::Matches((Get-Content $lib -Raw), '"path"\s+"([^"]+)"')) {
        $candidates += ($m.Groups[1].Value -replace '\\\\', '\') +
                       "\steamapps\common\Counter-Strike Global Offensive"
    }
}
# a stale libraryfolders.vdf can name a drive that no longer exists, and
# Test-Path throws on a missing drive under ErrorActionPreference=Stop
function Test-CS2([string]$p) {
    if (-not $p) { return $false }
    try { return Test-Path (Join-Path $p "game\csgo\gameinfo.gi") -ErrorAction SilentlyContinue }
    catch { return $false }
}
$CS2 = $candidates | Where-Object { Test-CS2 $_ } | Select-Object -First 1
if ($CS2) { Write-Host "  found: $CS2" -ForegroundColor Green }
else {
    Write-Host "  could not find CS2 automatically." -ForegroundColor Yellow
    do {
        $CS2 = Ask "  Full path to your Counter-Strike Global Offensive folder"
        if (-not (Test-CS2 $CS2)) {
            Write-Host "  that does not look like a CS2 install (no game\csgo\gameinfo.gi)" -ForegroundColor Red
            $CS2 = $null
        }
    } while (-not $CS2)
}
$cfg.CS2Path = $CS2

$rc = Join-Path $CS2 "game\bin\win64\resourcecompiler.exe"
if (-not (Test-Path $rc -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  WORKSHOP TOOLS NOT INSTALLED." -ForegroundColor Red
    Write-Host "  Steam -> Counter-Strike 2 -> gear -> Properties -> DLC" -ForegroundColor Yellow
    Write-Host "  -> tick 'Counter-Strike 2 Workshop Tools' (~10 GB), then re-run." -ForegroundColor Yellow
    Save-Settings; Read-Host "`n  Enter to exit"; exit 1
}
Write-Host "  Workshop Tools: present" -ForegroundColor Green

# ---------------------------------------------------------------- source
Write-Head "2. Where are the models?"
Write-Host @"
  1  A Workshop pack I'm subscribed to        (most common)
  2  A .vpk file on disk                      (delisted pack, backup, manual download)
  3  A folder of loose model files            (.vmdl_c extracted from anywhere)
"@
$srcMode = Ask "  Choice" $(if ($cfg.SrcMode) { $cfg.SrcMode } else { "1" })
$cfg.SrcMode = $srcMode
$Pack = ""; $VpkPath = ""; $SrcPath = ""

switch ($srcMode) {
  "2" {
      Write-Host "`n  Point me at the .vpk. If the pack is split into _dir and _000 etc,"
      Write-Host "  give me the _dir one (or any of them - I'll find the index)."
      do {
          $VpkPath = (Ask "  Path to .vpk" $cfg.VpkPath).Trim('"')
          $ok = Test-Path $VpkPath
          if (-not $ok) { Write-Host "  not found" -ForegroundColor Red }
      } while (-not $ok)
      $cfg.VpkPath = $VpkPath
      Write-Host ("  found: {0:N0} MB" -f ((Get-Item $VpkPath).Length / 1MB)) -ForegroundColor Green
  }
  "3" {
      Write-Host @"

  I need the compiled model files, the same shape they come out of a VPK:

      <any folder>\
        somemodel_player_model\
          somemodel_player_model.vmdl_c        <- required
          materials\
            whatever.vmat_c                    <- strongly recommended
            whatever.vtex_c                    <- strongly recommended

  Only the .vmdl_c is strictly required - each model records its own intended
  path internally, so I can work out where it belongs. Without the materials
  the model compiles but comes out untextured.

  Subfolders are searched, so point me at the top and I'll find everything.
"@
      do {
          $SrcPath = (Ask "  Folder containing the models" $cfg.SrcPath).Trim('"')
          $ok = Test-Path $SrcPath
          if (-not $ok) { Write-Host "  not found" -ForegroundColor Red; continue }
          $n = @(Get-ChildItem $SrcPath -Recurse -Filter *.vmdl_c -EA SilentlyContinue).Count
          if ($n -eq 0) { Write-Host "  no .vmdl_c files anywhere under that folder" -ForegroundColor Red; $ok = $false }
          else { Write-Host "  found $n .vmdl_c file(s)" -ForegroundColor Green }
      } while (-not $ok)
      $cfg.SrcPath = $SrcPath
  }
  default {
      $wsRoot = Split-Path (Split-Path $CS2 -Parent) -Parent   # ...\steamapps
      $wsRoot = Join-Path $wsRoot "workshop\content\730"
      Write-Host @"

  Open the pack's Steam Workshop page. The id is the number at the end:
      steamcommunity.com/sharedfiles/filedetails/?id=1234567890
                                                     ^^^^^^^^^^
  You must be subscribed, and have launched CS2 once since subscribing.
"@
      do {
          $Pack = (Ask "  Workshop id" $cfg.Pack).Trim()
          $ok = $Pack -match '^\d+$'
          if (-not $ok) { Write-Host "  ids are numbers only" -ForegroundColor Red; continue }
          $pdir = Join-Path $wsRoot $Pack
          if (-not (Test-Path $pdir)) {
              Write-Host "  not downloaded: $pdir" -ForegroundColor Red
              Write-Host "  Subscribe in Steam, launch CS2 once, then come back." -ForegroundColor Yellow
              Write-Host "  (If the item was removed from the Workshop, use option 2 or 3 instead.)" -ForegroundColor Yellow
              if (-not (Ask-YesNo "  Try a different id?")) { Save-Settings; exit 1 }
              $ok = $false
          }
      } while (-not $ok)
      $cfg.Pack = $Pack
      # prefer the _dir index over an archive part, for a less confusing message
      $vpk = Get-ChildItem $pdir -Filter *.vpk -EA SilentlyContinue |
             Sort-Object { $_.Name -notlike "*_dir.vpk" } | Select-Object -First 1
      Write-Host ("  found: {0} ({1:N0} MB)" -f $vpk.Name, ($vpk.Length / 1MB)) -ForegroundColor Green
  }
}

# args describing the chosen source, appended to every Port-Model call
$srcArgs = switch ($srcMode) {
    "2"     { @("-Vpk", $VpkPath) }
    "3"     { @("-Source", $SrcPath) }
    default { @("-Pack", $Pack) }
}

# ---------------------------------------------------------------- addon
Write-Head "3. Addon name"
Write-Host @"
  Your ported models go into a CS2 addon, which you later publish to the
  Workshop as your own item. Lowercase, no spaces.
"@
$Addon = Ask "  Addon name" $(if ($cfg.Addon) { $cfg.Addon } else { "ag2port" })
$cfg.Addon = $Addon
Save-Settings

# ---------------------------------------------------------------- menu
$common = @("-CS2Path", $CS2, "-Addon", $Addon)
function Run($script, $extra) {
    $p = Join-Path $here $script
    if (-not (Test-Path $p)) { Write-Host "  missing: $script" -ForegroundColor Red; return }
    & powershell -ExecutionPolicy Bypass -File $p @extra | Out-Host
}

while ($true) {
    Write-Head "What would you like to do?"
    Write-Host @"
   1  Set up          (one-time: gameinfo.gi, Source2Viewer, addon folders)
   2  List models     (see what is in the pack)
   3  Port ONE model
   4  Port ALL models
   5  Verify          (check compiled models before publishing)
   6  Clean up        (remove everything this tool added)
   7  What next?      (publishing and server setup)
   8  About
   Q  Quit
"@
    switch ((Read-Host "  Choice").ToUpper()) {
        "1" { Run "Setup-AG2.ps1"  ($common + $srcArgs) }
        "2" { Run "Port-Model.ps1" ($common + $srcArgs + @("-ListOnly")) }
        "3" {
            $m = Ask "  Model name (as shown by option 2)"
            Run "Port-Model.ps1" ($common + $srcArgs + @("-Model", $m))
        }
        "4" {
            Write-Host "  This can take several minutes." -ForegroundColor Yellow
            if (Ask-YesNo "  Port every model in the pack?") {
                Run "Port-Model.ps1" ($common + $srcArgs + @("-All"))
            }
        }
        "5" { Run "Verify-Model.ps1" ($common + @("-All")) }
        "6" {
            Run "Cleanup-AG2.ps1" @("-CS2Path", $CS2, "-Addon", $Addon)
            Write-Host ""
            if (Ask-YesNo "  Actually delete the paths listed above?" $false) {
                Run "Cleanup-AG2.ps1" @("-CS2Path", $CS2, "-Addon", $Addon, "-Remove")
            }
        }
        "7" {
            Write-Head "Publishing and server setup"
            Write-Host @"
  PUBLISH
    Launch the CS2 Workshop Tools and select addon '$Addon'.
    Asset Browser -> Tools -> Counter-Strike 2 Workshop Manager.
    Create an item, fill in title/description/preview, submit.

    New items are held for Steam moderation. Nothing - not even your own
    server - can download the item until it is approved. This usually takes
    hours. 'Unlisted' is fine; it stays out of search but is fetchable by id.

  SERVER
    Add your new workshop id to MultiAddonManager's mm_extra_addons, and
    remove the original pack's id so the broken originals cannot shadow
    yours. Point your player-model plugin at the same VPK-internal paths -
    they do not change.

    If your server writes config from a template directory, make sure the
    live copy actually got updated. Boot-time copies often skip files that
    already exist.

  TEST
    Restart the server, then BEFORE joining check that the addon mounted:
        docker logs <container> 2>&1 | grep -i "Mounting addon"
    If instead you see 'Addon download started' repeating, the server cannot
    fetch the item - it is still in moderation, or the id is wrong. Remove it
    from mm_extra_addons before it loops.

    Launch CS2 from Steam normally, NOT through the Workshop Tools - the
    tools run the game insecure and VAC servers will refuse the connection.

    Join, change map once so the addon downloads to your client, then switch
    to one of the ported models.
"@
            Read-Host "`n  Enter to continue" | Out-Null
        }
        "8" {
            Show-Banner
            Write-Host @"
  CS2's AnimGraph2 update broke every custom player model made before it.
  They load, they render, they stand there doing nothing. Turned out the
  cause was one line - the models ask for an AnimGraph1 graph that Valve
  deleted.

      characters/models/shared/animgraphs/player_ct.vanmgrph    <- gone
      animation/graphs/worldmodel/worldmodel.vnmgraph           <- what CS2 uses now

  These scripts rewrite that, plus everything else the migration needs, and
  recompile. No 3D work.

  The method came from pulling apart Valve's own agents and comparing them to
  broken community models until there were no differences left. Nothing in
  here is guesswork - every rule is measured against something that actually
  animates.

  Built over one long night - me doing the testing, an AI doing the reading,
  the two of us arguing until the models moved.

  MIT licensed. The scripts are free. The models aren't mine or yours - ask
  before you republish someone else's work.
"@ -ForegroundColor Gray
            Read-Host "`n  Enter to continue" | Out-Null
        }
        "Q" { Write-Host "`n  Settings saved to settings.json`n"; exit }
        default { Write-Host "  ?" -ForegroundColor DarkGray }
    }
}
