#!/bin/bash
# Local test harness for the install-mods.sh embedded in ../mods-configmap.yaml.
# Runs on Git Bash (Windows) or any Linux with bash, unzip, sha256sum, awk, curl, python3/python.
# No cluster, no network: every "download" is a file:// URL to a zip built here.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CM="$HERE/../mods-configmap.yaml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- extract the script: everything after the "  install-mods.sh: |" line, de-indented by 4.
# The key is deliberately the LAST key in the ConfigMap so this needs no end marker.
# Strip \r first: git's core.autocrlf=true can check this file out with CRLF line endings, and
# without stripping, the de-indented script would carry a trailing \r on every line -- which
# still "runs" under bash but corrupts anything that does an exact string/regex match ($-anchors).
tr -d '\r' < "$CM" | awk '/^  install-mods\.sh: \|$/{f=1; next} f{sub(/^    /, ""); print}' > "$WORK/install-mods.sh"
[ -s "$WORK/install-mods.sh" ] || { echo "FAIL: could not extract install-mods.sh from $CM"; exit 1; }

# python3 on some machines is a stub that fails (e.g. the Microsoft Store shim on Windows) --
# probe by actually running it rather than trusting `command -v`.
PY=""
for c in python3 python; do
  "$c" -c 1 >/dev/null 2>&1 && PY=$c && break
done
[ -n "$PY" ] || { echo "FAIL: no working python"; exit 1; }

# curl on Windows needs file:///C:/... ; on Linux file:///path works.
url_for() { if command -v cygpath >/dev/null 2>&1; then echo "file:///$(cygpath -m "$1")"; else echo "file://$1"; fi; }

# install-mods.sh's set_cfg uses awk to rewrite BepInEx-style .cfg files IN PLACE, and is
# deliberately \r-preserving (BepInEx-bound mods keep whatever line ending they were written
# with). On Linux (the real deployment target: an initContainer in the game's container image)
# that "just works" -- awk there does no line-ending translation. MSYS2's gawk build on THIS
# machine does: by default it opens files in Windows text mode and silently strips \r on read,
# so every CRLF the script is supposed to preserve comes out as bare LF -- purely a property of
# this dev machine's awk, not a bug in the script (verified: gawk -v BINMODE=3 on the same input
# preserves the \r). Rather than edit the script to hardcode a Windows-only flag it will never
# need on the real target, shadow `awk` for the duration of the script run only, with a wrapper
# that adds -v BINMODE=3. This never touches install-mods.sh itself.
REAL_AWK=$(command -v awk)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/awk" <<EOF
#!/bin/bash
exec "$REAL_AWK" -v BINMODE=3 "\$@"
EOF
chmod +x "$WORK/bin/awk"

