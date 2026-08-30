# ICARUS Dedicated Server

Persistent ICARUS server for a LAN/VPN group of 2–6 players. Wine under supervisord, on the
`k8` Talos cluster.

**Design spec:** `docs/superpowers/specs/2026-08-30-icarus-server-deployment-design.md`
**Implementation plan:** `docs/superpowers/plans/2026-08-30-icarus-server-deployment.md`

## Joining

`192.168.130.156:17777`, join password in `secret.yaml` (`server-password`). LAN/VPN only —
nothing is port-forwarded and the server is not publicly listed.

## ⚠️ Two files deploy OUTSIDE the `icarus` namespace

Read this before deleting anything here.

| File | Where it actually goes | Why it matters |
|---|---|---|
| `storageclass.yaml` | **cluster-scoped** | `longhorn-single-replica` is a generic name. Another workload may adopt it. Deleting `icarus/` would delete a cluster-scoped object something else depends on |
| `recurringjob.yaml` | `longhorn-system` | Not in `icarus`; `kubectl delete -n icarus` will not touch it |

Before removing the StorageClass, check nothing else uses it:

```powershell
kubectl get pvc -A -o json | ConvertFrom-Json | ForEach-Object { $_.items } |
  Where-Object { $_.spec.storageClassName -eq 'longhorn-single-replica' } |
  Select-Object @{n='ns';e={$_.metadata.namespace}}, @{n='pvc';e={$_.metadata.name}}
```

## Layout

```
icarus/
├── README.md
├── namespace.yaml         # no PSA labels -- cluster default `baseline` is intended
├── storageclass.yaml      # ⚠ CLUSTER-SCOPED
├── configmap.yaml         # icarus-config -- every ServerSettings.ini key pinned
├── secret.yaml.template   # real secret.yaml is gitignored by **/secret.yaml
├── pvc.yaml               # icarus-data (10Gi, 2 replicas) + icarus-server (50Gi, 1 replica)
├── deployment.yaml
├── service.yaml           # LoadBalancer 192.168.130.156, UDP only
└── recurringjob.yaml      # ⚠ deploys into longhorn-system
```

## Applying

```powershell
cd icarus/                                            # relative paths from repo root silently no-op
kubectl apply -f <file>.yaml --dry-run=server         # validate first
kubectl apply -f <file>.yaml                          # must say configured/created, not unchanged
```

`unchanged` is a **silent failure**, almost always the wrong working directory.

**A ConfigMap edit does not restart the pod.** Follow one with:

```powershell
kubectl rollout restart deploy/icarus -n icarus
kubectl rollout status  deploy/icarus -n icarus --timeout=600s
```

**A Deployment edit restarts on its own.** Do *not* add a `rollout restart` after applying
`deployment.yaml` — it starts a second Recreate cycle that races the first.

### Every apply is a brief outage

`strategy: Recreate` is mandatory, not stylistic: `RollingUpdate` would start a second pod
claiming the same ReadWriteOnce Longhorn volumes and deadlock. So the old pod is fully torn down
before the new one starts. **Confirm nobody is playing first** — ask the server directly:

```powershell
kubectl exec -n icarus deploy/icarus -- su icarus -c `
  'python3 -c "import a2s; i=a2s.info((\"127.0.0.1\",27015)); print(str(i.player_count)+\"/\"+str(i.max_players))"'
```
`0/6` is the all-clear. This is a live query, not a log window, so it does not go stale.

Two things about that command:

- **`su icarus` is required.** `python-a2s` is installed by the bootstrap into
  `/home/icarus/.local/lib/python3.12/site-packages`, i.e. the *user* site-packages. A plain
  `kubectl exec` runs as root and fails with `ModuleNotFoundError: No module named 'a2s'`, which
  looks exactly like "the package is missing" when it is present and fine.
- It is re-installed from PyPI on **every pod start** — `.local` is on the container layer, not on
  either PVC. If PyPI is unreachable at boot this command stops working (harmlessly, while
  `UPDATE_CRON` stays absent).

Do **not** substitute a log grep for this. `Select-String 'Join|Login|Player'` matches engine
start-up noise (`D_PlayerTalentModifiers`, `OnResUserTicket : No player found`) on a completely
idle server, so it reports activity that is not there.

`terminationGracePeriodSeconds: 120` is derived, not guessed: the image's SIGTERM trap waits 60 s
before escalating to KILL, and supervisord's `stopwaitsecs` is 90. Lowering it risks SIGKILL
mid-save, which corrupts a prospect.

### The PodSecurity warning on every apply is expected

Applying `deployment.yaml` prints:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
```

