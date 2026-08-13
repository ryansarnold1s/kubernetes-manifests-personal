# Deploy Mealie on the Talos Cluster — Design

**Date:** 2026-08-12
**Status:** Approved
**Scope:** A new `mealie/` workload directory, plus one cross-repo change to the shared
CloudNativePG cluster in `finance-manager`.

---

## 1. Goal

Run [Mealie](https://mealie.io) v3.22.0 as a self-hosted recipe manager at
`https://mealie.arnoldtech.io`, backed by a database on the **existing** CloudNativePG
cluster rather than a new Postgres instance, and reachable on the LAN through the
cluster's existing Traefik ingress.

Non-goals, deliberately:

- **No new Postgres.** The point of this design is to reuse `finance-service-cluster`.
- **No internet exposure.** LAN-only; no Cloudflare record, no forward-auth middleware.
  Mealie's own login is the gate.
- **No OIDC/SSO.** `ALLOW_PASSWORD_LOGIN` stays at its default.
- **No changes to any existing workload's behaviour.** The one edit to the finance
  Cluster adds a role; it must not alter the running finance app.

---

## 2. Cluster facts

Every row below was read off the live cluster on 2026-08-12, not from documentation.

| Property | Value |
|---|---|
| Ingress controller | Traefik, `LoadBalancer` `192.168.130.150`, entrypoints `web`(:8000) / `websecure`(:8443) |
| Traefik providers | `kubernetescrd` (ingressClass `traefik-external`, `allowCrossNamespace=true`) **and** `kubernetesingress` |
| House ingress pattern | `traefik.io/v1alpha1 IngressRoute`, annotation `kubernetes.io/ingress.class: traefik-external`, `entryPoints: [websecure]`, `tls: {}` |
| Default TLS | `TLSStore/default` in ns `traefik` → secret `local-arnoldtech-io-tls` |
| That cert | cert-manager `Certificate local-arnoldtech-io`, dnsNames `["arnoldtech.io","*.arnoldtech.io"]` |
| Issuer | ClusterIssuer `letsencrypt-production`, ACME **DNS-01 via Cloudflare**, zones `arnoldtech.io`, `zensity.cc` |
| DNS | `mealie.arnoldtech.io` **already resolves** to `192.168.130.150` (internal wildcard) |
| CNPG operator | `ghcr.io/cloudnative-pg/cloudnative-pg:1.27.0` — `databases.postgresql.cnpg.io` CRD present |
| Existing `Database` CRs | **none**, cluster-wide. Mealie's will be the first |
| Target DB cluster | `finance/finance-service-cluster` — 3 instances, `postgresql:18.3-standard-trixie`, 15Gi, `enableSuperuserAccess: false`, `spec.managed.roles` **empty** |
| Its backup | `ScheduledBackup finance-db-daily-backup`, `0 2 * * *`, retain 30d, volumeSnapshot method |
| Storage | Longhorn default SC, RWO, reclaimPolicy Delete |
| Mealie release | `v3.22.0`, published 2026-07-28 — confirmed current via the GitHub releases API |

### 2.1 The wildcard cert is reusable, but only via the TLS store

A plain `Ingress` cannot reference `local-arnoldtech-io-tls` because a TLS secret must live
in the Ingress's own namespace. An `IngressRoute` with an **empty** `tls: {}` sidesteps
this entirely: Traefik falls back to `TLSStore/default`, which is the wildcard. This is why
every app here uses `tls: {}` and none of them own a certificate.

**Consequence: Mealie needs no cert-manager object at all.**

---

## 3. Architecture

```
mealie ns                          finance ns                    traefik ns
┌──────────────────────┐          ┌────────────────────────┐    ┌──────────────┐
│ Deployment mealie    │          │ Cluster                │    │ TLSStore     │
│  :9000               │──5432───▶│  finance-service-      │    │  default     │
│  /app/data ─ PVC     │          │  cluster (3 inst,PG18) │    │  *.arnoldtech│
│  (Longhorn 10Gi RWO) │          │   spec.managed.roles:  │    └──────┬───────┘
│                      │          │     + mealie  ◀── NEW  │           │
│ Service :9000        │          │                        │           │
│ Middleware           │          │ Database CR    ◀── NEW │           │
│  mealie-headers      │          │  mealie / owner mealie │           │
│ IngressRoute ────────┼──────────┼────────────────────────┼───────────┘
│  mealie.arnoldtech.io│          │ Secret mealie-db       │
│  tls: {}             │          │  (basic-auth)          │
│ Secret mealie-db     │          └────────────────────────┘
└──────────────────────┘
```

Connection target is the CNPG read-write service, fully qualified because it is
cross-namespace: `finance-service-cluster-rw.finance.svc.cluster.local:5432`.

Cross-namespace traffic needs no policy work — **CNI is Flannel, so NetworkPolicy is not
enforced on this cluster.** There is correspondingly no network-level control preventing
the mealie pod from reaching the finance database; the isolation is Postgres role
privileges alone. That is accepted for a single-operator home cluster, and is the reason
§5 insists the `mealie` role is a plain login role with no `createdb`/`createrole`/`superuser`.

---

## 4. Key finding: the finance Cluster's repo file is stale

`finance-service-cluster` is **not** defined in this repository. It lives in
`finance-manager/k8s/database/cluster.yaml`, and that file no longer describes reality:

| Field | Repo file | Live object |
|---|---|---|
| `instances` | **1** | **3** |
| `storage.size` | **10Gi** | **15Gi** |
| `imageName` | *(unset)* | `ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie` |

Two further facts make this worse, and both were checked:

- The live Cluster's `kubectl.kubernetes.io/last-applied-configuration` annotation is
  **empty** — the object has not been maintained by `kubectl apply -f` from that file.
- `k8s/database/cluster.yaml` is referenced by **no** kustomization. (`k8s/wger/kustomization.yaml`
  references `cnpg/cluster.yaml`, which is wger's own, different file.)

So nothing reconciles the stale file today — but anyone who runs
`kubectl apply -f k8s/database/cluster.yaml` scales the finance database from three
instances to one. That landmine predates this work; it becomes relevant because Mealie
requires an edit to that same object.

### 4.1 Decision

Add the role with a **surgical `kubectl patch` scoped to `spec.managed`**, then, as a
separate committed change, correct `cluster.yaml` to match live reality *and* carry the
role. Patching first keeps the Mealie rollout independent of the repair; repairing the
file afterwards means the role is recorded in the finance repo and the 3→1 landmine is
defused.

The two changes are ordered patch-then-repair, and the repair is verified to be a no-op
against the live object (`--dry-run=server` diff showing only the `managed.roles`
addition) before it is applied.

---

## 5. Database provisioning

### 5.1 The role — a patch to the live Cluster

```yaml
# spec.managed on finance/finance-service-cluster
managed:
  roles:
  - name: mealie
    ensure: present
    login: true
    superuser: false
    createdb: false
    createrole: false
    inherit: true
    connectionLimit: 20
    comment: "Owner of the mealie database. Added 2026-08-12 for the Mealie workload in ns mealie."
    passwordSecret:
      name: mealie-db
```

`connectionLimit: 20` is bounded deliberately: the cluster runs `max_connections: 100`
and already serves the finance app. Mealie runs `UVICORN_WORKERS: 1`, so 20 is generous
headroom while making it impossible for Mealie to exhaust the pool and take finance down.

`passwordSecret` accepts only a `name` — the secret is resolved **in the Cluster's
namespace**, i.e. `finance`. CNPG requires it to be of type `kubernetes.io/basic-auth`
with `username` and `password` keys; this is asserted from CNPG's documentation and is
**verified at apply time** by confirming the role can actually authenticate (§9), not by
reading the Cluster's status.

### 5.2 The database — a `Database` CR

Schema confirmed against the live CRD via `kubectl explain` (`cluster.name`, `name`, and
`owner` are the required fields).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: mealie
  namespace: finance          # must match the Cluster's namespace
spec:
  cluster:
    name: finance-service-cluster
  name: mealie
  owner: mealie
  encoding: UTF8
  databaseReclaimPolicy: retain
```

`databaseReclaimPolicy: retain` is set explicitly rather than left to the default, so that
deleting the CR never drops the database.

### 5.3 Ordering constraint

The role must exist before the `Database` CR is applied — `spec.owner` must name an
existing role. And the database must exist before Mealie starts, or it crash-loops. §8
sequences this.

---

## 6. Files

### 6.1 New — `kubernetes-manifests-personal/mealie/`

Flat one-object-per-file, matching `mumble/`.

| File | Purpose |
|---|---|
| `namespace.yaml` | ns `mealie`. **No PSA labels** — inherits the cluster default `baseline`, which Mealie satisfies. Carries the same inline warning as `valheim/namespace.yaml` against adding `enforce: privileged` |
| `pvc.yaml` | `mealie-data`, 10Gi, `longhorn`, RWO — `/app/data` holds recipe images and Mealie's own backups |
| `secret.yaml.template` | Both Secrets in one file (see §7). Real `secret.yaml` is gitignored by the existing `**/secret.yaml` rule |
| `deployment.yaml` | See §6.3 |
| `service.yaml` | ClusterIP, port 9000 → `http` |
| `middleware.yaml` | `mealie-headers` in ns `mealie` — see §6.4 |
| `ingressroute.yaml` | See §6.5 |
| `cnpg-database.yaml` | The `Database` CR from §5.2. **Deploys into the `finance` namespace** |
| `recurringjob.yaml` | Longhorn daily snapshot, group `mealie`, retain 7. **Deploys into `longhorn-system`.** Carries `valheim/recurringjob.yaml`'s warning verbatim: the group binds to a label on the **Volume**, not the PVC |
| `README.md` | Operational detail, the cross-repo dependency, and the recovery path |

Two of these files deploy outside the `mealie` namespace — `cnpg-database.yaml` into
`finance` and `recurringjob.yaml` into `longhorn-system`. Both get a header comment saying
so, because `kubectl apply -f mealie/` from this directory would otherwise look like it
only touches one namespace.

### 6.2 Modified — `finance-manager/k8s/database/cluster.yaml`

Corrected to match live (`instances: 3`, `storage.size: 15Gi`, the PG18 image pin) plus
the `spec.managed.roles` block from §5.1, with a comment recording that the file had
drifted and that the values were recovered from the live object on 2026-08-12.

### 6.3 Deployment

- Image `ghcr.io/mealie-recipes/mealie:v3.22.0`, `replicas: 1`, **`strategy: Recreate`**
  (Longhorn RWO — a RollingUpdate would deadlock on the volume).
- `securityContext.fsGroup: 911` at pod level, with `PUID`/`PGID` `911`, so the Longhorn
  volume is group-writable by the uid Mealie drops to. The image's actual runtime uid is
  **verified inside the running container**, not assumed from the Dockerfile.
- Resources: requests `256Mi`/`100m`, limits `1Gi`/`1000m`. Mealie's recipe scraper is
  bursty; the limit is deliberately well above the request.

Environment:

| Variable | Value |
|---|---|
| `DB_ENGINE` | `postgres` |
| `POSTGRES_SERVER` | `finance-service-cluster-rw.finance.svc.cluster.local` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_DB` | `mealie` |
| `POSTGRES_USER` | `mealie` |
| `POSTGRES_PASSWORD` | from Secret `mealie-db`, key `password` |
| `BASE_URL` | `https://mealie.arnoldtech.io` |
| `ALLOW_SIGNUP` | `"false"` |
| `TZ` | `America/Phoenix` |
| `PUID` / `PGID` | `911` |

`POSTGRES_URL_OVERRIDE` is deliberately unset — the discrete variables are enough, and the
override would put the password in a non-secret-shaped field.

### 6.4 The headers middleware

The shared `traefik/default-headers` middleware is reachable cross-namespace, but its CSP
is `default-src 'none'` with **no `worker-src`, no `manifest-src`, and no `blob:` in
`img-src`**. Mealie v3 is a PWA with a service worker and blob-backed image previews, so
that CSP is a plausible breakage.

Rather than guess at the fix, Mealie follows the pattern wger already set — wger does not
use the shared middleware either, it owns a near-identical `wger-headers` in its own
namespace. So:

1. Ship `mealie-headers` as a faithful copy of `default-headers`.
2. Load the app and **read the browser console for CSP violations** (§9).
3. Apply the minimal recorded delta for whatever actually breaks, with the violation text
   quoted in the manifest comment as justification.

Predicted deltas, to be confirmed or refuted rather than pre-applied: `worker-src 'self' blob:`,
`manifest-src 'self'`, and `blob:` added to `img-src`/`media-src`.

`customRequestHeaders.X-Forwarded-Proto: https` is inherited from the copy and matters
here — Mealie builds OIDC callbacks and notification links from it alongside `BASE_URL`.

### 6.5 IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mealie
  namespace: mealie
  annotations:
    kubernetes.io/ingress.class: traefik-external
spec:
  entryPoints: [websecure]
  routes:
  - kind: Rule
    match: Host(`mealie.arnoldtech.io`)
    middlewares:
    - name: mealie-headers
      namespace: mealie
    services:
    - name: mealie
      port: 9000
  tls: {}
```

No `priority` field — unlike wger and finance, Mealie has a single route, so there is no
rule to disambiguate.

---

## 7. Secrets

One password, two Secret objects, because the two consumers read from different
namespaces:

| Object | Namespace | Type | Keys | Read by |
|---|---|---|---|---|
| `mealie-db` | `finance` | `kubernetes.io/basic-auth` | `username: mealie`, `password` | CNPG operator, for `managed.roles[].passwordSecret` |
| `mealie-db` | `mealie` | `Opaque` | `password` | the Mealie Deployment |

Both live in `mealie/secret.yaml`, which is gitignored; `secret.yaml.template` is
committed with placeholders, per the repo convention.

**The two values must match.** They are generated once and pasted into both objects. A
mismatch presents as Mealie failing authentication while the CNPG Cluster reports the role
as healthy — so §9 tests authentication with the *application's* copy of the credential.

Rotation means updating both objects and restarting the deployment; CNPG picks the new
password up on its next reconcile. This is recorded in `mealie/README.md`.

Note that `kubectl get/describe secret` is denied by policy on this machine, so both
Secrets are verified **functionally** (a successful login), never by reading them back.

---

## 8. Rollout order

Sequenced so that nothing starts before its dependency exists.

1. `postgres-expert` reviews the §5.1 patch and the §5.2 `Database` CR, file-only, with
   the context it needs: the app is live during the change, the cluster is 3-instance
   HA on PG18 with `max_connections: 100`, migrations here are forward-only, and the
   finance app is *not* being redeployed alongside.
2. Create both Secrets (§7).
3. `kubectl patch` `spec.managed` onto the live Cluster. Confirm the role by
   **authenticating as it** (§9.1).
4. Apply `cnpg-database.yaml`. Confirm `status.applied: true` and the database's owner.
5. Apply `namespace.yaml` → `pvc.yaml` → `middleware.yaml` → `deployment.yaml` →
   `service.yaml` → `ingressroute.yaml`.
6. Wait out `kubectl rollout status`, then complete first-run setup.
7. Apply `recurringjob.yaml` (into `longhorn-system`), then label the Longhorn **Volume**
   backing `mealie-data` with `recurring-job-group.longhorn.io/mealie=enabled`. The
   RecurringJob does nothing until that label exists, and the label goes on the Volume,
   not the PVC. Confirm a snapshot appears.
8. Repair `finance-manager/k8s/database/cluster.yaml` (§4.1) and commit it there.

Nothing in steps 2–7 causes downtime for finance or any other workload. Step 3 is the only
one that touches a shared object; CNPG applies role changes without restarting Postgres.

---

## 9. Verification

Per the repo's standing rule, a check only ever observed passing has not been verified.
Each item below states its negative case.

### 9.1 The role authenticates
Connect to `finance-service-cluster-rw` as `mealie` using the password from the
**`mealie` namespace** Secret — the application's copy — and run `SELECT current_user`.
*Negative case:* the same connection with a deliberately wrong password must be rejected.
This is what distinguishes "the operator wrote a role" from "the credential Mealie holds
actually works", and it is the check that catches a mismatch between the two Secrets.

### 9.2 The role is not over-privileged
`\du mealie` shows no `Superuser`, `Create role`, or `Create DB` attributes.
*Negative case:* as `mealie`, `CREATE DATABASE probe;` must fail, and a
`SELECT` against a real finance-owned table must be denied with `permission denied for
table`. Given §3 — no NetworkPolicy enforcement — role privilege is the only thing
isolating the two applications, so it is tested rather than assumed.

Note what this check does **not** claim. Postgres grants `CONNECT` on every database to
`PUBLIC` by default, so `mealie` *can* open a connection to the `finance` database and
read the catalog; `information_schema` will simply list nothing it lacks rights to. So
"cannot connect to finance" is the wrong assertion and would fail to fail. The correct
assertion is table-level denial, which is what is tested.

Tightening this further — `REVOKE CONNECT ON DATABASE finance FROM PUBLIC` — would be a
change to the finance application's own security posture and is **out of scope here**. It
is raised with `postgres-expert` at step 1 as a recommendation for the finance repo to
take separately.

### 9.3 The database exists and is owned correctly
`\l mealie` shows owner `mealie`, encoding `UTF8`; the `Database` CR reports
`status.applied: true`.

### 9.4 The health probe fails when it should
Pick Mealie's real unauthenticated health endpoint by enumerating it **from the running
container**, not from the docs. Then confirm the probe returns non-200 when the app is
genuinely unhealthy — the repo has shipped a no-op probe before, and an endpoint that
returns 200 from a static route while the DB is down is exactly that failure.
*Negative case:* with the DB unreachable, the readiness probe must go unready.

### 9.5 CSP does not break the UI
Load `https://mealie.arnoldtech.io`, sign in, open a recipe, and upload an image, with the
browser console open. **Zero CSP violations is the pass.** Any violation is quoted
verbatim into the `mealie-headers` manifest as the justification for its delta (§6.4).

### 9.6 TLS serves the wildcard
`openssl s_client -connect 192.168.130.150:443 -servername mealie.arnoldtech.io` shows the
`*.arnoldtech.io` certificate from `letsencrypt-production`.
*Negative case:* it must **not** be Traefik's self-signed default — that is what a missed
`TLSStore` lookup looks like, and it is indistinguishable from success in a browser that
has already been click-throughed.

### 9.7 Snapshots actually run
After labeling the Longhorn Volume, confirm a snapshot object appears for `mealie-data`.
*Negative case:* the RecurringJob with the Volume label **absent** produces nothing — the
documented failure mode from `valheim/recurringjob.yaml`, and the reason the label is
verified on the Volume rather than the PVC.

### 9.8 Applies took effect
Every `kubectl apply` reports `created` or `configured`. `unchanged` is treated as a
silent failure — usually the wrong working directory — not a success.

### 9.9 Finance is undisturbed
Before and after step 3: `finance-service-cluster` reports `Cluster in healthy state` with
3/3 ready, the primary is unchanged, and the finance app still serves. A failover or a
replica restart during a `managed.roles` patch would mean the patch was not as surgical as
believed.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| The stale `cluster.yaml` is applied by someone and scales finance 3→1 | Step 8 repairs the file. Until then, the risk is unchanged from today's baseline |
| Postgres 18 incompatibility with Mealie's SQLAlchemy migrations | Verified at step 6: first-run migrations must complete without error in the pod log. Mealie's own docs target `postgres:17`, so 18 is one major ahead of what upstream tests |
| Two Secrets drift apart on rotation | §9.1 tests with the application's copy, so drift fails the check rather than passing it |
| Mealie's writes affect finance DB performance | `connectionLimit: 20`; recipe workload is tiny. Worth a re-check if the household grows |
| CNPG `passwordSecret` type requirement is wrong | Asserted from docs; §9.1 is the functional proof either way |
| A future CNPG upgrade changes `Database` CR semantics | `databaseReclaimPolicy: retain` means the worst case is an orphaned database, not a dropped one |

---

## 11. Open items

- **`TZ: America/Phoenix`** is inferred from the operator's location, not stated. Trivially
  changed; called out so it is a decision rather than an accident.
- **Mealie's runtime uid** and **health endpoint path** are both specified as
  "verified in the running container" rather than pinned here, because the honest source
  of truth is the image, not this document.
