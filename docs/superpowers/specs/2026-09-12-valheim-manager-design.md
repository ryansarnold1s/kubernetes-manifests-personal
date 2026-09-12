# Valheim Manager — Read-Only Dashboard — Design

**Date:** 2026-09-12
**Status:** Approved in conversation; spec awaiting operator review
**Target cluster:** `k8` (Talos)
**App repo:** new, `gameops` (Node) — image published to `gitea.arnoldtech.io`
**Manifests:** this repo, `gameops/`
**Namespace / hostname:** `gameops` / `gameops.arnoldtech.io`
**Related:** `2026-09-11-valheim-public-server-design.md`, `2026-09-10-valheim-1.0-rebuild-design.md`

---

## 1. Goal

One web page, reachable on the LAN, that answers "what is the state of every Valheim server
right now?" — up or down, who is connected, which game and mod versions are actually loaded,
whether the pinned mods match the loaded ones, resource headroom, and whether backups are
really happening.

**Version one is read-only.** It creates nothing, changes nothing, restarts nothing, and holds
no credential for anything it displays.

Non-goals for v1: starting and stopping servers, editing mods, editing configuration, a login,
history or trends, any game other than Valheim, and any write path to the cluster or to git.
Each was offered and deferred; §10 records why and what it would take to add them.

---

## 2. Decisions taken in brainstorming

| Question | Decision |
|---|---|
| Feasible on this cluster at all? | Yes — see §3; the constraint is memory, not the API |
| Scope of v1 | Read-only dashboard. No writes of any kind |
| Breadth | Valheim only. ICARUS and future games are a later adapter, not a v1 abstraction |
| Data access | Logs + Kubernetes API only. No `exec`, no sidecar, no file access |
| History | None. Live state only; no database, no volume |
| App repo | New Node repo `gameops`, image to `gitea.arnoldtech.io/arnold-tech/gameops` |
| Manifest location | **This repo**, `gameops/` — deliberately unlike `attendance-tracker`, which keeps its `k8s/` in the app repo (§7) |
| Naming | Everything is `gameops` — repo, image, namespace, manifest directory, hostname. v1 is still Valheim-only; the neutral name simply does not become a lie when ICARUS is added |
| Exposure | LAN-only through Traefik, wildcard TLS, no authentication in v1 |
| Refresh | Client polling on an interval. No SSE, no websockets |
| If writes are ever added | Git stays authoritative: the UI would commit to this repo and the change would be applied from there, never written straight to the cluster |

---

## 3. Facts established before design

Measured on 2026-09-12 against the live cluster and the shipped game binary, not assumed.

| Fact | Consequence |
|---|---|
| Every verb a manager needs is available, and admission accepted a scoped ServiceAccount + Role + RoleBinding on a server dry-run | A pod can drive this. Nothing about Talos blocks it |
| **Valheim 1.0 exposes no remote management interface at all** — mining `assembly_valheim.dll` for `rcon`, `RemoteConsole`, `HttpListener`, `WebSocket`, `RestApi`, `ServerQuery`, `telnet` returns nothing. Only `Terminal`/`ConsoleCommand` (the in-game F5 console) and the game's own `ZNet`/`ZRpc`/`ZSteamSocket` transport exist | Logs, the Kubernetes API, and files on the volume are the only sources. There is no fourth |
| An unlisted server (`-public 0`) answers no Steam A2S query — proven against the modded server, which is reachable and joinable yet silent to a direct A2S probe | Player counts cannot come from the standard game-server protocol. They come from the log |
| All 42 PVCs in the cluster are `ReadWriteOnce`; no RWX volume exists anywhere | A dashboard pod can never mount a world volume. File-derived data would require `pods/exec` |
| `pods/exec` is arbitrary command execution as root inside the game container | Ruled out for v1 (§6). It is not "read-only" in any security sense |
| metrics-server is present and `kubectl top` works; there is no Prometheus, Grafana or other TSDB | CPU/memory come from `metrics.k8s.io`. Trends would need storage this design does not have |
| Memory is the binding constraint on server count: workers sit at 36%, 49%, 59% and 76% of memory **requests**, with limits committed at 72%, 98%, 64% and 83%. Each Valheim server requests 5Gi and may use 8Gi | Roughly two more servers fit at today's sizing. The dashboard itself is small (§7) |
| Longhorn has 151–241 GiB free per node against ~40 GiB per server (2 volumes × 10Gi × 2 replicas); MetalLB has 44 free addresses of 50 | Neither disk nor addresses limit growth before memory does |
| pihole answers every `*.arnoldtech.io` name with Traefik's `192.168.130.150` | A dashboard hostname needs no DNS work at all — unlike the game server, which needed its own address because it is not HTTP |
| `attendance` runs `gitea.arnoldtech.io/arnold-tech/…` images with `imagePullSecrets: gitea-registry-secret`, ClusterIP services, and a `traefik-external` IngressRoute on `websecure` | The build-and-ship path already exists and this follows it |
| Headlamp already runs in the `kubescape` namespace | Generic pod/log/scale UI already exists. This app must earn its place on Valheim-specific facts only (§5), not by re-implementing Headlamp |

