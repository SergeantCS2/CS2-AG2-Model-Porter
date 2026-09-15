param([Parameter(Mandatory=$true)][string]$MaterialsDir)

$SCRIPT_VERSION = "1.2.0"
Write-Host "Fix-Materials $SCRIPT_VERSION" -ForegroundColor DarkGray

# Clean up the .vmat files Source2Viewer-CLI produces so resourcecompiler
# accepts them.
#
# CLI output is already close: correct Texture* input names, source-named .png
# paths. Three things still break the compile:
#   1. a "Compiled Textures" sub-block listing g_t* -> .vtex references. Those
#      are compiler OUTPUTS; their presence makes the compiler reject the file.
#   2. params pointing at compiler-generated composites (_vmat_g_*), which have
#      no source file.
#   3. params pointing at CS2 stock defaults (materials/default/*), which are
#      not in the addon. Dropping them lets the shader use its own.
#
# Also handles GUI-exported files, where textures carry compiled-output names
# (foo_png_a1b2c3d4.png = "source foo.png compiled to foo_png_a1b2c3d4.vtex")
# and params use output slot names (g_tColor rather than TextureColor).

if (-not (Test-Path $MaterialsDir)) { Write-Error "not found: $MaterialsDir"; exit 1 }

# --- rename compiled-output-named textures back to source names ---
$renamed = 0
Get-ChildItem "$MaterialsDir\*.png", "$MaterialsDir\*.tga" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match '_vmat_g_') { return }        # generated composite, leave alone
    $n = $_.Name -replace '_(png|tga|jpg)_[0-9a-f]{8}(\.\w+)$', '$2'
    if ($n -ne $_.Name) {
        if (Test-Path (Join-Path $_.DirectoryName $n)) { Remove-Item $_.FullName -Force }
        else { Move-Item $_.FullName (Join-Path $_.DirectoryName $n) -Force }
        $renamed++
    }
}

# --- repair the .vmat sources ---
$fixed = 0; $dropped = 0
Get-ChildItem "$MaterialsDir\*.vmat" -ErrorAction SilentlyContinue | ForEach-Object {
    $out = @(); $depth = 0; $skip = $false
    foreach ($line in (Get-Content $_.FullName)) {

        # drop the "Compiled Textures" sub-block entirely
        if ($line -match '"Compiled Textures"') { $skip = $true; $depth = 0; continue }
        if ($skip) {
            $depth += ([regex]::Matches($line, '\{')).Count
            $depth -= ([regex]::Matches($line, '\}')).Count
            if ($depth -le 0 -and $line -match '\}') { $skip = $false }
            continue
        }

        # drop params pointing at things that are not real sources
        if ($line -match '_vmat_g_')           { $dropped++; continue }
        if ($line -match 'materials/default/') { $dropped++; continue }

        # GUI-export fixups (no-ops on CLI output)
        $line = $line -replace '_(png|tga|jpg)_[0-9a-f]{8}(\.\w+)', '$2'
        $line = $line -replace '^(\s*)"?g_t(\w+)"?(\s+")', '$1"Texture$2"$3'

        $out += $line
    }
    Set-Content $_.FullName -Value $out
    $fixed++
}

"  textures renamed : $renamed"
"  materials fixed  : $fixed  (dropped $dropped unusable texture ref(s))"
