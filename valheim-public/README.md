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
| `tests/verify-public.sh` | Read-only live checks; run after every rollout. It is a post-rollout check, not an anytime health check: the log-based rows read `kubectl logs`, and on a long-running pod the boot lines they look for eventually rotate out, so those rows can fail with no real problem present |

The DNS record is kept by `../ddns/`.

## Applying

```powershell
cd valheim-public/                            # relative paths from repo root silently no-op
Copy-Item secret.yaml.template secret.yaml    # first time only; then set a NEW password
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
```

Every line must say `created` or `configured`; `unchanged` means the wrong directory.

The Deployment apply also prints `Warning: would violate PodSecurity "restricted:latest"` naming
only `capabilities.drop=["ALL"]` and `runAsNonRoot=true`. That is expected: the cluster warns at
`restricted` but enforces `baseline`, and this image needs root for `init.sh`. Do not "fix" it by
weakening anything else. Any **other** item in that warning is a real problem.

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
- ⚠️ **The password in use as of 2026-09-11 is known-weak, and the operator chose to keep it.**
  It is 7 characters and is character-for-character one of the operator's own public DNS zone
  names — a name that appears in a tracked file in this repo
  (`../docs/superpowers/specs/2026-08-12-mealie-deployment-design.md`), resolves publicly, and
  appears in issued certificates. Anyone who has seen this infrastructure can guess it, and it
  is the only thing between the internet and this world. It was additionally printed into an
  assistant session transcript on 2026-09-11 while inspecting the running process. Rotation was
  offered twice and declined; this note exists so the risk is written down rather than
  forgotten. **Rotate before widening who has the address**, and prefer a value that appears
  nowhere in this repo.
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
there works here with `valheim` → `valheim-public` (namespace, Deployment, label), `valheim-data`
→ `valheim-public-data` and `TreeFellMeAgain` → `TreeFellMeVanilla` — **except** the container
name `-c valheim` and the saves path `/valheim-saves`, which are identical on both servers and
must **not** be substituted.

## Rollback

Remove the workload, keep the world:

```powershell
cd valheim-public/                            # relative paths from repo root silently no-op
kubectl delete -f deployment.yaml -f service.yaml
```

Also remove the router forward, so the WAN port does not point at an address MetalLB may
reassign.

Tear down completely — **this destroys the world**:

```powershell
cd valheim-public/                            # relative paths from repo root silently no-op
kubectl delete -f deployment.yaml -f service.yaml -f recurringjob.yaml
kubectl delete -f pvc.yaml   # DESTRUCTIVE: storageClass longhorn has reclaimPolicy Delete
kubectl delete -f namespace.yaml
```

## Verified

2026-09-11, at deployment. Two rows are **untested**, not passed — they are listed so the gap
is visible rather than assumed.

| Check | Result |
|---|---|
| `tests/verify-public.sh` | 22 checks, 0 failed |
| Same script against the modded `valheim/` server | **≥6 failed, exit 1** — the proof each of those checks can fail. Six are stable every run: `cmdline: no -setkey`, `log: no BepInEx`, `process env: no BepInEx doorstop preload`, `no /valheim/BepInEx directory`, `no service-account token mounted`, `no service-link env vars`. Re-run 2026-09-11: 8 failed — the two extra, `log: SteamCMD was not skipped` and `log: SteamCMD ran this boot`, depend on which boot the LAN server's log currently covers (`UPDATE_ON_START=false` there, so the log can be arbitrarily stale relative to SteamCMD activity) and are not stable across runs. The plan only ever claimed "at least these six" |
| `../ddns/tests/verify-ddns.sh` | pass; the proxied apex as negative control exits 1 |
| Join from outside the LAN, by **hostname** `valheim.arnoldtech.io:2456` | **pass** — a friend connected 16:35, handshake, `Network version check their:40 mine:40`, character spawned. Valheim's Join IP box does accept a DNS name, so nobody needs the raw IP |
| Join from the LAN by `192.168.130.157:2456` | pass (operator, 15:53) |
| Join **before** the router forward existed | **not run.** The forward was added before the test, and the substitute (reading the game's UDP peer addresses) does not work: `/proc/net/udp` and `/proc/net/udp6` hold only unconnected listeners even with players on, because Valheim's Steam networking keeps no connected socket. So nothing here proves the packets crossed the WAN — what stands is a second Steam account completing a handshake on an address never handed out on the LAN, plus the friend's own account. Testimony corroborated by logs, not a network-path proof. Reconciling with the hostname-join row above: the 16:35 connection's SteamID (`…274743071`) is distinct from the operator's own (`…963378853`), so a genuine third party did connect over that address — real corroboration, but still not the missing control, which is proof the port was **closed** before the forward existed. The server did not independently prove WAN traversal |
| Wrong password refused | **not tested** — declined at deployment. The password is the only access control on this server; until someone tries a wrong one, "the gate works" is an assumption |
| Game container `securityContext` | kept — `allowPrivilegeEscalation: false` + `NET_RAW` dropped survived boot. The plan's fallback of weakening it was never needed |
| First boot | crash-looped twice on SteamCMD `Missing configuration`, then installed on the third attempt, exactly as `../valheim/README.md` records. Nothing was changed in response |
| CloudCasa covers `valheim-public` with PVC data | **pending** — not yet confirmed in the console. Until it is, the world's only protection is Longhorn snapshots on the same cluster |
| First Longhorn snapshot | pending the 11:15 UTC run. The Volume label is verified by `tests/verify-public.sh`; no on-demand snapshot was taken, because a snapshot here cannot be purged by deleting its CR |
