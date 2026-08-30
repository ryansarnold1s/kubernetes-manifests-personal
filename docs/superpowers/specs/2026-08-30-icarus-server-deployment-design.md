# ICARUS Dedicated Server — Deployment Design

**Date:** 2026-08-30
**Status:** Approved
**Target cluster:** `k8` (Talos v1.13.4 / Kubernetes v1.35.4, Rancher-managed)
**Image:** `mornedhels/icarus-server:dev@sha256:63a559fee2c7e91469e11b74ac488ba2003541a027cbe4139cfb0b657dbfa6e4`

---

## 1. Goal

Run a persistent ICARUS dedicated server on the `k8` Talos cluster for a LAN/VPN group of
2–6 players, using the same manifest conventions as the existing `valheim/` deployment.

**Non-goals:** internet exposure, mods, off-cluster DR beyond the existing CloudCasa coverage,
migrating an existing prospect save, scheduled auto-updates.

---

## 2. Image recon

Everything below was verified by reading the image's own scripts at
`github.com/mornedhels/icarus-server@main`, not the Docker Hub store page. Several points
contradict the project README; those are called out explicitly.

### 2.1 Basic facts

| Aspect | Value |
|---|---|
| Base | `steamcmd/steamcmd:ubuntu-24` + WineHQ **stable** + supervisor |
| Steam app id | `2089300`, downloaded with `+@sSteamCmdForcePlatformType windows` |
| Game binary | `Icarus/Binaries/Win64/IcarusServer-Win64-Shipping.exe`, run under `wine` |
| Ports | `17777/udp` (game), `27015/udp` (Steam query) |
| Data volume | `/home/icarus/drive_c/icarus` — prospects, `ServerSettings.ini`, `Engine.ini` |
| Install volume | `/opt/icarus` — SteamCMD install, ~20 GB, up to 2x transiently during update |
| Runs as | `supervisord` as **root**; game drops to `icarus` (`PUID`/`PGID`, default `4711`) |
| Shutdown | `stopwaitsecs=90`; the script's own trap waits 60 s before escalating TERM to KILL |
| RAM | 8 GB minimum, 16 GB recommended (upstream) |

### 2.2 Tag selection

| Tag | Digest | Pushed | Notes |
|---|---|---|---|
| `1.0.0` = `latest` | `a3d932c1…` | 2025-05-04 | Last tagged release |
| `dev` | `63a559fe…` | 2026-07-24 | **Chosen** |
| `dev-wine-staging` | `9a3c9de9…` | 2026-07-24 | wine-staging build; least tested, no documented reason to prefer it |

`dev` is not an unstable branch. Every commit on `main` since the `1.0.0` tag is either a
dependabot bump of the `steamcmd/steamcmd` base image or the merge of `#94`
(`fix(#93): port enshrouded fix for steam update aborts`) — a real updater bug fix that
`1.0.0` does not contain. `dev` is therefore `1.0.0` plus that fix plus ~14 months of base-image
patches. Pinned by digest it is immutable, so the tag being mutable upstream does not matter.

The repository has exactly one open issue ("Switch from Wine to Proton", 2025-02). Low activity,
but not abandoned.

### 2.3 Corrections to the upstream README

These are wrong or misleading in the project README and were established from source:

1. **`SERVER_IP` is dead config.** The README describes it as driving the "server empty check".
   It appears only in `scripts/defaults` and is referenced by no other script. Setting it does
   nothing. Do not add it.
2. **The empty-check fails open.** `checkServerEmpty()` shells to
   `python3 -c "... a2s.players(('127.0.0.1', $SERVER_QUERYPORT)) ..."` and prints `null` on any
   exception, which the caller treats as *empty*. A failed query therefore permits an update
   that stops the server while players are connected. It also depends on
   `pip3 install python-a2s` succeeding during `icarus-bootstrap`, i.e. on PyPI egress at every
   pod start.
3. **The a2s fallback port is `15637`** — Enshrouded's port, left over from ported code. Harmless
   only because `SERVER_QUERYPORT` is always set here.
