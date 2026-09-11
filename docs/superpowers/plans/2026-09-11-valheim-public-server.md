# Valheim Public (Vanilla) Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a second, vanilla Valheim 1.0 server that friends reach over the internet at `valheim.arnoldtech.io:2456`, beside the untouched modded LAN server.

**Architecture:** Two new directories. `valheim-public/` is a stripped copy of `valheim/`: same image, no BepInEx layer, a tiny initContainer that only writes `adminlist.txt`, its own PVCs, snapshot job and MetalLB IP (`192.168.130.157`). `ddns/` runs `favonia/cloudflare-ddns` in its own `restricted` namespace, keeping a DNS-only A record on the home WAN IP. The operator adds a router port-forward and a Cloudflare token. Each directory gets a read-only live verification script written before the manifests, with a negative control that proves every check can fail.

**Tech Stack:** Kubernetes on Talos, Longhorn, MetalLB, Cloudflare DNS, `kubectl` from PowerShell or Git Bash with `KUBECONFIG` set in `.claude/settings.local.json`, bash + curl + python locally for the verify scripts.

**Spec:** `docs/superpowers/specs/2026-09-11-valheim-public-server-design.md`

## Global Constraints

Exact values, copied from the spec. Every task inherits these.

- **Game image:** `indifferentbroccoli/valheim-server-docker:v1.0.11@sha256:3702926c5e174e4e28189136b512a034cacb9b57636c5d29d978e9a97c6e2f98`, `imagePullPolicy: IfNotPresent`, both containers.
- **DDNS image:** `favonia/cloudflare-ddns:1.17.0@sha256:0770cab737e58544f9b7a880ceaec41554797de2cc8eccdde7e77b788893c154` — the **linux/amd64 platform digest** of tag 1.17.0 (tag digest `61013368…` is the multi-arch index). Same convention as the valheim pin.
- **Names:** namespace/label/Deployment/Service `valheim-public`; PVCs `valheim-public-data` (`/valheim-saves`) and `valheim-public-server` (`/valheim`); ConfigMap `valheim-public-config`; Secret `valheim-public-secrets` key `server-password`; RecurringJob `valheim-public-daily-snapshot`, group `valheim-public`. Game container name is `valheim` (the verify script relies on it).
- **World:** `TreeFellMeVanilla`. **Server name:** `Deathsquito Vanilla`. **IP:** `192.168.130.157`, UDP 2456/2457.
- **Vanilla trio, all load-bearing:** `BEPINEX_ENABLED: "false"`, `MODS: ""`, `MAX_PLAYERS: "10"`.
- **Listing knob:** `PUBLIC_ENABLED: "false"` (the variable `start.sh` reads). `PUBLIC` is not set.
- **Updates:** `UPDATE_ON_START: "true"`.
- **Preset:** `SERVER_PRESET: "Normal"`; `NO_BUILD_COST`, `NO_MAP`, `PLAYER_EVENTS`, `PASSIVE_MOBS`, `FIRE_HAZARDS` all `"false"`; no `MODIFIER_*`.
- **Carried from `valheim/`:** `strategy: Recreate`, `terminationGracePeriodSeconds: 120`, probes `pgrep -f '[v]alheim_server' > /dev/null` (startup 10s × 120, readiness 30s × 3, no liveness), 2 CPU / 5Gi request, 8Gi memory limit, no CPU limit, no `fsGroup`, no `runAsUser`.
- **Admin:** `ADMINLIST_IDS: "76561197963378853"`.
- **DNS name:** `valheim.arnoldtech.io`, `PROXIED=false`, `DELETE_ON_STOP=false`, `IP6_PROVIDER=none`.
- **Never write the server password or the Cloudflare token into a tracked file. Never write the home WAN IP into a tracked file.** Scripts print the IP to the terminal only.
- **The password is new.** Not the LAN server's (that one is in plaintext in the mumble ConfigMap).
- **`kubectl apply` output must say `created` or `configured`.** `unchanged` is a silent failure (wrong cwd). Always `cd <dir>/` first.
- **Never touch `valheim/`, its namespace, or its pod except read-only** (`get`, `logs`, `exec` of `cat`/`pgrep`/`curl`). Players may be on it.
- **Commits go straight to `main`.** Every commit ends with the attribution lines from the session's system reminder.
- Manifests carry inline comments saying *why*, aimed at the future edit that would undo the setting.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `valheim-public/tests/verify-public.sh` | Read-only live checks of spec §7 for the game server; env-overridable so it can be pointed at the LAN server as a negative control | 2 |
| `valheim-public/namespace.yaml` | Namespace, `baseline` by default | 3 |
| `valheim-public/configmap.yaml` | Every non-secret env var, with the why | 3 |
| `valheim-public/secret.yaml.template` | Password Secret template, value `CHANGEME` | 3 |
| `valheim-public/pvc.yaml` | Two 10Gi `longhorn` PVCs | 3 |
| `valheim-public/deployment.yaml` | `write-adminlist` initContainer + game container + hardening | 3 |
| `valheim-public/service.yaml` | MetalLB LoadBalancer `.157` | 3 |
| `valheim-public/recurringjob.yaml` | Daily snapshot, deploys to `longhorn-system` | 3 |
| `ddns/tests/verify-ddns.sh` | Updater running; public A record equals cluster egress IP; apex as negative control | 4 |
| `ddns/namespace.yaml` | Namespace `ddns`, PSA `restricted` enforce + warn | 4 |
| `ddns/configmap.yaml` | Updater env | 4 |
| `ddns/secret.yaml.template` | Token Secret template | 4 |
| `ddns/deployment.yaml` | The updater, non-root, read-only | 4 |
| `valheim-public/README.md`, `ddns/README.md` | Operator docs | 5 |
| `CLAUDE.md` | Two new directory bullets | 5 |
| `docs/superpowers/specs/2026-09-11-valheim-public-server-design.md` | Appended correction (token file mode, digest) | 5 |
| Cluster | Deploy + verify game server | 6 |
| Cluster + Cloudflare | Deploy + verify DDNS | 7 |
| Router + clients | Port-forward, internet join, results recorded in README | 8 |

---

### Task 1: Pre-flight go/no-go

Nothing is written until the port-forward approach is proven viable. No commit.

**Files:** none.

**Interfaces:**
- Consumes: nothing.
- Produces: a go/no-go. **No-go stops the plan** and returns to brainstorming (reachability).

- [ ] **Step 1: Read the cluster's egress IP**

Run (PowerShell, repo root; read-only exec into the LAN pod, which ships curl):

```powershell
kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep -E "^ip="'
```

Expected: `ip=<public IPv4>`. It must **not** be in `100.64.0.0/10` (CGNAT). Keep it in the terminal only.

- [ ] **Step 2: Operator compares it with the router's WAN address**

Ask the operator to open the router's WAN/status page and confirm the WAN IPv4 **equals** Step 1's address.

