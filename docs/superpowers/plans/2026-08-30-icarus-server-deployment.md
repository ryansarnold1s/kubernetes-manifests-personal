# ICARUS Dedicated Server Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a persistent ICARUS dedicated server on the `k8` Talos cluster for 2–6 LAN/VPN players, following the manifest conventions already established by `valheim/` and `mealie/`.

**Architecture:** Nine raw manifests in `icarus/`, applied with `kubectl`. A single-replica Deployment (`strategy: Recreate`) runs `mornedhels/icarus-server` pinned by digest, mounting two Longhorn PVCs with deliberately independent lifecycles — a 2-replica 10 Gi volume for irreplaceable prospect saves and a 1-replica 50 Gi volume for the disposable ~20 GB SteamCMD install. A MetalLB `LoadBalancer` publishes UDP 17777/27015 on the LAN. Two of the nine files deploy **outside** the `icarus` namespace, which is the `mealie/` precedent and carries the same README warning.

**Tech Stack:** Kubernetes v1.35.4, Talos v1.13.4, Longhorn v1.11.3, MetalLB (pool `vlan130-pool`), Flannel CNI, `kubectl` from PowerShell.

**Spec:** `docs/superpowers/specs/2026-08-30-icarus-server-deployment-design.md`

## Global Constraints

Exact values, copied from the spec. Every task inherits these.

- **Image:** `mornedhels/icarus-server:dev@sha256:63a559fee2c7e91469e11b74ac488ba2003541a027cbe4139cfb0b657dbfa6e4` — pinned by digest, `imagePullPolicy: IfNotPresent`. The `dev` tag is `1.0.0` plus the `#94` updater fix; do **not** substitute `1.0.0`/`latest`.
- **Ports:** `17777/UDP` (`game`), `27015/UDP` (`query`). No TCP.
- **LoadBalancer IP:** `192.168.130.156`, via `metallb.io/loadBalancerIPs`. **Never** `metallb.universe.tf/` — deprecated, logs a warning every reconcile.
- **`strategy: Recreate`** — mandatory. `RollingUpdate` starts a second pod against the same ReadWriteOnce volumes and deadlocks.
- **`terminationGracePeriodSeconds: 120`** — derived: the image's SIGTERM trap waits 60 s before escalating to KILL, and supervisord's `stopwaitsecs` is 90.
- **No `livenessProbe`.** A SIGKILL mid-save corrupts prospects; supervisord already restarts the program internally.
- **No `fsGroup`.** `scripts/bootstrap` already `chown -R`s both volumes as root each boot. Adding `fsGroup` makes kubelet do a *second* recursive pass over 50 Gi at every mount. If ever added it must be paired with `fsGroupChangePolicy: OnRootMismatch`.
- **No `securityContext` widening.** The namespace carries no PSA labels; cluster default `baseline` is the intended posture and the image is `baseline`-compatible.
- **No CPU limit.** CFS throttling shows up in-game as stutter. Memory `8Gi` request / `16Gi` limit; CPU `2` request, no limit.
- **No `UPDATE_CRON`, no `CLEANUP_CRON`.** Both absent means off — `initCrontab()` guards on `-n`. This is the **opposite** of the `lloesche/valheim-server` trap in CLAUDE.md; do not carry that fear over and do not add an empty-string key "for safety".
- **No `SERVER_IP`** — dead config, referenced by no script.
- **No `loadBalancerSourceRanges`** — nothing is port-forwarded. If exposure ever changes, that field is the enforcement point, **not** NetworkPolicy: Flannel does not enforce it.
- **`**/secret.yaml` is gitignored.** Commit `secret.yaml.template` only.
- Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it. Match the existing `valheim/` comment density.

## Prerequisites — already satisfied

Both gates from spec §4 were completed and verified on 2026-08-30 (see
`docs/superpowers/plans/2026-08-30-longhorn-capacity-reclamation.md`):

- `vm.max_map_count = 262144` on **all seven** nodes. Below 262144 the server OOMs under Wine with
  "Ran out of memory allocating 0 bytes" on a host with free memory.
- Longhorn headroom **420.3 GiB total**; three workers clear the ≥60 GiB gate (`mql-msp` 155.6,
  `uup-vn3` 145.8, `z9a-dpj` 67.3). `0ag-qr8` at 51.6 GiB does not, which is fine — the gate needs two.

Task 1 re-confirms both rather than trusting this paragraph.

## Cluster facts verified 2026-08-30 (do not re-derive)

- `192.168.130.156` is **free**. In use: `.150` traefik, `.153` enshrouded, `.154` mumble,
  `.155` valheim, `.199` pihole. Pool `vlan130-pool` = `192.168.130.150-192.168.130.199`.
- StorageClass `longhorn-single-replica` **does not exist** and must be created by this plan.
  Existing classes: `longhorn` (default), `longhorn-static`, `wazuh-storage`.
- Namespace `icarus` does not exist.
- Stock `longhorn` class parameters, to be cloned with only `numberOfReplicas` changed:

  ```
  backupTargetName=default   dataEngine=v1              dataLocality=disabled
  disableRevisionCounter=true  fromBackup=""            fsType=ext4
  numberOfReplicas=2         staleReplicaTimeout=30     unmapMarkSnapChainRemoved=ignored
  provisioner=driver.longhorn.io  reclaimPolicy=Delete
  volumeBindingMode=Immediate     allowVolumeExpansion=true
  ```

  Its two annotations — `longhorn.io/last-applied-configmap` and
  `storageclass.kubernetes.io/is-default-class` — **must not** be copied.

## Shell conventions

- All commands are `[PowerShell]`. `KUBECONFIG` is set via `.claude/settings.local.json`.
- **`cd icarus/` first.** Relative paths from the repo root silently no-op.
- `kubectl apply` must report `created`/`configured`. **`unchanged` is a silent failure**, almost
  always the wrong working directory.
- `kubectl get X --no-headers` prints `No resources found` as a line — filter blanks before
  `Measure-Object`.
- kubectl output is a string **array**; `-join "\`n"` before treating it as text.

## File Structure

```
icarus/
├── README.md              # operational doc; the two out-of-namespace warnings live here
├── namespace.yaml         # ns icarus, no PSA labels (deliberate)
├── storageclass.yaml      # ⚠ CLUSTER-SCOPED — outside the icarus namespace
├── configmap.yaml         # icarus-config: every ServerSettings.ini key pinned
├── secret.yaml.template   # real secret.yaml is gitignored
├── pvc.yaml               # icarus-data (10Gi, 2 replicas) + icarus-server (50Gi, 1 replica)
├── deployment.yaml        # the server
├── service.yaml           # LoadBalancer 192.168.130.156, UDP only
└── recurringjob.yaml      # ⚠ deploys into longhorn-system, NOT icarus
```