4. **`doUpdate()` calls `downloadIcarus` twice** — once bare with its result discarded, then again
   as the `if !` condition. Not harmful, but every update runs two SteamCMD passes, and a first
   install pays a full download plus a full validate.
5. **Documented "defaults" for most `ServerSettings.ini` keys are not env-var defaults.**
   `scripts/defaults` gives `SERVER_SHUTDOWN_IF_NOT_JOINED`, `SERVER_SHUTDOWN_IF_EMPTY`,
   `SERVER_ALLOW_NON_ADMINS_LAUNCH`, `SERVER_ALLOW_NON_ADMINS_DELETE` and
   `SERVER_RESUME_PROSPECT` **no fallback at all**. The values the README lists come from the
   first-boot heredoc in `updateOrCreateIcarusServerSettings()`. See §9.
6. **`UPDATE_CRON` empty genuinely means off** — `initCrontab()` guards on `-n`. This is the
   opposite of the `lloesche/valheim-server` trap documented in the repo CLAUDE.md, where an
   unset variable silently enables a 15-minute cron. Do not carry that fear over.

### 2.4 Config-file mechanics

`icarus-bootstrap` creates `ServerSettings.ini` from a heredoc **only if the file does not
exist**, then applies one `sed` per setting, each guarded by a non-empty test. Consequences:

- The file on the data PVC is the source of truth for which keys exist and what they hold.
- A key removed from the ConfigMap is **not** reverted — it merely stops being enforced.
- An empty value is indistinguishable from an unset one, so blanking a password in the Secret
  does not clear `JoinPassword`/`AdminPassword` from the `.ini`.
- `LoadProspect=` is force-cleared on every boot, unconditionally.
- `Engine.ini` gets `[OnlineSubsystemSteam] AsyncTaskTimeout` by the same create-then-sed pattern.

`WINEPREFIX` is `/home/icarus/` — the home directory itself is the Wine prefix and
`drive_c/icarus` is a subdirectory of it. Only the game's `UserDir` is persisted; the rest of the
prefix (registry, `drive_c/windows`) lives on the container layer and is rebuilt by
`wineboot --init` on every boot. This is intentional and keeps the data PVC small. It also means
the Wine prefix is not in any backup, and does not need to be.

---

## 3. Cluster context

Facts established by inspection on 2026-08-30, recorded so future readers need not re-derive them.

| Aspect | Value |
|---|---|
| Nodes | 7 (3 control-plane @ 8 GB, 4 workers @ 24 GB), all `Ready`, kernel `6.18.34-talos` |
| CNI | Flannel — does **not** enforce NetworkPolicy |
| Load balancer | MetalLB, pool `vlan130-pool` = `192.168.130.150-199`, `autoAssign: true` |
| Storage | Longhorn; `longhorn` is the default StorageClass, `numberOfReplicas: 2` |
| Longhorn disk | `/var/lib/longhorn/` on **every** worker |
| `vm.max_map_count` | **`65530`** — see §4 |

### 3.1 Longhorn capacity

Node `ephemeral-storage` capacity is `417993308Ki` = 398.63 GiB, which equals Longhorn's
`storageMaximum` exactly. Longhorn, the containerd image cache and everything else on the Talos
EPHEMERAL partition are provably the same filesystem. `storage-minimal-available-percentage` is
`25`, so Longhorn refuses any replica that would drop a disk below 99.66 GiB free.
`storageReserved` is 119.6 GiB per disk (30 %), which constrains the over-provisioning budget
(`storage-over-provisioning-percentage: 200`) but is not the binding constraint here.

Schedulable headroom at design time:

| Node | Available | Headroom above the 25 % floor |
|---|---|---|
| `talos-z9a-dpj` | 167.0 GiB | 67.3 GiB |
| `talos-0ag-qr8` | 151.3 GiB | 51.6 GiB |
| `talos-mql-msp` | 103.4 GiB | **3.8 GiB** |
| `talos-uup-vn3` | 103.5 GiB | **3.9 GiB** |

Two of four storage nodes can accept essentially no new replica. This is a **pre-existing cluster
condition, not one Icarus creates**, and it means a node failure today cannot fully rebuild its
replicas elsewhere. It is the reason §4 exists.