- Equal → go.
- Different, or a private/CGNAT address on the router's WAN → **no-go**: there is another NAT upstream and a forward cannot work. Stop.

- [ ] **Step 3: Confirm `192.168.130.157` is free**

```powershell
(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.loadBalancer.ingress[*].ip} {.metadata.annotations.metallb\.io/loadBalancerIPs}{"\n"}{end}') -join "`n" | Select-String "192\.168\.130\.157"
```

Expected: no output. Then ask the operator to confirm nothing on the LAN holds `.157` statically and the router's DHCP scope excludes `.150–.199` (the MetalLB pool).

- [ ] **Step 4: Record the go**

State in the conversation: egress IP matches router WAN (yes/no), `.157` free (yes/no). Proceed only on yes/yes.

---

### Task 2: Game-server verification script (written first; fails until Task 6)

**Files:**
- Create: `valheim-public/tests/verify-public.sh`

**Interfaces:**
- Consumes: env overrides `NS` (default `valheim-public`), `APP` (default `valheim-public`), `WORLD` (default `TreeFellMeVanilla`), `LB_IP` (default `192.168.130.157`), `PVC` (default `valheim-public-data`). Requires a pod labelled `app=$APP` with a container named `valheim`, a Service labelled `app=$APP`, and a Longhorn snapshot group named `$APP`.
- Produces: exit 0 all pass, 1 any fail, 2 no pod. One `ok`/`FAIL` line per check. Task 6 runs it.

- [ ] **Step 1: Write the script**

Create `valheim-public/tests/verify-public.sh`:

```bash
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
```

Note on the `grep -vc` line: `grep -c` prints `0` and exits 1 when nothing matches; the `$(...)` captures the `0`, which is what is compared. Do not add `|| true` inside the quotes; it would print a second line.

- [ ] **Step 2: Run it against the not-yet-existing server — it must fail**

Run (Git Bash, repo root): `bash valheim-public/tests/verify-public.sh; echo "exit=$?"`

Expected: `FAIL: no pod with app=valheim-public in namespace valheim-public` and `exit=2`.

- [ ] **Step 3: Run the negative control against the LAN server — it must fail for the right reasons**

Run:

```bash
NS=valheim APP=valheim WORLD=TreeFellMeAgain LB_IP=192.168.130.155 PVC=valheim-data \
  bash valheim-public/tests/verify-public.sh; echo "exit=$?"
```

Expected: `exit=1`, with **at least** these six `FAIL` lines:
`cmdline: no -setkey`, `process env: no BepInEx doorstop preload`, `no /valheim/BepInEx directory`, `log: no BepInEx`, `no service-account token mounted`, `no service-link env vars`.

And these must be `ok` (they prove the script reads the LAN server correctly rather than failing on everything): `game process found`, `cmdline: world TreeFellMeAgain`, `cmdline: -preset Normal`, `adminlist.txt holds the admin ID`, both probe lines, `Service granted 192.168.130.155`, `Longhorn volume … is in snapshot group valheim`.

If any of the expected-ok lines fails, the script has a bug (quoting, Git Bash path mangling, jsonpath). Fix it before continuing.

- [ ] **Step 4: Commit**

```bash
git add valheim-public/tests/verify-public.sh
git commit -F - <<'EOF'
Add a live verification script for the public valheim server

Read-only checks of the spec's verification table: vanilla cmdline and env,
log lines, adminlist, pod hardening, probe negative case, granted IP and
Longhorn snapshot group. Pointed at the modded LAN server it fails six
checks, which is the proof each check can fail.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 3: `valheim-public/` manifests

**Files:**
- Create: `valheim-public/namespace.yaml`, `configmap.yaml`, `secret.yaml.template`, `pvc.yaml`, `deployment.yaml`, `service.yaml`, `recurringjob.yaml`

**Interfaces:**
- Consumes: Global Constraints names.
- Produces: the objects Task 2's script checks (labels `app: valheim-public`, container `valheim`, snapshot group `valheim-public`). Task 6 applies them.

- [ ] **Step 1: `namespace.yaml`**

```yaml
# Deliberately no pod-security.kubernetes.io labels: the cluster default is baseline, and that is
# the ceiling for this image -- init.sh needs root for usermod and chown -R, so restricted is
# impossible. Do not add `enforce: privileged` either; nothing here needs more than baseline.
apiVersion: v1
kind: Namespace
metadata:
  name: valheim-public
  labels:
    app: valheim-public
```

- [ ] **Step 2: `configmap.yaml`**

```yaml
# Non-secret env for the indifferentbroccoli/valheim-server-docker image, VANILLA. Names are the
# image's, read from /home/steam/server/{init,start}.sh in v1.0.11 -- the scripts are the truth,
# not the README. See ../valheim/configmap.yaml for the modded twin; the two differ on purpose.
apiVersion: v1
kind: ConfigMap
metadata:
  name: valheim-public-config
  namespace: valheim-public
  labels:
    app: valheim-public
data:
  # Must not contain the server password: Valheim refuses to start if it does.
  SERVER_NAME: "Deathsquito Vanilla"
  WORLD_NAME: "TreeFellMeVanilla"
  PORT: "2456"
  TZ: "America/Phoenix"
  # false = Steam networking. Friends arrive through the router port-forward, which is what
  # Join IP expects. true would route through PlayFab and add relay latency.
  CROSSPLAY_ENABLED: "false"
  # The variable start.sh ACTUALLY reads for -public (it ignores PUBLIC, which ../valheim sets).
  # false keeps the server out of the community browser: strangers would otherwise find it and
  # start guessing the password, which is the only gate.
  PUBLIC_ENABLED: "false"
  SAVE_INTERVAL: "1800"
  # Load-bearing: start.sh passes -savedir "${SAVE_DIR}", the valheim-public-data mountPath in
  # deployment.yaml (both containers) and the image's init.sh chown all hardcode the same path.
  # Change this alone and the world is written off the PVC and lost on restart.
  SAVE_DIR: "/valheim-saves"
  # Valheim's native rolling backups in worlds_local/: one at 2h, then three 12h apart.
  KEEP_BACKUPS: "4"
  BACKUPS_SHORT: "7200"
  BACKUPS_LONG: "43200"
  SERVER_PRESET: "Normal"
  # Every -setkey toggle pinned false. A -setkey persists a global key INTO THE WORLD SAVE, so a
  # default flipping upstream would change the world permanently, not just for one boot.
  NO_BUILD_COST: "false"
  NO_MAP: "false"
  PLAYER_EVENTS: "false"
  PASSIVE_MOBS: "false"
  FIRE_HAZARDS: "false"
  # ⚠️ THE VANILLA TRIO. start.sh turns BepInEx on if ANY ONE of these is wrong:
  #   BEPINEX_ENABLED true  -> loads BepInEx
  #   MODS non-empty        -> forces BepInEx on and runs the image's unverified downloader
  #   MAX_PLAYERS != "10"   -> forces BepInEx on and installs its bundled MaxPlayerCount mod
  # MAX_PLAYERS is pinned even though the image ENV already says 10: "unset" is only safe while
  # that image default holds. 10 is Valheim's vanilla cap; raising it means a mod.
  BEPINEX_ENABLED: "false"
  MODS: ""
  MAX_PLAYERS: "10"
  # true = SteamCMD runs on EVERY boot (init.sh:27). No mods to break, and friends' clients
  # auto-update, so a restart after a patch is the whole update procedure. Opposite of
  # ../valheim on purpose.
  UPDATE_ON_START: "true"
  BETA: "public"
  # Required by init.sh, which exits without them. It usermods the steam user and chown -Rs both
  # volumes, then runs the game as root regardless.
  PUID: "10000"
  PGID: "10000"
  # Space-separated SteamID64s, written to /valheim-saves/adminlist.txt by the write-adminlist
  # initContainer on every boot. Admin grants the F5 console kick/ban -- the tools for a griefer
  # on a server strangers can reach. 76561197963378853 = Ryan.
  ADMINLIST_IDS: "76561197963378853"
  # Deliberately absent:
  #   PUBLIC              -- dead code in this image; PUBLIC_ENABLED above is the real knob
  #   BEPINEXPACK_VERSION -- only read inside the BepInEx branch
  #   MODIFIER_*          -- plain Normal preset
```

