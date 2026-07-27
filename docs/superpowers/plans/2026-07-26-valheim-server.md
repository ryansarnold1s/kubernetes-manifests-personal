# Valheim Dedicated Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a LAN-only Valheim dedicated server to the `k8` Talos cluster as raw manifests in `valheim/`, with persistent world storage, hourly in-app backups, and a *verified* daily Longhorn snapshot.

**Architecture:** Namespace `valheim` holding a single-replica `Deployment` (`strategy: Recreate`) of `lloesche/valheim-server`, backed by two Longhorn ReadWriteOnce PVCs — one for world data, one for the game install. Exposed on the LAN through a MetalLB `LoadBalancer` pinned to `192.168.130.155` (UDP 2456-2457). Config lives in a ConfigMap; the server password lives in a gitignored Secret.

**Tech Stack:** Kubernetes 1.35, Talos 1.13, Longhorn CSI, MetalLB (L2), `kubectl` on Windows PowerShell.

**Spec:** `docs/superpowers/specs/2026-07-26-valheim-server-deployment-design.md`

## Global Constraints

- Every `kubectl` invocation must be prefixed with `$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"` — the default `~/.kube/config` points at Docker Desktop, not this cluster.
- All work happens on the existing branch `valheim-server`. Do **not** commit to `main`.
- Image is pinned to `lloesche/valheim-server:sha-732221f4d5b5`. Never use `latest`. No semver tags exist for this image.
- `SERVER_PASS` is `<the value in the valheim-secrets Secret>`. It must be at least 5 characters and must **not** appear anywhere inside `SERVER_NAME`, or the server refuses to start.
- The real `secret.yaml` is gitignored by the repo's existing `**/secret.yaml` rule and must never be committed. Only `secret.yaml.template` is tracked.
- `strategy: Recreate` is mandatory on the Deployment. `RollingUpdate` deadlocks on the ReadWriteOnce Longhorn volume.
- `terminationGracePeriodSeconds: 120` is mandatory. Valheim needs ~2 minutes to flush the world on SIGTERM; a shorter value corrupts worlds on every restart.
- No CPU limit on the container. CPU limits cause CFS throttling, which manifests as in-game rubber-banding.
- No liveness probe, ever. It would SIGKILL the server mid-world-save.
- **No added capabilities.** The cluster enforces Pod Security Admission at `baseline`
  by default for namespaces without PSA labels; `valheim` carries none. `SYS_NICE` was
  originally specified and is rejected outright — `violates PodSecurity "baseline:latest"`.
  Seven namespaces in this cluster (`cattle-system`, `enshrouded`, `kubevirt`,
  `longhorn-system`, `metallb-system`, `pihole`, `traefik`) do carry
  `pod-security.kubernetes.io/enforce: privileged` — privileged is the norm for infra
  namespaces here, not a two-off exception. Ruled 2026-07-26: drop the capability
  rather than add `valheim` to that list. Do not add a container-level `securityContext`
  to reinstate it.
- One file per resource kind in `valheim/`, matching the existing `mumble/` convention.

---

## File Structure

| File | Responsibility |
|---|---|
| `valheim/namespace.yaml` | Namespace `valheim` |
| `valheim/configmap.yaml` | All non-secret env (`valheim-config`) |
| `valheim/secret.yaml.template` | Tracked placeholder for `valheim-secrets` |
| `valheim/secret.yaml` | **Untracked.** Real password. Created locally in Task 1. |
| `valheim/pvc.yaml` | `valheim-data` (/config) and `valheim-server` (/opt/valheim) |
| `valheim/deployment.yaml` | The server workload |
| `valheim/service.yaml` | MetalLB LoadBalancer, UDP 2456-2457 |
| `valheim/recurringjob.yaml` | Longhorn `valheim-daily-snapshot` |
| `valheim/README.md` | Operating notes: join address, restore, scaling, re-labeling |