---

## Task 1: Pre-flight re-verification, namespace, and StorageClass

Establishes the cluster-scoped foundations. Separated from the workload because
`storageclass.yaml` outlives the `icarus/` directory — deleting `icarus/` would remove an object
other workloads may have adopted.

**Files:**
- Create: `icarus/namespace.yaml`
- Create: `icarus/storageclass.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: namespace `icarus`; StorageClass `longhorn-single-replica` (referenced by
  `icarus-server` in Task 2).

- [ ] **Step 1: Re-verify both §4 prerequisites and the free IP**

`[PowerShell]`
```powershell
# sysctl on all seven nodes -- expect 262144 everywhere
@('talos-c2v-wpu','talos-kwn-eng','talos-pha-6st','talos-mql-msp','talos-uup-vn3','talos-0ag-qr8','talos-z9a-dpj') | ForEach-Object {
  $n = $_
  $sel = if ($n -in @('talos-c2v-wpu','talos-kwn-eng','talos-pha-6st')) {
    @{ns='kube-system'; lbl='k8s-app=flannel'}      # NOT app=flannel -- matches zero pods
  } else {
    @{ns='longhorn-system'; lbl='app=longhorn-manager'}
  }
  $pod = kubectl get pod -n $sel.ns -l $sel.lbl --field-selector "spec.nodeName=$n" -o jsonpath='{.items[0].metadata.name}'
  "{0,-16} {1}" -f $n, (kubectl exec -n $sel.ns $pod -- cat /proc/sys/vm/max_map_count 2>$null)
}

# Longhorn headroom -- need >=2 workers above 60 GiB
kubectl get nodes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | ForEach-Object {
    $d = $_.status.diskStatus.PSObject.Properties.Value | Select-Object -First 1
    [pscustomobject]@{ Node=$_.metadata.name; HeadroomGiB=[math]::Round(($d.storageAvailable-$d.storageMaximum*0.25)/1GB,1) }
  } | Sort-Object HeadroomGiB | Format-Table -AutoSize

# .156 must be unclaimed
kubectl get svc -A -o json | ConvertFrom-Json | ForEach-Object { $_.items } |
  Where-Object { $_.spec.type -eq 'LoadBalancer' } |
  ForEach-Object { $_.status.loadBalancer.ingress } | ForEach-Object { $_.ip } | Sort-Object
```
Expected: `262144` on all seven; at least two workers ≥60 GiB; `192.168.130.156` **absent** from
the IP list. **If `max_map_count` reads `65530` anywhere, stop** — a full `talosctl apply-config`
has reverted the patch (see `talos/README.md`) and ICARUS will OOM on that node.

- [ ] **Step 2: Create `icarus/namespace.yaml`**

```yaml
# Deliberately no pod-security.kubernetes.io labels. The cluster default is baseline,
# which is the intended posture -- do NOT add `enforce: privileged`.
#
# The container starts as root on purpose: scripts/bootstrap runs groupmod/usermod and
# `chown -R icarus:icarus` over both volumes before supervisord drops the game to the
# icarus user (PUID/PGID 4711). Running as root is permitted under baseline; nothing
# here needs the namespace widened.
#
# The `ntsync` Wine accelerator was declined for exactly this reason -- exposing
# /dev/ntsync needs a hostPath, which baseline forbids. Wine falls back to esync/fsync.
apiVersion: v1
kind: Namespace
metadata:
  name: icarus
  labels:
    app: icarus
```

- [ ] **Step 3: Create `icarus/storageclass.yaml`**

```yaml
# ⚠️ CLUSTER-SCOPED. This file does NOT deploy into the icarus namespace.
#
# Deleting the icarus/ directory would delete a cluster-scoped object that another
# workload may have adopted -- the name is generic on purpose. Check for other PVCs
# using this class before removing it.
#
# This is the stock `longhorn` class with numberOfReplicas 2 -> 1, and WITHOUT its two
# annotations (longhorn.io/last-applied-configmap and
# storageclass.kubernetes.io/is-default-class). Every other parameter is identical.
#
# Why a separate class rather than editing `longhorn`: the stock class is reconciled by
# Longhorn itself and carries a last-applied-configmap annotation. Editing it would be
# reverted, and would change replica counts for every other workload on the cluster.
#
# dataLocality stays `disabled` deliberately. On a single-replica volume `best-effort`
# would trigger a full 50 GB local rebuild every time the pod moves to another node.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single-replica
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"
  dataEngine: "v1"
  disableRevisionCounter: "true"
  unmapMarkSnapChainRemoved: "ignored"
  backupTargetName: "default"
```

- [ ] **Step 4: Validate both against the API server before applying**

`[PowerShell]`
```powershell
cd icarus/
kubectl apply -f namespace.yaml --dry-run=server
kubectl apply -f storageclass.yaml --dry-run=server
```
Expected: both report `created (server dry run)`. A schema error surfaces here, not after a
half-applied change.

- [ ] **Step 5: Apply**

`[PowerShell]`
```powershell
kubectl apply -f namespace.yaml
kubectl apply -f storageclass.yaml
```
Expected: `namespace/icarus created`, `storageclass.storage.k8s.io/longhorn-single-replica created`.
**`unchanged` means the wrong working directory** — check `Get-Location` before anything else.

- [ ] **Step 6: Verify the class is correct AND is not the default**

`[PowerShell]`
```powershell
kubectl get storageclass
kubectl get storageclass longhorn-single-replica -o jsonpath='{.parameters.numberOfReplicas}'
kubectl get storageclass longhorn-single-replica -o jsonpath='{.metadata.annotations}'
```
Expected: `numberOfReplicas` = `1`; the annotations output is empty or lacks
`is-default-class`; and `longhorn` still shows `(default)` in the listing. **Negative case: if
`longhorn-single-replica` appears as `(default)`, stop and remove the annotation** — every PVC on
the cluster that omits `storageClassName` would silently become single-replica.

- [ ] **Step 7: Commit**

```bash
git add icarus/namespace.yaml icarus/storageclass.yaml
git commit -m "Add icarus namespace and single-replica Longhorn StorageClass