---

## 4. Architecture

A single Node service, in one container, that:

1. reads the Kubernetes API with a read-only ServiceAccount,
2. derives a `ServerStatus` object per discovered server,
3. serves those objects as JSON, and serves the built React assets from the same process.

No database. No volume. No background workers beyond a short-lived in-memory cache. Restarting
the pod loses nothing, because it owns nothing.

**Caching.** Each `ServerStatus` is cached in memory for 5 seconds. The page polls every 10
seconds, so a handful of open tabs cannot multiply into API-server load. `kubectl logs` reads
are the expensive part and are bounded: `sinceSeconds` for the recent-connection window, and
`tailLines` for the boot-line lookups.

**Discovery.** A server is any Deployment carrying the label `game=valheim`. Adding a third
server means adding that label to its Deployment — no code change, no config file. The two
existing servers get the label as part of implementation; that is the one and only write this
project makes to existing manifests, and it happens in git, applied by hand, as usual.

**Failure posture.** Every field is independently derivable and independently absent. A field
whose source is unavailable renders as **unknown**, never as zero and never as a stale value.
This matters most for log-derived fields: container logs rotate, so a long-running pod may no
longer contain its own boot lines.

---

## 5. What is shown, and where each value comes from

| Field | Source | Absent when |
|---|---|---|
| Up / ready / restart count / age | Deployment + Pod status | never (API is the source of truth) |
| CPU, memory, and memory as % of limit | `metrics.k8s.io` | metrics-server down |
| Game version, network version | log `Valheim version: l-1.0.12 (network version 40)` | boot lines rotated out |
| Mods **pinned** | the `MODS` table in the workload's mods ConfigMap | server has no mods ConfigMap (the vanilla server) |
| Mods **loaded** | log: BepInEx pack line, `ValheimPlus [x] is loaded`, Jotunn load line | boot lines rotated out |
| **Mod drift** | pinned set compared against loaded set | either side unknown |
| Players connected | log `Got connection` / `Closing socket` since the last restart, cross-checked against the periodic `Connections N` line | boot lines rotated out; the counter alone is up to 10 minutes stale |
| World size (ZDOs) | periodic `Connections N ZDOS:x` line | no status line in the retained log |
| Volume usage | Longhorn `Volume.status.actualSize` vs PVC request | Longhorn CR unreadable |
| Snapshot health | Longhorn `Snapshot` CRs for the volume **and** whether the Volume carries its `recurring-job-group.longhorn.io/<group>` label | Longhorn CRs unreadable |
| Update posture | `UPDATE_ON_START` from the ConfigMap | never (ConfigMap is the source) |
| Save health | `World save (n/5) … [Nms]` lines: last save time and duration | no save in the retained log |
| Address and ports | Service `status.loadBalancer.ingress` + ports | never |
| Vanilla or modded | `BEPINEX_ENABLED`, `MODS`, `MAX_PLAYERS` from the ConfigMap | never |

**Two fields exist because they catch real failures this repo has hit:**

- **Mod drift** — a `MOD_CONFIG` or `MODS` edit that was applied but never restarted, or a
  restart that silently failed, leaves pinned and loaded disagreeing. Today nothing surfaces
  that except running a script by hand.
- **Snapshot label** — a recreated PVC's Longhorn Volume starts unlabelled, and the
  RecurringJob then looks perfectly healthy while producing zero snapshots. The dashboard shows
  the label's presence, not just the job's existence.

**Deliberately not shown:** the server password or any Secret content; the admin list (it lives
on the volume and would need `exec`); exact world-directory bytes (volume usage is the proxy).

---

## 6. Security

**Identity.** One ServiceAccount, one ClusterRole, one ClusterRoleBinding. The ClusterRole
holds `get`, `list` and `watch` — no `create`, `update`, `patch`, `delete`, and no `exec` — on:

