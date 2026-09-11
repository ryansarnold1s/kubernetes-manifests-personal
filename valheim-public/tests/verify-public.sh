#!/bin/bash
# Live checks for the vanilla, internet-reachable Valheim server: the rows of spec §7 that a
# script can prove. Run from the repo root after every rollout of valheim-public:
#
#   bash valheim-public/tests/verify-public.sh
#
# NEGATIVE CONTROL -- pointed at the modded LAN server it MUST exit 1, because that server has
# BepInEx, -setkey nobuildcost, a service-account token and service links. Re-run it whenever a
# check here changes; a check that cannot fail against the LAN server proves nothing:
#
#   NS=valheim APP=valheim WORLD=TreeFellMeAgain LB_IP=192.168.130.155 PVC=valheim-data \
#     bash valheim-public/tests/verify-public.sh
#
# Read-only (kubectl get / logs / exec of cat, pgrep, env). Safe with players connected.
#
# Exit 0: every check passed. Exit 1: at least one failed. Exit 2: no pod to check.
set -uo pipefail

NS=${NS:-valheim-public}
APP=${APP:-valheim-public}
WORLD=${WORLD:-TreeFellMeVanilla}
LB_IP=${LB_IP:-192.168.130.157}
PVC=${PVC:-valheim-public-data}
ADMIN_ID=76561197963378853

POD=$(kubectl get pod -n "$NS" -l "app=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "FAIL: no pod with app=$APP in namespace $NS"; exit 2; }
echo "checking $NS/$POD"

fails=0
ok()     { echo "  ok    $1"; }
bad()    { echo "  FAIL  $1"; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
has()    { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1 (missing '$2')"; fi; }
lacks()  { if grep -qF -- "$2" <<< "$3"; then bad "$1 (found '$2')"; else ok "$1"; fi; }

# Paths stay inside the sh -c string on purpose: Git Bash rewrites a bare /valheim/... argument
# into a Windows path before kubectl ever sees it.
in_pod() { kubectl exec -n "$NS" "$POD" -c valheim -- sh -c "$1" 2>/dev/null; }

# --- the game process is vanilla --------------------------------------------------------------
# "[v]alheim_server.x86_64" is bracketed so pgrep cannot match this sh -c command line itself.
CMD=$(in_pod 'p=$(pgrep -f "[v]alheim_server.x86_64" | head -1); [ -n "$p" ] && tr "\0" " " < /proc/$p/cmdline')
[ -n "$CMD" ] && ok "game process found" || bad "game process found"
has   "cmdline: world $WORLD"         "-world $WORLD "   "$CMD"
has   "cmdline: -preset Normal"        "-preset Normal "  "$CMD"
has   "cmdline: unlisted (-public 0)"  "-public 0 "       "$CMD"
lacks "cmdline: no -setkey"            "-setkey"          "$CMD"
lacks "cmdline: no -modifier"          "-modifier"        "$CMD"
lacks "cmdline: no -crossplay"         "-crossplay"       "$CMD"

ENVP=$(in_pod 'p=$(pgrep -f "[v]alheim_server.x86_64" | head -1); [ -n "$p" ] && tr "\0" "\n" < /proc/$p/environ | grep "^LD_PRELOAD="')
lacks "process env: no BepInEx doorstop preload" "doorstop" "$ENVP"
expect "no /valheim/BepInEx directory" absent "$(in_pod 'test -e /valheim/BepInEx && echo present || echo absent')"

# --- the game log -----------------------------------------------------------------------------
LOG=$(kubectl logs -n "$NS" "$POD" -c valheim 2>/dev/null)
lacks "log: no BepInEx"                          "BepInEx"                             "$LOG"
lacks "log: no MaxPlayerCount"                   "MaxPlayerCount"                      "$LOG"
lacks "log: password is not the template value"  "Server Password has not been changed" "$LOG"
lacks "log: SteamCMD was not skipped"            "UPDATE_ON_START is not set"          "$LOG"
has   "log: SteamCMD ran this boot"              "Success! App '896660'"               "$LOG"

# --- admin, hardening, probes -----------------------------------------------------------------
has    "adminlist.txt holds the admin ID" "$ADMIN_ID" "$(in_pod 'cat /valheim-saves/adminlist.txt')"
expect "no service-account token mounted" absent \
  "$(in_pod 'test -e /var/run/secrets/kubernetes.io/serviceaccount && echo present || echo absent')"
# KUBERNETES_* is always injected whatever enableServiceLinks says; anything else is a service link.
expect "no service-link env vars" 0 \
  "$(in_pod 'env | grep "_SERVICE_HOST=" | grep -vc "^KUBERNETES_"')"
expect "probe pattern cannot self-match (negative case exits 1)" 1 \
  "$(in_pod 'pgrep -f "[Z]ZZNOSUCH" > /dev/null; echo $?')"
expect "probe pattern matches the real server (exits 0)" 0 \
  "$(in_pod 'pgrep -f "[v]alheim_server" > /dev/null; echo $?')"

# --- network and backups ----------------------------------------------------------------------
expect "Service granted $LB_IP" "$LB_IP" \
  "$(kubectl get svc -n "$NS" -l "app=$APP" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')"
PV=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
has "Longhorn volume ${PV:-?} is in snapshot group $APP" \
  "\"recurring-job-group.longhorn.io/$APP\":\"enabled\"" \
  "$(kubectl get volumes.longhorn.io -n longhorn-system "${PV:-none}" -o jsonpath='{.metadata.labels}' 2>/dev/null)"

echo "$fails failed"
[ "$fails" -eq 0 ]