The class is the stock longhorn class with numberOfReplicas 1 and no default-class
annotation, for the disposable 50Gi SteamCMD install volume. It is cluster-scoped
and deliberately generically named, so it is called out as such in the file header."
```

---

## Task 2: Storage — the two PVCs

**Files:**
- Create: `icarus/pvc.yaml`

**Interfaces:**
- Consumes: namespace `icarus`, StorageClass `longhorn-single-replica` (Task 1).
- Produces: PVCs `icarus-data` and `icarus-server`, mounted by the Deployment in Task 4 and
  labelled for snapshots in Task 8.

- [ ] **Step 1: Create `icarus/pvc.yaml`**

```yaml
# /home/icarus/drive_c/icarus -- prospect saves, ServerSettings.ini, Engine.ini.
# THE IRREPLACEABLE DATA. Deleting this PVC destroys every prospect. See README.md
# (Restore/Rollback) before ever doing so.
#
# 2 replicas (the stock `longhorn` class default) precisely because this is the half
# that cannot be re-downloaded.
#
# Split from icarus-server deliberately: a Longhorn snapshot restore of the saves must
# not also roll back the game binaries, and the install must be wipeable to force a
# clean reinstall without ever risking a save. A single combined PVC was rejected for
# exactly that reason.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: icarus-data
  namespace: icarus
  labels:
    app: icarus
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
# /opt/icarus -- the ~20 GB SteamCMD install. DISPOSABLE: deleting this PVC only forces
# a clean reinstall on the next boot and does not touch any prospect.
#
# 50Gi, not 20Gi: `doUpdate()` calls `downloadIcarus` twice, so an update transiently
# needs up to 2x the install size on the volume.
#
# longhorn-single-replica, not longhorn: replicating a re-downloadable install buys
# nothing and would cost another 20+ GB of Longhorn headroom on a second node.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: icarus-server
  namespace: icarus
  labels:
    app: icarus
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn-single-replica
  resources:
    requests:
      storage: 50Gi
```

- [ ] **Step 2: Validate, then apply**

`[PowerShell]`
```powershell
cd icarus/
kubectl apply -f pvc.yaml --dry-run=server
kubectl apply -f pvc.yaml
```
Expected: both PVCs `created`.

- [ ] **Step 3: Verify both bound**

`[PowerShell]`
```powershell
kubectl get pvc -n icarus
```
Expected: `icarus-data` `Bound` 10Gi, `icarus-server` `Bound` 50Gi. `volumeBindingMode` is
`Immediate`, so they bind without waiting for a pod. A `Pending` PVC here means no node had
enough Longhorn headroom — re-check Task 1 Step 1.

- [ ] **Step 4: Verify the replica counts actually differ**

This is the negative case for Task 1. The class name proves nothing on its own.

`[PowerShell]`
```powershell
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -like 'icarus-*' } |
  Select-Object @{n='PVC';e={$_.status.kubernetesStatus.pvcName}},
                @{n='Volume';e={$_.metadata.name}},
                @{n='Replicas';e={$_.spec.numberOfReplicas}},
                @{n='SizeGi';e={[math]::Round($_.spec.size/1GB,0)}} |
  Format-Table -AutoSize
```
Expected: `icarus-data` → **2** replicas, `icarus-server` → **1**. If `icarus-server` shows 2, the
PVC bound to the wrong class; delete and recreate it before continuing — this is cheap now and
expensive after a 20 GB install lands on it.

Record the two Longhorn **Volume** names (`pvc-<uuid>`) from this output. Task 8 needs the
`icarus-data` one.

- [ ] **Step 5: Commit**

```bash
git add icarus/pvc.yaml
git commit -m "Add icarus data and install PVCs

icarus-data is 10Gi on longhorn (2 replicas) and holds the irreplaceable prospect
saves. icarus-server is 50Gi on longhorn-single-replica and holds the disposable
SteamCMD install, sized for the 2x transient the double downloadIcarus call needs."
```

---

## Task 3: Configuration — ConfigMap and Secret

Every `ServerSettings.ini` key is pinned explicitly, **including ones sitting at their
first-boot value**. Per spec §2.3 item 5, those values come from a heredoc that runs once — not
from env-var defaults — so an unpinned key is silently unmanaged rather than defaulted.

**Files:**
- Create: `icarus/configmap.yaml`
- Create: `icarus/secret.yaml.template`
- Create (local only, **never committed**): `icarus/secret.yaml`

**Interfaces:**
- Consumes: namespace `icarus`.
- Produces: ConfigMap `icarus-config` (consumed via `envFrom` in Task 4); Secret `icarus-secrets`
  with keys `server-password` and `admin-password` (consumed via `secretKeyRef` in Task 4).

- [ ] **Step 1: Create `icarus/configmap.yaml`**

```yaml
# Every ServerSettings.ini key is pinned here, including ones whose value equals the
# image's first-boot default. That is deliberate and NOT redundant:
# icarus-bootstrap writes ServerSettings.ini from a heredoc ONLY if the file does not
# exist, then applies one `sed` per setting guarded by a non-empty test. Most keys have
# NO env-var fallback in scripts/defaults -- SERVER_SHUTDOWN_IF_NOT_JOINED,
# SERVER_SHUTDOWN_IF_EMPTY, SERVER_ALLOW_NON_ADMINS_LAUNCH, SERVER_ALLOW_NON_ADMINS_DELETE
# and SERVER_RESUME_PROSPECT among them. An unpinned key is therefore unmanaged, not
# defaulted, and whatever the heredoc wrote on first boot stands forever.
#
# Removing a key from this ConfigMap does NOT revert the setting -- it only stops
# enforcing it. The file on the PVC is the source of truth for what the server runs.
apiVersion: v1
kind: ConfigMap
metadata:
  name: icarus-config
  namespace: icarus
  labels:
    app: icarus
