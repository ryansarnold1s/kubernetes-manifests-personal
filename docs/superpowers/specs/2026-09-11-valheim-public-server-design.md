# Valheim Public (Vanilla) Server — Design

**Date:** 2026-09-11
**Status:** Approved in conversation; spec awaiting operator review
**Target cluster:** `k8` (Talos)
**Image:** `indifferentbroccoli/valheim-server-docker` v1.0.11, same digest as `valheim/`
(`sha256:3702926c5e174e4e28189136b512a034cacb9b57636c5d29d978e9a97c6e2f98`)
**Related:** `2026-09-10-valheim-1.0-rebuild-design.md` (the modded LAN server, unchanged by this)

---

## 1. Goal

A second Valheim 1.0 server, vanilla (no BepInEx, no mods), reachable by friends over the
internet through a router port-forward, on a fresh world. It lives beside the modded LAN
server and shares nothing with it but the image.

Friends join with **Join IP → `valheim.arnoldtech.io:2456`** and the password.

Non-goals: a SteamID allowlist (`permittedlist.txt`), a source-IP allowlist, crossplay,
listing in the community browser, a pihole override for LAN name resolution, network
isolation beyond what the pod itself can do, automatic restarts for game patches. Each was
offered and declined; §9 records why.

---

## 2. Decisions taken in brainstorming

| Question | Decision |
|---|---|
| Reachability | Router port-forward, WAN UDP 2456–2457 → a dedicated MetalLB IP |
| Access control | Password only. Unique to this server, never the LAN server's password |
| World | Fresh: `TreeFellMeVanilla` |
| Game updates | `UPDATE_ON_START=true`; a restart after a patch brings the server level |
| Difficulty | `SERVER_PRESET=Normal`, no `-setkey`, no `-modifier` |
| Friend-facing address | `valheim.arnoldtech.io`, a DNS-only record kept current by an in-cluster DDNS updater |
| LAN players | Join by LAN IP `192.168.130.157:2456`; pihole untouched |
| Flat cluster network | Accepted and documented (§8) |
| Patch-day restart | Manual `rollout restart`, with the connection check |
| Structure | Standalone `valheim-public/` and `ddns/` directories; no shared base with `valheim/` |

Server name `Deathsquito Vanilla` and world `TreeFellMeVanilla` were chosen by the
assistant and can be changed at spec review.

---

## 3. Facts established before design

Read from the live cluster and the image's scripts on 2026-09-11, not inferred.

