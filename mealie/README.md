# mealie

Recipe manager at https://mealie.arnoldtech.io. LAN-only by deliberate decision.

Its database lives on the **shared** `finance-service-cluster` in the `finance`
namespace — see "Where the database lives" below before changing anything.

## Verified image facts

Read out of a throwaway container running the real image on 2026-08-12, not from
upstream docs. Re-verify these on any image bump; none of them are guaranteed stable.

| Fact | Value | How it was checked |
|---|---|---|
| Image | `ghcr.io/mealie-recipes/mealie:v3.22.0` | pinned in `deployment.yaml` |
| Digest | `sha256:36c28f0642fb6c75fae8997a2d55994631b9b4bcffba3016c208fc132a4c1e69` | `kubectl get pod … -o jsonpath='{.status.containerStatuses[0].imageID}'` |
| Runtime uid:gid | `911:911` | `kubectl exec … -- id` showed `uid=0(root)` — that's the exec shell, not the app. The actual PID 1 process (`/opt/mealie/bin/python3 /opt/mealie/bin/mealie`) runs as `911:911`, read from `/proc/1/status` (`Uid`/`Gid` lines) |
| `/app/data` owner | `911:911` | `stat -c '%u %g %n' /app/data` |
| Unauthenticated GET routes | 28 paths with no `security` key in `openapi.json`, but only 3 return a genuine 200 with no query params: `/api/app/about`, `/api/app/about/startup-info`, `/api/app/about/theme`. The rest are parameterized (`{group_slug}`, `{recipe_id}`, …) or fail for unrelated reasons (`/api/auth/oauth` → 500 unconfigured OAuth, `/api/media/docker/validate.txt` → 404 no such asset, `/api/utils/download` → 400 missing required param) | `curl localhost:9000/openapi.json`, filtered for `paths.*.get` with no `.security`, then each candidate re-curled individually |
| Health endpoint used | `/api/app/about` | see below |

### Does the health endpoint cover the database?

**Yes for `/api/app/about` — it is genuinely DB-backed, which contradicts what the task brief
predicted. `/api/app/about/startup-info` is also DB-backed. `/api/app/about/theme` is not
(it returns static, hardcoded color values and never touches the database).**

Tested by breaking the database out from under a running container and re-requesting
every unauthenticated 200-yielding endpoint. First attempt was a plain `mv` of
`mealie.db` to `mealie.db.bak`: all three endpoints kept returning 200. **This result is
misleading, not a pass** — on Linux, `mv` within the same filesystem is a rename, and the
app already held the SQLite file open by file descriptor/inode, so it kept reading and
writing the exact same data under the new name. The rename never actually broke anything
the app could observe.

To get a real answer, the renamed file's *contents* were then overwritten in place
(`dd if=/dev/zero of=/app/data/mealie.db.bak bs=1024 count=50 conv=notrunc`) — same inode,
so the app's already-open fd sees the corruption immediately, no restart needed. Re-testing
after that:

- `/api/app/about` started returning `500`, consistently, across repeated requests. The
  server log traceback shows `get_app_info` (in `mealie/routes/app/app_about.py`) calling
  `public_repos.groups.get_by_name(settings.DEFAULT_GROUP)`, which raises
  `sqlalchemy.exc.DatabaseError: (sqlite3.DatabaseError) file is not a database`. This is a
  real, unambiguous DB query failure, not an artifact of the corruption method.
- `/api/app/about/startup-info` also started returning `500`, same root cause
  (`get_startup_info` runs `db.query(User).filter_by(email=...).count()`, same
  `file is not a database` error).
- `/api/app/about/theme` kept returning `200` throughout, with the same static color JSON
  body. It never touches the database.

Results:

| Endpoint | HTTP, DB healthy | HTTP, DB broken (rename only — misleading, see above) | HTTP, DB broken (contents corrupted in place) | DB-backed? |
|---|---|---|---|---|
| `/api/app/about` | 200 | 200 | 500 | **Yes** |
| `/api/app/about/startup-info` | 200 | 200 | 500 | **Yes** |
| `/api/app/about/theme` | 200 | 200 | 200 | No |

