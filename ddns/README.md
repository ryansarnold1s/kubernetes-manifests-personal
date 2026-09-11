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
- **Don't edit the record's comment in the Cloudflare dashboard.** The comment is load-bearing:
  once it stops matching `MANAGED_RECORDS_COMMENT_REGEX`, the record silently falls out of
  management — no error in the log, updates just stop, and the name goes stale at the next WAN
  IP change. `tests/verify-ddns.sh` is what catches it.

## Adding a name

Append it to `IP4_DOMAINS` in `configmap.yaml` (comma-separated), apply, then
`kubectl rollout restart deploy/cloudflare-ddns -n ddns` (a ConfigMap edit needs the restart).
Each new name is only useful with its own router forward.

## Logs

```powershell
kubectl logs -n ddns deploy/cloudflare-ddns --tail=50
```