# make_zip <out.zip> <srcdir>  -- zips the CONTENTS of srcdir (paths relative to it)
make_zip() { (cd "$2" && "$PY" -c "
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for root, dirs, files in os.walk('.'):
        for d in dirs:  z.write(os.path.join(root, d))
        for f in files: z.write(os.path.join(root, f))
" "$1"); }

sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- fixtures ---------------------------------------------------------------------------
FX="$WORK/fx"; mkdir -p "$FX"
# pack: BepInExPack_Valheim/{BepInEx/core/BepInEx.dll, BepInEx/config/BepInEx.cfg, doorstop_libs/x.so}
mkdir -p "$FX/pack/BepInExPack_Valheim/BepInEx/core" "$FX/pack/BepInExPack_Valheim/BepInEx/config" "$FX/pack/BepInExPack_Valheim/doorstop_libs"
echo core   > "$FX/pack/BepInExPack_Valheim/BepInEx/core/BepInEx.dll"
echo cfg    > "$FX/pack/BepInExPack_Valheim/BepInEx/config/BepInEx.cfg"
echo so     > "$FX/pack/BepInExPack_Valheim/doorstop_libs/libdoorstop_x64.so"
make_zip "$FX/pack.zip" "$FX/pack"
# plugins layout: plugins/Jotunn.dll
mkdir -p "$FX/jot/plugins"; echo jot > "$FX/jot/plugins/Jotunn.dll"; make_zip "$FX/jot.zip" "$FX/jot"
# bepinex layout: BepInEx/plugins/ValheimPlus.dll
mkdir -p "$FX/vp/BepInEx/plugins"; echo vp > "$FX/vp/BepInEx/plugins/ValheimPlus.dll"; make_zip "$FX/vp.zip" "$FX/vp"

PACK_URL=$(url_for "$FX/pack.zip"); JOT_URL=$(url_for "$FX/jot.zip"); VP_URL=$(url_for "$FX/vp.zip")
PACK_SHA=$(sha "$FX/pack.zip");    JOT_SHA=$(sha "$FX/jot.zip");    VP_SHA=$(sha "$FX/vp.zip")

MODS_OK="# comment line
BepInExPack_Valheim 5.4.2350 $PACK_URL $PACK_SHA pack
Jotunn              2.30.0   $JOT_URL  $JOT_SHA  plugins
ValheimPlus         10.0.2   $VP_URL   $VP_SHA   bepinex"

# --- runner -----------------------------------------------------------------------------
# run <root> <expected-exit> [ENV=VAL ...]  -- runs the script, captures output to $OUT
run() {
  local root=$1 want=$2; shift 2
  mkdir -p "$root/tmp"
  set +e
  env "$@" SERVER="$root/valheim" SAVES="$root/saves" TMP="$root/tmp" PATH="$WORK/bin:$PATH" bash "$WORK/install-mods.sh" > "$root/out.log" 2>&1
  local got=$?
  set -e
  OUT=$(cat "$root/out.log")
  if [ "$got" != "$want" ]; then echo "FAIL: expected exit $want, got $got"; echo "$OUT"; exit 1; fi
}
pass=0
ok() { echo "  ok  $1"; pass=$((pass+1)); }
assert_file()    { [ -f "$1" ] || { echo "FAIL: missing file $1"; echo "$OUT"; exit 1; }; }
assert_nofile()  { [ ! -e "$1" ] || { echo "FAIL: unexpected path $1"; echo "$OUT"; exit 1; }; }
# assert_file checks a REGULAR file (-f); StaleA/B/C below are prune-candidate DIRECTORIES
# (mkdir -p), so proving one survived a refused prune needs -d, not -f.
assert_dir()     { [ -d "$1" ] || { echo "FAIL: missing dir $1"; echo "$OUT"; exit 1; }; }
assert_count()   { local n; n=$(grep -c -- "$1" <<< "$OUT" || true); [ "$n" = "$2" ] || { echo "FAIL: expected $2 x '$1', got $n"; echo "$OUT"; exit 1; }; }
assert_grep()    { grep -q -- "$1" "$2" || { echo "FAIL: '$1' not in $2"; cat "$2"; exit 1; }; }
# MSYS grep opens files in Windows text mode and silently strips \r on read -- verified:
# `grep -c $'\r' <file>` reports 0 matches against a file `od -c` proves contains \r\n
# throughout. So a \r-anchored grep pattern can never match here, independent of whether the
# script actually preserved the \r. awk -v BINMODE=3 does not have this problem (same fix used
# to run install-mods.sh itself, see REAL_AWK above), so a CRLF-terminated line is asserted by
# exact-matching $0 against BINMODE=3 awk, not by grep.
assert_cr_line() { local want=$1 file=$2; awk -v BINMODE=3 -v w="$want"$'\r' '$0==w{f=1} END{exit !f}' "$file" || { echo "FAIL: CRLF line '$want' (with trailing CR) not in $file"; cat -A "$file"; exit 1; }; }

# ========================================================================================
echo "test: first install lays down pack, plugins, marker, version file, adminlist"
R="$WORK/t1"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS="76561197963378853 76561198000000001"
assert_file "$R/valheim/BepInEx/core/BepInEx.dll"
assert_file "$R/valheim/doorstop_libs/libdoorstop_x64.so"
assert_file "$R/valheim/.bepinex_version"
[ "$(cat "$R/valheim/.bepinex_version")" = "5.4.2350" ] || { echo "FAIL: .bepinex_version content"; exit 1; }
assert_file "$R/valheim/BepInEx/plugins/Jotunn/Jotunn.dll"
assert_file "$R/valheim/BepInEx/plugins/ValheimPlus/ValheimPlus.dll"
assert_file "$R/valheim/.mod-state/BepInExPack_Valheim"
[ "$(cat "$R/valheim/.mod-state/Jotunn")" = "2.30.0 $JOT_SHA" ] || { echo "FAIL: marker content"; exit 1; }
assert_count "^\[ok   \]" 3
assert_count "^\[fetch\]" 3
assert_file "$R/saves/adminlist.txt"
[ "$(sed -n 1p "$R/saves/adminlist.txt")" = "// List admin players ID  ONE per line" ] || { echo "FAIL: adminlist header"; cat "$R/saves/adminlist.txt"; exit 1; }
[ "$(sed -n 2p "$R/saves/adminlist.txt")" = "76561197963378853" ] || { echo "FAIL: adminlist line 2"; exit 1; }
[ "$(wc -l < "$R/saves/adminlist.txt" | tr -d ' ')" = "3" ] || { echo "FAIL: adminlist line count"; exit 1; }
# Zips are named "$TMP/<name>.zip" (not "pack.zip") and are removed after a successful install.
assert_nofile "$R/tmp/BepInExPack_Valheim.zip"
assert_nofile "$R/tmp/Jotunn.zip"
assert_nofile "$R/tmp/ValheimPlus.zip"
ok "first install"

echo "test: second run skips everything and fetches nothing"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS="76561197963378853"
assert_count "^\[skip \]" 3
assert_count "^\[fetch\]" 0
ok "idempotent"

echo "test: checksum mismatch refuses to install and leaves nothing behind"
R="$WORK/t3"
BAD="BepInExPack_Valheim 5.4.2350 $PACK_URL 0000000000000000000000000000000000000000000000000000000000000000 pack"
run "$R" 1 MODS="$BAD" MOD_CONFIG="" ADMINLIST_IDS=""
assert_count "checksum mismatch" 1
assert_nofile "$R/valheim/BepInEx/core/BepInEx.dll"
assert_nofile "$R/valheim/.mod-state/BepInExPack_Valheim"
ok "checksum"

echo "test: version bump reinstalls just that mod (marker changes, others skip)"
R="$WORK/t4"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
mkdir -p "$FX/jot2/plugins"; echo jot2 > "$FX/jot2/plugins/Jotunn.dll"; make_zip "$FX/jot2.zip" "$FX/jot2"
MODS_BUMP="BepInExPack_Valheim 5.4.2350 $PACK_URL $PACK_SHA pack
Jotunn 2.31.0 $(url_for "$FX/jot2.zip") $(sha "$FX/jot2.zip") plugins
ValheimPlus 10.0.2 $VP_URL $VP_SHA bepinex"
run "$R" 0 MODS="$MODS_BUMP" MOD_CONFIG="" ADMINLIST_IDS=""
assert_count "^\[skip \]" 2
assert_count "^\[fetch\] Jotunn 2.31.0" 1
[ "$(cat "$R/valheim/BepInEx/plugins/Jotunn/Jotunn.dll")" = "jot2" ] || { echo "FAIL: upgraded dll not replaced"; exit 1; }
ok "upgrade"

echo "test: a mod removed from MODS is pruned, its marker dropped, pack files untouched"
R="$WORK/t5"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
MODS_NOVP="BepInExPack_Valheim 5.4.2350 $PACK_URL $PACK_SHA pack
Jotunn 2.30.0 $JOT_URL $JOT_SHA plugins"
run "$R" 0 MODS="$MODS_NOVP" MOD_CONFIG="" ADMINLIST_IDS=""
assert_nofile "$R/valheim/BepInEx/plugins/ValheimPlus"
assert_nofile "$R/valheim/.mod-state/ValheimPlus"
assert_file   "$R/valheim/BepInEx/plugins/Jotunn/Jotunn.dll"
assert_file   "$R/valheim/BepInEx/core/BepInEx.dll"
assert_file   "$R/valheim/BepInEx/config/BepInEx.cfg"
assert_count "^\[prune\] removing ValheimPlus" 1
ok "prune"

echo "test: a loose file in plugins/ (the image's MaxPlayerCount.dll) is never a prune candidate"
touch "$R/valheim/BepInEx/plugins/MaxPlayerCount.dll"
run "$R" 0 MODS="$MODS_NOVP" MOD_CONFIG="" ADMINLIST_IDS=""
assert_file "$R/valheim/BepInEx/plugins/MaxPlayerCount.dll"
assert_count "^\[prune\] removing" 0
ok "loose file ignored"

echo "test: bulk-prune breaker refuses 3 removals, PRUNE_ALLOW_BULK=yes lets them through"
R="$WORK/t7"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
mkdir -p "$R/valheim/BepInEx/plugins/StaleA" "$R/valheim/BepInEx/plugins/StaleB" "$R/valheim/BepInEx/plugins/StaleC"
run "$R" 1 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
assert_count "prune would remove 3 mods" 1
assert_dir "$R/valheim/BepInEx/plugins/StaleA"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS="" PRUNE_ALLOW_BULK=yes
assert_nofile "$R/valheim/BepInEx/plugins/StaleA"
assert_nofile "$R/valheim/BepInEx/plugins/StaleC"
ok "breaker"

echo "test: two removals pass the breaker without the override"
R="$WORK/t8"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
mkdir -p "$R/valheim/BepInEx/plugins/StaleA" "$R/valheim/BepInEx/plugins/StaleB"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
assert_nofile "$R/valheim/BepInEx/plugins/StaleB"
ok "breaker threshold"

echo "test: empty MODS is refused before anything is touched"
R="$WORK/t9"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
run "$R" 1 MODS="   " MOD_CONFIG="" ADMINLIST_IDS=""
assert_count "MODS parsed to an empty set" 1
assert_file "$R/valheim/BepInEx/plugins/Jotunn/Jotunn.dll"
ok "empty MODS"

echo "test: unknown layout fails"
R="$WORK/t10"
run "$R" 1 MODS="Jotunn 2.30.0 $JOT_URL $JOT_SHA sideways" MOD_CONFIG="" ADMINLIST_IDS=""
assert_count "unknown layout" 1
ok "layout"

echo "test: config applier replaces in place on a CRLF file, preserves separator style, keeps section count"
R="$WORK/t11"; run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
printf '[ValheimPlus]\r\nenabled=true\r\n\r\n[Fermenter]\r\nenabled=false\r\nshowDuration=false\r\n\r\n[Map]\r\nenabled=false\r\n' > "$R/valheim/BepInEx/config/valheim_plus.cfg"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="valheim_plus.cfg|Fermenter|enabled|true
# a comment
valheim_plus.cfg|Fermenter|newKey|1" ADMINLIST_IDS=""
F="$R/valheim/BepInEx/config/valheim_plus.cfg"
[ "$(grep -c '^\[' "$F")" = "3" ] || { echo "FAIL: section count changed"; cat -A "$F"; exit 1; }
[ "$(grep -c 'enabled=' "$F")" = "3" ] || { echo "FAIL: enabled= count changed"; cat -A "$F"; exit 1; }
assert_cr_line "enabled=true" "$F"
assert_cr_line "enabled=false" "$F"               # [Map] untouched
assert_grep $'^newKey=1' "$F"                     # appended inside [Fermenter], not at EOF
[ "$(awk '/^\[Fermenter\]/{f=1;next} /^\[/{f=0} f && /^newKey=/{print "in"}' "$F")" = "in" ] || { echo "FAIL: newKey landed outside [Fermenter]"; cat -A "$F"; exit 1; }
# [ValheimPlus] also has enabled=true (pre-existing), so the assert_cr_line check above is not
# scoped to [Fermenter] -- prove the [Fermenter] enabled=true specifically is the one that was
# rewritten inside that section, not a match against the unrelated [ValheimPlus] line.
[ "$(awk '/^\[Fermenter\]/{f=1;next} /^\[/{f=0} f && /^enabled=true/{print "in"}' "$F")" = "in" ] || { echo "FAIL: [Fermenter] enabled=true not inside [Fermenter]"; cat -A "$F"; exit 1; }
assert_count "^\[cfg  \]" 2
ok "config applier"

echo "test: config applier creates a missing file with BepInEx spacing"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="some.mod.cfg|1 - General|LogLevel|Debug" ADMINLIST_IDS=""
assert_grep '^LogLevel = Debug$' "$R/valheim/BepInEx/config/some.mod.cfg"
assert_grep '^\[1 - General\]$' "$R/valheim/BepInEx/config/some.mod.cfg"
ok "config create"

echo "test: empty ADMINLIST_IDS writes the header only"
run "$R" 0 MODS="$MODS_OK" MOD_CONFIG="" ADMINLIST_IDS=""
[ "$(wc -l < "$R/saves/adminlist.txt" | tr -d ' ')" = "1" ] || { echo "FAIL: adminlist should be header only"; cat "$R/saves/adminlist.txt"; exit 1; }
ok "adminlist empty"

echo "ALL PASSED ($pass tests)"