Resource names are fixed by the spec: Namespace/Deployment/Service all `valheim`; ConfigMap `valheim-config`; Secret `valheim-secrets` (key `server-password`); PVCs `valheim-data` and `valheim-server`; RecurringJob `valheim-daily-snapshot`.

---

### Task 1: Namespace, ConfigMap, and Secret

**Files:**
- Create: `valheim/namespace.yaml`
- Create: `valheim/configmap.yaml`
- Create: `valheim/secret.yaml.template`
- Create: `valheim/secret.yaml` (untracked)

**Interfaces:**
- Consumes: nothing.
- Produces: Namespace `valheim`; ConfigMap `valheim-config` (consumed via `envFrom` in Task 3); Secret `valheim-secrets` with key `server-password` (consumed via `secretKeyRef` in Task 3).

- [ ] **Step 1: Verify the namespace does not yet exist (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get ns valheim
```

Expected: FAIL — `Error from server (NotFound): namespaces "valheim" not found`

- [ ] **Step 2: Write `valheim/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: valheim
  labels:
    app: valheim
```

- [ ] **Step 3: Write `valheim/configmap.yaml`**

`BACKUPS_IF_IDLE: "false"` is a deliberate change from the image default of `true`; left at the default, an empty server writes identical backups around the clock and fills the PVC. `BACKUPS_IDLE_GRACE_PERIOD` is stated explicitly rather than relying on the implicit default, since it governs how long backups continue after the last player disconnects.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: valheim-config
  namespace: valheim
  labels:
    app: valheim
data:
  SERVER_NAME: "Deathsquito Support Group"
  WORLD_NAME: "TreeFellMeFirst"
  SERVER_PUBLIC: "false"
  SERVER_PORT: "2456"
  TZ: "America/Phoenix"
  UPDATE_CRON: "0 5 * * *"
  BACKUPS: "true"
  BACKUPS_ZIP: "true"
  BACKUPS_CRON: "0 * * * *"
  BACKUPS_MAX_AGE: "3"
  BACKUPS_IF_IDLE: "false"
  BACKUPS_IDLE_GRACE_PERIOD: "3600"
  ADMINLIST_IDS: ""
  PUID: "10000"
  PGID: "10000"
  STATUS_HTTP: "false"
```

- [ ] **Step 4: Write `valheim/secret.yaml.template`**

```yaml
# Copy to secret.yaml, set a real password, then apply.
# secret.yaml is gitignored by the repo-root **/secret.yaml rule - never commit it.
#
# Password rules enforced by the Valheim server:
#   - minimum 5 characters
#   - must NOT appear anywhere inside SERVER_NAME (see configmap.yaml)
apiVersion: v1
kind: Secret
metadata:
  name: valheim-secrets
  namespace: valheim
  labels:
    app: valheim
type: Opaque
stringData:
  server-password: "CHANGEME-min-5-chars"
```

- [ ] **Step 5: Create the real, untracked `valheim/secret.yaml`**

```powershell
Copy-Item "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim\secret.yaml.template" "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim\secret.yaml"
```

Then edit `valheim/secret.yaml` and replace `CHANGEME-min-5-chars` with `<the value in the valheim-secrets Secret>`.

- [ ] **Step 6: Verify git will ignore the real secret**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" check-ignore -v valheim/secret.yaml
```

Expected: PASS — prints `.gitignore:2:**/secret.yaml	valheim/secret.yaml`

If this prints nothing, **stop**. The secret is not ignored and must not be committed.

- [ ] **Step 7: Server-side dry-run all three manifests**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply --dry-run=server -f valheim/namespace.yaml -f valheim/configmap.yaml -f valheim/secret.yaml
```

Expected: three `... created (server dry run)` lines, no errors.

- [ ] **Step 8: Apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/namespace.yaml -f valheim/configmap.yaml -f valheim/secret.yaml
```

- [ ] **Step 9: Verify the check from Step 1 now passes**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get ns valheim; kubectl get configmap valheim-config -n valheim; kubectl get secret valheim-secrets -n valheim
```

Expected: namespace `Active`, ConfigMap with `DATA 16`, Secret of `TYPE Opaque` with `DATA 1`.

- [ ] **Step 10: Confirm the password survived the round-trip**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl get secret valheim-secrets -n valheim -o jsonpath='{.data.server-password}')))
```

Expected: `<the value in the valheim-secrets Secret>`

- [ ] **Step 11: Commit (tracked files only)**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/namespace.yaml valheim/configmap.yaml valheim/secret.yaml.template
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): add namespace, configmap, and secret template"
```

