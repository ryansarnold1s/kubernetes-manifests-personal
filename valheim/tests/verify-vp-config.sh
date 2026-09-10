#!/bin/bash
# Reads every ValheimPlus pin in MOD_CONFIG back off the live pod and compares it to the file V+
# actually loaded. Run from the repo root after any MOD_CONFIG change + rollout restart:
#
#   bash valheim/tests/verify-vp-config.sh [path/to/mods-configmap.yaml]
#
# Exit 0: every pin matches and no section name appears twice.
# Exit 1: a mismatch, a missing key, a duplicated section, or no pins found at all.
# Exit 2: the ConfigMap or the live file could not be read.
#
# WHY THIS EXISTS: a value V+ rejects is replaced by its own default, correctly formatted, in the
# right section, so the file looks healthy either way. Whether V+ 10 logs "could not be parsed"
# for a rejected value is unverified, so reading every key back is the only proof a pin took.
#
# A DUPLICATED SECTION is the signature of an applier line that missed its section (a typo in the
# section name) and appended a new one at the end of the file. It is checked by name rather than
# by a hard-coded section count, which would break on the next V+ release.
#
# The optional argument exists so this can be tested against a deliberately wrong copy of the
# ConfigMap without touching the cluster. Against the cluster it only runs `kubectl exec ... cat`.
set -uo pipefail

CM=${1:-valheim/mods-configmap.yaml}
FILE=org.bepinex.plugins.valheim_plus.cfg
[ -f "$CM" ] || { echo "FAIL: $CM not found (run from the repo root)"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# python3 is a Microsoft Store stub on some Windows machines; use the first one that actually runs.
PY=""
for c in python3 python; do "$c" -c 1 >/dev/null 2>&1 && PY=$c && break; done
[ -n "$PY" ] || { echo "FAIL: no working python"; exit 2; }

if [ -n "${VP_LIVE_FILE:-}" ]; then
  # Test hook: compare against a local copy instead of the pod, so every failure mode --
  # including a duplicated section -- can be proven offline. Never set in normal use.
  cp "$VP_LIVE_FILE" "$TMP/live.cfg" || { echo "FAIL: could not read $VP_LIVE_FILE"; exit 2; }
  POD="(local file $VP_LIVE_FILE)"
else
  POD=$(kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}')
  [ -n "$POD" ] || { echo "FAIL: no valheim pod found"; exit 2; }
  # The path is inside the sh -c string on purpose: a bare /valheim/... argument is rewritten
  # into a Windows path by Git Bash before kubectl ever sees it.
  kubectl exec -n valheim "$POD" -c valheim -- sh -c "cat /valheim/BepInEx/config/$FILE" > "$TMP/live.cfg" \
    || { echo "FAIL: could not read $FILE from $POD"; exit 2; }
fi

# MOD_CONFIG body = the lines after "  MOD_CONFIG: |" up to the next top-level ConfigMap key.
tr -d '\r' < "$CM" \
  | awk '/^  MOD_CONFIG: \|/{f=1;next} /^  [A-Za-z_.-]+: /{f=0} f' \
  | sed -E 's/^    //' \
  | grep -E '^org\.bepinex\.plugins\.valheim_plus\.cfg\|' > "$TMP/pins.txt"

"$PY" - "$TMP/live.cfg" "$TMP/pins.txt" "$POD" <<'PY'
import re
import sys

live, pins, pod = sys.argv[1:4]

values = {}
seen = []
section = None
for raw in open(live, encoding='utf-8-sig'):
    line = raw.rstrip('\r\n')
    m = re.match(r'^\[(.+)\]$', line)
    if m:
        section = m.group(1)
        seen.append(section)
        values.setdefault(section, {})
        continue
    m = re.match(r'^([A-Za-z0-9_]+)\s*=\s*(.*)$', line)
    if m and section:
        values[section][m.group(1)] = m.group(2).strip()


def same(a, b):
    """Numeric compare where both parse (2400 == 2400.0), else case-insensitive text."""
    try:
        return float(a) == float(b)
    except ValueError:
        return a.strip().lower() == b.strip().lower()


problems = []
count = 0
for raw in open(pins, encoding='utf-8'):
    line = raw.rstrip('\n')
    if not line:
        continue
    _, sec, key, want = line.split('|', 3)
    count += 1
    got = values.get(sec, {}).get(key)
    if got is None:
        problems.append(f'MISSING   [{sec}] {key} (want {want})')
    elif not same(got, want):
        problems.append(f'MISMATCH  [{sec}] {key}: live={got} want={want}')

dups = sorted({s for s in seen if seen.count(s) > 1})
for d in dups:
    problems.append(f'DUPLICATE section [{d}] appears {seen.count(d)} times')

print(f'pod {pod}: {count} V+ pins checked, {len(seen)} sections, {len(problems)} problems')
for p in problems[:25]:
    print('  ' + p)
if len(problems) > 25:
    print(f'  ... and {len(problems) - 25} more')
if count == 0:
    print('FAIL: no V+ pins found in MOD_CONFIG')
    sys.exit(1)
sys.exit(1 if problems else 0)
PY
