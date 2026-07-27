# Valheim Dedicated Server — Deployment Design

**Date:** 2026-07-26
**Status:** Approved
**Target cluster:** `k8` (Talos v1.13.4 / Kubernetes v1.35.4, Rancher-managed)
**Image:** `lloesche/valheim-server:sha-732221f4d5b5`

---

## 1. Goal

Run a persistent Valheim dedicated server on the `k8` Talos cluster for LAN/VPN players,
using the same manifest conventions as the existing `mumble/` deployment in this repo.

Non-goals: internet exposure, crossplay, mods (BepInEx / ValheimPlus), off-cluster DR,
migrating an existing world.

---

## 2. Cluster context

Facts established by inspection, recorded so future readers need not re-derive them.

| Aspect | Value |
|---|---|
| Nodes | 7 (3 control-plane, 4 worker), all `Ready` |
| CNI | **Flannel** — does *not* enforce NetworkPolicy |
| Ingress | Traefik, `IngressRoute` CRDs preferred over core `Ingress` |
| Load balancer | MetalLB, **L2 mode**, pool `vlan130-pool` = `192.168.130.150-199` |
| Storage | Longhorn, `longhorn` is the default StorageClass |
| TLS | cert-manager `letsencrypt-production`, wildcard `*.arnoldtech.io` as Traefik default cert |
| GitOps | Fleet installed but **zero `GitRepo` objects** — deployments are imperative |

Allocated LoadBalancer IPs at design time: `.150` traefik, `.153` enshrouded, `.154` mumble,
`.199` pihole. `.155` is free and is claimed by this design.

### Precedent: the Enshrouded server

The closest in-cluster analogue (`enshrouded` namespace) establishes the house game-server
pattern: namespace per game, `Deployment` with `strategy: Recreate`, MetalLB `LoadBalancer`
on a dedicated IP, split Longhorn PVCs for data and config, password in a `Secret`, no probes.
It currently sits at `replicas: 0` (parked).

Two Enshrouded conventions are **deliberately not copied** — see §6 and §8.

---

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Exposure | LAN / VPN only | No router port-forward; no public listing |
| World | Fresh | Nothing to migrate |
| Backups | Two layers | Image-native hourly + Longhorn daily snapshot |
| Updates | Nightly `0 5 * * *` | Stay current without interrupting evening sessions |
| Runtime | Always on, 1 replica | Workers have ~22GB free; no cold-start coordination |
| Delivery | Raw manifests, `kubectl apply` | Matches cluster norm; Fleet adoption later is zero-rework |
| Source allowlist | **None** | Considered and declined — see §7 |

---

## 4. Repository layout

```
kubernetes-manifests-personal/
├── mumble/
└── valheim/
    ├── README.md
    ├── namespace.yaml
    ├── configmap.yaml
    ├── secret.yaml.template     # real secret.yaml is gitignored
    ├── pvc.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── recurringjob.yaml
```

One file per resource kind, matching `mumble/`. The repo `.gitignore` already excludes
`**/secret.yaml` while permitting `**/secret.yaml.template`, so the real password never
enters version control.

---

## 5. Architecture

Namespace `valheim`. A single `Deployment` — not a `StatefulSet`, since there is exactly one
server and no ordinal identity to preserve — with `replicas: 1`.

**`strategy: Recreate` is mandatory, not stylistic.** The default `RollingUpdate` would start a
second pod claiming the same ReadWriteOnce Longhorn volume, which either deadlocks on volume
attach or allows two server processes to write one world file.

### Storage — two Longhorn PVCs

| PVC | Size | Mount | Purpose |
|---|---|---|---|
| `valheim-data` | 10Gi | `/config` | Worlds, adminlist, backups — the irreplaceable data |
| `valheim-server` | 10Gi | `/opt/valheim` | ~2–3GB game install; persisted to avoid SteamCMD re-download on restart |

Split so the irreplaceable data and the disposable-but-slow-to-rebuild install have
independent lifecycles: the install PVC can be deleted to force a clean reinstall without
risking a single world file.

### Resource names

Fixed here to remove ambiguity at implementation time.

| Kind | Name |
|---|---|
| Namespace | `valheim` |
| Deployment | `valheim` |
| Service | `valheim` |
| ConfigMap | `valheim-config` |
| Secret | `valheim-secrets` (key `server-password`) |
| PVC | `valheim-data`, `valheim-server` |
| RecurringJob | `valheim-daily-snapshot` |