data:
  SERVER_NAME: "Arnold Icarus Server"
  # Also the verification sentinel. Every OTHER pinned value equals the first-boot
  # heredoc default and would read back correct even if `sed` never ran; 6 differs from
  # the default, so MaxPlayers=6 in the .ini is the only line proving the ConfigMap was
  # actually applied. Do not "tidy" this to the default.
  SERVER_MAX_PLAYERS: "6"
  SERVER_PORT: "17777"
  # Also the port checkServerEmpty() queries. The image's a2s fallback port is 15637 --
  # Enshrouded's, left over from ported code -- which is harmless only because this is set.
  SERVER_QUERYPORT: "27015"
  # Seconds before a started prospect returns to the lobby if nobody joins.
  SERVER_SHUTDOWN_IF_NOT_JOINED: "300.000000"
  # Seconds after the last player leaves.
  SERVER_SHUTDOWN_IF_EMPTY: "60.000000"
  SERVER_ALLOW_NON_ADMINS_LAUNCH: "True"
  # Non-admins must not be able to delete prospects.
  SERVER_ALLOW_NON_ADMINS_DELETE: "False"
  # Resume the last prospect after a restart.
  SERVER_RESUME_PROSPECT: "True"
  GAME_BRANCH: "public"
  # Written to Engine.ini under [OnlineSubsystemSteam], not ServerSettings.ini.
  ASYNC_TASK_TIMEOUT: "60"
  # Image defaults. Both volumes are chowned to this uid/gid at every boot.
  PUID: "4711"
  PGID: "4711"
  # Update at pod start. Combined with the absence of UPDATE_CRON below, this makes
  # `kubectl rollout restart deploy/icarus -n icarus` the deliberate update mechanism.
  UPDATE_SKIP: "false"
  TZ: "America/Phoenix"
  # Pinned so a future base-image change cannot silently alter log volume.
  WINEDEBUG: "fixme-all"
  #
  # ── Deliberately ABSENT keys. Each is omitted for a reason; do not add them. ──
  #
  # UPDATE_CRON  -- absent means OFF. initCrontab() guards on `-n`, so an unset variable
  #   creates no cron. This is the OPPOSITE of the lloesche/valheim-server trap recorded in
  #   the repo CLAUDE.md, where UPDATE_CRON uses ${VAR-default} and an unset variable
  #   silently enables a 15-minute cron. Do NOT carry that fear over and add an empty-string
  #   key here "to be safe" -- it is unnecessary. Scheduled updates are declined because
  #   checkServerEmpty() FAILS OPEN: it prints `null` on any exception and the caller treats
  #   null as empty, so a failed query permits an update that stops the server while people
  #   are playing.
  # CLEANUP_CRON -- absent means OFF, same guard. icarus-cleanup MOVES prospect saves; it is
  #   not run unattended against irreplaceable data.
  # CLEANUP_DAYS / CLEANUP_DELETE_BACKUPS / CLEANUP_PRUNE_FOLDER / CLEANUP_EXCLUDES --
  #   meaningless without CLEANUP_CRON.
  # SERVER_IP -- dead config. It appears only in scripts/defaults and is referenced by no
  #   other script. The upstream README describes it as driving the empty-check; that is wrong.
  # STEAM_API_KEY -- deprecated.
  # STEAMCMD_ARGS -- the default is correct.
```

- [ ] **Step 2: Create `icarus/secret.yaml.template`**

```yaml
# Copy to secret.yaml, set real passwords, then apply.
# secret.yaml is gitignored by the repo-root **/secret.yaml rule -- never commit it.
#
# ⚠️ Both passwords are written IN PLAINTEXT to ServerSettings.ini on the icarus-data
# PVC. They are therefore present in every Longhorn snapshot and every CloudCasa backup.
# Treat a snapshot as containing them.
#
# ⚠️ Blanking a password here does NOT clear it from the .ini. Each `sed` is guarded by a
# non-empty test, so an empty value is indistinguishable from an unset one and the old
# password simply stays in the file. Clearing a password means editing
# ServerSettings.ini on the PVC directly -- see README.md.
#
#   server-password -> SERVER_PASSWORD       -> JoinPassword=
#   admin-password  -> SERVER_ADMIN_PASSWORD -> AdminPassword=
apiVersion: v1
kind: Secret
metadata:
  name: icarus-secrets
  namespace: icarus
  labels:
    app: icarus
type: Opaque
stringData:
  server-password: "CHANGEME-join-password"
  admin-password: "CHANGEME-admin-password"
```

- [ ] **Step 3: Create the real `icarus/secret.yaml` and confirm git ignores it**

`[PowerShell]`
```powershell
cd icarus/
Copy-Item secret.yaml.template secret.yaml
# Edit secret.yaml and set two real, distinct passwords before applying.
```

Then prove the ignore rule covers it — do not assume:
```powershell
git check-ignore -v icarus/secret.yaml
git status --short icarus/
```
Expected: `check-ignore` prints the matching `.gitignore` rule (`**/secret.yaml`), and
`git status` does **not** list `secret.yaml`. **If it appears as untracked, stop and fix
`.gitignore` before committing anything.**

- [ ] **Step 4: Apply both**

`[PowerShell]`
```powershell
kubectl apply -f configmap.yaml --dry-run=server
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
```
Expected: `configmap/icarus-config created`, `secret/icarus-secrets created`.

- [ ] **Step 5: Verify the ConfigMap contents and the Secret's shape**

`[PowerShell]`
```powershell
kubectl get configmap icarus-config -n icarus -o jsonpath='{.data.SERVER_MAX_PLAYERS}'
kubectl get configmap icarus-config -n icarus -o json | ConvertFrom-Json |
  ForEach-Object { $_.data.PSObject.Properties.Name } | Sort-Object
kubectl get secret icarus-secrets -n icarus -o jsonpath='{.metadata.name}'
```
Expected: `6`; a 16-key list containing **no** `UPDATE_CRON`, `CLEANUP_CRON` or `SERVER_IP`; and
the secret's name echoed back.

**Note:** reading Secret *values* with `kubectl get/describe secret` is hard-denied by policy on
this workstation. Verify the Secret functionally in Task 7 by checking that `JoinPassword` is
non-empty in the `.ini` — do not try to list its keys.

- [ ] **Step 6: Commit — template only**

```bash
git add icarus/configmap.yaml icarus/secret.yaml.template
git status --short   # confirm icarus/secret.yaml is NOT staged
git commit -m "Add icarus ConfigMap and secret template

Every ServerSettings.ini key is pinned, including ones at their first-boot value:
most have no env-var fallback, so an unpinned key is unmanaged rather than
defaulted. SERVER_MAX_PLAYERS=6 doubles as the verification sentinel because it
is the only pinned value that differs from the heredoc default.

UPDATE_CRON and CLEANUP_CRON are deliberately absent -- unlike the valheim image,
absent genuinely means off here."
```

---

## Task 4: Deployment and first boot

The long one. A first boot on an empty install PVC runs `wineboot`, `pip3 install python-a2s`,
a ~20 GB SteamCMD download, and then — because `doUpdate()` calls `downloadIcarus` twice — a full
re-validate of all 20 GB.

**Files:**
- Create: `icarus/deployment.yaml`

**Interfaces:**
- Consumes: PVCs `icarus-data`/`icarus-server` (Task 2); ConfigMap `icarus-config` and Secret
  `icarus-secrets` (Task 3).
- Produces: Deployment `icarus` with pod label `app: icarus`, which `service.yaml` selects in
  Task 6.

- [ ] **Step 1: Create `icarus/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: icarus
  namespace: icarus
  labels:
    app: icarus