### 3.2 Allocated LoadBalancer IPs

`.150` traefik, `.153` enshrouded, `.154` mumble, `.155` valheim, `.199` pihole.
**`.156` is free and is claimed by this design.** Because the pool has `autoAssign: true`, an
unpinned Service could otherwise take it, so the address is pinned explicitly.

---

## 4. Prerequisites (outside this repository)

Neither is a manifest. Both are Talos machine-config work, and both require a rolling node
reboot, so they are applied in a single pass. **Icarus is not deployed until both are done.**

This section states the requirement and the reasoning. The work itself gets its own design spec
and plan — it is cluster infrastructure, not part of a game-server deployment, and it touches
every workload on the cluster rather than only this one.

### 4.1 `vm.max_map_count = 262144`

The image's single documented failure mode is Wine/Unreal reporting
`Ran out of memory allocating 0 bytes` on a host with free memory, fixed only by raising
`vm.max_map_count`. `vm.*` is **not** a namespaced sysctl, so `securityContext.sysctls` cannot
reach it and no pod-level setting is possible. It must be set via Talos `machine.sysctls`.

Rejected alternative: a privileged init container running `sysctl -w`. It would require the
`icarus` namespace to enforce PSA `privileged`, and the setting would be lost on every node
reboot. The Valheim design already declined widening a namespace this way.

### 4.2 Expand the EPHEMERAL partition by ~250 GiB per storage worker

Growing the existing disk was chosen over adding a second one. The capacity outcome is identical
— growing by 250 GiB gives `103.4 + 250 − (25 % × 648.6) = 191.3` GiB of headroom; a separate
250 GiB disk gives `187.5 + 3.8` = the same 191.3 GiB — but expansion needs no Talos user-volume
document, no Longhorn disk registration and no replica migration.

Talos's EPHEMERAL volume defaults to `minSize: 2GiB, grow: true` with no `maxSize`, and is always
the last partition, so it fills space that appears after it. Expand the VMDK, reboot, Talos
resizes partition and filesystem.

Cost: 4 storage workers x 250 GiB = 1 TB of the 1.5 TB free on the ESXi datastore, leaving ~500 GB
of datastore margin. Thick provisioning is assumed; thin-provisioning the growth would overcommit
a datastore that Longhorn will then steadily fill.

**Accepted trade-off:** this does not separate Longhorn from the containerd image cache, so that
coupling — the structural cause of the DiskPressure incident this cluster has already seen —
remains. It is accepted because the incident's precondition was a tight partition, and 191 GiB of
headroom removes it. The safety ordering also favours the shared partition: Longhorn stops
scheduling at 25 % free (~162 GiB) while kubelet's DiskPressure eviction fires at 15 % (~97 GiB),
so Longhorn backs off before kubelet evicts.

**Must be confirmed before expanding:**

1. `talosctl` is **not installed** on the operator workstation. It is required for both changes.
2. `talosctl get volumeconfig EPHEMERAL` must show no explicit `maxSize`. Talos applies volume
   configuration only when a volume has not yet been provisioned, so a `maxSize` set at install
   time caps growth and cannot be changed retroactively without wiping the volume.
3. ESXi will not expand a VMDK that has snapshots.
4. Reboot one node at a time, with Longhorn volumes healthy in between.

---

## 5. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Exposure | LAN / VPN only | No port-forward, no public listing. Matches valheim/mumble |
| Image | `dev` pinned by digest | Contains the `#94` updater fix; `1.0.0` does not (§2.2) |
| Updates | Boot-only, no `UPDATE_CRON` | Deliberate updates via `kubectl rollout restart`. A scheduled check would trust an empty-check that fails open (§2.3) |
| Prospect cleanup | Disabled, no `CLEANUP_CRON` | `icarus-cleanup` moves prospect saves. Not run unattended against irreplaceable data |
| Runtime | Always on, `replicas: 1` | Friends join without coordination; fits on the two least-loaded 24 GB workers |
| Max players | 6 | Group size is 2–6 |
| Install-volume replicas | 1 | Replicating a re-downloadable SteamCMD install buys nothing (§7) |
| `ntsync` | Declined | Kernel 6.18.34 supports it, but exposing `/dev/ntsync` needs a hostPath or device plugin; hostPath is forbidden under PSA `baseline` and the namespace is not being widened. Wine falls back to esync/fsync |
| Delivery | Raw manifests, `kubectl apply` | Matches cluster norm |