Note the PVC holding `/config` is named `valheim-**data**`, not `valheim-config`. Naming it
`valheim-config` would collide with the ConfigMap of that name — legal in Kubernetes, since
they are different kinds, and `enshrouded` does exactly that, but it makes `envFrom` and
`claimName` references easy to misread. `mumble` avoids the collision the same way
(`mumble-config` ConfigMap, `mumble-data` PVC).

---

## 6. Workload configuration

Non-secret environment lives in a `ConfigMap` consumed via `envFrom`; only the password comes
from a `Secret`. This mirrors `mumble/deployment.yaml`.

### ConfigMap `valheim-config`

| Variable | Value | Note |
|---|---|---|
| `SERVER_NAME` | `Deathsquito Support Group` | Must not contain the password, or the server refuses to start |
| `WORLD_NAME` | `TreeFellMeFirst` | Becomes the literal `.db` / `.fwl` filename; no extension, no spaces |
| `SERVER_PUBLIC` | `false` | Suppresses master-server registration |
| `SERVER_PORT` | `2456` | 2457 derives from it |
| `TZ` | `America/Phoenix` | Drives when the cron schedules actually fire |
| `UPDATE_CRON` | `0 5 * * *` | Nightly update window |
| `BACKUPS` | `true` | |
| `BACKUPS_ZIP` | `true` | |
| `BACKUPS_CRON` | `0 * * * *` | Hourly |
| `BACKUPS_MAX_AGE` | `3` | Days — see sizing note |
| `BACKUPS_IF_IDLE` | `false` | **Changed from image default `true`** |
| `BACKUPS_IDLE_GRACE_PERIOD` | `3600` | Seconds backups keep running after the last player disconnects |
| `ADMINLIST_IDS` | *(empty)* | Editable later without redeploying |
| `PUID` / `PGID` | `10000` | See security note |
| `STATUS_HTTP` | `false` | Non-functional when `SERVER_PUBLIC=false` |

### Secret `valheim-secrets`

Key `server-password` = `<the value in the valheim-secrets Secret>`. Minimum 5 characters enforced by the server.
Committed only as `secret.yaml.template` with a placeholder.

### Backup sizing

`BACKUPS_IF_IDLE=false` is a deliberate change from the image default: left at `true`, an empty
server produces identical hourly backups around the clock and steadily consumes the PVC.

Hourly backups × 3 days retention ≈ 36 archives during active play (idle hours produce none).
At a late-game world of ~200MB compressing to ~80MB, that is ~3GB against a 10Gi PVC.

Hourly × 7 days would be ~168 archives and a genuine risk of filling the volume. Hence
granular retention is 3 days at the application layer, with the 7-day horizon provided by
volume snapshots instead (§9).

### Security — a necessary deviation from house style

`mumble` runs `runAsNonRoot: true, runAsUser: 10000`, and `enshrouded` runs `runAsUser: 10000`.
**Valheim cannot.** The `lloesche/valheim-server` entrypoint must start as root to run
supervisord, install via SteamCMD, and chown its volumes; forcing a non-root UID crashloops it.

Compromise adopted:

- Container starts as **root** (required, unavoidable).
- `PUID`/`PGID` = `10000` so the long-lived `valheim_server` process runs unprivileged as
  uid 10000, consistent with cluster convention.
- `fsGroup: 10000` keeps the Longhorn volumes writable.
- **No added capabilities.** `SYS_NICE` was originally specified here for the image's
  thread-priority tuning, but the cluster enforces Pod Security Admission at `baseline`
  by default for namespaces without PSA labels, and `valheim` carries none. `SYS_NICE`
  is not in baseline's permitted capability set. The ReplicaSet was rejected outright
  with `violates PodSecurity "baseline:latest": non-default capabilities`.

  Ruled 2026-07-26: drop the capability rather than label the namespace `privileged`.
  Upstream documents `SYS_NICE` as optional, so trading the namespace's entire security
  floor for a thread-priority tweak is a bad exchange. Seven namespaces in this cluster —
  `cattle-system`, `enshrouded`, `kubevirt`, `longhorn-system`, `metallb-system`,
  `pihole`, and `traefik` — do carry `pod-security.kubernetes.io/enforce: privileged`
  (plus `audit`/`warn: privileged`); privileged is the norm for infra namespaces in this
  cluster, not a two-off exception. `valheim` deliberately carries none of these labels,
  and so runs at a stricter baseline posture than any of them, achieved by dropping the
  optional capability instead of widening the namespace's security floor.