spec:
  replicas: 1
  strategy:
    # Recreate is mandatory, not stylistic: RollingUpdate would start a second pod
    # claiming the same ReadWriteOnce Longhorn volumes and deadlock on the mount.
    type: Recreate
  selector:
    matchLabels:
      app: icarus
  template:
    metadata:
      labels:
        app: icarus
    spec:
      # Derived, not guessed: the icarus-server script's SIGTERM trap sends TERM and waits
      # 60s before escalating to KILL, and supervisord's stopwaitsecs is 90. 120 leaves
      # headroom over both. Lowering this risks SIGKILL mid-save.
      terminationGracePeriodSeconds: 120
      #
      # Deliberately NO securityContext.fsGroup. scripts/bootstrap already runs
      # `chown -R icarus:icarus /opt/icarus /home/icarus` as root on every boot, so fsGroup
      # would make kubelet perform a SECOND recursive ownership pass over a 50Gi volume at
      # every single mount. If it is ever added it MUST be paired with
      # fsGroupChangePolicy: OnRootMismatch. Its absence is intentional -- do not "fix" it.
      containers:
      - name: icarus
        # `dev` pinned by digest. dev is 1.0.0 plus the #94 fix (steam update aborts) plus
        # base-image patches; the 1.0.0/latest tag does NOT contain that updater fix.
        # Pinned by digest, so the tag being mutable upstream does not matter.
        image: mornedhels/icarus-server:dev@sha256:63a559fee2c7e91469e11b74ac488ba2003541a027cbe4139cfb0b657dbfa6e4
        imagePullPolicy: IfNotPresent
        ports:
        - name: game
          containerPort: 17777
          protocol: UDP
        - name: query
          containerPort: 27015
          protocol: UDP
        envFrom:
        - configMapRef:
            name: icarus-config
        env:
        - name: SERVER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: icarus-secrets
              key: server-password
        - name: SERVER_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: icarus-secrets
              key: admin-password
        volumeMounts:
        # The Wine prefix is /home/icarus itself; only the game's UserDir below it is
        # persisted. drive_c/windows and the registry live on the container layer and are
        # rebuilt by `wineboot --init` every boot. That is intentional -- it keeps this PVC
        # small, and means the Wine prefix is not in any backup and does not need to be.
        - name: data
          mountPath: /home/icarus/drive_c/icarus
        - name: server
          mountPath: /opt/icarus
        # Deliberately NO livenessProbe: it would SIGKILL the server mid-save and corrupt a
        # prospect. supervisord already restarts the program internally (autorestart=true,
        # startretries=10), and the Deployment restarts the container if supervisord exits.
        #
        # `supervisorctl status` is the image's own definition of alive and is robust to
        # however Wine names the process. The alternative, pgrep, MUST keep the bracketed
        # form '[I]carusServer-Win64-Shipping' -- `pgrep -f` matches full command lines, so
        # a bare pattern matches the probe's own shell and yields a probe that can never
        # fail. This exact bug shipped in valheim/ once. Whichever form is used is tested
        # against a STOPPED server before it is trusted (see README.md).
        startupProbe:
          exec:
            command: ["sh", "-c", "supervisorctl status icarus-server | grep -q RUNNING"]
          periodSeconds: 15
          # 400 x 15s ~= 100 minutes. A first boot on an empty install PVC must run wineboot,
          # pip3 install python-a2s, and a ~20GB SteamCMD pull -- and because doUpdate calls
          # downloadIcarus twice, it then re-validates all 20GB inside this same window.
          failureThreshold: 400
        readinessProbe:
          exec:
            command: ["sh", "-c", "supervisorctl status icarus-server | grep -q RUNNING"]
          periodSeconds: 30
          failureThreshold: 3
        # No CPU limit: CFS throttling shows up in-game as stutter, same reasoning as valheim.
        # The 8Gi memory request also excludes the three 8GB control-plane nodes from the
        # scheduler without needing explicit affinity rules.
        resources:
          requests:
            cpu: "2"
            memory: "8Gi"
          limits:
            memory: "16Gi"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: icarus-data
      - name: server
        persistentVolumeClaim:
          claimName: icarus-server
```

- [ ] **Step 2: Validate before applying**

`[PowerShell]`
```powershell
cd icarus/
kubectl apply -f deployment.yaml --dry-run=server
```
Expected: `deployment.apps/icarus created (server dry run)`.

- [ ] **Step 3: Apply**

`[PowerShell]`
```powershell
kubectl apply -f deployment.yaml
```
Expected: `deployment.apps/icarus created`.

**Do not add `kubectl rollout restart` after this.** A Deployment apply rolls on its own; adding a
restart starts a second Recreate cycle that races the first.

- [ ] **Step 4: Confirm it scheduled onto a node with headroom**

`[PowerShell]`
```powershell
kubectl get pod -n icarus -o wide
kubectl describe pod -n icarus -l app=icarus | Select-String -Pattern 'Node:|Events' -Context 0,12
```
Expected: `Pending` briefly, then `Running` with `0/1` ready on one of `talos-mql-msp`,
`talos-uup-vn3` or `talos-z9a-dpj`. **`Pending` with `Insufficient memory` means it tried a
control-plane node — that is expected and self-correcting**, but `Pending` with
`FailedScheduling ... volume node affinity conflict` is not: it means the install PVC bound to a
node that cannot also satisfy the 8Gi request.

- [ ] **Step 5: Watch the first boot to completion**

This takes up to ~100 minutes and is dominated by the double 20 GB SteamCMD pass. Run it in the
background rather than blocking:

`[PowerShell]`
```powershell
# Progress: install volume filling up
kubectl exec -n icarus deploy/icarus -- df -h /opt/icarus
# Progress: what the bootstrap is doing right now
kubectl logs -n icarus deploy/icarus --tail=30
```
Expected end state: `kubectl get pod -n icarus` shows `1/1 Running`, and `df -h /opt/icarus`
settles near ~20 GB used of 50 Gi.

**Do not conclude failure from a quiet first minute** — `wineboot` and the SteamCMD handshake
produce little output before the download starts. Judge by `df` growing, not by log volume.

- [ ] **Step 6: Confirm the prerequisite actually holds inside the pod**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- cat /proc/sys/vm/max_map_count
```
Expected: `262144`. This is the in-pod confirmation of the §4.1 gate. `65530` here means the pod
landed on a node whose Talos patch was reverted, and the server will OOM under Wine with
"Ran out of memory allocating 0 bytes" regardless of free memory.

- [ ] **Step 7: Commit**

```bash
git add icarus/deployment.yaml
git commit -m "Deploy icarus server, pinned by digest

Recreate strategy and a 120s grace period, both derived from the image's own
shutdown behaviour rather than chosen stylistically. No livenessProbe and no
fsGroup, each for a documented reason in the file. 8Gi request excludes the
8GB control-plane nodes without explicit affinity."
```

---

## Task 5: Prove the readiness probe can fail

Spec §12 calls this out specifically: *"an always-passing probe has shipped in this repo before."*
A probe only ever observed passing has not been verified. This task exists solely to observe it
failing, and it must happen before the Service starts routing players.

**Files:** none modified unless the probe turns out to be broken.

**Interfaces:**
- Consumes: the running Deployment from Task 4.
- Produces: evidence the probe discriminates; the Service in Task 6 depends on it to gate traffic.

- [ ] **Step 1: Record the passing state**

