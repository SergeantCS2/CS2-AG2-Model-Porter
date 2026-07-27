param(
    [Parameter(Mandatory=$true)][string]$Path,
    # AnimGraph1-era nodes (MovementSettings, Feet/Foot, character_arm_config)
    # are STRIPPED BY DEFAULT. Measured against three known-working AG2 models -
    # Valve's own ctm_fbi and ctm_sas, plus B_CANSIN's Miku - and NONE of them
    # carry any of the three. Only the unported nozb1 models do. In AG2, arms
    # are decoupled from the player model entirely (Valve ships them separately
    # under agents/models/shared/arms/glove_*), so character_arm_config
    # pointing at an unported *_pm_arm.vmdl is at best dead weight.
    # Use -KeepAG1Nodes to retain them if a model needs it.
    [switch]$KeepAG1Nodes
)

$SCRIPT_VERSION = "1.0.0"
Write-Host "AG2-All $SCRIPT_VERSION" -ForegroundColor DarkGray
# ALL-IN-ONE: AG2 port + bodygroup repair + re-parent pelvis + wpnPivot graft

# Re-parent the pelvis subtree under root_motion.
#
# CS2's canonical AG2 skeleton is rooted at root_motion, with pelvis as its
# child. Many pre-AG2 nozb1 models instead have pelvis and root_motion as two
# INDEPENDENT roots, with root_motion holding only IK targets. The AG2 graph
# drives root_motion and its descendants, so on those models it drives a branch
# the body is not attached to -> correct names, correct graph, no animation.
#
# This moves the whole pelvis block to be the first child of root_motion.

if (-not (Test-Path $Path)) { Write-Error "not found: $Path"; exit 1 }
$L = [System.Collections.ArrayList]@(Get-Content -LiteralPath $Path)


# When pelvis stops being a root and becomes a child of root_motion, its
# transform must be re-expressed in root_motion's space or the whole body gets
# root_motion's rotation applied on top of its own - the model ends up rotated.
#
# root_motion is [0,90,90] in every nozb1 model AND in the working Miku, whose
# pelvis local origin [0, 42.82, -2.85] is exactly the canonical value in that
# space. Its matrix is the permutation [[0,0,1],[1,0,0],[0,1,0]], so R^T * M
# cycles the rows. Scalars throughout: PowerShell's nested array literals
# misparse this expression.
function Convert-ToRootMotionSpace {
    # Re-express a former root bone in root_motion's space: new = R^T * old,
    # where R is root_motion's own rotation. Handles ANY root_motion angles -
    # packs differ, and one seen in the wild sits at [0, 90.4687, 90] rather
    # than a clean [0, 90, 90]. Assuming the exact permutation there silently
    # skipped the conversion and left the model rotated.
    #
    # Written with flat scalars on purpose: PowerShell misparses nested
    # functions returning comma-arrays here, and it fails at runtime rather
    # than at parse time.
    param([double]$ox,[double]$oy,[double]$oz,          # bone origin
          [double]$ap,[double]$ay,[double]$ar,          # bone angles
          [double]$rp,[double]$ry,[double]$rr)          # root_motion angles
    $d = [math]::PI / 180.0

    # --- M: the bone's own rotation ---
    $p = $ap*$d; $y = $ay*$d; $r = $ar*$d
    $sp=[math]::Sin($p); $cp=[math]::Cos($p)
    $sy=[math]::Sin($y); $cy=[math]::Cos($y)
    $sr=[math]::Sin($r); $cr=[math]::Cos($r)
    $m00=$cp*$cy; $m01=$sr*$sp*$cy-$cr*$sy; $m02=$cr*$sp*$cy+$sr*$sy
    $m10=$cp*$sy; $m11=$sr*$sp*$sy+$cr*$cy; $m12=$cr*$sp*$sy-$sr*$cy
    $m20=-$sp;    $m21=$sr*$cp;             $m22=$cr*$cp

    # --- R: root_motion's rotation ---
    $p = $rp*$d; $y = $ry*$d; $r = $rr*$d
    $sp=[math]::Sin($p); $cp=[math]::Cos($p)
    $sy=[math]::Sin($y); $cy=[math]::Cos($y)
    $sr=[math]::Sin($r); $cr=[math]::Cos($r)
    $r00=$cp*$cy; $r01=$sr*$sp*$cy-$cr*$sy; $r02=$cr*$sp*$cy+$sr*$sy
    $r10=$cp*$sy; $r11=$sr*$sp*$sy+$cr*$cy; $r12=$cr*$sp*$sy-$sr*$cy
    $r20=-$sp;    $r21=$sr*$cp;             $r22=$cr*$cp

    # --- N = R^T * M ---
    $n00 = $r00*$m00 + $r10*$m10 + $r20*$m20
    $n01 = $r00*$m01 + $r10*$m11 + $r20*$m21
    $n02 = $r00*$m02 + $r10*$m12 + $r20*$m22
    $n10 = $r01*$m00 + $r11*$m10 + $r21*$m20
    $n11 = $r01*$m01 + $r11*$m11 + $r21*$m21
    $n12 = $r01*$m02 + $r11*$m12 + $r21*$m22
    $n20 = $r02*$m00 + $r12*$m10 + $r22*$m20
    $n21 = $r02*$m01 + $r12*$m11 + $r22*$m21
    $n22 = $r02*$m02 + $r12*$m12 + $r22*$m22

    # --- origin: R^T * o ---
    $nx = $r00*$ox + $r10*$oy + $r20*$oz
    $ny = $r01*$ox + $r11*$oy + $r21*$oz
    $nz = $r02*$ox + $r12*$oy + $r22*$oz

    $nyaw   = [math]::Atan2($n10, $n00) / $d
    $npitch = [math]::Atan2(-$n20, [math]::Sqrt($n00*$n00 + $n10*$n10)) / $d
    $nroll  = [math]::Atan2($n21, $n22) / $d
    return @{ ox=$nx; oy=$ny; oz=$nz; p=$npitch; y=$nyaw; r=$nroll }
}