- [ ] **Step 3: `secret.yaml.template`**

```yaml
# Copy to secret.yaml, set a real password, then apply.
# secret.yaml is gitignored by the repo-root **/secret.yaml rule -- never commit it.
#
# ⚠️ This server is reachable from the internet and the password is its ONLY gate.
#   - NEW password. Never the LAN server's (it sits in plaintext in the mumble ConfigMap).
#   - Minimum 5 characters, and must NOT appear inside SERVER_NAME (configmap.yaml).
#
# The value below is exactly CHANGEME on purpose: the image logs
# "Server Password has not been changed" for that exact string, and
# tests/verify-public.sh fails on that line. Do not "improve" the placeholder.
apiVersion: v1
kind: Secret
metadata:
  name: valheim-public-secrets
  namespace: valheim-public
  labels:
    app: valheim-public
type: Opaque
stringData:
  server-password: "CHANGEME"
```

- [ ] **Step 4: `pvc.yaml`**

```yaml
# /valheim-saves -- worlds_local/ (world + Valheim's rolling auto-backups) and adminlist.txt.
# The irreplaceable data. storageClass longhorn has reclaimPolicy Delete: deleting this PVC
# destroys the world.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-public-data
  namespace: valheim-public
  labels:
    app: valheim-public
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
# /valheim -- the SteamCMD game install. Disposable: deleting it forces a clean reinstall on the
# next boot and does not touch the world.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-public-server
  namespace: valheim-public
  labels:
    app: valheim-public
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 5: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim-public
  namespace: valheim-public
  labels:
    app: valheim-public
spec:
  replicas: 1
  strategy:
    # Recreate: RollingUpdate deadlocks on the ReadWriteOnce Longhorn volumes.
    type: Recreate
  selector:
    matchLabels:
      app: valheim-public
  template:
    metadata:
      labels:
        app: valheim-public
    spec:
      # The image traps SIGTERM, sends SIGINT to the game and waits for the world save. 120s,
      # not the image compose example's 30s.
      terminationGracePeriodSeconds: 120
      # --- Hardening. This pod parses internet traffic as root (a property of the image), on a
      # Flannel network where NetworkPolicy is NOT enforced. These are what the image tolerates:
      # Nothing in this pod talks to the Kubernetes API; a token would only help an attacker.
      automountServiceAccountToken: false
      # No Docker-link env vars describing other Services.
      enableServiceLinks: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      # No fsGroup: init.sh chown -Rs both volumes itself on every start.
      initContainers:
      # Writes adminlist.txt from ADMINLIST_IDS on every boot. This is the only job left of the
      # modded server's fetch-mods container: the image itself does nothing with admins.
      # No `$(` anywhere in this script: Kubernetes expands $(VAR) in command strings.
      - name: write-adminlist
        image: indifferentbroccoli/valheim-server-docker:v1.0.11@sha256:3702926c5e174e4e28189136b512a034cacb9b57636c5d29d978e9a97c6e2f98
        imagePullPolicy: IfNotPresent
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          out=/valheim-saves/adminlist.txt
          {
            echo "// List admin players ID  ONE per line"
            for id in ${ADMINLIST_IDS}; do echo "$id"; done
          } > "$out.tmp"
          mv "$out.tmp" "$out"
          echo "[admin] wrote $out:"
          cat "$out"
        env:
        - name: ADMINLIST_IDS
          valueFrom:
            configMapKeyRef:
              name: valheim-public-config
              key: ADMINLIST_IDS
        volumeMounts:
        - name: saves
          mountPath: /valheim-saves
        # Runs as root like the game (the volume is chowned to 10000 after the first boot, so
        # writing it needs root's DAC override). drop: ALL would remove that; NET_RAW is safe.
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["NET_RAW"]
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
          limits:
            memory: "64Mi"
      containers:
      # The container name `valheim` matches ../valheim so tests/verify-public.sh works on both.
      - name: valheim
        image: indifferentbroccoli/valheim-server-docker:v1.0.11@sha256:3702926c5e174e4e28189136b512a034cacb9b57636c5d29d978e9a97c6e2f98
        imagePullPolicy: IfNotPresent
        ports:
        - name: game
          containerPort: 2456
          protocol: UDP
        - name: query
          containerPort: 2457
          protocol: UDP
        envFrom:
        - configMapRef:
            name: valheim-public-config
        env:
        - name: SERVER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: valheim-public-secrets
              key: server-password
        volumeMounts:
        - name: server
          mountPath: /valheim
        - name: saves
          mountPath: /valheim-saves
        # Deliberately no livenessProbe: it would SIGKILL the server mid-world-save.
        #
        # The pattern MUST stay bracketed as '[v]alheim_server'. A bare `pgrep -f valheim_server`
        # matches the probe's own `sh -c` process and returns 0 unconditionally. The `> /dev/null`
        # keeps that shell alive so the bracket is what prevents the self-match. Verified by
        # tests/verify-public.sh against a name that does not exist.
        startupProbe:
          exec:
            command: ["sh", "-c", "pgrep -f '[v]alheim_server' > /dev/null"]
          periodSeconds: 10
          # 20 min: UPDATE_ON_START=true runs SteamCMD on every boot, and a cold install on an
          # empty valheim-public-server PVC must finish inside this window.
          failureThreshold: 120
        readinessProbe:
          exec:
            command: ["sh", "-c", "pgrep -f '[v]alheim_server' > /dev/null"]
          periodSeconds: 30
          failureThreshold: 3
        # init.sh needs root (usermod, chown -R), so runAsNonRoot and drop: ALL are out. These two
        # are what remain. If a future image needs a raw socket or a setuid helper, the boot will
        # fail loudly at init.sh -- remove the offending line here, not the whole block.
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["NET_RAW"]
        # No CPU limit: CFS throttling shows up in-game as rubber-banding.
        resources:
          requests:
            cpu: "2"
            memory: "5Gi"
          limits:
            memory: "8Gi"
      volumes:
      - name: server
        persistentVolumeClaim:
          claimName: valheim-public-server
      - name: saves
        persistentVolumeClaim:
          claimName: valheim-public-data
```

- [ ] **Step 6: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valheim-public
  namespace: valheim-public
  labels:
    app: valheim-public
  annotations:
    # .157 is the next free address after icarus (.156); pool vlan130-pool is .150-.199. A
    # REQUEST, not a guarantee: if it is taken MetalLB silently assigns another, and the router
    # port-forward then points at nothing. tests/verify-public.sh checks the granted address.
    metallb.io/loadBalancerIPs: 192.168.130.157
spec:
  type: LoadBalancer
  # Keeps the real client IP visible to the game, which is what makes a `ban` mean anything on a
  # server strangers can reach.
  externalTrafficPolicy: Local
  #
  # ⚠️ INTERNET-EXPOSED. The router forwards WAN UDP 2456-2457 here. There are deliberately NO
  # loadBalancerSourceRanges: by decision the password is the only gate (friends' residential
  # IPs change). If that changes, loadBalancerSourceRanges is the enforcement point -- NOT
  # NetworkPolicy, which Flannel silently ignores.
  ports:
  - name: game
    port: 2456
    targetPort: 2456
    protocol: UDP
  - name: query
    port: 2457
    targetPort: 2457
    protocol: UDP
  selector:
    app: valheim-public
```

- [ ] **Step 7: `recurringjob.yaml`**

```yaml
# This job does nothing until the Longhorn Volume backing valheim-public-data carries the label
# recurring-job-group.longhorn.io/valheim-public=enabled -- a new or recreated PVC's volume
# starts unlabeled. See README.md (Applying) for the label command.
# 11:15 UTC = 04:15 Arizona, 15 minutes after the LAN server's job so the two never contend.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: valheim-public-daily-snapshot
  namespace: longhorn-system
spec:
  cron: "15 11 * * *"
  task: snapshot
  groups:
  - valheim-public
  retain: 7
  concurrency: 1
```

- [ ] **Step 8: Validate with a server-side dry run**

The namespace must exist for namespaced dry-runs to resolve, so create it for real (it holds nothing). Then dry-run the rest. PowerShell:

```powershell
cd valheim-public
kubectl apply -f namespace.yaml
kubectl apply --dry-run=server -f configmap.yaml -f secret.yaml.template -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
cd ..
```

Expected: `namespace/valheim-public created`, then six lines each ending `created (server dry run)`. Any `Warning:` or error is a failure — fix the manifest.

- [ ] **Step 9: Static check of the vanilla trio**

```powershell
Select-String -Path valheim-public/configmap.yaml -Pattern '^\s+(BEPINEX_ENABLED|MODS|MAX_PLAYERS|PUBLIC_ENABLED|UPDATE_ON_START|PUBLIC):'
```

Expected exactly five lines: `BEPINEX_ENABLED: "false"`, `MODS: ""`, `MAX_PLAYERS: "10"`, `PUBLIC_ENABLED: "false"`, `UPDATE_ON_START: "true"`. No bare `PUBLIC:` line.

- [ ] **Step 10: Commit**

```bash
git add valheim-public/namespace.yaml valheim-public/configmap.yaml valheim-public/secret.yaml.template valheim-public/pvc.yaml valheim-public/deployment.yaml valheim-public/service.yaml valheim-public/recurringjob.yaml
git commit -F - <<'EOF'
Add manifests for the vanilla, internet-reachable valheim server

Same image as valheim/, with BEPINEX_ENABLED, MODS and MAX_PLAYERS pinned so
start.sh never turns BepInEx on, PUBLIC_ENABLED (the variable start.sh reads)
keeping it unlisted, and UPDATE_ON_START=true. A small initContainer writes
adminlist.txt; the pod has no service-account token, no service links,
RuntimeDefault seccomp and drops NET_RAW. MetalLB .157, own PVCs and
snapshot job.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 4: `ddns/` manifests and verification script

**Files:**
- Create: `ddns/tests/verify-ddns.sh`, `ddns/namespace.yaml`, `ddns/configmap.yaml`, `ddns/secret.yaml.template`, `ddns/deployment.yaml`

**Interfaces:**
- Consumes: a running `valheim-public` Deployment with container `valheim` (for the egress-IP read; overridable by `EGRESS_NS` / `EGRESS_DEPLOY`).
- Produces: pod labelled `app=cloudflare-ddns` in namespace `ddns`; Secret `cloudflare-ddns-token` key `token` mounted at `/run/secrets/cloudflare/token`. Task 7 applies and verifies.

- [ ] **Step 1: Write the failing verification script**

Create `ddns/tests/verify-ddns.sh`:

```bash
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
```

- [ ] **Step 2: Run it — it must fail**

Run (Git Bash, repo root): `bash ddns/tests/verify-ddns.sh; echo "exit=$?"`

Expected: `FAIL  namespace ddns enforces restricted`, `FAIL  updater pod is Running`, `FAIL  updater log names …`, then either `FAIL: could not read the cluster egress IP` / `exit=2` (if valheim-public is not deployed yet) or a failing resolution line and `exit=1`. Either is correct at this point.

- [ ] **Step 3: `ddns/namespace.yaml`**

```yaml
# restricted: the updater is a static Go binary that needs no root, no capabilities and no
# writable filesystem, so the strictest profile costs nothing. enforce rejects non-compliant
# Pods; warn makes `kubectl apply` of a non-compliant DEPLOYMENT print a warning (enforce alone
# only acts on Pods, so a bad Deployment would apply silently and then never create a pod).
# Kept apart from valheim-public on purpose: the Cloudflare token must never share a namespace
# with the internet-facing root process.
apiVersion: v1
kind: Namespace
metadata:
  name: ddns
  labels:
    app: cloudflare-ddns
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

- [ ] **Step 4: `ddns/secret.yaml.template`**

```yaml
# Copy to secret.yaml, paste the token, then apply. Gitignored by the **/secret.yaml rule.
#
# Create the token at Cloudflare → My Profile → API Tokens → Create Token → "Edit zone DNS"
# template, Zone Resources: Include → Specific zone → arnoldtech.io. No client-IP filter: after a
# WAN IP change the updater calls from the NEW address, and a filter would reject exactly the call
# that fixes DNS. This is NOT the cert-manager token -- never reuse that one.
#
# ⚠️ Zone DNS Edit cannot be narrowed to one record: this token can rewrite ANY arnoldtech.io
# record. Keep it in this namespace only.
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-ddns-token
  namespace: ddns
  labels:
    app: cloudflare-ddns
type: Opaque
stringData:
  token: "CHANGEME"
```

- [ ] **Step 5: `ddns/configmap.yaml`**

```yaml
# Env for favonia/cloudflare-ddns v1.17.0. Names from its README at tag v1.17.0.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflare-ddns-config
  namespace: ddns
  labels:
    app: cloudflare-ddns
data:
  # From a mounted file, not an env var, so the token never shows in `kubectl describe pod`.
  CLOUDFLARE_API_TOKEN_FILE: "/run/secrets/cloudflare/token"
  # The only managed name. Add names here comma-separated; each needs its own router forward.
  IP4_DOMAINS: "valheim.arnoldtech.io"
  # The pod's egress as Cloudflare sees it -- the home WAN IP (checked 2026-09-11).
  IP4_PROVIDER: "cloudflare.trace"
  # No AAAA: the game Service is IPv4 only, and an AAAA pointing anywhere else would send
  # IPv6-preferring clients into nothing.
  IP6_PROVIDER: "none"
  # ⚠️ MUST stay false. A proxied (orange-cloud) record resolves to Cloudflare anycast, and
  # Cloudflare's proxy does not carry Valheim's UDP. Friends would resolve fine and never connect.
  PROXIED: "false"
  # Friends follow a WAN IP change within ~5 min of the updater noticing it.
  TTL: "300"
  UPDATE_CRON: "@every 5m"
  UPDATE_ON_START: "true"
  # ⚠️ MUST stay false. true deletes the record whenever the pod stops -- every restart, node
  # drain or image bump would take the server off DNS.
  DELETE_ON_STOP: "false"
  # The updater only touches records whose comment matches the regex, and writes that comment on
  # records it creates. A hand-made record of the same name is left alone.
  RECORD_COMMENT: "managed by ddns/cloudflare-ddns (kubernetes-manifests-personal)"
  MANAGED_RECORDS_COMMENT_REGEX: "^managed by ddns/cloudflare-ddns"
  TZ: "America/Phoenix"
```

- [ ] **Step 6: `ddns/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflare-ddns
  namespace: ddns
  labels:
    app: cloudflare-ddns
spec:
  replicas: 1
  # Recreate: two updaters racing on the same record is harmless but pointless.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: cloudflare-ddns
  template:
    metadata:
      labels:
        app: cloudflare-ddns
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        # Makes the mounted token file group-owned by 1000 -- see defaultMode below.
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: cloudflare-ddns
        # linux/amd64 platform digest of tag 1.17.0 (the tag's index digest is 61013368...).
        image: favonia/cloudflare-ddns:1.17.0@sha256:0770cab737e58544f9b7a880ceaec41554797de2cc8eccdde7e77b788893c154
        imagePullPolicy: IfNotPresent
        envFrom:
        - configMapRef:
            name: cloudflare-ddns-config
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: token
          mountPath: /run/secrets/cloudflare
          readOnly: true
        # No probes: the updater has no health endpoint, and it exits on a fatal error, which the
        # Deployment restarts.
        resources:
          requests:
            cpu: "10m"
            memory: "32Mi"
          limits:
            memory: "64Mi"
      volumes:
      - name: token
        secret:
          secretName: cloudflare-ddns-token
          # 0440, NOT 0400: the file is owned by root and group-owned by fsGroup 1000. 0400 would
          # leave it readable by root only, and the updater (uid 1000) could not read its token.
          defaultMode: 0440
```

- [ ] **Step 7: Validate, including the restricted negative control**

PowerShell:

```powershell
cd ddns
kubectl apply -f namespace.yaml
# Negative control: a non-compliant pod MUST be rejected, proving the label is live.
kubectl run psa-probe -n ddns --image=busybox --restart=Never --dry-run=server -- sleep 1
# The real manifests MUST dry-run clean, with no PodSecurity warning.
kubectl apply --dry-run=server -f configmap.yaml -f secret.yaml.template -f deployment.yaml
cd ..
```

Expected:
1. `namespace/ddns created`.
2. The `psa-probe` line **errors** with `violates PodSecurity "restricted:latest"`. If it is accepted, the namespace label is wrong — stop and fix.
3. Three lines ending `created (server dry run)` and **no** line starting `Warning: would violate PodSecurity`.

- [ ] **Step 8: Commit**

```bash
git add ddns/tests/verify-ddns.sh ddns/namespace.yaml ddns/configmap.yaml ddns/secret.yaml.template ddns/deployment.yaml
git commit -F - <<'EOF'
Add a Cloudflare DDNS updater for valheim.arnoldtech.io

favonia/cloudflare-ddns pinned by amd64 digest in its own restricted
namespace, so its zone-wide DNS token never shares a namespace with the
internet-facing game server. DNS-only (PROXIED=false: the proxy drops game
UDP), DELETE_ON_STOP=false, and a comment regex limiting it to its own record.
verify-ddns.sh compares the public A record with the cluster's egress IP;
the proxied apex is its negative control.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 5: Documentation

**Files:**
- Create: `valheim-public/README.md`, `ddns/README.md`
- Modify: `CLAUDE.md` (two bullets in the directory list)
- Modify: `docs/superpowers/specs/2026-09-11-valheim-public-server-design.md` (append a correction)

**Interfaces:**
- Consumes: names and commands from Tasks 2–4.
- Produces: operator docs; Task 8 appends a "Verified" section to `valheim-public/README.md`.

- [ ] **Step 1: Write `valheim-public/README.md`**

````markdown
# Valheim Public (Vanilla) Server

Vanilla Valheim 1.0 for friends over the internet, beside the modded LAN server in `../valheim/`.
Same image, no BepInEx, no mods, its own world and IP.
Design: `../docs/superpowers/specs/2026-09-11-valheim-public-server-design.md`.

## Joining

- **From the internet:** Start Game → Select Character → Join Game → Join IP →
  `valheim.arnoldtech.io:2456`, then the password.
- **From the LAN:** Join IP → `192.168.130.157:2456`. The name does **not** work on the LAN:
  pihole answers every `*.arnoldtech.io` name with Traefik's `.150`.

World `TreeFellMeVanilla`, server name `Deathsquito Vanilla`. Steam clients only (crossplay
off). Not listed in the community browser. The password lives in the `valheim-public-secrets`
Secret and is shared with friends out of band.

## What keeps it vanilla

`start.sh` turns BepInEx on if **any one** of these is wrong. All three are pinned in
`configmap.yaml`:

| Key | Value | If wrong |
|---|---|---|
| `BEPINEX_ENABLED` | `false` | Loads BepInEx |
| `MODS` | `""` | Forces BepInEx on and runs the image's unverified mod downloader |
| `MAX_PLAYERS` | `10` | Forces BepInEx on and installs the bundled MaxPlayerCount mod |

`PUBLIC_ENABLED` is the image's real listing knob; `PUBLIC`, which `../valheim` sets, is dead
code. `bash valheim-public/tests/verify-public.sh` proves the running process is vanilla.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `valheim-public` (baseline, the ceiling for a root image) |
| `configmap.yaml` | Every non-secret env var, with the why |
| `secret.yaml.template` | Template for the password Secret |
| `pvc.yaml` | `valheim-public-data` (world), `valheim-public-server` (game install) |
| `deployment.yaml` | initContainer `write-adminlist` + game container |
| `service.yaml` | MetalLB LoadBalancer `192.168.130.157`, UDP 2456-2457 |
| `recurringjob.yaml` | Longhorn daily snapshot (deploys to `longhorn-system`) |
| `tests/verify-public.sh` | Read-only live checks; run after every rollout |

The DNS record is kept by `../ddns/`.

## Applying

```powershell
cd valheim-public/                            # relative paths from repo root silently no-op
Copy-Item secret.yaml.template secret.yaml    # first time only; then set a NEW password
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
```

Every line must say `created` or `configured`; `unchanged` means the wrong directory.

The password: new, at least 5 characters, not inside `SERVER_NAME`, and **never** the LAN
server's, which sits in plaintext in the mumble ConfigMap.

**Post-deploy, required, after any PVC (re)creation** — a new volume starts unlabeled and the
RecurringJob looks healthy while producing nothing:

```powershell
$pv = kubectl get pvc valheim-public-data -n valheim-public -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim-public=enabled" --overwrite
```

Then, from the repo root: `bash valheim-public/tests/verify-public.sh` must exit 0.

## Outside the cluster

- **Router:** WAN UDP 2456 and 2457 → `192.168.130.157`, same ports. Nothing is forwarded to
  the LAN server.
- **DNS:** `valheim.arnoldtech.io`, DNS-only, kept current by `../ddns/`.
- **CloudCasa:** a policy must cover namespace `valheim-public` and capture PVC data.

## Game updates

Friends' Steam clients update themselves; this server updates only when it restarts
(`UPDATE_ON_START=true` runs SteamCMD on every boot). On patch day, check nobody is on, then
restart — in the same action:

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c valheim --since=5m | Select-String "Got connection|Closing socket"
kubectl rollout restart deploy/valheim-public -n valheim-public
kubectl rollout status  deploy/valheim-public -n valheim-public --timeout=1500s
```

Until someone restarts it, patched clients are refused with an incompatible-version error.

## Operating notes

- **Never lower `terminationGracePeriodSeconds` below 120**, never switch off `Recreate`, never
  add a liveness probe, never add a CPU limit. Same reasons as `../valheim/README.md`.
- **Never unbracket the probe pattern.** `verify-public.sh` checks the negative case.
- **A first boot on a fresh `valheim-public-server` PVC can crash-loop on a transient SteamCMD
  `Missing configuration` error and heal itself** within the 20-minute startup window. Wait;
  do not delete anything. See `../valheim/README.md`.
- **`externalTrafficPolicy: Local` + pod reschedule = brief outage** while MetalLB re-announces.
- **Hardening:** no service-account token, no service links, RuntimeDefault seccomp,
  `allowPrivilegeEscalation: false`, `NET_RAW` dropped. `runAsNonRoot` and `drop: ALL` are
  impossible: `init.sh` needs root for `usermod` and `chown -R`.

## Access control and accepted risks

- **The password is the only gate.** Rotate it by editing `secret.yaml`, applying, restarting,
  and telling friends. For a single griefer, an admin runs `ban <name>` in the F5 console.
- To tighten later, `spec.loadBalancerSourceRanges` in `service.yaml` is the enforcement point.
  **Never NetworkPolicy** — Flannel ignores it.
- **The game runs as root and parses internet traffic**, on a cluster network where a
  compromised pod can reach every in-cluster Service (including the shared finance Postgres).
  Each service's own authentication is the barrier. Accepted 2026-09-11; see the spec §8.

## Connections

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c valheim --since=5m | Select-String "Got connection|Closing socket"
kubectl logs -n valheim-public deploy/valheim-public -c valheim --tail=600 | Select-String "Connections \d+" | Select-Object -Last 1
```

## Backups and restore

Same three layers as `../valheim/README.md` (Valheim's rolling backups in `worlds_local/`,
Longhorn `valheim-public-daily-snapshot` at 11:15 UTC retaining 7, CloudCasa). Every command
there works here with `valheim` → `valheim-public`, `valheim-data` → `valheim-public-data`,
`app=valheim` → `app=valheim-public` and `TreeFellMeAgain` → `TreeFellMeVanilla`.

## Rollback

Remove the workload, keep the world: `kubectl delete -f deployment.yaml -f service.yaml`. Also
remove the router forward, so the WAN port does not point at an address MetalLB may reassign.

Tear down completely — **this destroys the world**:

```powershell
kubectl delete -f deployment.yaml -f service.yaml -f recurringjob.yaml
kubectl delete -f pvc.yaml   # DESTRUCTIVE: storageClass longhorn has reclaimPolicy Delete
kubectl delete -f namespace.yaml
```
````

- [ ] **Step 2: Write `ddns/README.md`**

````markdown
# Cloudflare DDNS

Keeps `valheim.arnoldtech.io` (DNS-only) pointed at the home WAN IPv4, using
`favonia/cloudflare-ddns` v1.17.0. Serves `../valheim-public/`.
Design: `../docs/superpowers/specs/2026-09-11-valheim-public-server-design.md` §5.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `ddns`, Pod Security `restricted` (enforce + warn) |
| `configmap.yaml` | Updater env, with the why |
| `secret.yaml.template` | Template for the Cloudflare token Secret |
| `deployment.yaml` | The updater: non-root, read-only, no capabilities, no SA token |
| `tests/verify-ddns.sh` | Public A record == cluster egress IP; run after any change |

## The token

Cloudflare → My Profile → API Tokens → Create Token → **Edit zone DNS** template → Zone
Resources: Include → Specific zone → `arnoldtech.io`. No client-IP filter, no expiry.

- **Not** the cert-manager token (`cloudflare-token-secret`). Never reuse it.
- Zone DNS Edit cannot be narrowed to one record: this token can rewrite **any**
  `arnoldtech.io` record. It lives only in this namespace, whose pod has no service-account
  token and runs non-root.
- To revoke: delete it in the Cloudflare dashboard. The record stays at its last value.

## Applying

```powershell
cd ddns/
Copy-Item secret.yaml.template secret.yaml    # first time only; paste the token
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f deployment.yaml
```

From the repo root: `bash ddns/tests/verify-ddns.sh` must exit 0, and
`NAME=arnoldtech.io bash ddns/tests/verify-ddns.sh` must exit 1 (the proxied apex is the
negative control).

## Settings that must not change

- **`PROXIED=false`.** Cloudflare's proxy does not carry Valheim UDP. A proxied record resolves
  fine and never connects.
- **`DELETE_ON_STOP=false`.** Otherwise every pod restart deletes the record.
- **`MANAGED_RECORDS_COMMENT_REGEX`** limits the updater to records carrying its own comment.

## Adding a name

Append it to `IP4_DOMAINS` in `configmap.yaml` (comma-separated), apply, then
`kubectl rollout restart deploy/cloudflare-ddns -n ddns` (a ConfigMap edit needs the restart).
Each new name is only useful with its own router forward.

## Logs

```powershell
kubectl logs -n ddns deploy/cloudflare-ddns --tail=50
```
````

- [ ] **Step 3: Add the two `CLAUDE.md` bullets**

In `CLAUDE.md`, insert immediately after the `valheim/` bullet (the one ending `…there is no cron`):

```markdown
- `valheim-public/` — **vanilla** Valheim reachable from the internet (router forward UDP 2456–2457 →
  `192.168.130.157`), password-only. Same image as `valheim/`. `BEPINEX_ENABLED=false`, `MODS=""` and
  `MAX_PLAYERS="10"` are each load-bearing — any one wrong makes `start.sh` turn BepInEx on. The
  image's real listing knob is `PUBLIC_ENABLED`, not `PUBLIC`. `UPDATE_ON_START=true`: a restart *is*
  the game update. Never reuse the LAN password here. `tests/verify-public.sh` after every rollout
```

and immediately after the `mealie/` bullet:

```markdown
- `ddns/` — `favonia/cloudflare-ddns` keeping `valheim.arnoldtech.io` (DNS-only) on the home WAN IP,
  in a `restricted` namespace. Its token can edit the whole `arnoldtech.io` zone and is **not** the
  cert-manager token. `PROXIED` must stay `false` (Cloudflare's proxy drops game UDP) and
  `DELETE_ON_STOP` `false` (or every restart deletes the record)
```

- [ ] **Step 4: Append the spec correction**

Append to the end of `docs/superpowers/specs/2026-09-11-valheim-public-server-design.md`:

```markdown

---

**Correction (2026-09-11, implementation plan) — two details in §3 and §5 were wrong.**

1. **The token file mode is `0440`, not `0400`.** With `fsGroup: 1000` the mounted Secret file is
   owned by root and group-owned by 1000; `0400` leaves it readable by root only, and the
   updater runs as uid 1000. `0440` grants the group read.
2. **The updater is pinned by its linux/amd64 platform digest**,
   `sha256:0770cab737e58544f9b7a880ceaec41554797de2cc8eccdde7e77b788893c154`, not the tag's
   multi-arch index digest `61013368…` quoted in §3 — the same convention as the valheim image
   pin.
```

- [ ] **Step 5: Check the docs**

```powershell
Select-String -Path CLAUDE.md -Pattern '^- `(valheim|valheim-public|mumble|mealie|ddns|icarus|talos)/`' | ForEach-Object { $_.Line.Substring(0, 30) }
git check-ignore -v valheim-public/secret.yaml ddns/secret.yaml
```

Expected: the directory bullets in order `valheim/`, `valheim-public/`, `icarus/`, `mumble/`,
`mealie/`, `ddns/`, `talos/` — each **once** (a duplicate means a failed edit). And
`git check-ignore` prints the `**/secret.yaml` rule for **both** paths (proof the secrets can
never be committed).

- [ ] **Step 6: Commit**

```bash
git add valheim-public/README.md ddns/README.md CLAUDE.md docs/superpowers/specs/2026-09-11-valheim-public-server-design.md
git commit -F - <<'EOF'
Document the public valheim server and the DDNS updater

READMEs for both directories, CLAUDE.md bullets for the vanilla trio and the
DDNS settings that must not change, and a spec correction: the token file
mode is 0440 (0400 is unreadable by the non-root updater) and the updater is
pinned by its amd64 platform digest.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 6: Deploy and verify the game server

**Files:**
- Create (gitignored, never committed): `valheim-public/secret.yaml`
- Modify only if Step 5 needs the fallback: `valheim-public/deployment.yaml`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: a running, verified `valheim-public` at `192.168.130.157`. Task 7 needs its pod for the egress-IP read.

- [ ] **Step 1: Operator creates the Secret**

Ask the operator to run, and to type the password themselves (the agent must not choose, see or echo it):

```powershell
cd valheim-public
Copy-Item secret.yaml.template secret.yaml
notepad secret.yaml      # replace CHANGEME with the NEW password; save
cd ..
```

Then confirm it is ignored: `git status --short valheim-public/` must **not** list `secret.yaml`.

- [ ] **Step 2: Apply**

```powershell
cd valheim-public
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
cd ..
```

Expected: `namespace/valheim-public unchanged` (created in Task 3 — the one acceptable `unchanged`), and `created` for the other seven. Any other `unchanged` is a failure.

- [ ] **Step 3: Watch the first boot**

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c write-adminlist
kubectl rollout status deploy/valheim-public -n valheim-public --timeout=1500s
```

Expected: `[admin] wrote /valheim-saves/adminlist.txt:` followed by the header and `76561197963378853`; then `successfully rolled out`. SteamCMD takes several minutes on the empty PVC. A `CrashLoopBackOff` with `Missing configuration` in `--previous` logs is the known transient — wait up to 20 minutes, change nothing.

- [ ] **Step 4: Label the Longhorn volume**

```powershell
$pv = kubectl get pvc valheim-public-data -n valheim-public -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim-public=enabled" --overwrite
```

Expected: `volume.longhorn.io/pvc-… labeled`.

- [ ] **Step 5: Fallback, only if the pod did not start**

If Step 3 failed with an error from `init.sh` (`usermod`, `chown`, `Operation not permitted`) rather than the SteamCMD transient: remove the game container's `securityContext:` block (the `allowPrivilegeEscalation` + `drop: ["NET_RAW"]` lines) from `valheim-public/deployment.yaml`, add a comment in its place saying which error the image raised and on what date, apply, and re-run Step 3. Keep the pod-level `seccompProfile`, `automountServiceAccountToken` and `enableServiceLinks`. If the error persists without it, stop and report — do not remove further hardening without the operator. Skip this step when Step 3 passed.

- [ ] **Step 6: Second boot, to prove update-on-start**

The first boot always runs SteamCMD (the binary is absent), so it proves nothing about `UPDATE_ON_START`. Nobody can be connected yet (no router forward), but check in the same action anyway:

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c valheim --since=5m | Select-String "Got connection|Closing socket"; kubectl rollout restart deploy/valheim-public -n valheim-public
kubectl rollout status deploy/valheim-public -n valheim-public --timeout=1500s
```

Expected: no connection lines, then `successfully rolled out`.

- [ ] **Step 7: Run the verification script — it must now pass**

Run (Git Bash, repo root): `bash valheim-public/tests/verify-public.sh; echo "exit=$?"`

Expected: every line `ok`, `0 failed`, `exit=0`. Specifically `log: SteamCMD ran this boot` on this second boot, and `log: password is not the template value`.

- [ ] **Step 8: Re-run the negative control**

```bash
NS=valheim APP=valheim WORLD=TreeFellMeAgain LB_IP=192.168.130.155 PVC=valheim-data \
  bash valheim-public/tests/verify-public.sh; echo "exit=$?"
```

Expected: `exit=1` with the same six `FAIL` lines as Task 2 Step 3. (Proves nothing about the script changed its ability to fail.)

- [ ] **Step 9: Commit, only if Step 5 changed `deployment.yaml`**

```bash
git add valheim-public/deployment.yaml
git commit -F - <<'EOF'
Drop the game container's securityContext the image cannot run under

<one line: the init.sh error and date>

<attribution lines from the session's system reminder>
EOF
```

Otherwise nothing to commit.

---

### Task 7: Deploy and verify the DDNS updater

**Files:**
- Create (gitignored, never committed): `ddns/secret.yaml`

**Interfaces:**
- Consumes: Task 4; the running `valheim-public` pod from Task 6 (egress-IP read).
- Produces: a live DNS-only `valheim.arnoldtech.io` A record. Task 8 uses the name.

- [ ] **Step 1: Operator creates the token and the Secret**

Ask the operator to create the token exactly as in `ddns/secret.yaml.template`'s header, then:

```powershell
cd ddns
Copy-Item secret.yaml.template secret.yaml
notepad secret.yaml      # replace CHANGEME with the token; save
cd ..
```

`git status --short ddns/` must **not** list `secret.yaml`.

- [ ] **Step 2: Apply**

```powershell
cd ddns
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f deployment.yaml
cd ..
kubectl rollout status deploy/cloudflare-ddns -n ddns --timeout=120s
```

Expected: `namespace/ddns unchanged` (created in Task 4), `created` for the other three, then `successfully rolled out`. No `Warning: would violate PodSecurity`.

- [ ] **Step 3: Read the updater log**

```powershell
kubectl logs -n ddns deploy/cloudflare-ddns --tail=40
```

Expected: the token is accepted, the IPv4 is detected, and a record for `valheim.arnoldtech.io` is added (first run). No authentication or permission errors. If it reports it cannot read the token file, the `defaultMode`/`fsGroup` pair is wrong — fix `deployment.yaml` and re-apply.

- [ ] **Step 4: Run the verification script — it must pass**

Run (Git Bash, repo root): `bash ddns/tests/verify-ddns.sh; echo "exit=$?"`

Expected: all `ok`, `exit=0`. If only the resolution line fails right after creation, wait 60s (DoH caching) and re-run once.

- [ ] **Step 5: Negative control — the proxied apex must fail**

Run: `NAME=arnoldtech.io bash ddns/tests/verify-ddns.sh; echo "exit=$?"`

Expected: `FAIL  arnoldtech.io resolves publicly to the cluster egress IP …` with Cloudflare anycast addresses as `got`, and `exit=1`.

- [ ] **Step 6: Operator confirms the record in the dashboard**

Ask the operator to open Cloudflare → `arnoldtech.io` → DNS → Records and confirm `valheim` is an **A** record, **DNS only** (grey cloud), with the comment `managed by ddns/cloudflare-ddns (kubernetes-manifests-personal)`, and that no other record changed.

No commit (nothing tracked changed).

---

### Task 8: Router forward, internet join, and record the results

**Files:**
- Modify: `valheim-public/README.md` (append a "Verified" section)

**Interfaces:**
- Consumes: Tasks 6 and 7.
- Produces: the finished, verified service.

- [ ] **Step 1: Negative case first — no forward, no join**

Before the operator adds the forward, ask them to connect from a client **off** the home network (phone hotspot tethered to a PC, or a friend) with Join IP → `valheim.arnoldtech.io:2456`.

Expected: the join fails (cannot connect / times out). This proves the test path crosses the WAN rather than the LAN. If it **succeeds**, the client is not actually off the home network — fix the test setup before continuing.

- [ ] **Step 2: Operator adds the router forward**

WAN UDP 2456 → `192.168.130.157:2456` and WAN UDP 2457 → `192.168.130.157:2457`.

- [ ] **Step 3: Join by raw IP from off-network**

The same off-network client joins with Join IP → `<WAN IP from Task 1>:2456` and the password.

Expected: character loads into `TreeFellMeVanilla`. The server log shows it:

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c valheim --since=10m | Select-String "Got connection"
```

- [ ] **Step 4: Wrong password is refused**

The same client disconnects and rejoins with a deliberately wrong password.

Expected: refused at the password prompt.

- [ ] **Step 5: Join by hostname**

The same client joins with Join IP → `valheim.arnoldtech.io:2456`.

Expected: connects. **If Valheim rejects or cannot resolve the hostname** (the spec's one unverified item): record that friends must use the raw IP, and update the Joining section of `valheim-public/README.md` to say so and to say the ddns record is then informational. Do not write the IP itself into the README.

- [ ] **Step 6: LAN join by IP**

From the LAN: Join IP → `192.168.130.157:2456`. Expected: connects.

- [ ] **Step 7: CloudCasa and snapshots**

Ask the operator to confirm in the CloudCasa console that a policy covers namespace `valheim-public` **and** captures PVC data. After the next 11:15 UTC run (or next session), list snapshots:

```powershell
$pv = kubectl get pvc valheim-public-data -n valheim-public -o jsonpath='{.spec.volumeName}'
kubectl get snapshots.longhorn.io -n longhorn-system -o json | ConvertFrom-Json | ForEach-Object { $_.items } | Where-Object { $_.spec.volume -eq $pv } | ForEach-Object { $_.metadata.name }
```

Expected: at least one `valheim-public--<uuid>` name. If the job has not run yet, record it as pending in Step 8 rather than claiming it.

- [ ] **Step 8: Append the results to `valheim-public/README.md`**

Append, filling each line with what was actually observed (pass / fail / pending and the date — no IP addresses, no password):

```markdown
## Verified

2026-09-11, implementation:

- `tests/verify-public.sh`: <n> checks, 0 failed; negative control against `valheim/`: <n> failed, exit 1
- `../ddns/tests/verify-ddns.sh`: pass; apex negative control: exit 1
- Off-network join before the forward: <refused/timed out>
- Off-network join by IP after the forward: <pass>
- Wrong password: <refused>
- Join by hostname `valheim.arnoldtech.io`: <pass / not accepted by Valheim → raw IP in use>
- LAN join by `192.168.130.157`: <pass>
- Game container securityContext: <kept / dropped, with the error>
- CloudCasa policy covers `valheim-public` with PVC data: <confirmed by operator / pending>
- First Longhorn snapshot: <name, or pending the 11:15 UTC run>
```

- [ ] **Step 9: Commit**

```bash
git add valheim-public/README.md
git commit -F - <<'EOF'
Record the verification results for the public valheim server

<attribution lines from the session's system reminder>
EOF
```