This matters because a probe that only ever passes has not been verified, and this repo
has shipped a no-op probe before. It also means Task 4 cannot use `/api/app/about` as a
"the process is alive" liveness check without accepting that it will also fail (correctly)
if the database is unreachable — which is actually the desired readiness-probe behavior,
but it is the opposite of what the task brief assumed going in. No endpoint among the
unauthenticated candidates is both DB-independent AND a meaningful liveness signal beyond
"the HTTP server is up" — `/api/app/about/theme` is DB-independent but proves nothing about
the app being functional beyond serving a static config.

## Where the database lives

Mealie does **not** get its own PostgreSQL cluster. It shares
`finance/finance-service-cluster` — the 3-instance CloudNativePG cluster that the
personal-finance app runs on. This is a deliberate co-tenancy decision, and it is the
reason every change in this directory that touches the database is treated as a change to
a live production system.

What Mealie owns on that cluster:

| Object | Where | Created by |
|---|---|---|
| Login role `mealie` | `finance-service-cluster`, via `spec.managed.roles` | patched into the live Cluster object, 2026-08-12 |
| Secret `mealie-db` (`kubernetes.io/basic-auth`) | ns `finance` | `secret.yaml` (gitignored; see `secret.yaml.template`) |
| Secret `mealie-db` (`Opaque`) | ns `mealie` | same file, same password |
| Database `mealie` | `finance-service-cluster` | `cnpg-database.yaml` |

**The two Secrets must hold the same password.** CNPG resolves
`managed.roles[].passwordSecret` in the *Cluster's* namespace (`finance`); Mealie reads its
own copy from `mealie`. A mismatch presents as Mealie failing authentication while the CNPG
Cluster still reports the role reconciled — the Cluster is telling the truth about the role,
it just knows nothing about Mealie's copy.

The `finance` Secret carries `cnpg.io/reload: "true"`. **Do not remove it.** Without that
label the operator does not watch the Secret at all: initial creation still works, but a
later password *rotation* silently no-ops — you edit the Secret, CNPG never reconciles, the
Postgres password never changes, and Mealie fails auth while `managedRolesStatus` still
shows `mealie` under `reconciled`.

### Role attributes as actually created

Read out of `pg_authid` on `finance-service-cluster-1` after the patch, not from the CR
(the CR states intent; the catalog states reality):

```
rolname|canlogin|super|createdb|createrole|inherit|replication|bypassrls|connlimit|validuntil|password
mealie |t       |f    |f       |f         |t      |f          |f        |20        |(null)    |SCRAM-SHA-256
```

