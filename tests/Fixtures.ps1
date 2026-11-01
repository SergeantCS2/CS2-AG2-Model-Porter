# Synthetic ModelDoc sources for the test suite.
#
# Nothing here is a game asset. Every fixture is generated from the small
# specifications below, laid out the way Source2Viewer writes a decompiled
# .vmdl (tabs, "children =" with the "[" on the next line), so AG2-All.ps1 sees
# the same shapes it sees in a real run. The bone values are invented; only
# the structure matters.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function New-Bone([string]$Name, [double[]]$Origin = @(0,0,0), [double[]]$Angles = @(0,0,0), $Children = @()) {
    return @{ Name = $Name; Origin = $Origin; Angles = $Angles; Children = @($Children) }
}

function Format-Vec([double[]]$v) {
    $s = $v | ForEach-Object { $_.ToString("0.0#####", [Globalization.CultureInfo]::InvariantCulture) }
    return "[ " + ($s -join ", ") + " ]"
}

function Format-Bone($bone, [string]$ind) {
    $out = @("$ind{", "$ind`t_class = `"Bone`"", "$ind`tname = `"$($bone.Name)`"",
             "$ind`torigin = $(Format-Vec $bone.Origin)", "$ind`tangles = $(Format-Vec $bone.Angles)",
             "$ind`tdo_not_discard = true")
    if ($bone.Children.Count) {
        $out += @("$ind`tchildren = ", "$ind`t[")
        foreach ($c in $bone.Children) { $out += Format-Bone $c "$ind`t`t" }
        $out += "$ind`t]"
    }
    $out += "$ind},"
    return $out
}

# A humanoid on CS2's naming, the way the community packs this tool targets
# are rigged. $Side is "L"/"R" or "l"/"r" for the pre-convention variant.
function New-Body([string]$l = "L", [string]$r = "R", [double[]]$PelvisOrigin = @(0.458082, 0, 42.123554),
                  [double[]]$PelvisAngles = @(3.509018, -90, 0)) {
    $arm = {
        param($s)
        New-Bone "clavicle_$s" @(6,0,0) @(0,0,0) @(
            (New-Bone "arm_upper_$s" @(5,0,0) @(0,0,0) @(
                (New-Bone "arm_lower_$s" @(11,0,0) @(0,0,0) @(
                    (New-Bone "hand_$s" @(10,0,0) @(0,0,0) @(
                        (New-Bone "finger_index_meta_$s" @(1,0,0)),
                        (New-Bone "finger_index_0_$s" @(3,0,0)),
                        (New-Bone "weapon_hand_$($s.ToUpper())" @(0,0,0))
                    ))
                ))
            ))
        )
    }
    $leg = {
        param($s)
        New-Bone "leg_upper_$s" @(0,3.5,0) @(0,0,0) @(
            (New-Bone "leg_lower_$s" @(18,0,0) @(0,0,0) @(
                (New-Bone "ankle_$s" @(17,0,0) @(0,0,0) @(
                    (New-Bone "ball_$s" @(5,0,0))
                ))
            ))
        )
    }
    $spine3 = New-Bone "spine_3" @(5,0,0) @(0,0,0) @(
        (New-Bone "neck_0" @(4,0,0) @(0,0,0) @((New-Bone "head_0" @(4,0,0)))),
        (& $arm $l), (& $arm $r)
    )
    $spine = New-Bone "spine_0" @(3,0,0) @(0,0,0) @(
        (New-Bone "spine_1" @(4,0,0) @(0,0,0) @(
            (New-Bone "spine_2" @(4,0,0) @(0,0,0) @($spine3))
        ))
    )
    return New-Bone "pelvis" $PelvisOrigin $PelvisAngles @($spine, (& $leg $l), (& $leg $r))
}

