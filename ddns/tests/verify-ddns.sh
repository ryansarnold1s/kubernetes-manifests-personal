#!/bin/bash
# Proves the DDNS record is live, current and DNS-only. Run from the repo root:
#
#   bash ddns/tests/verify-ddns.sh
#
# NEGATIVE CONTROL -- the apex is Cloudflare-proxied, so it resolves to Cloudflare anycast, not
# the home WAN IP, and this MUST exit 1 for it:
#
#   NAME=arnoldtech.io bash ddns/tests/verify-ddns.sh
#
# The home WAN IP is printed to the terminal only. Never paste it into a tracked file.
# Exit 0: all checks passed. Exit 1: a check failed. Exit 2: a prerequisite could not be read.
set -uo pipefail

NAME=${NAME:-valheim.arnoldtech.io}
EGRESS_NS=${EGRESS_NS:-valheim-public}
EGRESS_DEPLOY=${EGRESS_DEPLOY:-valheim-public}

PY=""
for c in python3 python; do "$c" -c 1 >/dev/null 2>&1 && PY=$c && break; done
[ -n "$PY" ] || { echo "FAIL: no working python"; exit 2; }

fails=0
ok()     { echo "  ok    $1"; }
bad()    { echo "  FAIL  $1"; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
has()    { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1 (missing '$2')"; fi; }

expect "namespace ddns enforces restricted" restricted \
  "$(kubectl get ns ddns -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
expect "updater pod is Running" Running \
  "$(kubectl get pod -n ddns -l app=cloudflare-ddns -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
has "updater log names valheim.arnoldtech.io" "valheim.arnoldtech.io" \
  "$(kubectl logs -n ddns deploy/cloudflare-ddns 2>/dev/null)"

# The address the updater should have published: what the cluster egresses from, read from a
# pod because this workstation may not share the home WAN.
EGRESS=$(kubectl exec -n "$EGRESS_NS" "deploy/$EGRESS_DEPLOY" -c valheim -- \
  sh -c 'curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | sed -n "s/^ip=//p"' 2>/dev/null)
[ -n "$EGRESS" ] || { echo "FAIL: could not read the cluster egress IP"; exit 2; }

# What the internet resolves NAME to, over Cloudflare DNS-over-HTTPS (Git Bash has no dig).
# A proxied record returns Cloudflare anycast (104.21.x / 172.67.x) and fails the comparison.
PUB=$(curl -s --max-time 10 -H 'accept: application/dns-json' \
  "https://cloudflare-dns.com/dns-query?name=$NAME&type=A" \
  | "$PY" -c 'import json,sys; print(",".join(a["data"] for a in json.load(sys.stdin).get("Answer", []) if a["type"] == 1))')
expect "$NAME resolves publicly to the cluster egress IP (DNS-only and current)" "$EGRESS" "$PUB"

echo "$fails failed"
[ "$fails" -eq 0 ]