---

## 6. Repository layout and resource names

```
icarus/
├── README.md
├── namespace.yaml
├── storageclass.yaml      # cluster-scoped — deploys OUTSIDE the icarus namespace
├── configmap.yaml
├── secret.yaml.template   # real secret.yaml is gitignored by **/secret.yaml
├── pvc.yaml
├── deployment.yaml
├── service.yaml
└── recurringjob.yaml      # longhorn-system namespace — also outside icarus
```

Two files deploying outside the workload namespace mirrors the `mealie/` precedent and gets the
same README warning plus a CLAUDE.md entry.

| Kind | Name |
|---|---|
| Namespace / Deployment / Service | `icarus` |
| ConfigMap | `icarus-config` |
| Secret | `icarus-secrets` (keys `server-password`, `admin-password`) |
| PVC | `icarus-data`, `icarus-server` |
| StorageClass | `longhorn-single-replica` |
| RecurringJob | `icarus-daily-snapshot` (group `icarus`) |

The namespace carries **no** PSA labels; the cluster default `baseline` is the intended posture.
The container starts as root — `scripts/bootstrap` runs `groupmod`/`usermod`/`chown -R` before
supervisord drops the game to `icarus` — which `baseline` permits. Nothing needs widening.

---

## 7. Storage

| PVC | Size | Class | Replicas | Mount | Nature |
|---|---|---|---|---|---|
| `icarus-data` | 10 Gi | `longhorn` | 2 | `/home/icarus/drive_c/icarus` | Prospect saves, `ServerSettings.ini`, `Engine.ini`. **Irreplaceable** |
| `icarus-server` | 50 Gi | `longhorn-single-replica` | 1 | `/opt/icarus` | SteamCMD install, ~20 GB with 2x transient. **Disposable** |

Split for the same reason as Valheim's two PVCs: the irreplaceable data and the
disposable-but-slow-to-rebuild install get independent lifecycles, so the install can be wiped to
force a clean reinstall without ever risking a save. A single combined PVC was rejected because a
Longhorn snapshot restore would then roll back the game binaries along with the saves.

`longhorn-single-replica` is the stock `longhorn` class with `numberOfReplicas: "1"` and no
default-class annotation — otherwise identical (`dataLocality: disabled`, `fsType: ext4`,
`reclaimPolicy: Delete`, `volumeBindingMode: Immediate`, `allowVolumeExpansion: true`).

- The stock `longhorn` class carries a `longhorn.io/last-applied-configmap` annotation and is
  reconciled by Longhorn itself. **It must not be edited.** A separate class is the only correct
  mechanism.
- `dataLocality` stays `disabled` deliberately. On a single-replica volume, `best-effort` would
  trigger a 50 GB local rebuild every time the pod changes nodes.
- The class name is generic and another workload may adopt it. The README notes that deleting
  `icarus/` would delete a cluster-scoped object others might depend on.

---

## 8. Networking

`Service` type `LoadBalancer`, annotation `metallb.io/loadBalancerIPs: 192.168.130.156`
(`metallb.io/`, not the deprecated `metallb.universe.tf/`), `externalTrafficPolicy: Local`,
ports `17777/UDP` named `game` and `27015/UDP` named `query`.

No `loadBalancerSourceRanges`: nothing is port-forwarded, so there is no untrusted path to
restrict. The README records that `loadBalancerSourceRanges` — **not** NetworkPolicy — is the
enforcement point if that ever changes, because Flannel does not enforce NetworkPolicy.

---

## 9. Configuration

### 9.1 `icarus-config`

Every `ServerSettings.ini` key is pinned explicitly, including ones sitting at their first-boot
value. Per §2.3 item 5 those values come from a heredoc that runs once, not from env-var
defaults, so an unpinned key is silently unmanaged.