`[PowerShell]`
```powershell
kubectl get pod -n icarus -l app=icarus
kubectl exec -n icarus deploy/icarus -- supervisorctl status icarus-server
```
Expected: pod `1/1`, and `icarus-server RUNNING`.

- [ ] **Step 2: Stop the game process inside the container**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- supervisorctl stop icarus-server
kubectl exec -n icarus deploy/icarus -- supervisorctl status icarus-server
```
Expected: `icarus-server STOPPED`. The **container** stays up — supervisord is still PID 1, which
is exactly why there is no livenessProbe to trip here.

- [ ] **Step 3: Confirm readiness actually flips**

Readiness is `periodSeconds: 30`, `failureThreshold: 3`, so allow ~90–120 s.

`[PowerShell]`
```powershell
kubectl get pod -n icarus -l app=icarus -w
```
Expected: **`READY` goes from `1/1` to `0/1`.** This is the whole point of the task.

**If it stays `1/1` after three periods, the probe is broken — stop and fix it.** The likely cause
is `supervisorctl` exiting 0 while printing a non-RUNNING state, in which case switch both probes
to the bracketed pgrep form and re-run this task from Step 1:

```yaml
          command: ["sh", "-c", "pgrep -f '[I]carusServer-Win64-Shipping' > /dev/null"]
```

Keep the brackets and the `> /dev/null`. Without the redirect, bash exec-replaces itself and there
is nothing to self-match, which is precisely why the bare form passes a manual smoke test and
still never fails.

- [ ] **Step 4: Restore and confirm it recovers**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- supervisorctl start icarus-server
kubectl get pod -n icarus -l app=icarus -w
```
Expected: back to `1/1`. Both directions are now observed — the probe reports not-ready when the
server is down and ready when it is up.

- [ ] **Step 5: Commit only if the probe had to change**

```bash
git add icarus/deployment.yaml
git commit -m "Switch icarus probes to bracketed pgrep

supervisorctl exits 0 even when the program is not RUNNING, so the original
probe could never fail. Verified against a stopped server: readiness now flips
to 0/1 and recovers."
```
If the probe was already correct, record the verification in Task 9's README instead and skip this
commit.

---

## Task 6: Service and LAN connectivity

**Files:**
- Create: `icarus/service.yaml`

**Interfaces:**
- Consumes: pods labelled `app: icarus` (Task 4), proven to gate correctly (Task 5).
- Produces: `192.168.130.156:17777/udp` reachable on the LAN.

- [ ] **Step 1: Create `icarus/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: icarus
  namespace: icarus
  labels:
    app: icarus
  annotations:
    # metallb.io/ is the current domain. The old metallb.universe.tf/ prefix still works
    # but logs a deprecatedAnnotation warning on every reconcile.
    # .156 chosen as the next free address after valheim (.155); pool vlan130-pool is
    # 192.168.130.150-199.
    metallb.io/loadBalancerIPs: 192.168.130.156
spec:
  type: LoadBalancer
  # Preserves the client source IP, which the Steam query protocol needs.
  externalTrafficPolicy: Local
  #
  # Deliberately NO loadBalancerSourceRanges: nothing is port-forwarded to this service, so
  # there is no untrusted path to restrict. If this server is ever exposed to the internet,
  # loadBalancerSourceRanges is the enforcement point -- NOT NetworkPolicy. The CNI is
  # Flannel, which does not enforce NetworkPolicy at all: a NetworkPolicy here would be
  # silently inert and would read as protection that does not exist.
  ports:
  - name: game
    port: 17777
    targetPort: 17777
    protocol: UDP
  - name: query
    port: 27015
    targetPort: 27015
    protocol: UDP
  selector:
    app: icarus
```

- [ ] **Step 2: Validate, then apply**

`[PowerShell]`
```powershell
cd icarus/
kubectl apply -f service.yaml --dry-run=server
kubectl apply -f service.yaml
```

- [ ] **Step 3: Verify the requested IP was actually granted**

`[PowerShell]`
```powershell
kubectl get svc -n icarus
kubectl get svc icarus -n icarus -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```
Expected: exactly `192.168.130.156`. **MetalLB falls back to auto-assigning a different address
from the pool if the requested one is taken** — the annotation is a request, not a guarantee. A
different IP here means .156 was claimed between Task 1 and now.

- [ ] **Step 4: Verify endpoints exist — the probe gates this**

`[PowerShell]`
```powershell
kubectl get endpointslice -n icarus -l kubernetes.io/service-name=icarus -o json |
  ConvertFrom-Json | ForEach-Object { $_.items } |
  Select-Object @{n='addresses';e={($_.endpoints.addresses) -join ','}},
                @{n='ready';e={($_.endpoints.conditions.ready) -join ','}}
```
Expected: one address, `ready = True`. An empty endpoint list means readiness is failing — go back
to Task 5 rather than debugging the Service.

- [ ] **Step 5: Connect a real client**

From a LAN/VPN machine, add `192.168.130.156:17777` in ICARUS's server browser, join with the
`server-password`, and start a prospect.

Expected: the server appears, accepts the password, and a prospect loads. **This is the only check
that exercises the whole path** — MetalLB, `externalTrafficPolicy: Local`, UDP, the query port and
the game's own auth.

- [ ] **Step 6: Commit**

```bash
git add icarus/service.yaml
git commit -m "Expose icarus on 192.168.130.156 over UDP

LAN/VPN only, no loadBalancerSourceRanges because nothing is port-forwarded.
The file records that sourceRanges -- not NetworkPolicy -- is the enforcement
point if that ever changes, since Flannel does not enforce NetworkPolicy."
```

---

## Task 7: Verify the configuration actually reached the server

The ConfigMap being applied proves nothing about the `.ini`. `icarus-bootstrap` only `sed`s keys
whose env var is non-empty, and the file is only created from the heredoc if absent.

**Files:** none modified.

**Interfaces:**
- Consumes: the running server (Task 4), reachable config (Task 3).
- Produces: confirmation that every pinned key is live; nothing depends on this, but a failure
  here invalidates §9 of the spec.

- [ ] **Step 1: Read `ServerSettings.ini` off the PVC**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'cat "/home/icarus/drive_c/icarus/Saved/Config/WindowsServer/ServerSettings.ini"'
```
If that path is empty, locate it rather than guessing:
```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'find /home/icarus/drive_c/icarus -name ServerSettings.ini'
```

- [ ] **Step 2: Check the sentinel first**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'find /home/icarus/drive_c/icarus -name ServerSettings.ini -exec grep -E "MaxPlayers|JoinPassword|AdminPassword|AllowNonAdmins|ShutdownIf|ResumeProspect" {} +'
```
Expected: **`MaxPlayers=6`**. This is the only line that proves the `sed` pass ran — every other
pinned value equals the heredoc default and would read back correct even if the ConfigMap had
never been applied. `MaxPlayers=8` (or anything else) means the ConfigMap is not reaching the
file, and every other "correct" value in it is meaningless.

