#!/usr/bin/env bash
# CS2-AG2-Model-Porter — interactive launcher for Linux.
#
#   ./start.sh
#
# Everything ag2port.py does can also be driven with flags; see README.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/ag2port.py"
CFG="$HOME/.config/ag2port/settings.json"
C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[90m'; C_X=$'\033[0m'

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
[ -f "$PY" ] || { echo "ag2port.py not found next to this script"; exit 1; }
chmod +x "$PY" 2>/dev/null

banner() {
  clear
  echo
  local art=(
    '  ___  ___ ___    _   ___ ___   ___  ___  ___ _____ '
    ' / __|/ __|_  )  /_\ / __|_  ) | _ \/ _ \| _ \_   _|'
    '| (__ \__ \/ /  / _ \ (_ |/ /  |  _/ (_) |   / | |  '
    ' \___||___/___|/_/ \_\___/___| |_|  \___/|_|_\ |_|  '
  )
  for l in "${art[@]}"; do printf '  %s%s%s\n' "$C_B" "$l" "$C_X"; sleep 0.045; done
  echo
  local tag='  make pre-AnimGraph2 player models animate again'
  for ((i=0; i<${#tag}; i++)); do printf '%s%s%s' "$C_D" "${tag:$i:1}" "$C_X"; sleep 0.006; done
  echo; echo
}

head() { echo; printf '%s%s%s\n' "$C_B" "============================================================" "$C_X"
         printf '%s  %s%s\n' "$C_B" "$1" "$C_X"
         printf '%s%s%s\n' "$C_B" "============================================================" "$C_X"; }

cfg_get() { python3 -c "
import json,sys
try: print(json.load(open('$CFG')).get('$1',''))
except Exception: print('')
" 2>/dev/null; }

cfg_set() { python3 -c "
import json,os,sys
p='$CFG'; os.makedirs(os.path.dirname(p),exist_ok=True)
try: d=json.load(open(p))
except Exception: d={}
d['$1']='$2'; json.dump(d,open(p,'w'),indent=2)
" 2>/dev/null; }

banner
cat <<'EOF'
Repairs CS2 player models broken by the AnimGraph2 update, so they animate
again instead of T-posing.

On Linux everything runs natively except the final compile - resourcecompiler
is a Windows binary with no Linux build, so that step goes through Wine or
Proton. You will need CS2 with the Workshop Tools DLC, and one of those.
EOF

# ---------------------------------------------------------------- CS2
head "1. Locate CS2"
CS2="$(cfg_get cs2)"
if [ -z "$CS2" ] || [ ! -f "$CS2/game/csgo/gameinfo.gi" ]; then
  CS2="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('a', '$PY')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.find_cs2() or '')
" 2>/dev/null)"
fi
if [ -n "$CS2" ] && [ -f "$CS2/game/csgo/gameinfo.gi" ]; then
  printf '  %sfound: %s%s\n' "$C_G" "$CS2" "$C_X"
else
  printf '  %scould not find CS2 automatically.%s\n' "$C_Y" "$C_X"
  while :; do
    read -rp "  Full path to your Counter-Strike Global Offensive folder: " CS2
    CS2="${CS2/#\~/$HOME}"
    [ -f "$CS2/game/csgo/gameinfo.gi" ] && break
    printf '  %sthat does not look like a CS2 install (no game/csgo/gameinfo.gi)%s\n' "$C_R" "$C_X"
  done
fi
cfg_set cs2 "$CS2"

if [ -f "$CS2/game/bin/win64/resourcecompiler.exe" ]; then
  printf '  %sWorkshop Tools: present%s\n' "$C_G" "$C_X"
else
  printf '\n  %sWORKSHOP TOOLS DLC NOT INSTALLED%s\n' "$C_R" "$C_X"
  printf '  %s1. Steam Library, right-click Counter-Strike 2, Properties%s\n' "$C_Y" "$C_X"
  printf '  %s2. DLC tab%s\n' "$C_Y" "$C_X"
  printf '  %s3. Tick "Counter-Strike 2 Workshop Tools" (~10 GB)%s\n' "$C_Y" "$C_X"
  printf '  %s4. Wait for the download, then re-run this%s\n\n' "$C_Y" "$C_X"
  exit 1
fi

if command -v wine >/dev/null 2>&1; then
  printf '  %swine: %s%s\n' "$C_G" "$(command -v wine)" "$C_X"
elif ls "$HOME"/.steam/steam/steamapps/common/Proton* >/dev/null 2>&1 \
  || ls "$HOME"/.local/share/Steam/steamapps/common/Proton* >/dev/null 2>&1; then
  printf '  %sProton found (will be used for the compile step)%s\n' "$C_G" "$C_X"
else
  printf '\n  %sNo wine or Proton found.%s\n' "$C_R" "$C_X"
  printf '  %sresourcecompiler.exe is a Windows binary and needs one of them.%s\n' "$C_Y" "$C_X"
  printf '  %s  Debian/Ubuntu:  sudo apt install wine%s\n' "$C_Y" "$C_X"
  printf '  %s  Fedora:         sudo dnf install wine%s\n' "$C_Y" "$C_X"
  printf '  %s  Arch:           sudo pacman -S wine%s\n' "$C_Y" "$C_X"
  printf '  %sOr install CS2 through Steam Play, which brings Proton.%s\n\n' "$C_Y" "$C_X"
  read -rp "  Continue anyway? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || exit 1
fi

# ---------------------------------------------------------------- source
head "2. Where are the models?"
cat <<EOF
  1  A Workshop pack I'm subscribed to        (most common)
  2  A .vpk file on disk                      (delisted pack, backup, download)
  3  A folder of loose model files            (.vmdl_c from anywhere)
EOF
DEF_MODE="$(cfg_get srcmode)"; DEF_MODE="${DEF_MODE:-1}"
read -rp "  Choice [$DEF_MODE]: " MODE; MODE="${MODE:-$DEF_MODE}"
cfg_set srcmode "$MODE"

SRC_ARGS=()
case "$MODE" in
  2)
    while :; do
      DEF="$(cfg_get vpk)"
      read -rp "  Path to .vpk${DEF:+ [$DEF]}: " V; V="${V:-$DEF}"; V="${V/#\~/$HOME}"
      [ -f "$V" ] && break
      printf '  %snot found%s\n' "$C_R" "$C_X"
    done
    cfg_set vpk "$V"
    printf '  %sfound: %s MB%s\n' "$C_G" "$(( $(stat -c%s "$V") / 1048576 ))" "$C_X"
    SRC_ARGS=(--vpk "$V")
    ;;
  3)
    cat <<'EOF'

  I need the compiled model files, the same shape they come out of a VPK:

      <any folder>/
        somemodel_player_model/
          somemodel_player_model.vmdl_c        <- required
          materials/
            whatever.vmat_c                    <- strongly recommended
            whatever.vtex_c                    <- strongly recommended

  Only the .vmdl_c is strictly required - each model records its own intended
  path internally, so the folder name does not matter. Without the materials
  the model compiles but comes out untextured. Subfolders are searched.
EOF
    while :; do
      DEF="$(cfg_get src)"
      read -rp "  Folder containing the models${DEF:+ [$DEF]}: " S; S="${S:-$DEF}"; S="${S/#\~/$HOME}"
      if [ ! -d "$S" ]; then printf '  %snot found%s\n' "$C_R" "$C_X"; continue; fi
      N=$(find "$S" -name '*.vmdl_c' 2>/dev/null | wc -l)
      if [ "$N" -eq 0 ]; then printf '  %sno .vmdl_c files under that folder%s\n' "$C_R" "$C_X"; continue; fi
      printf '  %sfound %s .vmdl_c file(s)%s\n' "$C_G" "$N" "$C_X"; break
    done
    cfg_set src "$S"
    SRC_ARGS=(--source "$S")
    ;;
  *)
    cat <<'EOF'

  Open the pack's Steam Workshop page. The id is the number at the end:
      steamcommunity.com/sharedfiles/filedetails/?id=1234567890
                                                     ^^^^^^^^^^
  You must be subscribed, and have launched CS2 once since subscribing.
  (If the item was removed from the Workshop, use option 2 or 3 instead.)
EOF
    DEF="$(cfg_get pack)"
    read -rp "  Workshop id${DEF:+ [$DEF]}: " P; P="${P:-$DEF}"
    cfg_set pack "$P"
    SRC_ARGS=(--pack "$P")
    ;;
esac

# ---------------------------------------------------------------- addon
head "3. Addon name"
cat <<'EOF'
  Your ported models go into a CS2 addon, which you later publish to the
  Workshop as your own item. Lowercase, no spaces.
EOF
DEF="$(cfg_get addon)"; DEF="${DEF:-ag2port}"
read -rp "  Addon name [$DEF]: " ADDON; ADDON="${ADDON:-$DEF}"
cfg_set addon "$ADDON"

COMMON=(--cs2 "$CS2" --addon "$ADDON")

# ---------------------------------------------------------------- menu
while :; do
  head "What would you like to do?"
  cat <<'EOF'
   1  Set up          (one-time: gameinfo.gi, Source2Viewer, addon folders)
   2  List models     (see what is in the pack)
   3  Port ONE model
   4  Port ALL models
   5  Verify          (check compiled models before publishing)
   6  Clean up        (remove everything this tool added)
   7  What next?      (publishing and server setup)
   8  About
   Q  Quit
EOF
  read -rp "  Choice: " c
  case "${c^^}" in
    1) python3 "$PY" "${COMMON[@]}" setup ;;
    2) python3 "$PY" "${COMMON[@]}" list "${SRC_ARGS[@]}" ;;
    3) read -rp "  Model name (as shown by option 2): " m
       python3 "$PY" "${COMMON[@]}" port "${SRC_ARGS[@]}" --model "$m" ;;
    4) printf '  %sThis can take several minutes.%s\n' "$C_Y" "$C_X"
       read -rp "  Port every model in the pack? [Y/n] " a
       [[ "$a" =~ ^[Nn] ]] || python3 "$PY" "${COMMON[@]}" port "${SRC_ARGS[@]}" --all ;;
    5) python3 "$PY" "${COMMON[@]}" verify --all ;;
    6) python3 "$PY" "${COMMON[@]}" clean
       read -rp "  Actually delete the paths listed above? [y/N] " a
       [[ "$a" =~ ^[Yy] ]] && python3 "$PY" "${COMMON[@]}" clean --remove ;;
    7) head "Publishing and server setup"
       cat <<EOF
  PUBLISH
    This part needs Windows or a working Wine desktop - the CS2 Workshop
    Manager is a GUI tool with no command-line equivalent.

    If you have a Windows machine, copy the addon folder over:
        $CS2/content/csgo_addons/$ADDON
        $CS2/game/csgo_addons/$ADDON
    into the same paths on that machine, then use the Workshop Tools there.

    New items are held for Steam moderation. Nothing - not even your own
    server - can download the item until it is approved, usually a few hours.
    "Unlisted" is fine; it stays out of search but works by id.

  SERVER
    Add your new workshop id to MultiAddonManager's mm_extra_addons, and
    remove the original pack's id so the broken originals cannot shadow
    yours. Your player-model plugin config does not change - the paths
    inside the VPK are the same.

    If your server copies configs from a template directory at boot, check
    the live copy actually changed. Boot-time copies often skip files that
    already exist.

  TEST
    Restart, then BEFORE joining confirm it mounted:
        docker logs <container> 2>&1 | grep -i "Mounting addon"
    'Addon download started' on repeat means the server cannot fetch it -
    still in moderation, or the wrong id. Pull it out before it loops.

    Launch CS2 from Steam normally, not through the Workshop Tools.

    Join, change map once so the addon reaches your client, then switch
    models.
EOF
       read -rp $'\n  Enter to continue' _ ;;
    8) banner
       cat <<'EOF'
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

  Built over one long night by a human doing all the testing and an AI doing
  all the reading, arguing until the models moved.

  MIT licensed. The scripts are free. The models aren't mine or yours - ask
  before you republish someone else's work.
EOF
       read -rp $'\n  Enter to continue' _ ;;
    Q) printf '\n  Settings saved to %s\n\n' "$CFG"; exit 0 ;;
    *) printf '  %s?%s\n' "$C_D" "$C_X" ;;
  esac
done