| Key | Value | Note |
|---|---|---|
| `SERVER_NAME` | `Arnold Icarus Server` | Shown in the client server list |
| `SERVER_MAX_PLAYERS` | `6` | Also the verification sentinel — see §12 |
| `SERVER_PORT` | `17777` | |
| `SERVER_QUERYPORT` | `27015` | Also the port `checkServerEmpty` queries |
| `SERVER_SHUTDOWN_IF_NOT_JOINED` | `300.000000` | Seconds before a started prospect returns to lobby |
| `SERVER_SHUTDOWN_IF_EMPTY` | `60.000000` | Seconds after the last player leaves |
| `SERVER_ALLOW_NON_ADMINS_LAUNCH` | `True` | |
| `SERVER_ALLOW_NON_ADMINS_DELETE` | `False` | Non-admins must not be able to delete prospects |
| `SERVER_RESUME_PROSPECT` | `True` | Resume last prospect after a restart |
| `GAME_BRANCH` | `public` | |
| `ASYNC_TASK_TIMEOUT` | `60` | Written to `Engine.ini` |
| `PUID` / `PGID` | `4711` | Image default; the volumes are chowned to it at boot |
| `UPDATE_SKIP` | `false` | Update at pod start |
| `TZ` | `America/Phoenix` | |
| `WINEDEBUG` | `fixme-all` | Image default, pinned so a future base change cannot alter log volume |

Deliberately **absent**, each with an inline comment explaining why: `UPDATE_CRON` and
`CLEANUP_CRON` (empty means off, and unlike the Valheim trap that is genuinely safe here),
`SERVER_IP` (dead config), `STEAM_API_KEY` (deprecated), `STEAMCMD_ARGS` (default is correct),
`CLEANUP_DAYS` / `CLEANUP_DELETE_BACKUPS` / `CLEANUP_PRUNE_FOLDER` / `CLEANUP_EXCLUDES`
(meaningless without `CLEANUP_CRON`).

### 9.2 `icarus-secrets`

| Key | Env | Lands in |
|---|---|---|
| `server-password` | `SERVER_PASSWORD` | `JoinPassword=` |
| `admin-password` | `SERVER_ADMIN_PASSWORD` | `AdminPassword=` |

Two facts the README must state:

1. Both passwords are written **in plaintext** to `ServerSettings.ini` on the data PVC, and are
   therefore present in every Longhorn snapshot and CloudCasa backup.
2. Blanking a password in the Secret does **not** clear it from the `.ini` — an empty value skips
   the `sed`. Clearing it means editing the file on the PVC.

---

## 10. Deployment and lifecycle

`replicas: 1`, `strategy: Recreate` — mandatory, not stylistic: `RollingUpdate` would start a
second pod claiming the same ReadWriteOnce Longhorn volumes.

`terminationGracePeriodSeconds: 120`, derived rather than guessed: `icarus-server`'s SIGTERM trap
sends TERM and waits 60 s before escalating to KILL, and supervisord's `stopwaitsecs` is 90.

### 10.1 Probes

- **`startupProbe`**, `periodSeconds: 15`, `failureThreshold: 400` ≈ 100 minutes. A first boot on
  an empty install PVC must run `wineboot`, `pip3 install python-a2s`, and a ~20 GB SteamCMD pull
  — and because `doUpdate` calls `downloadIcarus` twice (§2.3), it then re-validates all 20 GB.
- **`readinessProbe`**, `periodSeconds: 30`, `failureThreshold: 3`. Gates the Service so nobody
  connects to a half-started server.
- **No `livenessProbe`.** A SIGKILL mid-save corrupts data, and supervisord already restarts the
  program internally (`autorestart=true`, `startretries=10`); the Deployment restarts the
  container if supervisord itself exits.

Probe command: `supervisorctl status icarus-server | grep -q RUNNING` — the image's own
definition of alive, and robust to however Wine names the process.
`pgrep -f '[I]carusServer-Win64-Shipping'` is the fallback; if used it keeps the bracketed form,
because `pgrep -f` otherwise matches the probe's own shell and yields a probe that can never
fail. **Whichever is chosen is tested against a stopped server before it is trusted** (§12).