Also expected: `JoinPassword` and `AdminPassword` both **non-empty**. That is the functional
verification of the Secret — do not try to read the Secret's values directly, which is
policy-denied on this workstation.

- [ ] **Step 3: Verify `Engine.ini` got the async timeout**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'find /home/icarus/drive_c/icarus -name Engine.ini -exec grep -A2 OnlineSubsystemSteam {} +'
```
Expected: `AsyncTaskTimeout=60` under `[OnlineSubsystemSteam]`.

- [ ] **Step 4: Verify no cron was installed — the negative case for both cron keys**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'crontab -l -u icarus 2>&1; echo "---"; crontab -l 2>&1'
```
Expected: empty, or `no crontab for ...`. **Anything scheduled here means `UPDATE_CRON` or
`CLEANUP_CRON` leaked in** — the whole reason both are absent is that the update path trusts an
empty-check that fails open.

- [ ] **Step 5: Verify the boot-time update actually ran**

`[PowerShell]`
```powershell
kubectl exec -n icarus deploy/icarus -- cat /opt/icarus/current_version
(Invoke-RestMethod "https://api.steamcmd.net/v1/info/2089300").data.'2089300'.depots.branches.public.buildid
```
Expected: the two match. A mismatch means `UPDATE_SKIP` took effect or SteamCMD failed silently —
check the logs before assuming the server is current.

- [ ] **Step 6: Record the result**

No commit unless a manifest changed. If any pinned key did **not** reach the `.ini`, fix
`configmap.yaml`, `kubectl apply` it, `kubectl rollout restart deploy/icarus -n icarus` (a
ConfigMap edit alone does **not** restart the pod), and re-run this task from Step 1.

---

## Task 8: Backups

**Files:**
- Create: `icarus/recurringjob.yaml`

**Interfaces:**
- Consumes: the Longhorn Volume backing `icarus-data` (name recorded in Task 2 Step 4).
- Produces: a daily snapshot of the saves.

- [ ] **Step 1: Create `icarus/recurringjob.yaml`**

```yaml
# ⚠️ NOTE: this file deploys into `longhorn-system`, NOT `icarus`.
#
# This job does nothing until the Longhorn VOLUME backing icarus-data carries the label
# recurring-job-group.longhorn.io/icarus=enabled. The label goes on the VOLUME, not the
# PVC -- a new or recreated PVC's volume starts unlabeled, so a PVC that is ever deleted
# and recreated SILENTLY stops being snapshotted. If snapshots are not appearing, check
# that before anything else. See icarus/README.md (Backups) for the commands.
#
# ONLY icarus-data is labelled. The install volume is a re-downloadable SteamCMD tree and
# needs no snapshots.
#
# 12:00 is deliberately an hour off valheim-daily-snapshot (11:00) and clear of
# mealie-daily-snapshot (10:00) so the three do not contend for Longhorn I/O.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: icarus-daily-snapshot
  namespace: longhorn-system
spec:
  cron: "0 12 * * *"
  task: snapshot
  groups:
  - icarus
  retain: 7
  concurrency: 1
```

- [ ] **Step 2: Apply**

`[PowerShell]`
```powershell
cd icarus/
kubectl apply -f recurringjob.yaml --dry-run=server
kubectl apply -f recurringjob.yaml
kubectl get recurringjob -n longhorn-system
```

- [ ] **Step 3: Label the Longhorn Volume — not the PVC**

`[PowerShell]`
```powershell
$vol = kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -eq 'icarus-data' } |
  ForEach-Object { $_.metadata.name }
$vol
kubectl label volumes.longhorn.io -n longhorn-system $vol recurring-job-group.longhorn.io/icarus=enabled
```
Expected: one `pvc-<uuid>` name, then `labeled`.

- [ ] **Step 4: Verify the label landed on the right object**

`[PowerShell]`
```powershell
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -like 'icarus-*' } |
  Select-Object @{n='PVC';e={$_.status.kubernetesStatus.pvcName}},
                @{n='Volume';e={$_.metadata.name}},
                @{n='JobGroup';e={$_.metadata.labels.'recurring-job-group.longhorn.io/icarus'}} |
  Format-Table -AutoSize
```
Expected: `icarus-data` → `enabled`; `icarus-server` → blank. **The install volume must NOT be
labelled** — snapshotting 20 GB of re-downloadable binaries daily is exactly what the two-PVC
split exists to avoid.

- [ ] **Step 5: Prove a snapshot actually appears**

Do not wait for 12:00 to find out it was misconfigured. Take one on demand:

`[PowerShell]`
```powershell
@"
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: icarus-data-verify
  namespace: longhorn-system
spec:
  volume: $vol
  createSnapshot: true
"@ | kubectl apply -f -

kubectl get snapshots.longhorn.io -n longhorn-system | Select-String icarus
```
Expected: the snapshot reaches `readyToUse: true`.

**Note:** deleting the Snapshot CR afterwards is a **no-op** — the controller recreates it and
frees nothing. Purging snapshots is API-only. Leave it; the `retain: 7` policy handles it.

Then confirm the scheduled job is registered against the volume:
```powershell
kubectl get volumes.longhorn.io -n longhorn-system $vol -o jsonpath='{.status.kubernetesStatus.workloadsStatus}'
```

- [ ] **Step 6: Commit**

```bash
git add icarus/recurringjob.yaml
git commit -m "Add daily Longhorn snapshot for icarus-data

Deploys into longhorn-system, not icarus. Only the data volume is labelled --
the install volume is re-downloadable. 12:00 is offset from valheim (11:00) and
mealie (10:00) so the three do not contend for Longhorn I/O."
```

---

## Task 9: README and CLAUDE.md entry

**Files:**
- Create: `icarus/README.md`
- Modify: `CLAUDE.md` (workload list)

**Interfaces:**
- Consumes: everything verified in Tasks 1–8.
- Produces: the operational document a future reader hits before changing anything here.

- [ ] **Step 1: Write `icarus/README.md`**

Written as an operational document, matching `mealie/README.md`'s tone. It must contain, at
minimum:

1. **⚠️ Two files deploy outside the `icarus` namespace** — `storageclass.yaml` is cluster-scoped
   and generically named, so another workload may adopt it; `recurringjob.yaml` goes to
   `longhorn-system`. Deleting `icarus/` removes both.
2. **Deploy/restart procedure**, including that a ConfigMap edit needs an explicit
   `kubectl rollout restart deploy/icarus -n icarus`, while a Deployment edit restarts on its own
   — and that adding a restart after a Deployment apply starts a second Recreate cycle that races
   the first.