Net effect: root privilege exists for a few seconds of setup, not for the process exposed to
the network.

Capability hardening beyond `SYS_NICE` (dropping `ALL` and re-adding only `CHOWN`, `SETUID`,
`SETGID`, `DAC_OVERRIDE`, `FOWNER`) is plausible but unverified against this image, and is
therefore out of scope for v1 rather than guessed at.

### Resources

```yaml
requests: { cpu: "2", memory: "5Gi" }
limits:   { memory: "8Gi" }        # no CPU limit
```

The absent CPU limit is deliberate: CPU limits cause CFS throttling, which on a game server
manifests as rubber-banding. `enshrouded` sets requests-only for the same reason. Memory *is*
limited so that a leak cannot destabilise the node.

Upstream guidance: ~2.8GB RSS idle, ~30% of one core idle, recommend 8GB and a high-clocked
4-core. Workers `talos-0ag-qr8` and `talos-uup-vn3` were at 7–8% memory commitment
(~22GB free each) at design time, so no `nodeSelector` is needed.

### `terminationGracePeriodSeconds: 120`

**The highest-consequence value in this design.** Valheim needs roughly two minutes to flush
the world to disk on `SIGTERM`; upstream docs explicitly recommend `--stop-timeout 120`.

`enshrouded` uses 30 seconds. Inheriting that here would `SIGKILL` the server mid-save on
*every* restart — including the nightly update restart — risking world corruption on a
recurring schedule.

---

## 7. Networking

`Service` type `LoadBalancer`, **UDP 2456 and 2457 only**. No 2458 (crossplay / RPC mods, not
in use), no TCP.

- IP pinned to **`192.168.130.155`** via the `metallb.io/loadBalancerIPs` annotation. (Originally
  written as `metallb.universe.tf/loadBalancerIPs`; that prefix is deprecated and logs a
  `deprecatedAnnotation` warning on every reconcile under MetalLB v0.16.1.)
  Pinning matters more than usual: players type this address into Valheim's **Join IP** box, so
  a MetalLB reassignment would silently break every saved entry.
- `externalTrafficPolicy: Local` — keeps game packets on the node running the pod rather than
  SNAT-hopping via another node, and preserves the real client IP. Low risk at one replica.
  In-cluster precedent: `pihole/pihole-dns` already uses `Local`.

### Access control — explicitly scoped

`SERVER_PUBLIC=false` is **not** access control. It only prevents master-server registration so
the server does not appear in the community browser; it filters no packets. Any host that can
route to `192.168.130.155:2456` and knows the password can join.

Valheim's real controls are the password plus optional `PERMITTEDLIST_IDS` /
`BANNEDLIST_IDS` (SteamID64). Neither Valheim nor this image supports CIDR filtering.

Reachability is therefore determined by **routing, not by the application**:

- Hosts on `192.168.130.0/24` reach it directly at layer 2.
- Hosts on other `192.168.x.0/24` subnets reach it only if a router forwards between that
  subnet and VLAN 130 without an ACL blocking it.

**NetworkPolicy is not a usable lever on this cluster.** The CNI is Flannel, which does not
enforce NetworkPolicy; the four existing NetworkPolicy objects (`gitea`, `cloudcasa-io`,
`cattle-fleet-local-system`) are accepted by the API server and silently do nothing.

**Decision: no source allowlist.** `spec.loadBalancerSourceRanges` (enforced by kube-proxy,
independent of the CNI, honoured by MetalLB) was offered and declined. The password remains the
only gate, and the router decides who can route to `.155` — consistent with every other
LoadBalancer service in the cluster.

Should this be revisited, the change is a one-line, no-downtime edit to `service.yaml`:

```yaml
spec:
  loadBalancerSourceRanges:
    - 192.168.0.0/16
```

⚠️ If added, any VPN tunnel subnet must be listed explicitly. A `192.168.0.0/16` allowlist
would lock out VPN clients addressed on `10.x` (WireGuard/OpenVPN) or `100.64.0.0/10`
(Tailscale).

---

## 8. Health probing

**No liveness probe — by design.** A liveness probe firing during a world save would `SIGKILL`
the process mid-write and corrupt the world. The failure modes are already covered without
granting a probe that authority: supervisord restarts the game process internally if it dies,
and the Deployment restarts the container if supervisord itself exits.