### 10.2 Resources

| | Request | Limit |
|---|---|---|
| CPU | `2` | **none** |
| Memory | `8Gi` | `16Gi` |

No CPU limit: CFS throttling shows up in-game as stutter, the same reasoning as Valheim. The 8 GB
control-plane nodes cannot satisfy an 8 Gi request, so the scheduler excludes them without needing
explicit affinity.

### 10.3 securityContext

**No `fsGroup`.** `scripts/bootstrap` already runs `chown -R icarus:icarus /opt/icarus
/home/icarus` as root on every boot. Adding `fsGroup` would make kubelet perform a *second*
recursive ownership pass over a 20 GB volume at every mount. If it is ever added it must be
paired with `fsGroupChangePolicy: OnRootMismatch`. Documented so its absence is not "fixed".

---

## 11. Backups

`RecurringJob` `icarus-daily-snapshot` in `longhorn-system`: `task: snapshot`, `groups: [icarus]`,
`cron: "0 12 * * *"`, `retain: 7`, `concurrency: 1`. 12:00 is deliberately an hour off Valheim's
11:00 so the two do not contend.

**Only `icarus-data` is labelled.** The install volume needs no snapshots.

The job does nothing until the Longhorn **Volume** — not the PVC — carries
`recurring-job-group.longhorn.io/icarus=enabled`. A recreated PVC silently stops being
snapshotted. The README carries the labelling and verification commands.

Off-cluster coverage remains CloudCasa. ICARUS also writes its own `.backup` files beside each
prospect on the data PVC.

---

## 12. Verification plan

Built around negative cases: a check only ever observed passing has not been verified.

| Claim | Proof | Negative case |
|---|---|---|
| `vm.max_map_count` applied | `cat /proc/sys/vm/max_map_count` in-pod = `262144` | Already banked — `65530` was observed on 2026-08-30 |
| EPHEMERAL actually grew | Longhorn `storageMaximum` rises from 398.63 GiB on every worker | Pre-expansion value recorded in §3.1 |
| Probe can fail | `supervisorctl stop icarus-server`, confirm readiness flips to not-ready | The entire point; an always-passing probe has shipped in this repo before |
| ConfigMap reached the `.ini` | Read `ServerSettings.ini` off the PVC and compare every pinned key | **`MaxPlayers=6` is the sentinel.** Every other pinned value equals the first-boot heredoc default and would read back correct even if `sed` never ran |
| No cron was installed | `crontab -l -u icarus` in-pod is empty | — |
| Update ran at boot | `/opt/icarus/current_version` matches the `api.steamcmd.net` buildid for app `2089300` | — |
| Snapshots are happening | Snapshot CRs appear after 12:00 | An unlabelled Volume produces none |
| Players can connect | A real client joins from the LAN and starts a prospect | — |

---

## 13. Risks and open items

| Risk | Mitigation |
|---|---|
| Upstream image is low-activity; Wine-based, Proton migration open since 2025-02 | Pinned by digest; the game files themselves come from Steam at runtime, so image staleness does not block game patches |
| `pip3 install python-a2s` at every pod boot is a PyPI egress dependency | Non-fatal — failure only degrades the empty-check, which is unused with `UPDATE_CRON` off |
| Single-replica install volume: losing that node means a ~20 GB redownload | Accepted; the volume is disposable by construction |
| Longhorn still shares the EPHEMERAL partition with the containerd image cache | Accepted, see §4.2. Headroom, not isolation, is the mitigation |
| Wine process naming may defeat a `pgrep` probe | `supervisorctl` chosen instead; either is tested against a stopped server before use |

**Open items to resolve during implementation:**

1. Install `talosctl` on the operator workstation.
2. Confirm EPHEMERAL has no explicit `maxSize` before expanding.
3. Confirm the exact Talos v1.13.4 `machine.sysctls` schema against the docs rather than
   recollection.
4. Verify empirically, in the running container, which readiness command discriminates.
5. Measure real memory use under 2–6 players and revisit the `16Gi` limit.