function Get-Block([System.Collections.ArrayList]$lines, [int]$nameIdx) {
    # walk back to the '{' that opens this bone, then brace-match to its '}'
    $s = $nameIdx
    while ($s -ge 0 -and $lines[$s].Trim() -ne '{') { $s-- }
    $d = 0; $e = $s
    while ($e -lt $lines.Count) {
        $d += ([regex]::Matches($lines[$e], '\{')).Count
        $d -= ([regex]::Matches($lines[$e], '\}')).Count
        if ($d -eq 0) { break }
        $e++
    }
    return @($s, $e)
}

# locate the Skeleton node and the two candidate roots beneath it
$sk = -1
for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match '_class = "Skeleton"') { $sk = $i; break } }
if ($sk -lt 0) { Write-Error "no Skeleton node"; exit 1 }

$pel = -1; $rm = -1
for ($i = $sk; $i -lt $L.Count; $i++) {
    if ($pel -lt 0 -and $L[$i] -match 'name = "pelvis"')      { $pel = $i }
    if ($rm  -lt 0 -and $L[$i] -match 'name = "root_motion"') { $rm  = $i }
    if ($pel -ge 0 -and $rm -ge 0) { break }
}
if ($pel -lt 0 -or $rm -lt 0) { Write-Error "need both pelvis and root_motion"; exit 1 }