Startup and readiness probes are *desirable* — they would stop MetalLB advertising a server
still performing a multi-GB SteamCMD install. The natural check is an exec probe on the server
process, but the standard signal is unavailable here: `STATUS_HTTP` and its `/status.json`
endpoint are documented as functional **only when `SERVER_PUBLIC=true`**, which this design
sets to `false`.

An unverified exec probe carries a specific failure mode: if the command is absent from the
image, readiness never becomes true, the Service registers no endpoints, and the server is
unreachable while appearing healthy.

**Approach:** deploy without probes initially (matching `enshrouded`), then exec into the
running container to confirm a probe command actually works, and add the readiness probe as a
verified follow-up. Verified, not guessed.

**Resolved in `c82acc9`:** `pgrep -f valheim_server` was confirmed against the running
container and added as both `startupProbe` and `readinessProbe` in `valheim/deployment.yaml`.
No liveness probe was added, per above.

**Correction — that verification was insufficient, and the probe it approved was a no-op.**
The check only asked "does this return 0 while the server is up?" It never asked "does it
return 1 when the server is down?" `pgrep -f` matches full command lines, so
`sh -c "pgrep -f valheim_server > /dev/null"` matches its *own* shell — argv included — and
returns 0 unconditionally. Both probes were therefore decorative from `c82acc9` until the fix:
the startup probe passed on its first tick regardless of state, and readiness could never drop
the Service's endpoints. That is the exact failure mode this section was written to prevent; it
shipped anyway because the verification was one-sided.

The `> /dev/null` is the active ingredient. Without a redirect bash exec-replaces the shell and
there is no parent left to self-match; with one, the shell survives and matches. That is why the
bare form looks correct under a manual smoke test.

Fixed by bracketing the pattern to `'[v]alheim_server'`, which matches the real process but not
the literal shell argv. Verified **both** directions in the live container — real process → 0,
a name that does not exist → 1 — with the probe invoked from a script file so no ancestor
process argv contained the pattern. `startupProbe.failureThreshold` was raised 60 → 120 at the
same time: the 10-minute budget had never actually been enforced, and a cold SteamCMD install
on a fresh `valheim-server` PVC can exceed it.

**Standing rule for any future exec probe here: verify the negative case.** A probe that has
only ever been observed passing has not been verified.

---

## 9. Backups and snapshots

Two independent layers:

1. **Application layer** — image-native hourly zipped backups into `/config/backups`,
   3-day retention, skipped while idle. Granular: restores a single world.
2. **Volume layer** — Longhorn `RecurringJob` `valheim-daily-snapshot`, cron `0 11 * * *`
   (11:00 UTC = 04:00 America/Phoenix — Longhorn crons are not TZ-aware, unlike the
   in-container `UPDATE_CRON`/`BACKUPS_CRON`; Arizona has no DST so this mapping is stable
   year-round), retain 7, group `valheim`. Mirrors the existing `wger-daily-snapshot` job.

Applied by label to **`valheim-data` only**. Snapshotting the 3GB re-downloadable game
install would be pure waste.

**Stated limitation:** Longhorn *snapshots* reside on the same volume, so they protect against
corruption and bad writes, not against loss of the volume itself. True off-cluster DR would
require a Longhorn *backup* target or CloudCasa (already present in-cluster). Out of scope.

---

## 10. Rollout and rollback

Apply order: `namespace` → `configmap` + `secret` → `pvc` → `deployment` → `service` →
`recurringjob`.

Verification:

1. Pod reaches `Running`; SteamCMD install completes (expect several minutes on first boot).
2. MetalLB assigns `192.168.130.155`; Service shows the external IP.
3. World files `TreeFellMeFirst.db` / `.fwl` appear under `/config/worlds_local`.
4. A LAN client joins via **Join IP** → `192.168.130.155:2456` with password `<redacted — see valheim-secrets>`.
5. Confirm a probe command inside the container, then add the readiness probe (§8) — done,
   see `valheim/deployment.yaml`.

Rollback: `kubectl delete -f valheim/` **while retaining the PVCs**. The world survives any
manifest error, so rollout mistakes are cheap.

---

## 11. Open items

- ~~Readiness probe command, pending empirical verification against the running container~~
  — resolved in `c82acc9`; see §8 and `valheim/deployment.yaml`.
- `ADMINLIST_IDS` intentionally empty; populate with SteamID64s when known. Requires only a
  ConfigMap edit and a pod restart.
- Capability hardening beyond `SYS_NICE`, if ever verified (§6).
