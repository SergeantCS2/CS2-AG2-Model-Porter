param(
    [switch]$Remove,
    [switch]$KeepGameinfo,   # leave the gameinfo.gi patch in place (still mid-project)
    [switch]$ResetWork,      # clear extracted/compiled work only, keep setup intact
    [string]$Addon = "ag2port",
    # CS2 lives elsewhere if your Steam library is on another drive
    [string]$CS2Path = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"
)

$SCRIPT_VERSION = "1.3.0"
Write-Host "Cleanup-AG2 $SCRIPT_VERSION" -ForegroundColor DarkGray

# Removes everything this project added to the local CS2 install.
# Run with no arguments to LIST what would go. Run with -Remove to delete.
#
#   .\Cleanup-AG2.ps1            # dry run, shows everything
#   .\Cleanup-AG2.ps1 -Remove    # actually deletes

$CS = $CS2Path

# gameinfo.gi with our one line taken out, keeping its own line endings and
# encoding - i.e. the file exactly as it was before Setup touched it.
function Get-UnpatchedGameinfo([string]$Path) {
    $Path  = (Resolve-Path -LiteralPath $Path).ProviderPath
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text  = [IO.File]::ReadAllText($Path)
    $nl    = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $keep  = [regex]::Split($text, '\r?\n') | Where-Object { $_ -notmatch '"include"\s+"characters"' }
    return @{ Text = (@($keep) -join $nl); Bom = $bom }
}
function Get-Normalised([string]$t) { return ($t -replace "`r`n", "`n").TrimEnd() }

if ($ResetWork) {
    Write-Host "`n=== resetting work in progress (setup left intact) ===" -ForegroundColor Cyan
    foreach ($d in @("$CS\content\csgo_addons\$Addon\characters",
                     "$CS\game\csgo_addons\$Addon\characters",
                     "$CS\content\csgo_addons\$Addon\materials",
                     "$CS\game\csgo_addons\$Addon\materials")) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force; Write-Host "  cleared $d" -ForegroundColor Green }
        else { Write-Host "  already clean  $d" -ForegroundColor DarkGray }
    }
    Write-Host "`ngameinfo.gi and the addon shell are untouched. Re-run Port-Model.ps1.`n"
    exit
}

# Addon authoring folder and the compiler's output folder. These are the only
# two places this tool writes, apart from one line in gameinfo.gi.
$targets = @(
    "$CS\content\csgo_addons\$Addon",
    "$CS\game\csgo_addons\$Addon"
)

Write-Host "`n=== paths this project created ===" -ForegroundColor Cyan
$found = @()
foreach ($t in $targets) {
    if (Test-Path $t) {
        $item = Get-Item $t
        $n = if ($item.PSIsContainer) { (Get-ChildItem $t -Recurse -File).Count } else { 1 }
        Write-Host ("  EXISTS  {0,-5} file(s)  {1}" -f $n, $t) -ForegroundColor Yellow
        $found += $t
    } else {
        Write-Host ("  absent              {0}" -f $t) -ForegroundColor DarkGray
    }
}