Then confirm the real secret was not staged:

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" show --stat --name-only HEAD
```

Expected: exactly three files, none named `secret.yaml`.

---

### Task 2: PersistentVolumeClaims

**Files:**
- Create: `valheim/pvc.yaml`

**Interfaces:**
- Consumes: Namespace `valheim` from Task 1.
- Produces: PVC `valheim-data` (mounted at `/config` in Task 3, snapshotted in Task 5) and PVC `valheim-server` (mounted at `/opt/valheim` in Task 3).

- [ ] **Step 1: Verify the PVCs do not exist (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pvc -n valheim
```

Expected: FAIL — `No resources found in valheim namespace.`

- [ ] **Step 2: Write `valheim/pvc.yaml`**

The `/config` PVC is named `valheim-data`, **not** `valheim-config`, to avoid colliding with the ConfigMap of that name. This mirrors how `mumble/` pairs `mumble-config` with `mumble-data`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-data
  namespace: valheim
  labels:
    app: valheim
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-server
  namespace: valheim
  labels:
    app: valheim
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 3: Dry-run**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply --dry-run=server -f valheim/pvc.yaml
```

Expected: two `created (server dry run)` lines.

- [ ] **Step 4: Apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/pvc.yaml
```

- [ ] **Step 5: Verify both PVCs reach `Bound`**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pvc -n valheim
```

Expected: PASS — both `valheim-data` and `valheim-server` show `STATUS Bound`, `CAPACITY 10Gi`, `STORAGECLASS longhorn`.

If either sits at `Pending` for more than 60 seconds, run `kubectl describe pvc -n valheim <name>` and resolve before continuing.

- [ ] **Step 6: Record the bound PV names — Task 5 needs them**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pvc -n valheim -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}{end}'
```

Expected: two lines mapping each PVC to a `pvc-<uuid>` volume name. Note the one for `valheim-data`.

- [ ] **Step 7: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/pvc.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): add longhorn PVCs for world data and game install"
```

---

### Task 3: Deployment

**Files:**
- Create: `valheim/deployment.yaml`

**Interfaces:**
- Consumes: ConfigMap `valheim-config` and Secret `valheim-secrets` (Task 1); PVCs `valheim-data` and `valheim-server` (Task 2).
- Produces: Deployment `valheim` with pod label `app: valheim` — the selector Task 4's Service targets.

- [ ] **Step 1: Verify no deployment exists (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get deploy -n valheim
```

Expected: FAIL — `No resources found in valheim namespace.`

- [ ] **Step 2: Write `valheim/deployment.yaml`**

No `runAsUser`/`runAsNonRoot` is set: this image's entrypoint **must** start as root to run supervisord, install via SteamCMD, and chown its volumes. Privilege is dropped internally to uid 10000 by `PUID`/`PGID` in the ConfigMap, so the long-lived network-facing process is unprivileged. `fsGroup: 10000` keeps the Longhorn volumes writable by that uid.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
  namespace: valheim
  labels:
    app: valheim
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: valheim
  template:
    metadata:
      labels:
        app: valheim
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        fsGroup: 10000
      containers:
      - name: valheim
        image: lloesche/valheim-server:sha-732221f4d5b5
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
            name: valheim-config
        env:
        - name: SERVER_PASS
          valueFrom:
            secretKeyRef:
              name: valheim-secrets
              key: server-password
        volumeMounts:
        - name: config
          mountPath: /config
        - name: server
          mountPath: /opt/valheim
        resources:
          requests:
            cpu: "2"
            memory: "5Gi"
          limits:
            memory: "8Gi"
      volumes:
      - name: config
        persistentVolumeClaim:
          claimName: valheim-data
      - name: server
        persistentVolumeClaim:
          claimName: valheim-server