- core: `pods`, `pods/log`, `configmaps`, `services`, `persistentvolumeclaims`
- `apps`: `deployments`
- `longhorn.io`: `volumes`, `snapshots`, `recurringjobs`
- `metrics.k8s.io`: `pods`

**`secrets` appear nowhere in the ClusterRole.** The app never needs one, and this cluster's
policy denies reading them anyway.

**Pod hardening**, matching `ddns/`: `runAsNonRoot`, `readOnlyRootFilesystem`,
`allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`,
`enableServiceLinks: false`. The namespace enforces `restricted` Pod Security — unlike the game
servers, this image needs no root.

**Exposure.** LAN-only IngressRoute (`traefik-external`, `websecure`, empty `tls: {}` so it
inherits the `*.arnoldtech.io` wildcard, per `mealie/ingressroute.yaml`). **No authentication in
v1**, accepted because the page is read-only, displays no credentials, and is reachable only
from the LAN. Recorded as an accepted risk in §9 rather than assumed away.

---

## 7. Repo layout, build and deploy

**App repo `gameops`** (new), following `attendance-tracker`:

- `api/` — NestJS service: Kubernetes client, per-field derivation, log parsers, JSON endpoints.
- `web/` — React + Vite + Tailwind + TanStack Query, built to static assets the API serves.
- Multi-stage `Dockerfile` on `dhi.io/node:24-debian13-dev`, the base `attendance-tracker` uses.
  Verified 2026-09-12: this workstation has Docker 29.1.3 with logins configured for both
  `dhi.io` and `gitea.arnoldtech.io`, so the hardened base is available and no fallback is needed.
- Image `gitea.arnoldtech.io/arnold-tech/gameops:<semver>`, built and pushed from the
  workstation. There is no CI runner in-cluster.

**Manifests in this repo**, `gameops/`: `namespace.yaml`, `rbac.yaml`, `deployment.yaml`,
`service.yaml`, `ingressroute.yaml`, `README.md`. This deviates from `attendance-tracker`, which
keeps its manifests in the app repo; the operator chose consistency with `valheim/`, `ddns/` and
`mealie/` over consistency with `attendance-tracker`.

**One operator step:** the `gitea-registry-secret` image-pull Secret is namespaced and must be
created in the new namespace by hand (`kubectl create secret docker-registry`), exactly as it
exists in `attendance`. It is never committed.

**Sizing**, following the `attendance-api` precedent and this app's much lighter workload:
requests 100m / 128Mi, limits 500m / 256Mi. One replica; `Recreate` is unnecessary since it
mounts nothing.

---

## 8. UI scope

One page listing every discovered server as a card, each showing: name, vanilla or modded,
up/down with restart count, players connected, game version, mod drift state, CPU and memory
against limits, volume usage, last save, snapshot health, and the join address. A server card
expands to show the pinned-versus-loaded mod table and the recent connection events.

> **CORRECTION (2026-09-12, during implementation — not built, deliberately).** "The recent
> connection events" cannot be delivered and was dropped. The API exposes a player **count** and
> the source that count came from (`sockets` or `counter`), never the individual joins and
> disconnects. Reconstructing an event list would mean shipping raw game-server log lines to an
> unauthenticated LAN page — those lines carry player SteamID64s, so it is a privacy decision
> dressed as a UI feature, and §4's read-only-and-minimal posture argues against it. The mod
> table on expand **was** built. This correction previously existed only in the design canvas
> (`design/canvas.json` in the gameops repo), which left the binding spec promising a feature
> nobody can build; it is recorded here so the next reader meets it in the authority rather than
> in an artifact they may never open.
>
> Three smaller drifts from this spec are known, unfixed, and tracked as follow-ups rather than
> silently accepted: `cpuMillicores` and `updateOnStart` are fetched by the API but never
> rendered (§5 names both), and "last save" renders only the duration, not the time (§5 asks for
> both) — `lastSave.at` is a bare container-local timestamp with no timezone, so presenting it
> honestly needs a decision about whose clock it is, which is why it was not done in passing.

Visual design is deliberately out of scope for this spec. It is done at implementation with the
`/design` skill, using the operator's chosen references (`tasteskill.dev`, `impeccable.style`).
What this spec fixes is the **information architecture** above — what is shown, and what each
value means when it says "unknown".

---

## 9. Verification

Every check names its negative case, per the repo rule that a check only ever observed passing
has not been verified.