| Fact | Consequence |
|---|---|
| Image ENV sets `MAX_PLAYERS=10`; `start.sh:69` enables BepInEx and installs MaxPlayerCount when `MAX_PLAYERS != "10"` | Pinned `"10"` explicitly. "Unset" is safe only because of an image default that could change |
| `start.sh:74`: non-empty `MODS` forces `BEPINEX_ENABLED=true` | `MODS` pinned to `""` |
| `start.sh:79`: the BepInEx install, `install_mods` and the `LD_PRELOAD` doorstop env all sit inside `if BEPINEX_ENABLED = true` | `BEPINEX_ENABLED: "false"` gives a genuinely vanilla process |
| `start.sh:15`: `-public` follows `PUBLIC_ENABLED`, not `PUBLIC` | This server pins `PUBLIC_ENABLED: "false"`, the real knob, so it stays out of the community browser |
| `start.sh:44`: the map key's env name is `NO_MAP` (the comment says `NO_MAPS`) | `NO_MAP` is the name pinned |
| `init.sh:27`: SteamCMD runs when `UPDATE_ON_START = true` **or** the binary is absent | `true` updates on every boot |
| `check_password` only warns, and only when the password is exactly `CHANGEME` (`Server Password has not been changed`) | The Secret template uses exactly `CHANGEME`, so an unreplaced template is visible in the log (§7) |
| Cluster egress, seen by `1.1.1.1/cdn-cgi/trace` from a pod, is a public IPv4 outside `100.64.0.0/10` | A port-forward is viable. The router's WAN address must match it; if not, there is double NAT (§6). The address is deliberately not recorded in git |
| `arnoldtech.io` is on Cloudflare (cert-manager's DNS01 issuer), apex proxied; `valheim.arnoldtech.io` has no public record | A new DNS-only record is created. Cloudflare's proxy does not carry Valheim UDP |
| pihole (Helm release `pihole`, chart 2.38.0, values not in any repo) has `address=/.arnoldtech.io/192.168.130.150` | On the LAN, the new name resolves to Traefik. LAN players use the IP |
| MetalLB `vlan130-pool` is `.150–.199`; LoadBalancers hold `.150 .154 .155 .156 .199` | `192.168.130.157` requested; the granted address is verified, not assumed |
| Worker `talos-0ag-qr8` has 14% memory / 59% CPU requested; every Longhorn disk has ≥154 GiB free; `longhorn` SC is 2 replicas | 2 CPU / 5Gi requests and 2×10Gi PVCs (≈40 GiB with replicas) fit |
| `favonia/cloudflare-ddns` v1.17.0 (2026-07-28), `sha256:61013368c8f95981c0bb8bf56d962078d8b4e95724a554fa2dabb20d6e478097` on Docker Hub; a long-running daemon (`UPDATE_CRON`), non-root 1000, reads the token from a file | The updater is a Deployment, not a CronJob. The digest is Docker Hub's tag digest and is re-checked for linux/amd64 at implementation |

---

## 4. `valheim-public/`

Namespace `valheim-public`, no PSA labels (cluster default `baseline`), label
`app: valheim-public` on everything.

### Files

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace, with the `baseline` comment carried from `valheim/` |
| `configmap.yaml` | `valheim-public-config`, every non-secret env var, with the why |
| `secret.yaml.template` | `valheim-public-secrets`, key `server-password`, value `CHANGEME` |
| `pvc.yaml` | `valheim-public-data` (`/valheim-saves`), `valheim-public-server` (`/valheim`), 10Gi each, `longhorn` |
| `deployment.yaml` | initContainer `write-adminlist` + game container |
| `service.yaml` | MetalLB LoadBalancer `192.168.130.157`, UDP 2456–2457 |
| `recurringjob.yaml` | `valheim-public-daily-snapshot`, group `valheim-public` (deploys to `longhorn-system`) |
| `README.md` | Joining, applying, router/DNS steps, operating notes, accepted risks |

### `configmap.yaml`

| Key | Value | Note |
|---|---|---|
| `SERVER_NAME` | `Deathsquito Vanilla` | Must not contain the password |
| `WORLD_NAME` | `TreeFellMeVanilla` | Fresh world |
| `PORT` | `2456` | |
| `TZ` | `America/Phoenix` | |
| `CROSSPLAY_ENABLED` | `false` | Steam networking; the port-forward is the path in |
| `PUBLIC_ENABLED` | `false` | The variable `start.sh` actually reads; keeps `-public 0` |
| `SAVE_INTERVAL` | `1800` | Stock |
| `SAVE_DIR` | `/valheim-saves` | Load-bearing, same reasoning as `valheim/` |
| `KEEP_BACKUPS` / `BACKUPS_SHORT` / `BACKUPS_LONG` | `4` / `7200` / `43200` | Stated explicitly |
| `SERVER_PRESET` | `Normal` | No `MODIFIER_*` |
| `NO_BUILD_COST`, `NO_MAP`, `PLAYER_EVENTS`, `PASSIVE_MOBS`, `FIRE_HAZARDS` | `false` | Pinned so a default change cannot persist a key into the world |
| `BEPINEX_ENABLED` | `false` | Vanilla |
| `MODS` | `""` | Non-empty forces BepInEx on |
| `MAX_PLAYERS` | `10` | Any other value forces BepInEx on and installs MaxPlayerCount. Vanilla cap is 10 |
| `UPDATE_ON_START` | `true` | SteamCMD on every boot. No mods to break |
| `BETA` | `public` | |
| `PUID` / `PGID` | `10000` | Required by `init.sh` |
| `ADMINLIST_IDS` | `76561197963378853` | Consumed by the initContainer |

`BEPINEXPACK_VERSION` is deliberately absent: it is read only inside the BepInEx branch.

### `deployment.yaml`

Carried from `valheim/` with their comments: `strategy: Recreate`,
`terminationGracePeriodSeconds: 120`, image by digest with `IfNotPresent`, `envFrom` the
ConfigMap plus `SERVER_PASSWORD` from the Secret, the bracketed `pgrep -f '[v]alheim_server'`
startup (10s × 120) and readiness (30s × 3) probes, no liveness probe, no CPU limit,
2 CPU / 5Gi requested and an 8Gi limit, no `fsGroup`.

Dropped: the `fetch-mods` initContainer, the `valheim-mods` ConfigMap, the `mod-scripts` and
`mod-tmp` volumes.

Added:

- **initContainer `write-adminlist`.** Same image, `command: ["/bin/bash", "-c", …]`, mounts
  only the saves volume, reads `ADMINLIST_IDS` by `configMapKeyRef`, and writes
  `/valheim-saves/adminlist.txt` with the header `// List admin players ID  ONE per line`
  and then one ID per line. It runs every boot, so a ConfigMap edit plus a restart is the
  procedure. Admin rights give the F5 console `kick`/`ban`, which matter on a server
  strangers can reach. Small requests (50m / 32Mi, limit 64Mi).
- **Pod hardening that the image tolerates:**
  - `automountServiceAccountToken: false` — nothing in the pod talks to the API.
  - `enableServiceLinks: false` — no Docker-link-style env vars for Services in the namespace.
  - `securityContext.seccompProfile.type: RuntimeDefault`.
  - Game container `capabilities.drop: ["NET_RAW"]` and `allowPrivilegeEscalation: false`.
    These two are **tried at implementation and kept only if the entrypoint still boots**;
    `init.sh` needs root for `usermod` and `chown -R`, so `runAsNonRoot` and `drop: ALL`
    are out.

### `service.yaml`

`type: LoadBalancer`, `metallb.io/loadBalancerIPs: 192.168.130.157`,
`externalTrafficPolicy: Local` (keeps real client IPs in the log, which is what makes a
`ban` meaningful), UDP `2456` game and `2457` query. **No `loadBalancerSourceRanges`**, by
decision: the comment says the password is the only gate and names `loadBalancerSourceRanges`
as the enforcement point if that ever changes, never NetworkPolicy (Flannel).

### `pvc.yaml` and `recurringjob.yaml`

Two 10Gi `longhorn` PVCs, with the same comments as `valheim/` (data is irreplaceable; the
server PVC is disposable). RecurringJob `valheim-public-daily-snapshot`: cron `15 11 * * *`,
15 minutes after the LAN job so the two never contend, `task: snapshot`, group
`valheim-public`, `retain: 7`, `concurrency: 1`. It binds via a label on the Longhorn
**Volume**, applied after the first boot.

### Secret

`secret.yaml` is gitignored by the existing `**/secret.yaml` rule; the template is committed.
The password must be new, at least 5 characters, not a substring of `SERVER_NAME`, and
**not** the LAN server's password, which sits in plaintext in the mumble ConfigMap. It is
shared with friends out of band.

---

## 5. `ddns/`

A cluster utility with a single job: keep `valheim.arnoldtech.io` pointed at the home WAN
IPv4. It is its own namespace so the Cloudflare token never shares a namespace with the
internet-facing root process.

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `ddns`, `pod-security.kubernetes.io/enforce: restricted` |
| `secret.yaml.template` | `cloudflare-ddns-token`, key `token` |
| `configmap.yaml` | `cloudflare-ddns-config`, the updater's env |
| `deployment.yaml` | `cloudflare-ddns`, one replica, `Recreate` |
| `README.md` | Token creation, verifying, adding a name |

### Token

A **new** Cloudflare API token with **Zone → DNS → Edit** on zone `arnoldtech.io` only,
created by the operator in the Cloudflare dashboard. Not the cert-manager token. Zone DNS
Edit cannot be narrowed to one record, so the token can rewrite any record in the zone; §8
records that. No client-IP filter on the token: after a WAN IP change, the updater's request
comes from the new address and a filter would reject exactly the call that fixes DNS.

### `configmap.yaml`

| Key | Value | Note |
|---|---|---|
| `CLOUDFLARE_API_TOKEN_FILE` | `/run/secrets/cloudflare/token` | Token from a file, not an env var |
| `IP4_DOMAINS` | `valheim.arnoldtech.io` | The only managed name |
| `IP6_PROVIDER` | `none` | No AAAA record: the game Service is IPv4 only |
| `IP4_PROVIDER` | `cloudflare.trace` | The pod's egress, which is the home WAN (§3) |
| `PROXIED` | `false` | Grey cloud. A proxied record would break UDP |
| `TTL` | `300` | Friends follow an IP change within about 5 minutes of the update |
| `UPDATE_CRON` | `@every 5m` | |
| `UPDATE_ON_START` | `true` | |
| `DELETE_ON_STOP` | `false` | Otherwise every pod restart deletes the record |
| `RECORD_COMMENT` | `managed by ddns/cloudflare-ddns (kubernetes-manifests-personal)` | |
| `MANAGED_RECORDS_COMMENT_REGEX` | `^managed by ddns/cloudflare-ddns` | The updater touches only records carrying its own comment |
| `TZ` | `America/Phoenix` | |

### `deployment.yaml`

`favonia/cloudflare-ddns:1.17.0@sha256:61013368c8f95981c0bb8bf56d962078d8b4e95724a554fa2dabb20d6e478097`
(re-verified for linux/amd64 at implementation),
`automountServiceAccountToken: false`, `enableServiceLinks: false`, pod `runAsNonRoot`,
`runAsUser`/`runAsGroup` 1000, `seccompProfile: RuntimeDefault`, container
`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
All of that satisfies `restricted`. `envFrom` the ConfigMap; the Secret is mounted read-only at
`/run/secrets/cloudflare` with `defaultMode: 0400` and the pod's `fsGroup` 1000. Resources
10m / 32Mi, limit 64Mi. No probes: the updater has no health endpoint and exits on a fatal
error, and the Deployment restarts it.

---

## 6. Outside the cluster (operator steps)

1. **Double-NAT check.** The router's WAN address must equal the cluster's egress IP from §3.
   If it does not, the router is behind another NAT and a forward cannot work; stop and
   revisit reachability.
2. **Cloudflare token** as in §5, pasted into `ddns/secret.yaml`.
3. **Router forward:** WAN UDP 2456 and 2457 → `192.168.130.157`, same ports. Nothing is
   forwarded to the LAN server (`.155`); the two keep port 2456 on separate IPs.
4. **CloudCasa:** confirm a policy covers namespace `valheim-public` and captures PVC data.
5. **Tell friends:** Join IP `valheim.arnoldtech.io:2456` plus the password. Steam clients
   only (crossplay off).

---

## 7. Verification

Every check names its negative case. A check only ever observed passing has not been
verified.

| Check | Pass | Negative case |
|---|---|---|
| Vanilla process | Game log has no `BepInEx` banner; `/valheim/BepInEx` does not exist | The LAN server's log shows the banner |
| No keys or modifiers | `/proc/<pid>/cmdline` has no `-setkey` or `-modifier`; has `-preset Normal`, `-public 0`, and no `-crossplay` | The LAN server's cmdline shows `-setkey nobuildcost` |
| No MaxPlayerCount | Game log has no `MaxPlayerCount` | `start.sh:116` logs it whenever the branch runs |
| Password replaced | Game log has no `Server Password has not been changed` | The committed template value, `CHANGEME`, produces exactly that line |
| Password enforced | A wrong password is refused at join | |
| Updates on start | The init log on the **second** boot (binary already present) shows SteamCMD running | With the flag false and the binary present, `init.sh:30` logs `UPDATE_ON_START is not set, skipping the SteamCMD update`; that line must be absent |
| Probe | `pgrep -f "[Z]ZZNOSUCH"` exits 1 in-container | The unbracketed form exits 0 unconditionally |
| Adminlist | `/valheim-saves/adminlist.txt` holds the ID | The file does not exist before the initContainer writes it |
| Hardening | `/var/run/secrets/kubernetes.io` absent in the game container; no `*_SERVICE_HOST` env other than `KUBERNETES_*` (always injected, whatever `enableServiceLinks` says) | The LAN pod has both: a token mount and `VALHEIM_SERVICE_HOST` |
| Granted IP | `kubectl get svc` shows `.157` | MetalLB silently assigns another address if `.157` is claimed |
| DNS record | `Resolve-DnsName valheim.arnoldtech.io -Server 1.1.1.1` returns the egress IP | A proxied record returns Cloudflare anycast (`104.21.x`/`172.67.x`), as the apex does today |
| DDNS scope | The updater log names only `valheim.arnoldtech.io` | |
| Internet join | A client **off** the home network (phone hotspot, or a friend) joins by name | The same client fails **before** the router forward exists, which proves the test path crosses the WAN rather than the LAN |
| Join by hostname | Valheim's Join IP accepts `valheim.arnoldtech.io:2456` | **Unverified before implementation.** Fallback: hand out the raw IP |
| Snapshots | A snapshot appears for the `valheim-public-data` Volume | A labelless Volume produces zero snapshots from a healthy-looking job |

---

## 8. Accepted risks

- **The game process runs as root and parses internet traffic.** It is a property of the
  image (`init.sh` never drops privileges). Mitigated by the pod hardening in §4, not
  removed.
- **The cluster network is flat.** Flannel does not enforce NetworkPolicy. A compromised
  game pod can reach every in-cluster Service over the network, including the shared
  `finance-service-cluster` Postgres and the Longhorn and Traefik endpoints. What stops it
  there is each service's own authentication. Real isolation (a CNI that enforces policy,
  host-level firewall rules through Talos, or a dedicated node) was offered and deferred.
- **Password-only access.** A leaked password lets anyone in until it is rotated. Rotation
  is: edit `secret.yaml`, apply, `rollout restart`, tell friends. `ban` plus the real client
  IPs from `externalTrafficPolicy: Local` handle an individual griefer.
- **The Cloudflare token can edit any `arnoldtech.io` record.** It lives only in namespace
  `ddns`, whose pod has no service-account token and runs non-root, read-only, with no
  capabilities.
- **The home WAN IP becomes public** through the DNS record. That is inherent to a
  port-forward.
- **Patch-day lockout.** Friends' clients auto-update; the server updates only when
  restarted. Until someone restarts it, newer clients are refused.

---

## 9. Declined alternatives

| Alternative | Why declined |
|---|---|
| Crossplay / PlayFab join code | No port-forward needed, but relay latency and a PlayFab dependency; a port-forward was viable |
| VPN (Tailscale) | Per-friend install and sign-in friction |
| `permittedlist.txt` SteamID allowlist | Operator chose password-only; each new friend would have needed a ConfigMap edit |
| `loadBalancerSourceRanges` allowlist | Residential IPs change and lock friends out silently |
| Kustomize base shared with `valheim/` | Couples the servers; the repo uses plain manifests; `valheim/` comments are mod-specific |
| pihole per-host override | pihole is Helm-managed from values outside this repo; a `kubectl` edit would be reverted |
| Nightly restart CronJob | Needs RBAC and kicks late players; manual restart chosen |
| DDNS as a CronJob | The chosen updater is a daemon with its own schedule; a CronJob would need a one-shot wrapper |

---

## 10. Documentation

- This spec.
- `valheim-public/README.md` and `ddns/README.md`.
- `CLAUDE.md`: a `valheim-public/` bullet (vanilla, internet-exposed, password-only, the
  `MAX_PLAYERS`/`MODS`/`BEPINEX_ENABLED` trio that keeps it vanilla) and a `ddns/` bullet
  (token scope, `PROXIED=false`, `DELETE_ON_STOP=false`).
- `icarus/service.yaml` and `icarus/README.md` are untouched. Their "if ever exposed" notes
  now have a worked example to point to, but they are not changed by this work.

---

**Correction (2026-09-11, implementation plan) — two details in §3 and §5 were wrong.**

1. **The token file mode is `0440`, not `0400`.** With `fsGroup: 1000` the mounted Secret file is
   owned by root and group-owned by 1000; `0400` leaves it readable by root only, and the
   updater runs as uid 1000. `0440` grants the group read.
2. **The updater is pinned by its linux/amd64 platform digest**,
   `sha256:0770cab737e58544f9b7a880ceaec41554797de2cc8eccdde7e77b788893c154`, not the tag's
   multi-arch index digest `61013368…` quoted in §3 — the same convention as the valheim image
   pin.