This is **warn-level only**. The namespace carries no PSA labels, so it enforces the cluster
default `baseline`, which the pod satisfies — it was admitted and runs. The container starts as
root deliberately: `scripts/bootstrap` runs `groupmod`/`usermod` and `chown -R` over both volumes
before supervisord drops the game to `icarus` (uid/gid 4711). Do **not** "fix" this by adding
`runAsNonRoot` or by widening the namespace.

## Verified on first deploy (2026-08-30)

| Thing | Measured |
|---|---|
| First boot to ready | **4.1 minutes** on `talos-mql-msp` |
| SteamCMD download | 9.7 GiB (`10426327064` bytes) |
| Install size on `/opt/icarus` | **9.9 GB** |
| Image pull | 1.0 GB in 24 s |
| Steam buildid | `24941100`, matching `api.steamcmd.net` for app `2089300` |
| `vm.max_map_count` in-pod | `262144` |

The `startupProbe` budget is `failureThreshold: 400` × `periodSeconds: 15` ≈ **100 minutes**,
sized for a ~20 GB pull plus a full revalidate. The real first boot took 4.1 minutes. The budget
is deliberately left oversized on a single sample — but be aware that a genuinely broken first
boot will take ~100 minutes to surface as a crash-loop rather than failing fast.

## Configuration

### The `.ini` on the PVC is the source of truth, not this repo

`icarus-bootstrap` writes `ServerSettings.ini` from a heredoc **only if the file does not exist**,
then applies one `sed` per setting, each guarded by a non-empty test. Therefore:

- **Removing a key from `configmap.yaml` does not revert it** — it only stops being enforced.
  Whatever is in the file keeps running.
- An empty value is indistinguishable from an unset one, so **blanking a value changes nothing**.
- `LoadProspect=` is force-cleared on every boot, unconditionally.

Read what is actually live:

```powershell
kubectl exec -n icarus deploy/icarus -- cat /home/icarus/drive_c/icarus/Saved/Config/WindowsServer/ServerSettings.ini
kubectl exec -n icarus deploy/icarus -- cat /home/icarus/drive_c/icarus/Saved/Config/WindowsServer/Engine.ini
```

### `MaxPlayers=6` is the only line that proves anything

Every other pinned value equals the first-boot heredoc default, so it would read back correct
**even if the ConfigMap had never been applied**. `SERVER_MAX_PLAYERS: "6"` differs from the
default, so it is the sentinel. After any config change, check that first.

Stronger still, confirm it on the **running server** rather than in the file — this proves the
game actually loaded the config, not merely that `sed` wrote it:

```powershell
kubectl exec -n icarus deploy/icarus -- su icarus -c `
  'python3 -c "import a2s; i=a2s.info((\"127.0.0.1\",27015)); print(i.server_name); print(i.player_count,\"/\",i.max_players)"'