| Check | Pass | Negative case |
|---|---|---|
| Log parsers | unit tests over real captured fixtures from both live servers | a fixture with the boot lines removed must yield **unknown**, never 0 or a stale value |
| Mod drift | a fixture whose pinned set differs from the loaded set is reported as drift | an identical pair must report no drift — a detector that always fires is useless |
| Players connected | a fixture with two joins and one disconnect reports one connected | a fixture whose retained log predates the joins reports unknown, not 0 |
| Snapshot label | a volume missing its `recurring-job-group…` label is reported unhealthy | a labelled volume reports healthy |
| RBAC is genuinely read-only | `kubectl auth can-i --as=system:serviceaccount:gameops:gameops` returns **no** for `delete deployments`, `create pods`, `get secrets` and `create pods/exec` | the same command returns **yes** for `get pods` and `get pods/log`, proving the impersonation check works at all |
| Pod Security | the Deployment applies into a `restricted` namespace with no PodSecurity warning | a deliberately non-compliant probe pod is rejected |
| Reachability | `https://gameops.arnoldtech.io` serves the page on the LAN, on the wildcard certificate | no DNS record is created anywhere: pihole's `address=/.arnoldtech.io/192.168.130.150` already resolves it. If it does not load, the fault is Traefik or the IngressRoute, never DNS |
| No secret exposure | the ClusterRole names no `secrets` resource anywhere, and `kubectl auth can-i --as=system:serviceaccount:gameops:gameops get secrets` returns **no** | the same impersonation returns **yes** for `get pods`, proving the check can tell the two apart. **Do not** verify this by fetching the live password and grepping the response for it: reading a secret to test a guard is how one leaked into a transcript on 2026-09-11 |

---

## 10. Accepted risks and deferred features

- **No authentication.** Anyone on the LAN can read the dashboard. It shows no credentials and
  can change nothing. Revisit before any write action is added, and before exposing it beyond
  the LAN.
- **Log-derived data is only as good as the retained log.** Kubelet rotates container logs; a
  long-running pod loses its boot lines, and with them the game and mod versions. The UI says
  unknown rather than guessing. A restart restores them.
- **Player counts are approximate.** They are reconstructed from connect/disconnect events plus
  a counter that updates every ten minutes. This is the same approximation the operator already
  relies on before restarting a server.
- **Deferred: start/stop, mod editing, config editing.** Each needs write access, which needs
  authentication first, and (per §2) a git-authoritative write path rather than direct cluster
  mutation.
- **Deferred: history and trends.** Needs storage and a backup story; v1 owns no data on purpose.
- **Deferred: other games.** ICARUS has different logs, different mods and a different update
  model. A second game is what would reveal the right abstraction; guessing it now would be
  invention.

---

## 11. Declined alternatives

| Alternative | Why declined |
|---|---|
| **Agones** | Purpose-built for game servers on Kubernetes, but requires its SDK compiled into the game binary for health, lifecycle and state. Valheim has none, so Agones would manage a black box while adding a control plane |
| **Pterodactyl / Pelican** | Their node agent drives a Docker daemon. Talos is immutable and deliberately has none; emulating one in a privileged container fights the platform to duplicate what the cluster already does |
| **Catalyst** | Closer in spirit (containerd-based), but young and still node-agent-shaped rather than Kubernetes-API-shaped |
| **Extending Headlamp** | Already installed and already does generic pod/log/scale. It cannot express Valheim facts (players, mods, drift, world size), and a plugin would be a harder path than a small read-only service |
| **Sidecar per game server** (approach B) | Would add the admin list and exact world size with no extra permissions, but costs a restart of both servers and a container to maintain per server. Kept as the documented upgrade if those fields prove necessary |
| **Dashboard with `exec`** (approach C) | Full fidelity, but turns an unauthenticated LAN page into remote code execution as root inside the game containers |
| **Steam A2S queries** | Proven silent against an unlisted server on 2026-09-12. Not a data source here |

---

## 12. Settled at spec time, and the one item left

Settled on 2026-09-12, recorded so implementation does not re-open them:

1. **Hostname** `gameops.arnoldtech.io`. `valheim.arnoldtech.io` was unavailable — it is the
   public game server's own DNS record, created by `ddns/`.
2. **Base image** `dhi.io/node:24-debian13-dev`. The workstation has Docker 29.1.3 and logins
   for `dhi.io` and `gitea.arnoldtech.io`; no fallback needed.
3. **Namespace** `gameops`, matching the repo, image, manifest directory and hostname.

The one item that is genuinely implementation work:

4. The two existing game Deployments need the `game=valheim` discovery label. That is a normal
   reviewed change to `valheim/deployment.yaml` and `valheim-public/deployment.yaml`, applied in
   git like any other — and it restarts both servers, so it waits for an empty server, checked in
   the same action as the apply.
