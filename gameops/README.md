# gameops — game server dashboard

Read-only web dashboard for the Valheim servers on this cluster, at
`https://gameops.arnoldtech.io` (LAN only — pihole resolves every `*.arnoldtech.io` name to
Traefik, so no DNS record is needed).
App code: the `gameops` repo. Design: `../docs/superpowers/specs/2026-09-12-valheim-manager-design.md`.

## What it shows

Per server: up/down and restarts, players connected, game and network version, mods pinned
versus actually loaded (**drift**), CPU and memory against limits, volume usage, last save
duration, snapshot count and whether the volume carries its recurring-job label, and the join
address.

**A field reads `unknown` when its source is unavailable — never `0`.** Container logs rotate,
so a long-running pod eventually loses its own boot lines and with them the version and mod
information. A restart restores them.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `gameops`, Pod Security `restricted` |
| `rbac.yaml` | ServiceAccount + read-only ClusterRole + binding |
| `deployment.yaml` | The app, hardened, one replica |
| `service.yaml` | ClusterIP :3000 |
| `ingressroute.yaml` | `gameops.arnoldtech.io` on the wildcard cert |

## Applying

```powershell
cd gameops/
kubectl apply -f namespace.yaml -f rbac.yaml -f deployment.yaml -f service.yaml -f ingressroute.yaml
```

**First time only**, create the registry pull secret in this namespace (it is namespaced, and
never committed):

```powershell
kubectl create secret docker-registry gitea-registry-secret -n gameops `
  --docker-server=gitea.arnoldtech.io --docker-username=<user> --docker-password=<token>
```

## Discovery

A server appears on the dashboard when its Deployment carries the label `game=valheim`. Adding
a new server needs no change here — label it and it shows up.

## The permissions, and why they stop where they do

`get`/`list`/`watch` only. **`secrets` and `pods/exec` are deliberately absent.** The app never
needs a secret value, and `exec` would make an unauthenticated LAN page a way to run commands
as root inside a game container. If a future feature seems to need either, that feature needs
a login first.

## Accepted risks

- **No authentication.** Anyone on the LAN can read it. It is read-only and shows no
  credentials. Revisit before adding any write action or exposing it beyond the LAN.
- **Player counts are approximate**, reconstructed from connect/disconnect events plus a
  counter the server prints every ten minutes.