# Assemble a full .vmdl. Options:
#   Roots         top-level bones of the Skeleton node
#   AG1           include anim_graph_name + the animset include (pre-AG2 model)
#   Lists         'none' | 'graph-only' | 'skeleton-only' | 'complete'
#   Side          'L' or 'l' - case used by physics/feet references
#   ExtraBodyGroup an extra BodyGroup name (non-ASCII test)
function New-FixtureVmdl {
    param([string]$Name, [object[]]$Roots, [switch]$AG1, [string]$Lists = 'none',
          [string]$Side = 'L', [string]$ExtraBodyGroup = '')
    $s = $Side; $sr = $(if ($Side -ceq 'L') { 'R' } else { 'r' })
    $T = "`t"
    $lines = New-Object System.Collections.Generic.List[string]
    $add = { param([string[]]$x) foreach ($y in $x) { $lines.Add($y) } }

    & $add '<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:modeldoc29:version{3cec427c-1b0e-4d48-a90a-0436f33a6041} -->'
    & $add @('{', ("$T" + 'rootNode = '), "$T{", ("$T$T" + '_class = "RootNode"'), ("$T$T" + 'children = '), "$T$T[")
    $i3 = "$T$T$T"; $i4 = "$i3$T"; $i5 = "$i4$T"; $i6 = "$i5$T"; $i7 = "$i6$T"; $i8 = "$i7$T"

    & $add @("$i3{", "${i4}_class = `"MaterialGroupList`"", ("$i4" + 'children = '), "$i4[",
             "$i5{", "${i6}_class = `"DefaultMaterialGroup`"", ("$i6" + 'remaps = '), "$i6[",
             "$i7{", ("$i8" + 'from = "body.vmat"'), ("$i8" + "to = `"characters/models/test/$Name/materials/body.vmat`""), "$i7},",
             "$i6]", ("$i6" + 'use_global_default = false'), ("$i6" + 'global_default_material = ""'), "$i5},",
             "$i4]", "$i3},")
    & $add @("$i3{", "${i4}_class = `"RenderMeshList`"", ("$i4" + 'children = '), "$i4[",
             "$i5{", "${i6}_class = `"RenderMeshFile`"", ("$i6" + "filename = `"characters/models/test/$Name/$($Name)_body.dmx`""),
             ("$i6" + 'import_translation = [ 0.0, 0.0, 0.0 ]'), ("$i6" + 'import_rotation = [ 0.0, 0.0, 0.0 ]'),
             ("$i6" + 'import_scale = 1.0'), ("$i6" + 'parent_bone = ""'),
             ("$i6" + 'import_filter = '), "$i6{", ("$i7" + 'exclude_by_default = false'), ("$i7" + 'exception_list = [  ]'), "$i6}",
             "$i5},", "$i4]", "$i3},")
    if ($AG1) {
        & $add @("$i3{", "${i4}_class = `"AnimationList`"", ("$i4" + 'children = '), "$i4[",
                 "$i5{", "${i6}_class = `"AnimIncludeModel`"", ("$i6" + 'model = "characters/models/shared/animsets/animset_ct.vmdl"'), "$i5},",
                 "$i4]", "$i3},")
    }
    if ($Lists -in 'skeleton-only', 'complete') {
        & $add @("$i3{", "${i4}_class = `"NmSkeletonList`"", ("$i4" + 'children = '), "$i4[")
        foreach ($k in 'worldmodel', 'viewmodel') {
            & $add @("$i5{", "${i6}_class = `"NmSkeletonReference`"", ("$i6" + "filename = `"animation/skeletons/characters/$k.vnmskel`""), "$i5},")
        }
        & $add @("$i4]", "$i3},")
    }
    if ($Lists -in 'graph-only', 'complete') {
        & $add @("$i3{", "${i4}_class = `"AnimGraph2List`"", ("$i4" + 'children = '), "$i4[",
                 "$i5{", "${i6}_class = `"DefaultAnimGraph2`"", ("$i6" + 'filename = "animation/graphs/worldmodel/worldmodel.vnmgraph"'), "$i5},")
        if ($Lists -eq 'complete') {
            foreach ($g in @(@('uimodel','ui/uimodel'), @('hudmodel','viewmodel/viewmodel'), @('worldmodel','worldmodel/worldmodel'))) {
                & $add @("$i5{", "${i6}_class = `"AnimGraph2`"", ("$i6" + "name = `"$($g[0])`""),
                         ("$i6" + "filename = `"animation/graphs/$($g[1]).vnmgraph`""), "$i5},")
            }
        }
        & $add @("$i4]", "$i3},")
    }
    & $add @("$i3{", "${i4}_class = `"Skeleton`"", ("$i4" + 'children = '), "$i4[")
    foreach ($r in $Roots) { & $add (Format-Bone $r $i5) }
    & $add @("$i4]", "$i3},")

    & $add @("$i3{", "${i4}_class = `"PhysicsShapeList`"", ("$i4" + 'children = '), "$i4[",
             "$i5{", "${i6}_class = `"PhysicsShapeCapsule`"", ("$i6" + "parent_bone = `"hand_$s`""),
             ("$i6" + 'surface_prop = "flesh"'), ("$i6" + 'radius = 2.0'), ("$i6" + "name = `"hand_$($s.ToLower())`""), "$i5},",
             "$i4]", "$i3},")
    & $add @("$i3{", "${i4}_class = `"AttachmentList`"", ("$i4" + 'children = '), "$i4[")
    foreach ($w in @(@('weapon_hand_r','weapon_hand_R'), @('weapon_hand_l','weapon_hand_L'))) {
        & $add @("$i5{", "${i6}_class = `"Attachment`"", ("$i6" + "name = `"$($w[0])`""), ("$i6" + "parent_bone = `"$($w[1])`""),
                 ("$i6" + 'relative_origin = [ 0.0, 0.0, 0.0 ]'), ("$i6" + 'relative_angles = [ 0.0, 0.0, 0.0 ]'),
                 ("$i6" + 'weight = 1.0'), ("$i6" + 'ignore_rotation = false'), "$i5},")
    }
    & $add @("$i4]", "$i3},")
    if ($AG1) {
        & $add @("$i3{", "${i4}_class = `"MovementSettings`"", ("$i4" + 'max_speed = 250.0'), "$i3},")
        & $add @("$i3{", "${i4}_class = `"Feet`"", ("$i4" + 'children = '), "$i4[",
                 "$i5{", "${i6}_class = `"Foot`"", ("$i6" + 'name = "left"'), ("$i6" + "anklebone = `"ankle_$($s.ToLower())`""),
                 ("$i6" + "toebone = `"ball_$($s.ToLower())`""), "$i5},", "$i4]", "$i3},")
    }
    & $add @("$i3{", "${i4}_class = `"GameDataList`"", ("$i4" + 'children = '), "$i4[")
    if ($AG1) {
        & $add @("$i5{", "${i6}_class = `"GenericGameData`"", ("$i6" + 'game_class = "character_arm_config"'),
                 ("$i6" + 'game_keys = '), "$i6{", ("$i7" + "arm_model = `"characters/models/test/$Name/$($Name)_pm_arm.vmdl`""), "$i6}", "$i5},")
    }
    & $add @("$i4]", "$i3},")
    & $add @("$i3{", "${i4}_class = `"BodyGroupList`"", ("$i4" + 'children = '), "$i4[",
             "$i5{", "${i6}_class = `"BodyGroup`"", ("$i6" + 'name = "body"'), ("$i6" + 'children = '), "$i6[",
             "$i7{", "${i8}_class = `"BodyGroupChoice`"", ("$i8" + 'meshes = '), "$i8[", "$i8$T`"$($Name)_body`",", "$i8]", "$i7},",
             "$i6]", ("$i6" + 'hidden_in_tools = false'), "$i5},")
    if ($ExtraBodyGroup) {
        & $add @("$i5{", "${i6}_class = `"BodyGroup`"", ("$i6" + "name = `"$ExtraBodyGroup`""), ("$i6" + 'children = '), "$i6[",
                 "$i7{", "${i8}_class = `"BodyGroupChoice`"", ("$i8" + 'name = "on"'), ("$i8" + 'meshes = [  ]'), "$i7},",
                 "$i6]", "$i5},")
    }
    & $add @("$i4]", "$i3},")
    & $add @("$T$T]", ("$T$T" + 'model_archetype = ""'), ("$T$T" + 'primary_associated_entity = ""'))
    if ($AG1) { & $add ("$T$T" + 'anim_graph_name = "characters/models/shared/animgraphs/player_ct.vanmgrph"') }
    & $add @("$T$T" + 'base_model_name = ""', "$T}", '}')
    return ($lines -join "`n")
}

# A stand-in for a binary DMX: joint names as null-delimited strings, which is
# all the case-flip patch touches.
function New-FixtureDmx([string[]]$Joints) {
    $body = "<!-- dmx encoding binary 9 format model 22 -->`n" + [char]0 + ($Joints -join [char]0) + [char]0 + "tail" + [char]0
    return [System.Text.Encoding]::GetEncoding(28591).GetBytes($body)
}

function Get-Fixtures {
    # root_motion carries IK targets in the community packs this was built on
    $ik  = @((New-Bone 'ik_foot_L' @(0,0,0)), (New-Bone 'ik_foot_R' @(0,0,0)))
    $rm  = { param($a = @(0, 90, 90), $kids = $ik) New-Bone "root_motion" @(0,0,0) $a $kids }
    $f = [ordered]@{}

    # nozb1-style: pelvis and root_motion as independent roots, every AG1 node present
    $f['standard'] = @{ Text = (New-FixtureVmdl -Name 'standard' -AG1 -Roots @((New-Body), (& $rm))) }

    # pre-convention lowercase sides, with a DMX for this model and an
    # unrelated model's DMX in the same folder
    $f['lowercase'] = @{
        Text = (New-FixtureVmdl -Name 'lowercase' -AG1 -Side 'l' -Roots @((New-Body 'l' 'r'), (& $rm)))
        Dmx  = @{ 'lowercase_body.dmx' = @('pelvis','hand_l','hand_r','ankle_l','ball_l','finger_index_0_l');
                  'other_body.dmx'     = @('pelvis','hand_l','hand_r') }
    }

    # no root_motion at all, plus an extra custom root
    $f['no_root_motion'] = @{ Text = (New-FixtureVmdl -Name 'no_root_motion' -AG1 -Roots @((New-Body), (New-Bone 'lean_root' @(0,0,38) @(0,0,0)))) }

    # authored lying down along -X
    $f['x_up'] = @{ Text = (New-FixtureVmdl -Name 'x_up' -AG1 -Roots @((New-Body 'L' 'R' @(-42.0, 0.3, 0.5) @(0, 0, 0)), (& $rm))) }

    # pelvis already converted under root_motion, plus a stray helper root
    $f['parented_stray'] = @{ Text = (New-FixtureVmdl -Name 'parented_stray' -AG1 -Roots @(
        (& $rm @(0,90,90) @((New-Body 'L' 'R' @(0, 42.123554, 0.458082) @(0, 90, 86.490982)))),
        (New-Bone 'helper_root' @(1,2,3) @(0,0,0)))) }

    # root_motion at a non-canonical angle seen in the wild, plus a stray root
    $f['odd_root_motion'] = @{ Text = (New-FixtureVmdl -Name 'odd_root_motion' -AG1 -Roots @(
        (New-Body), (& $rm @(0, 90.4687, 90)), (New-Bone 'lean_root' @(0,0,38) @(0,0,0)))) }

    # half-ported: graph list with one entry, no skeleton list
    $f['graph_only'] = @{ Text = (New-FixtureVmdl -Name 'graph_only' -Lists 'graph-only' -Roots @((New-Body), (& $rm)))  }

    # half-ported the other way: skeleton list, no graph list
    $f['skeleton_only'] = @{ Text = (New-FixtureVmdl -Name 'skeleton_only' -Lists 'skeleton-only' -Roots @((New-Body), (& $rm))) }

    # non-ASCII text, as anime packs commonly carry in bodygroup names
    $f['unicode'] = @{ Text = (New-FixtureVmdl -Name 'unicode' -AG1 -ExtraBodyGroup ([string][char]0x30D5 + [char]0x30A3 + [char]0x30C3 + [char]0x30B7 + [char]0x30E5) -Roots @((New-Body), (& $rm))) }

    # root_motion present but empty - the re-parent has to give it a children array
    $f['leaf_root_motion'] = @{ Text = (New-FixtureVmdl -Name 'leaf_root_motion' -AG1 -Roots @((New-Body), (New-Bone 'root_motion' @(0,0,0) @(0,90,90)))) }

    # no root_motion, pelvis under a plain root bone, authored lying along +Y
    $f['y_up_under_root'] = @{ Text = (New-FixtureVmdl -Name 'y_up_under_root' -AG1 -Roots @(
        (New-Bone 'root' @(0,0,0) @(0,0,0) @((New-Body 'L' 'R' @(0.4, 42.0, 0.3) @(0, 0, 0)))))) }

    # not a player model
    $f['no_pelvis'] = @{ Text = (New-FixtureVmdl -Name 'no_pelvis' -AG1 -Roots @((New-Bone 'root' @(0,0,0) @(0,0,0) @((New-Bone 'prop_part' @(1,0,0)))))) }
    return $f
}

# Write a fixture to <dir>/characters/models/test/<name>/ the way an extract would.
function Write-Fixture([string]$Root, [string]$Name, $Fixture) {
    $dir = Join-Path $Root "characters/models/test/$Name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir "$Name.vmdl"
    [IO.File]::WriteAllText($path, $Fixture.Text, $script:Utf8NoBom)
    if ($Fixture.Dmx) {
        foreach ($k in $Fixture.Dmx.Keys) { [IO.File]::WriteAllBytes((Join-Path $dir $k), (New-FixtureDmx $Fixture.Dmx[$k])) }
    }
    return $path
}