```
Verified 2026-08-30: returned `Arnold Icarus Server` and `0 / 6`, so both `SERVER_NAME` and
`SERVER_MAX_PLAYERS` are live in the process, not just on disk.

### Key names in the `.ini` do not match the env var names

`SERVER_NAME` lands in **`SessionName`**, not `ServerName`. Grepping for `ServerName` returns
nothing and reads as a missing setting when it is actually present. The full mapping as verified:

| Env var | `.ini` key |
|---|---|
| `SERVER_NAME` | `SessionName` |
| `SERVER_MAX_PLAYERS` | `MaxPlayers` |
| `SERVER_SHUTDOWN_IF_NOT_JOINED` | `ShutdownIfNotJoinedFor` |
| `SERVER_SHUTDOWN_IF_EMPTY` | `ShutdownIfEmptyFor` |
| `SERVER_ALLOW_NON_ADMINS_LAUNCH` | `AllowNonAdminsToLaunchProspects` |
| `SERVER_ALLOW_NON_ADMINS_DELETE` | `AllowNonAdminsToDeleteProspects` |
| `SERVER_RESUME_PROSPECT` | `ResumeProspect` |
| `SERVER_PASSWORD` | `JoinPassword` |
| `SERVER_ADMIN_PASSWORD` | `AdminPassword` |
| `ASYNC_TASK_TIMEOUT` | `Engine.ini` → `[OnlineSubsystemSteam] AsyncTaskTimeout` |

### ⚠️ The two shutdown timers — do not set them to 0

`SERVER_SHUTDOWN_IF_NOT_JOINED` and `SERVER_SHUTDOWN_IF_EMPTY` are **shutdown** timers for a
running prospect. At the image's first-boot defaults (`300` / `60`) the server stops its prospect
60 seconds after the last player logs off. Both are pinned to `86400` (24 h) here, which is
effectively "never" for this group.

**Setting them to `0` does not disable them — it means shut down immediately.** A server
configured that way stops the instant a prospect starts. Use a large number.

These only apply while a prospect is running, so a server with no prospect looks perfectly healthy
indefinitely. That is why the original 60 s value survived the entire first-deploy verification
pass unnoticed: no prospect existed yet.

The value is read **when a prospect starts**, not continuously, so a change needs
`kubectl rollout restart deploy/icarus -n icarus` before it takes effect.

### Is a prospect actually loaded?

**Do not use the A2S `Map` field** — ICARUS leaves it empty whether or not a prospect is running,
so it looks identical in both states. The reliable checks:

```powershell
kubectl exec -n icarus deploy/icarus -- sh -c `
  'grep LastProspectName /home/icarus/drive_c/icarus/Saved/Config/WindowsServer/ServerSettings.ini'
kubectl exec -n icarus deploy/icarus -- sh -c `
  'ls -la /home/icarus/drive_c/icarus/Saved/PlayerData/DedicatedServer/Prospects/'
```

A server with **no** prospect will accept connections but clients bounce, so an empty
`LastProspectName` is the first thing to check when players cannot get in. The image has **no**
env var for `CreateProspect` or `LoadProspect` — `icarus-bootstrap` line 154 unconditionally
*clears* `LoadProspect` on every boot — so prospects are created from a connected client, or by
editing `ServerSettings.ini` on the PVC directly.

Confirm the saves are on the data PVC and not the container layer:

```powershell
kubectl exec -n icarus deploy/icarus -- df -h /home/icarus/drive_c/icarus
```
Verified 2026-08-30: `/dev/longhorn/pvc-aea546c0-…`, i.e. the 2-replica snapshotted volume.

### Passwords

⚠️ **Both passwords are stored in plaintext** in `ServerSettings.ini` on the `icarus-data` PVC.
They are therefore present in **every Longhorn snapshot and every CloudCasa backup**. Treat any
snapshot of `icarus-data` as containing them.

⚠️ **Blanking a password in the Secret does not clear it.** The `sed` is guarded by a non-empty
test, so an empty value is skipped and the old password stays live. Clearing one means editing
the file on the PVC and restarting:

```powershell
kubectl exec -n icarus deploy/icarus -- sed -i 's/^JoinPassword=.*/JoinPassword=/' \
  /home/icarus/drive_c/icarus/Saved/Config/WindowsServer/ServerSettings.ini