$pelInd = ($L[$pel] -replace 'name.*$', '').Length
$rmInd  = ($L[$rm]  -replace 'name.*$', '').Length
# Different depths means pelvis is already somewhere under root_motion, so the
# re-parent is done. Skip THIS STEP only - the AG2 nodes, weapon bones and the
# rest still need applying. Exiting here would silently skip them.
$needsReparent = ($pelInd -eq $rmInd)
if (-not $needsReparent) {
    "pelvis already parented under root_motion - skipping that step"
}
if ($needsReparent) {

$pb = Get-Block $L $pel;  $ps = $pb[0]; $pe = $pb[1]
"pelvis block:      lines $($ps+1)-$($pe+1)"
"root_motion at:    line $($rm+1)"

# --- re-express pelvis in root_motion's space -------------------------------
$rmAng = $null
for ($i = $rm; $i -lt [Math]::Min($rm + 6, $L.Count); $i++) {
    $mm = [regex]::Match($L[$i], 'angles = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]')
    if ($mm.Success) { $rmAng = @([double]$mm.Groups[1].Value, [double]$mm.Groups[2].Value, [double]$mm.Groups[3].Value); break }
}
if ($null -eq $rmAng) { $rmAng = @(0.0, 0.0, 0.0) }
# any root_motion rotation is handled - no need to match a specific one
if ($true) {
    $oIdx = -1; $aIdx = -1; $po = $null; $pa = $null
    for ($i = $pel; $i -lt [Math]::Min($pel + 8, $pe); $i++) {
        $mo = [regex]::Match($L[$i], 'origin = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]')
        if ($mo.Success -and $oIdx -lt 0) { $oIdx = $i; $po = @([double]$mo.Groups[1].Value, [double]$mo.Groups[2].Value, [double]$mo.Groups[3].Value) }
        $ma = [regex]::Match($L[$i], 'angles = \[ *([-\d.eE]+), *([-\d.eE]+), *([-\d.eE]+) *\]')
        if ($ma.Success -and $aIdx -lt 0) { $aIdx = $i; $pa = @([double]$ma.Groups[1].Value, [double]$ma.Groups[2].Value, [double]$ma.Groups[3].Value) }
    }
    if ($oIdx -ge 0 -and $aIdx -ge 0) {
        $c = Convert-ToRootMotionSpace $po[0] $po[1] $po[2] $pa[0] $pa[1] $pa[2] `
                                       $rmAng[0] $rmAng[1] $rmAng[2]
        $L[$oIdx] = [regex]::Replace($L[$oIdx], 'origin = \[[^\]]*\]', ("origin = [ {0:F6}, {1:F6}, {2:F6} ]" -f $c.ox, $c.oy, $c.oz))
        $L[$aIdx] = [regex]::Replace($L[$aIdx], 'angles = \[[^\]]*\]', ("angles = [ {0:F6}, {1:F6}, {2:F6} ]" -f $c.p, $c.y, $c.r))
        "pelvis transform  -> origin [{0:F4}, {1:F4}, {2:F4}]  angles [{3:F4}, {4:F4}, {5:F4}]" -f $c.ox,$c.oy,$c.oz,$c.p,$c.y,$c.r
    } else {
        Write-Warning "could not read pelvis origin/angles - transform NOT applied, model may be rotated"
    }
}

# lift the pelvis block out, re-indented one level deeper
$pelvis = @()
for ($i = $ps; $i -le $pe; $i++) { $pelvis += "`t" + $L[$i] }
$L.RemoveRange($ps, $pe - $ps + 1)

# root_motion moved if it sat after pelvis
$rm = -1
for ($i = $sk; $i -lt $L.Count; $i++) { if ($L[$i] -match 'name = "root_motion"') { $rm = $i; break } }
if ($rm -lt 0) { Write-Error "lost root_motion after removal"; exit 1 }

$ind = $L[$rm] -replace 'name.*$', ''
$k = -1
for ($i = $rm + 1; $i -lt $L.Count; $i++) {
    if ($L[$i].Trim() -eq 'children =' -and ($L[$i] -replace 'children.*$', '') -eq $ind) { $k = $i; break }
    if ($L[$i].Trim() -eq '}' -and ($L[$i] -replace '\}.*$', '').Length -lt $ind.Length) { break }
}
if ($k -lt 0) {
    # root_motion is a leaf: give it a children array containing pelvis
    $rb = Get-Block $L $rm; $re = $rb[1]
    $ins = @("$ind" + "children = ", "$ind[") + $pelvis + @("$ind]")
    $L.InsertRange($re, $ins)
    "root_motion had no children array - created one"
} else {
    $L.InsertRange($k + 2, $pelvis)
    "pelvis grafted as first child of root_motion"
}

$t = $L -join "`n"
$o = ([regex]::Matches($t, '\{')).Count; $c = ([regex]::Matches($t, '\}')).Count
$so = ([regex]::Matches($t, '\[')).Count; $sc = ([regex]::Matches($t, '\]')).Count
if ($o -ne $c -or $so -ne $sc) { Write-Error "BRACE MISMATCH {$o/$c} [$so/$sc] - not written"; exit 1 }

Copy-Item -LiteralPath $Path "$Path.preparent" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $Path -Value $t -NoNewline -Encoding utf8
"`nOK - braces balanced, backup at $Path.preparent"


}   # end: needsReparent

# ---- reload after re-parent, then apply the AG2 edits ----

# Port a decompiled ModelDoc .vmdl from AnimGraph 1 to AnimGraph 2.
# Edits: drop anim_graph_name + AnimIncludeModel, add NmSkeletonList +
# AnimGraph2List, graft wpnPivot -> wpn under root_motion.

if (-not (Test-Path $Path)) { Write-Error "not found: $Path"; exit 1 }

$L = [System.Collections.ArrayList]@(Get-Content -LiteralPath $Path)
$log = @()

# A model may already carry AG2 nodes (e.g. recompiled post-AG2 from old source)
# while still needing the case flip, Feet fix or bone graft. Skip only the node
# insertion, not the whole script.
$hasAG2 = ($L -join "`n") -match 'AnimGraph2List' 


# --- 0. case-flip side suffixes if this model predates the uppercase convention ---
# CS2's canonical AG2 skeleton uses _L/_R/_TWIST. One model in the nozb1 anime
# pack (adult_neptune) still uses lowercase _l/_r/_twist and will not bind by
# name. Flip only bones whose uppercase form is canonical - never touch custom
# bones, which may be referenced elsewhere. The flip is length-preserving.
$CANON = @('ankle_L','ankle_R','arm_lower_L','arm_lower_R','arm_upper_L','arm_upper_R','attachFoot_L','attachFoot_R','attachHand_L','attachHand_R','ball_L','ball_R','clavicle_L','clavicle_R','finger_index_0_L','finger_index_0_R','finger_index_1_L','finger_index_1_R','finger_index_2_L','finger_index_2_R','finger_index_meta_L','finger_index_meta_R','finger_middle_0_L','finger_middle_0_R','finger_middle_1_L','finger_middle_1_R','finger_middle_2_L','finger_middle_2_R','finger_middle_meta_L','finger_middle_meta_R','finger_pinky_0_L','finger_pinky_0_R','finger_pinky_1_L','finger_pinky_1_R','finger_pinky_2_L','finger_pinky_2_R','finger_pinky_meta_L','finger_pinky_meta_R','finger_ring_0_L','finger_ring_0_R','finger_ring_1_L','finger_ring_1_R','finger_ring_2_L','finger_ring_2_R','finger_ring_meta_L','finger_ring_meta_R','finger_thumb_0_L','finger_thumb_0_R','finger_thumb_1_L','finger_thumb_1_R','finger_thumb_2_L','finger_thumb_2_R','hand_L','hand_R','leg_lower_L','leg_lower_R','leg_upper_L','leg_upper_R','wpnHand_L','wpnHand_R')
$lower = @($L | Where-Object { $_ -match 'name = "\w+_(l|r)"' }).Count
if ($lower -gt 0) {
    $flipped = 0
    $pairs = @()
    for ($i = 0; $i -lt $L.Count; $i++) {
        # only rename actual Bone nodes. Physics shapes, hitboxes and
        # attachments have their own 'name =' and their own lowercase
        # conventions; renaming those breaks their binding.
        if ($i -lt 1 -or $L[$i-1] -notmatch '_class = "Bone"') { continue }
        $m = [regex]::Match($L[$i], 'name = "([A-Za-z0-9_]+)"')
        if (-not $m.Success) { continue }
        $n = $m.Groups[1].Value
        $c = $n -replace '_twist1$','_TWIST1' -replace '_twist$','_TWIST' `
                -replace '_l$','_L' -replace '_r$','_R' `
                -replace '_l(?=_TWIST)','_L' -replace '_r(?=_TWIST)','_R'
        if ($c -cne $n -and $CANON -contains $c) {
            $L[$i] = $L[$i] -replace ('name = "' + [regex]::Escape($n) + '"'), ('name = "' + $c + '"')
            $pairs += [pscustomobject]@{ Old = $n; New = $c }
            $flipped++
        }
    }
    if ($flipped) {
        $log += "case-flipped $flipped bone name(s) to _L/_R"

        # The mesh binds to bones BY NAME through the DMX jointList. Renaming
        # only the .vmdl desynchronises them and the compiler reports
        # "Invalid skinning bone index :: -1" for every joint. The flip is
        # length-preserving, so patch the DMX string table in place.
        $enc = [System.Text.Encoding]::GetEncoding(28591)   # Latin1, byte-preserving
        $dmxDir = Split-Path -Parent $Path
        $patched = 0
        foreach ($dmx in (Get-ChildItem "$dmxDir\*.dmx" -ErrorAction SilentlyContinue)) {
            $bytes = [IO.File]::ReadAllBytes($dmx.FullName)
            $txt = $enc.GetString($bytes)
            $before = $txt
            foreach ($p in $pairs) {
                $txt = $txt.Replace([char]0 + $p.Old + [char]0, [char]0 + $p.New + [char]0)
            }
            if ($txt -cne $before) {
                [IO.File]::WriteAllBytes($dmx.FullName, $enc.GetBytes($txt))
                $patched++
            }
        }
        if ($patched) { $log += "patched $patched DMX file(s) to match" }
        else { $log += "WARNING: no DMX patched - mesh binding may be broken" }

        # Attachments, hitboxes, physics shapes and the Feet node all reference
        # skeleton bones BY NAME through their own fields. Renaming only the
        # Bone nodes leaves those pointing at names that no longer exist, which
        # silently breaks hit registration, collision and attachment points.
        # Only reference fields are touched - a physics shape's own 'name' may
        # legitimately be lowercase and must not be rewritten.
        $refFields = 'parent_bone|bone|bone_name|anklebone|toebone|start_bone|end_bone|attachment_bone'
        $refFix = 0
        for ($i = 0; $i -lt $L.Count; $i++) {
            $mm = [regex]::Match($L[$i], "^\s*($refFields) = `"([A-Za-z0-9_]+)`"")
            if (-not $mm.Success) { continue }
            $target = $mm.Groups[2].Value
            foreach ($pr in $pairs) {
                if ($pr.Old -ceq $target) {
                    $L[$i] = $L[$i].Replace('"' + $pr.Old + '"', '"' + $pr.New + '"')
                    $refFix++
                    break
                }
            }
        }
        if ($refFix) { $log += "repointed $refFix bone reference(s) in attachments/hitboxes/physics" }
    }
}

# --- 0b. correct Feet/Foot bone references -------------------------------------
# nozb1's models carry an AnimGraph1-era Feet node whose anklebone/toebone point
# at lowercase names (ankle_l) while the skeleton uses uppercase (ankle_L). AG2
# appears not to read this node - the working Miku has none - but a reference to
# a bone that does not exist is worth correcting while we are here.
# NOTE: PowerShell hashtables and -eq are case-INSENSITIVE by default, which is
# exactly the distinction that matters here. Use a list with -ccontains.
$skelNames = @()
for ($i = 1; $i -lt $L.Count; $i++) {
    if ($L[$i-1] -match '_class = "Bone"' -and $L[$i] -match 'name = "([A-Za-z0-9_]+)"') {
        $skelNames += $Matches[1]
    }
}
$footFix = 0
for ($i = 0; $i -lt $L.Count; $i++) {
    $m = [regex]::Match($L[$i], '(anklebone|toebone) = "([A-Za-z0-9_]+)"')
    if (-not $m.Success) { continue }
    $b = $m.Groups[2].Value
    if ($skelNames -ccontains $b) { continue }             # already resolves exactly
    $alt = ($skelNames | Where-Object { $_ -eq $b }) | Select-Object -First 1
    if ($alt -and $alt -cne $b) {
        $L[$i] = $L[$i].Replace('"' + $b + '"', '"' + $alt + '"')
        $footFix++
    }
}
if ($footFix) { $log += "corrected $footFix Feet bone reference(s)" }

# --- 1. drop the AnimGraph 1 binding ---
for ($i = $L.Count - 1; $i -ge 0; $i--) {
    if ($L[$i] -match 'anim_graph_name' -and $L[$i] -match 'vanmgrph') {
        $L.RemoveAt($i); $log += "removed anim_graph_name"
    }
}

# --- 2. drop AnimIncludeModel -> animset ---
for ($i = $L.Count - 1; $i -ge 0; $i--) {
    if ($L[$i] -match '_class = "AnimIncludeModel"') {
        $tail = [Math]::Min($i + 3, $L.Count - 1)
        if (($L[$i..$tail] -join "`n") -match 'animsets/') {
            $s = $i - 1
            while ($s -ge 0 -and $L[$s].Trim() -ne '{') { $s-- }
            $d = 0; $e = $s
            while ($e -lt $L.Count) {
                $d += ([regex]::Matches($L[$e], '\{')).Count
                $d -= ([regex]::Matches($L[$e], '\}')).Count
                if ($d -eq 0) { break }
                $e++
            }
            $L.RemoveRange($s, $e - $s + 1); $log += "removed AnimIncludeModel"
        }
    }
}

# --- 3+4. insert the AG2 node lists before the Skeleton node ---
# A model may already carry these - a partially-ported model, or one
# recompiled from post-AG2 sources. Inserting a second set duplicates the
# references and the compile output is wrong. Check first.
if ($hasAG2) {
    $log += "AnimGraph2List already present - not inserting a second one"
} else {
    $sk = -1
    for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match '_class = "Skeleton"') { $sk = $i; break } }
    if ($sk -lt 0) { Write-Error "no Skeleton node"; exit 1 }
    $open = $sk - 1
    while ($open -ge 0 -and $L[$open].Trim() -ne '{') { $open-- }
    $ind = $L[$open] -replace '\{.*$', ''

    $graphs = @(
      @('DefaultAnimGraph2', $null,         'animation/graphs/worldmodel/worldmodel.vnmgraph'),
      @('AnimGraph2',        'uimodel',     'animation/graphs/ui/uimodel.vnmgraph'),
      @('AnimGraph2',        'hudmodel',    'animation/graphs/viewmodel/viewmodel.vnmgraph'),
      @('AnimGraph2',        'worldmodel',  'animation/graphs/worldmodel/worldmodel.vnmgraph')
    )
    $blk = @("$ind{", "$ind`t_class = `"NmSkeletonList`"", "$ind`tchildren = ", "$ind`t[")
    foreach ($s in @('worldmodel','viewmodel')) {
        $blk += @("$ind`t`t{", "$ind`t`t`t_class = `"NmSkeletonReference`"",
                  "$ind`t`t`tfilename = `"animation/skeletons/characters/$s.vnmskel`"", "$ind`t`t},")
    }
    $blk += @("$ind`t]", "$ind},", "$ind{", "$ind`t_class = `"AnimGraph2List`"", "$ind`tchildren = ", "$ind`t[")
    foreach ($g in $graphs) {
        $blk += "$ind`t`t{"
        $blk += "$ind`t`t`t_class = `"$($g[0])`""
        if ($g[1]) { $blk += "$ind`t`t`tname = `"$($g[1])`"" }
        $blk += "$ind`t`t`tfilename = `"$($g[2])`""
        $blk += "$ind`t`t},"
    }
    $blk += @("$ind`t]", "$ind},")
    $L.InsertRange($open, $blk); $log += "inserted NmSkeletonList + AnimGraph2List"
}