```

- [ ] **Step 3: Dry-run**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply --dry-run=server -f valheim/deployment.yaml
```

Expected: `deployment.apps/valheim created (server dry run)`

- [ ] **Step 4: Apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/deployment.yaml
```

- [ ] **Step 5: Verify the pod reaches `Running`**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl rollout status deploy/valheim -n valheim --timeout=300s
```

Expected: PASS — `deployment "valheim" successfully rolled out`

- [ ] **Step 6: Watch the SteamCMD install finish**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl logs -n valheim deploy/valheim --tail=40 --follow
```

Expected: SteamCMD download progress, then `Success! App '896660' fully installed`, then Valheim startup lines ending in `Game server connected`. First boot pulls ~3GB and can take several minutes. Press `Ctrl+C` once you see the server report it is listening.

- [ ] **Step 7: Verify the world files were created with the exact configured name**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- ls -la /config/worlds_local
```

Expected: PASS — `TreeFellMeFirst.db` and `TreeFellMeFirst.fwl` are present.

If the filenames differ from `TreeFellMeFirst`, `WORLD_NAME` did not apply and the server generated a different world — fix the ConfigMap before anyone plays, because a world switch after the fact loses progress.

- [ ] **Step 8: Verify the game process dropped to uid 10000**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- ps -o user,pid,comm -e
```

Expected: a `valheim_server` process owned by uid `10000`, not `root`.

- [ ] **Step 9: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/deployment.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): add server deployment"
```

---

### Task 4: LoadBalancer Service

**Files:**
- Create: `valheim/service.yaml`

**Interfaces:**
- Consumes: pod label `app: valheim` from Task 3.
- Produces: Service `valheim` reachable at `192.168.130.155:2456/udp` — the address players enter under **Join IP**.