3. **`strategy: Recreate` means every apply is a brief outage.** Confirm nobody is playing first.
4. **Backups:** the label goes on the **Volume**, not the PVC; a recreated PVC silently stops
   being snapshotted; the exact labelling and verification commands from Task 8; and that snapshot
   deletion is API-only.
5. **Both passwords are plaintext in `ServerSettings.ini`** on the data PVC, hence in every
   Longhorn snapshot and CloudCasa backup; and **blanking a password in the Secret does not clear
   it** — that requires editing the file on the PVC.
6. **The `.ini` on the PVC is the source of truth**, not this repo. A key removed from the
   ConfigMap stops being enforced rather than reverting.
7. **`MaxPlayers=6` is the verification sentinel** and why every other pinned value is worthless
   as proof.
8. **Which probe form is in use and that it was tested against a stopped server** (Task 5), with
   the bracketed-pgrep warning if the fallback is in play.
9. **Exposure:** LAN/VPN only; `loadBalancerSourceRanges` — not NetworkPolicy — is the enforcement
   point, because Flannel does not enforce NetworkPolicy.
10. **Updates are deliberate**, via `kubectl rollout restart`. Record *why* no `UPDATE_CRON`: the
    empty-check fails open, so a scheduled update can stop the server while people are playing.
11. **The `vm.max_map_count = 262144` dependency** lives in `talos/`, and a full
    `talosctl apply-config` silently reverts it — the in-pod check from Task 4 Step 6 is how to
    confirm it.

- [ ] **Step 2: Add the workload entry to `CLAUDE.md`**

Under the workload list, following the `mealie/` entry's shape:

```markdown
- `icarus/` — ICARUS dedicated server, Wine under supervisord. Two files deploy **outside** the
  `icarus` namespace: `storageclass.yaml` is cluster-scoped (`longhorn-single-replica`, generically
  named — another workload may adopt it) and `recurringjob.yaml` targets `longhorn-system`. Read the
  README before applying. Depends on `vm.max_map_count=262144` from `talos/` — below that it OOMs
  under Wine on a host with free memory
```

- [ ] **Step 3: Verify the README's commands actually run**

Do not ship a README whose commands were never executed. Run every command block in it verbatim
and confirm each produces the described output. A README command that fails is worse than no
command, because it will be trusted at 2am during an outage.

- [ ] **Step 4: Commit**

```bash
git add icarus/README.md CLAUDE.md
git commit -m "Add icarus README and CLAUDE.md workload entry

Documents the two out-of-namespace files, the Volume-not-PVC snapshot labelling
trap, that both passwords are plaintext in ServerSettings.ini and therefore in
every snapshot, and that MaxPlayers=6 is the only pinned value that proves the
ConfigMap reached the file."
```

---

## Task 10: Final verification and close-out

**Files:**
- Modify: `docs/superpowers/specs/2026-08-30-icarus-server-deployment-design.md` (§12 results)

- [ ] **Step 1: Walk the spec §12 verification table**

Confirm every row, and record the evidence:

| Claim | Command |
|---|---|
| `vm.max_map_count` | `kubectl exec -n icarus deploy/icarus -- cat /proc/sys/vm/max_map_count` → `262144` |
| Capacity gate | already recorded — three workers ≥60 GiB |
| Probe can fail | Task 5 — readiness observed flipping to `0/1` and back |
| ConfigMap reached `.ini` | `MaxPlayers=6` present |
| No cron installed | `crontab -l` empty |
| Update ran at boot | `current_version` matches the steamcmd buildid |
| Snapshots happening | a Snapshot CR reached `readyToUse` |
| Players can connect | a real client joined and started a prospect |

- [ ] **Step 2: Confirm nothing else on the cluster regressed**

`[PowerShell]`
```powershell
kubectl get nodes
kubectl get pods -A --field-selector status.phase!=Running --no-headers | Select-String -NotMatch 'Completed'
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | Group-Object { $_.status.robustness } | Select-Object Name, Count
```
Expected: 7 nodes `Ready`. Volume robustness gains **2** healthy volumes (the two new icarus
ones) over the pre-ICARUS baseline of 34 healthy / 3 unknown. The 3 `unknown` are the parked
`enshrouded` workload — **not** a regression, do not chase it. The pre-existing `Error` pods
(`kubevirt/virt-controller`, two `longhorn-system` CSI pods) also predate this work.

- [ ] **Step 3: Append a Results section to the ICARUS spec**

Record the measured first-boot duration against the `failureThreshold: 400` budget, the actual
install size on `/opt/icarus`, which probe form ended up in use, and the node it scheduled onto.
Per the repo convention, **append a correction rather than rewriting** if any figure contradicts
the design.

- [ ] **Step 4: Resolve the spec's remaining open items**

Spec §13 lists four. Item 1 (capacity gate) is already closed. Close or re-scope the rest with the
data this deployment produced:

- **Item 2** — which readiness command discriminates: answered by Task 5.
- **Item 3** — measure real memory use under 2–6 players and revisit the `16Gi` limit:
  ```powershell
  kubectl top pod -n icarus
  ```
  Take this with players actually connected, not idle.
- **Item 4** — confirm first-boot duration against the ~100 minute budget. If a cold install lands
  nowhere near it, `failureThreshold` is larger than it needs to be; record the real figure rather
  than trimming it blind.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-30-icarus-server-deployment-design.md
git commit -m "Record measured results of the icarus deployment"
```

---

## Self-review notes

Checked against the spec on 2026-08-30:

- **Spec coverage.** §5 decisions → Tasks 1/4/6; §6 layout → all nine files created across Tasks
  1–9; §7 storage → Task 2; §8 networking → Task 6; §9.1/§9.2 config → Task 3, verified in Task 7;
  §10 deployment/probes/resources → Tasks 4–5; §11 backups → Task 8; §12 verification → Tasks 5,
  7, 8 and 10; §13 open items → Task 10 Step 4.
- **Deliberate omission.** Spec §2.3 item 4 (`doUpdate` calling `downloadIcarus` twice) is not
  fixed by any task — it is upstream behaviour, and the plan accommodates it in the
  `failureThreshold: 400` budget and the 50 Gi install PVC rather than working around it.
- **Naming consistency.** `icarus-data` / `icarus-server` (PVCs), `icarus-config`,
  `icarus-secrets` with keys `server-password` / `admin-password`, `longhorn-single-replica`,
  `icarus-daily-snapshot` group `icarus` — used identically in every task that references them.
- **Ordering constraint.** Task 5 (probe fails correctly) precedes Task 6 (Service) on purpose:
  the readiness probe is what gates traffic, so trusting it before observing it fail would be the
  same defect the spec warns about.