# --- safety check ---
# This tool never writes to game\csgo. But plenty of older guides tell people
# to drop model files there by hand, and it does not work - CS2 resolves these
# paths inside VPKs. If anything shows up here it came from somewhere else, and
# it is worth knowing about.
Write-Host "`n=== safety check: loose files under game\csgo ===" -ForegroundColor Cyan
Write-Host "    (this tool never writes here - CS2 ships these inside pak01)" -ForegroundColor DarkGray
foreach ($d in @("$CS\game\csgo\characters", "$CS\game\csgo\materials")) {
    if (Test-Path $d) {
        $f = Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue
        Write-Host ("  {0}  ->  {1} file(s)" -f $d, $f.Count) -ForegroundColor Yellow
        $f | Select-Object -First 12 | ForEach-Object {
            Write-Host ("      " + $_.FullName.Replace("$CS\game\csgo\", "")) -ForegroundColor DarkYellow }
        if ($f.Count -gt 12) { Write-Host "      ... and $($f.Count - 12) more" -ForegroundColor DarkYellow }
    } else {
        Write-Host "  $d  ->  does not exist (clean)" -ForegroundColor DarkGray
    }
}

# --- gameinfo.gi ---
Write-Host "`n=== gameinfo.gi ===" -ForegroundColor Cyan
$gi = "$CS\game\csgo\gameinfo.gi"
if (Test-Path $gi) { $gi = (Resolve-Path -LiteralPath $gi).ProviderPath }   # .NET calls below need a real path
$hits = (Select-String -Path $gi -Pattern '"include"\s+"characters"' -ErrorAction SilentlyContinue).Count
if ($hits -gt 0) {
    Write-Host "  MODIFIED - contains the 'characters' include we added" -ForegroundColor Yellow
    if (Test-Path "$gi.bak") {
        $un = Get-UnpatchedGameinfo $gi
        if ((Get-Normalised $un.Text) -ceq (Get-Normalised ([IO.File]::ReadAllText("$gi.bak")))) {
            Write-Host "  backup present at $gi.bak" -ForegroundColor Green
        } else {
            Write-Host "  backup at $gi.bak is from an older CS2 build - cleanup will remove just" -ForegroundColor Yellow
            Write-Host "  the added line instead of restoring it" -ForegroundColor Yellow
        }
    }
    else { Write-Host "  no backup - cleanup will remove just the added line" -ForegroundColor Yellow }
} else {
    Write-Host "  unmodified (no 'characters' include)" -ForegroundColor Green
    if (Test-Path "$gi.bak") {
        Write-Host "  (an old gameinfo.gi.bak is still there - not needed, safe to delete)" -ForegroundColor DarkGray
    }
}

if (-not $Remove) {
    Write-Host "`nDRY RUN. Nothing has been changed." -ForegroundColor Cyan
    Write-Host "Re-run with -Remove to delete the paths above" -NoNewline
    if ($hits -gt 0) { Write-Host " and undo the gameinfo.gi change." }
    else { Write-Host "." }
    Write-Host ""
    exit
}

Write-Host "`n=== removing ===" -ForegroundColor Red
foreach ($t in $found) {
    try { Remove-Item $t -Recurse -Force -ErrorAction Stop; Write-Host "  removed  $t" -ForegroundColor Green }
    catch { Write-Host "  FAILED   $t  ($($_.Exception.Message))" -ForegroundColor Red }
}

# prune empty parents we may have created
foreach ($d in @("$CS\game\csgo\characters\models",
                 "$CS\game\csgo\characters")) {
    if ((Test-Path $d) -and -not (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue)) {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed empty  $d" -ForegroundColor Green
    }
}

# --- restore gameinfo.gi ---
if ($hits -gt 0 -and $KeepGameinfo) {
    Write-Host "  gameinfo.gi left patched (-KeepGameinfo)" -ForegroundColor DarkGray
} elseif ($hits -gt 0) {
    $un = Get-UnpatchedGameinfo $gi
    $bakMatches = (Test-Path "$gi.bak") -and
                  ((Get-Normalised $un.Text) -ceq (Get-Normalised ([IO.File]::ReadAllText("$gi.bak"))))
    if ($bakMatches) {
        # the backup IS this file minus our line - restore it byte for byte
        Copy-Item "$gi.bak" $gi -Force
        Write-Host "  restored gameinfo.gi from backup" -ForegroundColor Green
    } else {
        # No backup, or one from an older CS2 build: restoring that would roll
        # the file back. Take out just the line Setup added.
        [IO.File]::WriteAllText($gi, $un.Text, (New-Object Text.UTF8Encoding($un.Bom)))
        if (Test-Path "$gi.bak") {
            Write-Host "  removed the 'characters' include (the backup predates a CS2 update, so it was not restored)" -ForegroundColor Green
        } else {
            Write-Host "  removed the 'characters' include from gameinfo.gi (no backup existed)" -ForegroundColor Green
        }
    }
    if (Test-Path "$gi.bak") { Remove-Item "$gi.bak" -Force }
}

Write-Host "`nDone. For a guaranteed-clean install:" -ForegroundColor Cyan
Write-Host "  Steam -> Counter-Strike 2 -> gear -> Properties -> Installed Files"
Write-Host "        -> Verify integrity of game files`n"