# --- 5. graft wpnPivot -> wpn under root_motion ---
# Rest transforms taken from CS2's canonical skeleton (worldmodel.vnmskel,
# m_parentSpaceReferencePose): wpnPivot is [-3.4717, 0, 58.7817] in skeleton
# space = [0, 58.7817, -3.4717] under ModelDoc's axis order, which is exactly
# what B_CANSIN used on the model confirmed to animate. wpn negates it, so the
# pair nets to the root position while leaving the pivot at the canonical
# weapon anchor height. MEASURED from both sources, not guessed.
$rm = -1
for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match 'name = "root_motion"') { $rm = $i; break } }
if (($L -join "`n") -match 'name = "wpnPivot"') {
    # already grafted - a second pass would add a duplicate pair
    $log += "wpnPivot already present - skipped"
} elseif ($rm -lt 0) {
    Write-Warning "no root_motion bone - wpnPivot NOT added"
} else {
    # 'children =' belonging to root_motion sits at the SAME indent as its
    # 'name =' line. Array formatting varies between VRF builds (inline vs
    # expanded), so match on indent rather than a fixed lookahead window.
    $rmInd = $L[$rm] -replace 'name.*$', ''
    $kids = -1
    for ($i = $rm + 1; $i -lt $L.Count; $i++) {
        $t = $L[$i].Trim()
        if ($t -eq 'children =' -and ($L[$i] -replace 'children.*$', '') -eq $rmInd) { $kids = $i; break }
        if ($t -match '^_class = ' -and ($L[$i] -replace '_class.*$', '').Length -le $rmInd.Length) { break }
    }
    if ($kids -lt 0) {
        Write-Warning "root_motion has no children array - wpnPivot NOT added"
    } else {
        $b = $kids + 1
        $bi = ($L[$b] -replace '\[.*$', '') + "`t"
        $bone = @("$bi{", "$bi`t_class = `"Bone`"", "$bi`tname = `"wpnPivot`"",
                  "$bi`torigin = [ 0.0, 58.781631, -3.471687 ]", "$bi`tangles = [ 0.0, 0.0, 0.0 ]",
                  "$bi`tdo_not_discard = true", "$bi`tchildren = ", "$bi`t[",
                  "$bi`t`t{", "$bi`t`t`t_class = `"Bone`"", "$bi`t`t`tname = `"wpn`"",
                  "$bi`t`t`torigin = [ 0.0, -58.781662, 3.471689 ]", "$bi`t`t`tangles = [ 0.0, 0.0, 0.0 ]",
                  "$bi`t`t`tdo_not_discard = true", "$bi`t`t},", "$bi`t]", "$bi},")
        $L.InsertRange($b + 1, $bone); $log += "grafted wpnPivot/wpn"
    }
}