- [ ] **Step 1: Confirm `192.168.130.155` is still unclaimed (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get svc -A --field-selector spec.type=LoadBalancer -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip
```

Expected: `.150`, `.153`, `.154`, `.199` are listed; `.155` appears nowhere. If `.155` is taken, pick another free address in `192.168.130.150-199` and update both the manifest and the README.

- [ ] **Step 2: Write `valheim/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valheim
  namespace: valheim
  labels:
    app: valheim
  annotations:
    # CORRECTION: shipped as metallb.io/loadBalancerIPs — the universe.tf prefix below is
    # deprecated and warns on every reconcile under MetalLB v0.16.1.
    metallb.universe.tf/loadBalancerIPs: 192.168.130.155
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
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
    app: valheim
```

- [ ] **Step 3: Dry-run**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply --dry-run=server -f valheim/service.yaml
```

Expected: `service/valheim created (server dry run)`

- [ ] **Step 4: Apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/service.yaml
```

- [ ] **Step 5: Verify MetalLB assigned the pinned IP**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get svc valheim -n valheim
```

Expected: PASS — `EXTERNAL-IP` is exactly `192.168.130.155`, ports `2456:3xxxx/UDP,2457:3xxxx/UDP`.

If `EXTERNAL-IP` stays `<pending>`, run `kubectl describe svc valheim -n valheim` and check MetalLB events for an allocation conflict.

- [ ] **Step 6: Verify the Service has a live endpoint**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get endpointslice -n valheim -l kubernetes.io/service-name=valheim -o jsonpath='{range .items[*]}{.endpoints[*].addresses}{" ready="}{.endpoints[*].conditions.ready}{"\n"}{end}'
```

Expected: one pod IP with `ready=true`. An empty result means the Service selector does not match the pod labels.

- [ ] **Step 7: Verify reachability from a LAN host**

From a Windows machine on `192.168.130.0/24`:

```powershell
Test-NetConnection -ComputerName 192.168.130.155 -InformationLevel Detailed
```

Expected: `PingSucceeded : True`. (ICMP only proves MetalLB is answering for the address — UDP 2456 cannot be probed this way. The definitive test is Step 8.)

- [ ] **Step 8: Join the server from a Valheim client**

In Valheim: **Start Game → Select Character → Join Game → Join IP →** `192.168.130.155:2456`, password `<redacted — see valheim-secrets>`.

Expected: PASS — world `TreeFellMeFirst` loads and you spawn in.

- [ ] **Step 9: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/service.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): expose server via metallb loadbalancer on 192.168.130.155"
```

---

### Task 5: Longhorn daily snapshot — with proof it actually runs

**Files:**
- Create: `valheim/recurringjob.yaml`

**Interfaces:**
- Consumes: the PV name backing PVC `valheim-data`, recorded in Task 2 Step 6.
- Produces: RecurringJob `valheim-daily-snapshot` in `longhorn-system`, bound to the `valheim-data` volume via a group label.

**Why this task is unusually careful:** the existing `wger-daily-snapshot` job in this cluster targets `groups: [wger]` while **no volume carries the matching `recurring-job-group.longhorn.io/wger` label**. It has fired 109 times and produced zero snapshots, while looking perfectly healthy in `kubectl get`. A RecurringJob existing is *not* evidence that snapshots are being taken. This task therefore ends by proving a snapshot is really created.

- [ ] **Step 1: Verify no valheim recurring job exists (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get recurringjobs.longhorn.io -n longhorn-system
```

Expected: only `wger-daily-snapshot` is listed.

- [ ] **Step 2: Write `valheim/recurringjob.yaml`**

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: valheim-daily-snapshot
  namespace: longhorn-system
spec:
  cron: "0 11 * * *"
  task: snapshot
  groups:
  - valheim
  retain: 7
  concurrency: 1
```

- [ ] **Step 3: Apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/recurringjob.yaml
```

- [ ] **Step 4: Label the Longhorn Volume backing `valheim-data`**

The label goes on the Longhorn `Volume` CR, not the PVC. Longhorn does not propagate PVC labels to volumes — this is precisely the step that was missed for wger.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim=enabled" --overwrite
```

- [ ] **Step 5: Verify the label landed on the volume**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl get volumes.longhorn.io -n longhorn-system $pv -o jsonpath='{.metadata.labels}'
```

Expected: PASS — the output includes `"recurring-job-group.longhorn.io/valheim":"enabled"`.

- [ ] **Step 6: Temporarily accelerate the cron to prove execution**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl patch recurringjobs.longhorn.io valheim-daily-snapshot -n longhorn-system --type=merge -p '{\"spec\":{\"cron\":\"*/2 * * * *\"}}'
```

- [ ] **Step 7: Wait, then confirm a real snapshot was produced by the job**

Wait about 3 minutes, then:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl get snapshots.longhorn.io -n longhorn-system -o json | ConvertFrom-Json | ForEach-Object { $_.items } | Where-Object { $_.spec.volume -eq $pv } | ForEach-Object { "$($_.metadata.name)  created=$($_.metadata.creationTimestamp)  source=$($_.metadata.labels.'recurring-job.longhorn.io/source')" }
```

Expected: PASS — at least one snapshot whose name begins with `valheim--` (Longhorn names
snapshots `valheim--<uuid>`, not `valheim-daily-snapshot-<uuid>`).

**This is the gate.** If the list is empty, the job is not bound to the volume — recheck Step 5 before proceeding. Do not accept "the RecurringJob exists" as success.

- [ ] **Step 8: Restore the real schedule**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/recurringjob.yaml
```

Then confirm the cron is back to daily:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get recurringjobs.longhorn.io valheim-daily-snapshot -n longhorn-system -o jsonpath='{.spec.cron}'
```

Expected: `0 11 * * *`

- [ ] **Step 9: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/recurringjob.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): add verified daily longhorn snapshot job"
```

---

### Task 6: Verified startup and readiness probes

**Files:**
- Modify: `valheim/deployment.yaml`

**Interfaces:**
- Consumes: the running Deployment from Task 3.
- Produces: a readiness gate so MetalLB stops advertising the server during a multi-GB SteamCMD reinstall.

**Why this is a separate, empirical task:** the usual health signal (`STATUS_HTTP` / `/status.json`) is documented as functional only when `SERVER_PUBLIC=true`, which this deployment sets to `false`. An exec probe whose command is missing from the image would leave readiness permanently false, drop the Service's endpoints, and make the server unreachable while looking healthy. So the command gets verified against the live container *before* it is committed.

> 🛑 **CORRECTION — this task as written produced a broken probe. Do not copy the YAML below.**
> Step 1's check is one-sided: it only asks whether the command returns 0 while the server is
> up. `pgrep -f` matches full command lines, so `sh -c "pgrep -f valheim_server > /dev/null"`
> matches its own shell's argv and returns 0 **unconditionally** — including when no server
> exists. Step 1 therefore prints `PROBE_OK` no matter what, and the probe it approved could
> never fail. Both probes were decorative from `c82acc9` until fixed.
>
> The `> /dev/null` is what does it: without a redirect bash exec-replaces the shell, leaving
> nothing to self-match; with one, the shell survives.
>
> **Shipped fix** (see `valheim/deployment.yaml` and §8 of the design spec) — bracket the
> pattern, and raise the startup threshold to 120 since the 10-minute budget below had never
> actually been enforced:
>
> ```yaml
>         startupProbe:
>           exec:
>             command: ["sh", "-c", "pgrep -f '[v]alheim_server' > /dev/null"]
>           periodSeconds: 10
>           failureThreshold: 120
>         readinessProbe:
>           exec:
>             command: ["sh", "-c", "pgrep -f '[v]alheim_server' > /dev/null"]
>           periodSeconds: 30
>           failureThreshold: 3
> ```
>
> **Lesson for any future exec probe: verify the negative case.** Run the candidate against a
> process name that does not exist and require exit 1. Wrap it in a script file so no ancestor
> process argv contains the pattern, or the test self-matches the same way the probe does.

- [ ] **Step 1: Test the primary probe candidate against the running container**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- sh -c "pgrep -f valheim_server > /dev/null && echo PROBE_OK || echo PROBE_FAIL"
```

Expected: `PROBE_OK`. Record the result — it decides Step 3.

- [ ] **Step 2: Test the fallback candidate**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- sh -c "supervisorctl status valheim-server | grep -q RUNNING && echo PROBE_OK || echo PROBE_FAIL"
```

Expected: `PROBE_OK` or `PROBE_FAIL`. Used only if Step 1 failed.

- [ ] **Step 3: Add the probe block that verified `PROBE_OK`**

Insert into `valheim/deployment.yaml` inside the container spec, immediately after the `volumeMounts:` block and before `resources:`. (The container-level `securityContext:` block that previously anchored this insertion was removed when `SYS_NICE` was dropped — see Global Constraints.)

If **Step 1** returned `PROBE_OK`:

```yaml
        startupProbe:
          exec:
            command: ["sh", "-c", "pgrep -f valheim_server > /dev/null"]
          periodSeconds: 10
          failureThreshold: 60
        readinessProbe:
          exec:
            command: ["sh", "-c", "pgrep -f valheim_server > /dev/null"]
          periodSeconds: 30
          failureThreshold: 3
```

If Step 1 returned `PROBE_FAIL` and **Step 2** returned `PROBE_OK`:

```yaml
        startupProbe:
          exec:
            command: ["sh", "-c", "supervisorctl status valheim-server | grep -q RUNNING"]
          periodSeconds: 10
          failureThreshold: 60
        readinessProbe:
          exec:
            command: ["sh", "-c", "supervisorctl status valheim-server | grep -q RUNNING"]
          periodSeconds: 30
          failureThreshold: 3
```

If **both** returned `PROBE_FAIL`, add no probe. Leave `valheim/deployment.yaml` unchanged, note it in the README under Known Gaps, and end this task — an unverified probe is worse than none.

`failureThreshold: 60` at `periodSeconds: 10` allows 10 minutes for a cold SteamCMD install before the container is declared failed. No liveness probe is added, per the global constraints.

- [ ] **Step 4: Apply and confirm the rollout survives the probe**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/deployment.yaml; kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Expected: PASS — `deployment "valheim" successfully rolled out`.

Note this triggers a `Recreate` rollout: the old pod is fully terminated (up to 120s of world-save grace) before the new one starts. A short outage here is expected and correct.

- [ ] **Step 5: Verify the pod is `READY 1/1` and endpoints are still registered**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pods -n valheim; kubectl get endpointslice -n valheim -l kubernetes.io/service-name=valheim -o jsonpath='{range .items[*]}{.endpoints[*].conditions.ready}{"\n"}{end}'
```

Expected: PASS — pod `1/1 Running`, endpoint `ready=true`.

**If the pod is stuck at `0/1`, the probe is wrong.** Revert immediately:

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" checkout valheim/deployment.yaml
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f valheim/deployment.yaml
```

- [ ] **Step 6: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/deployment.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): add verified startup and readiness probes"
```

---

### Task 7: README and branch finalization

**Files:**
- Create: `valheim/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: operating documentation. No cluster changes.

- [ ] **Step 1: Write `valheim/README.md`**

````markdown
# Valheim Dedicated Server

LAN-only Valheim server on the `k8` Talos cluster.
Design: `../docs/superpowers/specs/2026-07-26-valheim-server-deployment-design.md`

## Joining

**Start Game → Select Character → Join Game → Join IP →** `192.168.130.155:2456`

The server is not listed in the community browser: `SERVER_PUBLIC=false`.
World: `TreeFellMeFirst`. Password lives in the `valheim-secrets` Secret.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `valheim` |
| `configmap.yaml` | Non-secret server config |
| `secret.yaml.template` | Template for the password Secret |
| `pvc.yaml` | `valheim-data` (/config), `valheim-server` (/opt/valheim) |
| `deployment.yaml` | The server |
| `service.yaml` | MetalLB LoadBalancer, UDP 2456-2457 |
| `recurringjob.yaml` | Longhorn daily snapshot |

`secret.yaml` is gitignored. Copy the template, set the password, apply.

## Applying

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
```

## Operating notes

- **Never lower `terminationGracePeriodSeconds` below 120.** Valheim needs ~2 minutes to
  flush the world on SIGTERM. A shorter value corrupts the world on every restart.
- **`strategy: Recreate` is required.** RollingUpdate deadlocks on the ReadWriteOnce volume.
- **No liveness probe, deliberately.** It would SIGKILL the server mid-save. Supervisord
  restarts the game process internally; the Deployment restarts the container.
- **No CPU limit, deliberately.** CFS throttling shows up in-game as rubber-banding.
- Server auto-updates nightly at 05:00 America/Phoenix (`UPDATE_CRON`), which restarts it
  and disconnects anyone online.

## Backups

Two layers:

1. **In-app** — hourly zipped backups in `/config/backups`, 3-day retention, skipped while
   idle. List them:
   `kubectl exec -n valheim deploy/valheim -- ls -la /config/backups`
2. **Longhorn snapshots** — `valheim-daily-snapshot`, cron `0 11 * * *` (11:00 UTC = 04:00
   America/Phoenix; Longhorn crons are not TZ-aware, unlike `UPDATE_CRON`/`BACKUPS_CRON`
   which honor `TZ`; Arizona has no DST so this mapping is stable year-round), retain 7, on
   the `valheim-data` volume only.

⚠️ **The snapshot job binds via a label on the Longhorn Volume, not the PVC.** If
`valheim-data` is ever deleted and recreated, the new volume will NOT be labeled and
snapshots silently stop. Re-apply:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim=enabled" --overwrite
```

Verify snapshots are genuinely being produced — a healthy-looking RecurringJob is not proof:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl get snapshots.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | Where-Object { $_.spec.volume -eq $pv } |
  ForEach-Object { $_.metadata.name }
```

Longhorn snapshots live on the same volume, so they protect against corruption and bad
writes, not against loss of the volume. Off-cluster DR is not configured.

## Access control

`SERVER_PUBLIC=false` is not access control — it only hides the server from the browser.
Anything that can route to `192.168.130.155:2456` and knows the password can join. There is
no source-IP allowlist; the router decides reachability.

NetworkPolicy cannot help here — this cluster runs Flannel, which does not enforce it. To
add a real allowlist, use `spec.loadBalancerSourceRanges` in `service.yaml` (enforced by
kube-proxy). If you do, list any VPN tunnel subnet explicitly, or VPN clients on `10.x` or
`100.64.x` will be locked out.

## Common tasks

Add admins — edit `ADMINLIST_IDS` in `configmap.yaml` (space-separated SteamID64), then:

```powershell
kubectl apply -f configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
```

Stop the server without deleting anything:

```powershell
kubectl scale deploy/valheim -n valheim --replicas=0
```

Follow logs:

```powershell
kubectl logs -n valheim deploy/valheim --follow
```

## Rollback

Remove the workload while keeping the world intact:

```powershell
kubectl delete -f deployment.yaml -f service.yaml
```

This leaves both PVCs bound, so the world survives any manifest mistake. Re-apply to
restore service.

To tear down completely — **this destroys the world** — delete the PVCs explicitly:

```powershell
kubectl delete -f deployment.yaml -f service.yaml -f recurringjob.yaml
kubectl delete -f pvc.yaml   # DESTRUCTIVE: storageClass longhorn has reclaimPolicy Delete
kubectl delete -f namespace.yaml
```

Take a manual Longhorn snapshot or copy `/config/worlds_local` off the volume first.
````

- [ ] **Step 2: Verify the working tree is clean and no secret is tracked**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" status --short
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" ls-files valheim/
```

Expected: `status` shows only untracked `valheim/secret.yaml` plus the new README; `ls-files` lists **no** `valheim/secret.yaml`.

- [ ] **Step 3: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/README.md
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "docs(valheim): add operating README"
```

- [ ] **Step 4: Final end-to-end verification**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get all,pvc -n valheim
```

Expected: Deployment `1/1`, pod `Running`, Service `valheim` with `EXTERNAL-IP 192.168.130.155`, both PVCs `Bound`.

- [ ] **Step 5: Review the branch before any merge or push**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" log --oneline main..valheim-server
```

Expected: the design-spec commit plus six or seven task commits. Merging to `main` and pushing to `origin` are **user decisions** — do not perform them unprompted.

---

## Out of scope — raise separately

- **`wger-daily-snapshot` is broken.** It targets `groups: [wger]` but no volume carries the
  `recurring-job-group.longhorn.io/wger` label. It has fired 109 times and produced zero
  snapshots; `wger-db-1` holds a single 2026-06-15 snapshot with no recurring-job source
  label. wger's Postgres has no snapshot protection despite appearing configured. The fix is
  the same volume-labeling step as Task 5 Step 4.
- **`gitea` has been stuck in `Init:0/3` for over two days**, so Gitea is down.
- **Four NetworkPolicy objects** (`gitea`, `cloudcasa-io`, `cattle-fleet-local-system`) are
  silently unenforced under Flannel and may be giving false assurance.