kubectl rollout restart deploy/icarus -n icarus
```

⚠️ **Keep passwords alphanumeric.** They are substituted with `sed`, so a `/` breaks the
expression, an `&` is replaced by the whole match, and a backslash escapes the next character.
Each silently corrupts the file rather than erroring.

⚠️ **Do not set `admin-password` equal to `server-password`.** `AdminPassword` grants admin
rights, so reusing the join password hands every player the ability to administer the server —
including deleting prospects, which `SERVER_ALLOW_NON_ADMINS_DELETE=False` exists to prevent.

Reading Secret values with `kubectl get/describe secret` is **denied by policy** on this
workstation. Verify a Secret change functionally, by reading the `.ini` back.

### Updates are deliberate, not scheduled

There is no `UPDATE_CRON` and no `CLEANUP_CRON`, and **absent genuinely means off** here —
`initCrontab()` guards on `-n`, so an unset variable creates no cron.

> This is the **opposite** of the `lloesche/valheim-server` trap in the repo CLAUDE.md, where
> `UPDATE_CRON` uses `${VAR-default}` and removing the key silently enables a 15-minute cron. Do
> not carry that fear over and add an empty-string key here "to be safe".

Scheduled updates were declined because `checkServerEmpty()` **fails open**: it shells to
`python3 -c "... a2s.players(...)"` and prints `null` on *any* exception, and the caller treats
`null` as empty. A failed query therefore permits an update that stops the server while people
are mid-prospect. It also depends on `pip3 install python-a2s` succeeding at every pod start.

Update deliberately instead:

```powershell
kubectl rollout restart deploy/icarus -n icarus
```

`UPDATE_SKIP: "false"` means every pod start checks for and applies an update.

Confirm no cron ever appears:

```powershell
kubectl exec -n icarus deploy/icarus -- sh -c 'crontab -l -u icarus; crontab -l'
```
Empty (and `no crontab for root`) is the pass.

Confirm the server is current:

```powershell
kubectl exec -n icarus deploy/icarus -- cat /opt/icarus/current_version
(Invoke-RestMethod "https://api.steamcmd.net/v1/info/2089300").data.'2089300'.depots.branches.public.buildid
```
The two must match.

## Probes

`supervisorctl status icarus-server | grep -q RUNNING`, on both `startupProbe` and
`readinessProbe`. There is **no `livenessProbe`** — it would SIGKILL the server mid-save and
corrupt a prospect. supervisord already restarts the program internally (`autorestart=true`,
`startretries=10`), and the Deployment restarts the container if supervisord itself exits.

### Verified against a stopped server (2026-08-30) — not just observed passing

A probe only ever seen passing has not been verified, and an always-passing probe has shipped in
this repo before. Both directions were observed:

```powershell
kubectl exec -n icarus deploy/icarus -- supervisorctl stop icarus-server
kubectl get pod -n icarus -l app=icarus -w      # expect 1/1 -> 0/1
kubectl exec -n icarus deploy/icarus -- supervisorctl start icarus-server
kubectl get pod -n icarus -l app=icarus -w      # expect 0/1 -> 1/1
```

Result: probe command exited `0` while RUNNING and `1` while STOPPED; readiness flipped to `0/1`
**92 seconds** after the stop (3 × `periodSeconds: 30`) and recovered within ~30 s of restart.

Note `supervisorctl status` with **no argument** exits `3` when any program is stopped. That does
not affect the probe, because the pipeline's exit code comes from `grep`, not from
`supervisorctl`.

If the probe is ever switched to `pgrep`, it **must** keep the bracketed form:

```yaml
command: ["sh", "-c", "pgrep -f '[I]carusServer-Win64-Shipping' > /dev/null"]
```

`pgrep -f` matches full command lines, so a bare pattern matches the probe's own shell and yields
a probe that can never fail. The `> /dev/null` is what keeps that shell alive to be matched —
which is why the bare form passes a manual smoke test and still never fails. Re-run the
stopped-server test after any probe change.

## Storage

| PVC | Size | Class | Replicas | Mount | Nature |
|---|---|---|---|---|---|
| `icarus-data` | 10 Gi | `longhorn` | 2 | `/home/icarus/drive_c/icarus` | Prospects, `ServerSettings.ini`, `Engine.ini`. **Irreplaceable** |
| `icarus-server` | 50 Gi | `longhorn-single-replica` | 1 | `/opt/icarus` | SteamCMD install. **Disposable** |

Split so the irreplaceable saves and the slow-but-rebuildable install have independent
lifecycles: the install can be wiped to force a clean reinstall without ever risking a save, and
a snapshot restore of the saves does not roll back the game binaries.

`icarus-server` is 50 Gi rather than ~10 Gi because `doUpdate()` calls `downloadIcarus` **twice**,
so an update transiently needs up to 2× the install size.

Only the game's `UserDir` is persisted. `WINEPREFIX` is `/home/icarus` — the home directory *is*
the Wine prefix — and `drive_c/windows` plus the registry live on the container layer, rebuilt by
`wineboot --init` every boot. That is intentional: it keeps the data PVC small, and means the Wine
prefix is not in any backup and does not need to be.

Confirm the replica split is actually what it claims:

```powershell
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -like 'icarus-*' } |
  Select-Object @{n='PVC';e={$_.status.kubernetesStatus.pvcName}},
                @{n='Replicas';e={$_.spec.numberOfReplicas}}