`rolvaliduntil` is NULL, so the password does not expire. Hashing is SCRAM-SHA-256
(PostgreSQL 18's `password_encryption` default, confirmed `source=default` in `pg_settings`).
The role is a member of no other role — `pg_auth_members` returns zero rows for it — so it
inherits no privileges from anywhere.

`connectionLimit: 20` is a deliberate bound so Mealie cannot exhaust the pool the finance
app depends on. Note that **the live cluster runs `max_connections = 300`, not 100** — the
figure of 100 in the design spec and in the review artifact was wrong (live `pg_settings`:
`max_connections = 300`, `shared_buffers = 512MB`, both `source=configuration file`; ~17
sessions in use at the time of the change). The bound of 20 is therefore more conservative
than intended, not less, so it stands — but anything downstream that hardcodes 100 or 256MB
is repeating a stale number.

### The exact role block that was applied

The live Cluster object is the only authoritative copy. This is what went in, and it is what
`finance-manager/k8s/database/cluster.yaml` must say if it is ever reconciled with live —
field for field, comment string included, or the two will diff:

```yaml
spec:
  managed:
    roles:
    - name: mealie
      ensure: present
      login: true
      superuser: false
      createdb: false
      createrole: false
      inherit: true
      replication: false
      bypassrls: false
      connectionLimit: 20
      comment: "Owner of the mealie database. Added 2026-08-12 for the Mealie workload in ns mealie."
      passwordSecret:
        name: mealie-db
```

## The postgres-expert review of the role change (gate)

The role patch and the `Database` CR were reviewed by the `postgres-expert` agent **before**
being applied, file-only, per the mandatory review gate for shared-database changes. The
artifacts reviewed are in
`.superpowers/sdd/2026-08-12-mealie-deployment/pg-review-artifact.md`.

**Verdict: APPROVE WITH CHANGES.**

Mechanism the review confirmed sound: applying `spec.managed.roles` takes only a
`RowExclusiveLock` on `pg_authid`/`pg_shdescription` for a single sub-millisecond
transaction. The operator does **not** restart or roll the instances — roles are catalog
state, not `postgresql.conf` — so there is no rollout and no failover. There is no deadlock
path against concurrent finance queries; the lock sets are disjoint.

The four required changes, and how each was handled here:

| # | Required change | How it was handled |
|---|---|---|
| 1 | The `finance` Secret needs `cnpg.io/reload: "true"`, and must be applied from the committed file rather than created with `kubectl create secret generic` | Adopted **here**. The label is in `secret.yaml.template`; both Secrets were applied from `secret.yaml`. This required the `mealie` namespace to exist earlier than planned, so it was created in this step — a later apply of `namespace.yaml` therefore reports `configured`, not `created`, which is expected |
| 2 | `REVOKE ALL ON DATABASE mealie FROM PUBLIC` once the database exists — `datacl` is otherwise NULL, so the `finance` role could connect into Mealie's database and create temp objects there | Adopted, but it acts on the *database*, not the role, so it is carried by `cnpg-database.yaml` and not by the role patch |
| 3 | `ALTER ROLE mealie SET idle_in_transaction_session_timeout='60s', lock_timeout='10s', statement_timeout='300s'` — `connectionLimit` bounds how *many* sessions Mealie holds, nothing bounds how *long*, and one session left idle-in-transaction stalls vacuum of the **shared** catalogs and hence `datfrozenxid` cluster-wide | Adopted; also carried by the database step rather than the role patch. These settings land in `pg_db_role_setting`, which CNPG does not manage, so they survive role reconciliation |
| 4 | Pin `replication: false` and `bypassrls: false` explicitly rather than relying on defaults, so the role block is a complete auditable statement of the role's powers | Adopted **here**, in the applied patch; confirmed `f`/`f` in `pg_authid` above |

Two further review points were adopted in how the change was *carried out* rather than in
what was applied:

- **Credentials never go in a connection URI.** Probe pods use `--env=PGPASSWORD=…` with a
  password-free `postgresql://mealie@…` URI. The URI form would write the password into a
  Pod spec readable by anyone who can `kubectl get pod -o yaml`, and into shell history.
- **The patch file is not kept.** `kubectl patch --type=merge` is a JSON Merge Patch, which
  replaces the `roles` array wholesale. That was safe here because the array was empty.
  Re-running the same file after a second role has been added would silently drop that other
  role *from the spec* — CNPG then stops managing it without dropping it in Postgres, so it
  keeps working while quietly falling out of password reconciliation, a failure with no
  symptom until the next rotation. The file was written to `$env:TEMP`, applied once, and
  deleted. Its canonical home is `finance-manager/k8s/database/cluster.yaml`.

Two recommendations were deliberately **deferred**, not rejected:

- `REVOKE CONNECT ON DATABASE finance FROM PUBLIC` — by PostgreSQL default the `mealie` role
  can open a connection to the `finance` database (it cannot read finance's tables). Fixing
  this is a change to the finance application's own security posture and belongs to the
  finance repo.
- `Database.spec.extensions: pg_trgm` — nobody has established that Mealie's migrations issue
  `CREATE EXTENSION`. If a first boot fails on an extension, add it then, with the error as
  the evidence.

### Verified on application

Confirmed at the time of the change, not assumed:

- Positive: a throwaway pod in the `default` namespace authenticated as `mealie` against
  `finance-service-cluster-rw.finance.svc.cluster.local` and returned
  `current_user = mealie`.
- Negative: the same probe with a deliberately wrong password failed with
  `FATAL: password authentication failed for user "mealie"` (SQLSTATE 28P01). Without this
  the positive test proves nothing — a role created with no password would pass it.
- Finance undisturbed: `Cluster in healthy state ready=3/3 primary=finance-service-cluster-1`
  before and after, with **identical restart counts and identical pod start times** on all
  three instances and both poolers. The cluster phase alone would not have shown a rollout;
  the start times do.
- The password did not leak into the Postgres log: searching all three instances' logs for
  the literal password string and for `CREATE ROLE`/`ALTER ROLE` returned zero occurrences
  on each.