# --- 6. repair BodyGroupChoice entries missing a name (VRF decompile artifact) ---
$fixed = 0
for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -notmatch '_class = "BodyGroupChoice"') { continue }
    $d = 0; $e = $i
    while ($e -lt $L.Count) {
        $d += ([regex]::Matches($L[$e], '\{')).Count
        $d -= ([regex]::Matches($L[$e], '\}')).Count
        if ($d -lt 0) { break }
        $e++
    }
    $seg = $L[$i..([Math]::Min($e, $L.Count-1))] -join "`n"
    if ($seg -match 'name = ') { continue }
    $mesh = if ($seg -match '"([^"]+)"\s*,') { $Matches[1] } else { "choice$fixed" }
    $ind = $L[$i] -replace '_class.*$', ''
    $L.Insert($i + 1, "$ind" + 'name = "' + $mesh + '"')
    $fixed++
}
if ($fixed) { $log += "named $fixed BodyGroupChoice entries" }


# --- 7. strip AnimGraph1-era nodes (default) --------------------------------
if (-not $KeepAG1Nodes) {
    $removed = 0
    foreach ($cls in @('MovementSettings', 'Feet')) {
        while ($true) {
            $hit = -1
            for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match "_class = `"$cls`"") { $hit = $i; break } }
            if ($hit -lt 0) { break }
            $b = Get-Block $L $hit
            $L.RemoveRange($b[0], $b[1] - $b[0] + 1)
            $removed++
        }
    }
    # character_arm_config is a GenericGameData node identified by game_class
    while ($true) {
        $hit = -1
        for ($i = 0; $i -lt $L.Count; $i++) {
            if ($L[$i] -match 'game_class = "character_arm_config"') { $hit = $i; break }
        }
        if ($hit -lt 0) { break }
        $b = Get-Block $L $hit
        $L.RemoveRange($b[0], $b[1] - $b[0] + 1)
        $removed++
    }
    if ($removed) { $log += "stripped $removed AnimGraph1-era node(s) to match Valve/Miku" }
}


# --- 8. add the physics body markup Valve and Miku both carry ----------------
# All three known-working AG2 models (Valve ctm_fbi, ctm_sas, and Miku) carry a
# CPhysicsBodyGameMarkupData node mapping 15 logical body names to physics
# bodies. nozb1's models have the same 15 physics shapes but no markup node.
# The names are lowercase even on models whose skeletons are uppercase - that
# is how Valve ships it and how Miku works, so they are copied verbatim.
# Likely governs ragdoll and hit reactions rather than animation, but it costs
# nothing and removes one more difference from the reference.
if (-not $KeepAG1Nodes -and ($L -join "`n") -notmatch 'CPhysicsBodyGameMarkupData') {
    $gd = -1
    for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match '_class = "GameDataList"') { $gd = $i; break } }
    if ($gd -lt 0) {
        $log += "no GameDataList node - physics markup skipped (harmless, affects ragdoll only)"
    } else {
        $k = -1
        for ($i = $gd + 1; $i -lt [Math]::Min($gd + 6, $L.Count); $i++) {
            if ($L[$i].Trim() -eq 'children =') { $k = $i; break }
        }
        if ($k -ge 0) {
            $ind = ($L[$k] -replace 'children.*$', '') + "`t"
            $bodies = @('hand_l','ankle_r','ankle_l','hand_r','arm_upper_r','arm_lower_r',
                        'arm_lower_l','leg_lower_r','arm_upper_l','head_0','leg_upper_L',
                        'leg_lower_l','leg_upper_r','spine_2','pelvis')
            $blk = @("$ind{", "$ind`t_class = `"GenericGameData`"", "$ind`tname = `"`"",
                     "$ind`tgame_class = `"CPhysicsBodyGameMarkupData`"", "$ind`tgame_keys = ",
                     "$ind`t{", "$ind`t`tm_PhysicsBodyMarkupByBoneName = ", "$ind`t`t{")
            foreach ($b in $bodies) {
                $blk += @("$ind`t`t`t$b = ", "$ind`t`t`t{",
                          "$ind`t`t`t`tm_TargetBody = `"$b`"", "$ind`t`t`t`tm_Tag = `"`"", "$ind`t`t`t}")
            }
            $blk += @("$ind`t`t}", "$ind`t}", "$ind},")
            $L.InsertRange($k + 2, $blk)
            $log += "added CPhysicsBodyGameMarkupData ($($bodies.Count) bodies)"
        }
    }
}

# --- verify braces before writing ---
$txt = $L -join "`n"
$o = ([regex]::Matches($txt, '\{')).Count; $c = ([regex]::Matches($txt, '\}')).Count
$so = ([regex]::Matches($txt, '\[')).Count; $sc = ([regex]::Matches($txt, '\]')).Count
if ($o -ne $c -or $so -ne $sc) { Write-Error "BRACE MISMATCH {$o/$c} [$so/$sc] - not written"; exit 1 }

Copy-Item -LiteralPath $Path "$Path.bak" -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $Path -Value $txt -NoNewline -Encoding utf8
$log | ForEach-Object { Write-Host "  $_" }
Write-Host "`nOK - $Path  ($($L.Count) lines, braces balanced, backup at $Path.bak)"