```
Expect `icarus-data` 2, `icarus-server` 1.

## Backups

`RecurringJob` `icarus-daily-snapshot` in `longhorn-system` — `task: snapshot`, `groups: [icarus]`,
`cron: "0 12 * * *"`, `retain: 7`. 12:00 is an hour off Valheim's 11:00 and clear of Mealie's
10:00 so the three do not contend for Longhorn I/O.

### The label is on the Volume, not the PVC — check this first if snapshots stop appearing

The job does **nothing** until the Longhorn **Volume** carries
`recurring-job-group.longhorn.io/icarus=enabled`. A new or recreated PVC's volume starts
**unlabeled**, so deleting and recreating `icarus-data` silently stops all snapshots with no error
anywhere.

```powershell
# find the volume and label it
$vol = kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -eq 'icarus-data' } |
  ForEach-Object { $_.metadata.name }
kubectl label volumes.longhorn.io -n longhorn-system $vol recurring-job-group.longhorn.io/icarus=enabled

# verify -- data labelled, install NOT
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } |
  Where-Object { $_.status.kubernetesStatus.pvcName -like 'icarus-*' } |
  Select-Object @{n='PVC';e={$_.status.kubernetesStatus.pvcName}},
                @{n='JobGroup';e={$_.metadata.labels.'recurring-job-group.longhorn.io/icarus'}}
```

**Only `icarus-data` is labelled.** The install volume is re-downloadable; snapshotting ~10 GB of
game binaries daily is exactly what the two-PVC split exists to avoid.

Take one on demand without the UI:

```powershell
@"
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: icarus-data-adhoc
  namespace: longhorn-system
spec:
  volume: $vol
  createSnapshot: true
"@ | kubectl apply -f -
```

⚠️ **Deleting a Snapshot CR is a no-op** — the controller recreates it and frees nothing. Purging
is API-only. Do not expect `kubectl delete snapshot` to reclaim space.

Verified 2026-08-30: an on-demand snapshot reached `readyToUse: true` at 239 MB, restore size
10 Gi.

Off-cluster coverage remains CloudCasa (`cloudcasa-io`), which deletes its CRs after each run — an
empty `kubectl get backups.cloudcasa.io` proves nothing either way. ICARUS also writes its own
`.backup` files beside each prospect on the data PVC.

## Networking and exposure

`Service` type `LoadBalancer`, `metallb.io/loadBalancerIPs: 192.168.130.156` (**not** the
deprecated `metallb.universe.tf/`), `externalTrafficPolicy: Local` to preserve the client source
IP for the Steam query protocol. Ports `17777/UDP` (game) and `27015/UDP` (query). No TCP.

The annotation is a **request, not a guarantee** — if `.156` is already claimed MetalLB silently
auto-assigns a different address from `vlan130-pool` (`192.168.130.150-199`). Verify:

```powershell
kubectl get svc icarus -n icarus -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

⚠️ There are deliberately **no `loadBalancerSourceRanges`**, because nothing is port-forwarded. If
this server is ever exposed to the internet, **`loadBalancerSourceRanges` is the enforcement
point — not NetworkPolicy.** The CNI is Flannel, which does not enforce NetworkPolicy at all: a
NetworkPolicy added here would be silently inert and would read as protection that does not exist.

## The `vm.max_map_count` dependency lives in `talos/`

The server needs `vm.max_map_count = 262144`. Below that it fails under Wine with
`Ran out of memory allocating 0 bytes` **on a host with free memory**. `vm.*` is not a namespaced
sysctl, so no pod-level `securityContext.sysctls` can set it — it is Talos machine config, applied
by `talos/image-gc-and-sysctl.patch.yaml`.

⚠️ **A full `talosctl apply-config` silently reverts that patch.** Confirm at the point of use:

```powershell
kubectl exec -n icarus deploy/icarus -- cat /proc/sys/vm/max_map_count
```
`262144` is the pass; `65530` means the node's patch is gone. See `talos/README.md`.

## Known gaps

- **Memory limit is unvalidated under load.** `16Gi` limit / `8Gi` request came from the upstream
  recommendation, not from measurement. Take `kubectl top pod -n icarus` with 2–6 players actually
  connected and revisit.
- **The startup budget is sized for a worst case that did not occur** (100 min budget, 4.1 min
  actual). Left as-is on one sample; a broken first boot will therefore take ~100 minutes to
  surface.
- **`doUpdate()` runs SteamCMD twice** on every update. Upstream behaviour, not worked around —
  it is accommodated by the startup budget and the 50 Gi install PVC.
- **The empty-check fails open** (`checkServerEmpty()` returns `null` on any exception, read as
  empty). Irrelevant while `UPDATE_CRON` is absent; it becomes live the moment anyone adds one.
