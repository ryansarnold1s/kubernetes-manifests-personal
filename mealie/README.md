# mealie

Recipe manager at https://mealie.arnoldtech.io. LAN-only by deliberate decision — there is
no ingress rule or DNS record exposing it beyond the LAN, and no `loadBalancerSourceRanges`
is needed because Traefik's IngressRoute is itself only reachable on the LAN-facing IP.

Its database lives on the **shared** `finance-service-cluster` in the `finance` namespace —
see "Where the database lives" below before changing anything. That is the sharpest
consequence of this deployment and it is not optional reading.

**Two files in this directory deploy outside the `mealie` namespace**: `cnpg-database.yaml`
→ `finance`, `recurringjob.yaml` → `longhorn-system`. Applying every file in this directory
by name still deploys each object to its correct namespace — every file sets its own
`metadata.namespace` — but `kubectl get all -n mealie` will never show either object.

**Do not write `kubectl apply -f *.yaml`.** PowerShell's native `kubectl.exe` gets no glob
expansion for that pattern, so nothing after `-f` matches and the command fails.
`kubectl apply -f .` is the working form, and it is safe to use on this directory
specifically: kubectl only reads `.yaml`/`.yml`/`.json` files from a directory, so the
gitignored real `secret.yaml` is picked up while `secret.yaml.template` (no such extension
match) is skipped — it will not overwrite your password with the template's placeholder
value. That said, **on a fresh rebuild use the ordered sequence in "Deploying" below, not a
single `-f .`** — the database must exist before `deployment.yaml` is applied, and `-f .`
applies everything in one pass with no ordering guarantee.

## Layout

| File | Purpose | Namespace |
|---|---|---|
| `namespace.yaml` | Namespace `mealie`, no PSA labels (cluster default `baseline` applies) | `mealie` |
| `pvc.yaml` | `mealie-data` (`/app/data`) — recipe images, uploads, Mealie's own backup exports. **Not** the database | `mealie` |
| `secret.yaml.template` | Template for **two** Secret objects sharing one password — see "Where the database lives" | `finance` + `mealie` |
| `deployment.yaml` | The app | `mealie` |
| `service.yaml` | ClusterIP, port 9000 | `mealie` |
| `middleware.yaml` | Traefik headers/CSP (a per-namespace copy of the shared one) **plus the two rate-limit Middlewares** | `mealie` |
| `ingressroute.yaml` | `mealie.arnoldtech.io`, wildcard cert via `TLSStore/default`. **Two routes** — a strict-rate-limit route for the scraping endpoints and a catch-all | `mealie` |
| `cnpg-database.yaml` | The `mealie` `Database` CR against `finance-service-cluster` | **`finance`** |
| `recurringjob.yaml` | Longhorn daily snapshot of `mealie-data` | **`longhorn-system`** |

`secret.yaml` is gitignored; copy the template and set a real password before first apply.

The database **role** itself (`spec.managed.roles` on the Cluster object) is not in this
repo at all — see "The cross-repo dependency" below.

## Verified image facts

Read out of a throwaway container running the real image on 2026-08-12, not from upstream
docs. Re-verify these on any image bump; none of them are guaranteed stable.

| Fact | Value | How it was checked |
|---|---|---|
| Image | `ghcr.io/mealie-recipes/mealie:v3.22.0` | pinned in `deployment.yaml` |
| Digest | `sha256:36c28f0642fb6c75fae8997a2d55994631b9b4bcffba3016c208fc132a4c1e69` | `kubectl get pod … -o jsonpath='{.status.containerStatuses[0].imageID}'` |
| Runtime uid:gid | `911:911` | `kubectl exec … -- id` showed `uid=0(root)` — that's the exec shell, not the app. The actual PID 1 process (`/opt/mealie/bin/python3 /opt/mealie/bin/mealie`) runs as `911:911`, read from `/proc/1/status` (`Uid`/`Gid` lines) |
| `/app/data` owner | `911:911` | `stat -c '%u %g %n' /app/data` |
| Unauthenticated GET routes | 28 paths with no `security` key in `openapi.json`, but only 3 return a genuine 200 with no query params: `/api/app/about`, `/api/app/about/startup-info`, `/api/app/about/theme`. The rest are parameterized (`{group_slug}`, `{recipe_id}`, …) or fail for unrelated reasons (`/api/auth/oauth` → 500 unconfigured OAuth, `/api/media/docker/validate.txt` → 404 no such asset, `/api/utils/download` → 400 missing required param) | `curl localhost:9000/openapi.json`, filtered for `paths.*.get` with no `.security`, then each candidate re-curled individually |
| Health endpoint used for readiness | `/api/app/about` | see "Probes" below |

Re-verified inside the running pod after Task 4's deploy (`about: 200`, `theme: 200`, curled
directly against `http://localhost:9000`) — matches this table, not just inferred from a
throwaway container.

## Where the database lives

Mealie does **not** get its own PostgreSQL cluster. It shares
`finance/finance-service-cluster` — the 3-instance CloudNativePG cluster that the
personal-finance app runs on — as its **third** tenant, alongside `finance` (the app the
cluster was built for) and `attendance`. This is a deliberate co-tenancy decision, made
because standing up a fourth Postgres cluster for a low-traffic recipe manager was judged
not worth it, and it is the reason every change in this directory that touches the database
is treated as a change to a live production system.

**This repo's own precedent runs the other way.** `wger` (in the `finance-manager` repo, not
here) gets a dedicated `wger-db` CNPG cluster rather than a role on an existing one.
Co-tenanting Mealie was a deliberate departure from that pattern, not an oversight — record it
as a choice, not a default.

**Consequences of that choice, stated plainly:**

- **There is currently no restore path for Mealie's database at all — not a coupled one,
  none.** An earlier version of this README claimed a `finance-db-daily-backup`
  `ScheduledBackup` covered `finance-service-cluster` and, by extension, Mealie's data. That
  object does not exist: `kubectl get scheduledbackups.postgresql.cnpg.io -A` and
  `kubectl get backups.postgresql.cnpg.io -A` both return no resources cluster-wide (verified
  2026-08-12), and `finance-service-cluster.spec.backup` is empty. The manifest that would
  create it, `finance-manager/k8s/database/scheduled-backup.yaml`, exists in that repo but is
  never applied — nothing references it, the same trap `cluster.yaml` was in before Task 8
  repaired it. If this had been true, the consequence would have been that a Mealie restore
  requires rolling finance back to the same point in time and vice versa; since it is not
  true, the actual consequence is worse: finance, attendance, and mealie all have **zero**
  CNPG-level backup coverage today. See "Backups" below.
- **PostgreSQL has no per-database quota.** Mealie's data grows inside the same 15Gi Longhorn
  volume finance and attendance already share. Nothing here caps how large Mealie's tables can
  get, and a full PGDATA volume takes the **whole cluster** down — finance and attendance
  included, not just Mealie.
- **NetworkPolicy is not enforced on this cluster** (Flannel CNI). Nothing at the network
  layer stops the Mealie pod from reaching the finance database; the role's own privileges —
  verified below — are the only isolation that exists.

What Mealie owns on that cluster:

| Object | Where | Created by |
|---|---|---|
| Login role `mealie` | `finance-service-cluster`, via `spec.managed.roles` | patched into the live Cluster object, 2026-08-12 — canonical copy lives in `finance-manager/k8s/database/cluster.yaml`, a **different repo** (see "The cross-repo dependency") |
| Secret `mealie-db` (`kubernetes.io/basic-auth`) | ns `finance` | `secret.yaml` (gitignored; see `secret.yaml.template`) |
| Secret `mealie-db` (`Opaque`) | ns `mealie` | same file, same password |
| Database `mealie` | `finance-service-cluster` | `cnpg-database.yaml` |

**The two Secrets must hold the same password.** CNPG resolves
`managed.roles[].passwordSecret` in the *Cluster's* namespace (`finance`); Mealie reads its
own copy from `mealie`. A mismatch presents as Mealie failing authentication while the CNPG
Cluster still reports the role reconciled — the Cluster is telling the truth about the role,
it just knows nothing about Mealie's copy. See "Rotation" below for the safe order of
operations.

The `finance` Secret carries `cnpg.io/reload: "true"`. **Do not remove it.** Without that
label the operator does not watch the Secret at all: initial creation still works, but a
later password *rotation* silently no-ops — you edit the Secret, CNPG never reconciles, the
Postgres password never changes, and Mealie fails auth while `managedRolesStatus` still
shows `mealie` under `reconciled`.

### Corrections to the spec and the plan

Two figures were wrong in the design spec and the implementation plan. Both were checked
against `pg_settings` on the live cluster, not assumed from those documents:

- **The live cluster runs `max_connections = 300` and `shared_buffers = 512MB`**, not the
  100 / 256MB the spec and plan claim throughout (`source=configuration file` for both,
  confirmed via `pg_settings`; ~17 sessions in use at the time of the check).
  `finance-manager/k8s/database/cluster.yaml` **already carries the correct 300 / 512MB
  figures** — it was repaired from the same wrong 100 / 256MB values as part of this
  deployment (Task 8) and is committed but deliberately not applied (applying it would stamp
  a `last-applied-configuration` annotation that makes future applies prune live-only fields,
  and would have forced an unplanned restart of all three instances to shrink a live
  `max_connections`). `kubectl diff -f finance-manager/k8s/database/cluster.yaml` against the
  live object is empty. See the correction appended to
  `docs/superpowers/plans/2026-08-12-mealie-deployment.md` for the full account.
- **`connectionLimit: 20` for the `mealie` role is tested, not assumed.** 20 concurrent
  sessions connected successfully and the 21st was rejected with
  `FATAL: too many connections for role "mealie"` — see the isolation-test table below (test 6).
  Because the real `max_connections` is 300, not 100, this bound is more conservative than it
  was designed to be, not less — it stands as-is, but anything downstream that still hardcodes
  100 or 256MB is repeating a stale number.
- **`finance-db-daily-backup` does not exist.** The spec's §2 "Cluster facts" table and an
  earlier version of this README both asserted it as a verified fact; neither verification
  actually happened. See "Backups" below and the correction appended to
  `docs/superpowers/specs/2026-08-12-mealie-deployment-design.md`.

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

### The exact role block that was applied

The live Cluster object is the only authoritative copy. This is what went in, and it is what
`finance-manager/k8s/database/cluster.yaml` must say if it is ever reconciled with live —
field for field, including the CNPG `comment:` field, or the two will diff. (A YAML `#`
comment above the block is not part of the object and never affects `kubectl diff`; it is
only the `comment:` key inside `spec.managed.roles[]` that CNPG sends to Postgres and that
this statement is about.)

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

### The postgres-expert review of the role change (gate)

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
| 2 | `REVOKE ALL ON DATABASE mealie FROM PUBLIC` once the database exists — `datacl` is otherwise NULL, so the `finance` role could connect into Mealie's database and create temp objects there | Adopted, and **applied 2026-08-12** with the database. It acts on the *database*, not the role. It is **not** in `cnpg-database.yaml` — CNPG's `Database` CR has no ACL field — see "Ad-hoc SQL applied alongside the Database CR" below |
| 3 | `ALTER ROLE mealie SET idle_in_transaction_session_timeout='60s', lock_timeout='10s', statement_timeout='300s'` — `connectionLimit` bounds how *many* sessions Mealie holds, nothing bounds how *long*, and one session left idle-in-transaction stalls vacuum of the **shared** catalogs and hence `datfrozenxid` cluster-wide | Adopted, and **applied 2026-08-12** with the database. Also not in any manifest: these land in `pg_db_role_setting`, which CNPG does not manage, so they survive role reconciliation. See the same section below |
| 4 | Pin `replication: false` and `bypassrls: false` explicitly rather than relying on defaults, so the role block is a complete auditable statement of the role's powers | Adopted **here**, in the applied patch; confirmed `f`/`f` in `pg_authid` above |

Two further review points were adopted in how the change was *carried out* rather than in
what was applied:

- **Credentials never go in a connection URI.** Probe pods use `--env=PGPASSWORD=…` with a
  password-free `postgresql://mealie@…` URI. The URI form would put the password directly in
  the shell command — visible in shell history and, since it becomes a container arg, also
  in `.spec.containers[].args` — and inside the connection string itself, which tends to get
  copy-pasted into logs and terminals whole. `--env=PGPASSWORD=…` closes those two paths, but
  it is **not** a way to keep the credential out of reach altogether: the value still lands in
  the Pod spec, this time under `.spec.containers[].env`, and is readable by anyone who can
  run `kubectl get pod -o yaml`. Nothing here closes that path; the mitigation only avoids the
  shell-history and bare-connection-string exposure the URI form adds on top.
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

## The cross-repo dependency

The `mealie` role does not live in this repo at all. It lives in `spec.managed.roles` on the
`Cluster` object defined in `finance-manager/k8s/database/cluster.yaml` — a different
repository, owned by the finance deployment. This repo only carries the `Database` CR
(`cnpg-database.yaml`, which requires the role to already exist) and the two password
Secrets.

**Deleting or reverting that role block does not fail loudly here.** It breaks Mealie's login
with `FATAL: password authentication failed for user "mealie"` or `role "mealie" does not
exist` — an error that looks exactly like a Mealie bug (bad password, bad Secret, app
misconfiguration) and gives no hint that the actual cause is a role definition that lives in
an entirely different repository. If Mealie's auth breaks with no local change having been
made, check `finance-manager/k8s/database/cluster.yaml` and the live Cluster's
`spec.managed.roles` before debugging anything in this directory.

## The `mealie` database

Created 2026-08-12 by `cnpg-database.yaml`. The CR reports
`{"applied":true,"observedGeneration":1}` with no `message`. Verified in the catalog rather
than trusting that status:

```
datname|owner |encoding|datacl
mealie |mealie|UTF8    |{mealie=CTc/mealie}
```

`databaseReclaimPolicy: retain` is set explicitly, so deleting the CR detaches the object
without dropping the database.

### Ad-hoc SQL applied alongside the Database CR

**This SQL is live on the cluster and lives in no manifest.** CNPG's `Database` CR has no
field for database ACLs, and role-level GUCs live in `pg_db_role_setting`, which CNPG does
not manage at all. Nothing will re-apply either of these if they are undone — and nothing
will warn you. **If you recreate this database, run both again.** An undocumented `REVOKE`
is exactly the kind of thing a future operator undoes by accident while "cleaning up" — it is
recorded here, prominently, for that reason.

```sql
-- Executed as `postgres` on finance-service-cluster-1 (the primary), 2026-08-12.

-- Review change 2. CNPG leaves datacl NULL on a database it creates, which means PUBLIC
-- keeps CONNECT and TEMP — so `finance` and `attendance` could connect into Mealie's
-- database and create temp objects there. REVOKE ... FROM PUBLIC does not touch the owner,
-- so this cannot lock Mealie out; `mealie` keeps CONNECT/CREATE/TEMP as datdba.
REVOKE ALL ON DATABASE mealie FROM PUBLIC;

-- Review change 3. connectionLimit: 20 bounds how MANY sessions Mealie holds; nothing
-- bounds how LONG. One session left idle-in-transaction blocks vacuum of the SHARED
-- catalogs and stalls mealie's datfrozenxid, which over weeks trips cluster-wide wraparound
-- protection and would take finance read-only with it. 300s is deliberate headroom for
-- Mealie's first Alembic migration run and can be tightened once that is known to be quick.
ALTER ROLE mealie SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE mealie SET lock_timeout = '10s';
ALTER ROLE mealie SET statement_timeout = '300s';
```

Both verified after the fact, not assumed. `datacl` went from `(NULL)` to
`{mealie=CTc/mealie}`. The GUCs landed with `setdatabase = 0`, i.e. for the role across every
database on the cluster:

```
$ psql -tAc "SELECT coalesce(setdatabase::text,'0'), setconfig FROM pg_db_role_setting WHERE setrole='mealie'::regrole;"
0|{idle_in_transaction_session_timeout=60s,lock_timeout=10s,statement_timeout=300s}
```

Reading `pg_db_role_setting` only proves the rows exist. A real session as `mealie` was also
asked what it had in effect, which is the assertion that actually matters:

```
idle_in_transaction_session_timeout|60000 |user
lock_timeout                       |10000 |user
statement_timeout                  |300000|user
```

`source=user` is the proof these came from the role setting and not from a cluster default.

### The `public` schema ACL — checked, and it is the safe PG15+ shape

This one fact decides whether Mealie's migrations can create tables at all, so it was read
rather than assumed:

```
$ psql -d mealie -tAc "SELECT nspname, pg_get_userbyid(nspowner), nspacl FROM pg_namespace WHERE nspname='public';"
public|pg_database_owner|{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}
```

Owner is `pg_database_owner` and PUBLIC holds only `USAGE` — the PostgreSQL 15+ default, not
the legacy `GRANT ALL ON SCHEMA public TO PUBLIC`. No legacy ACL was inherited from
`template1`, so **no corrective `ALTER SCHEMA` / `REVOKE CREATE` was needed**. If a future
restore or a rebuilt `template1` ever shows owner `postgres` or PUBLIC with `=UC`, fix it:
every role on the cluster can create objects in Mealie's database in that state.

The `finance` database was checked too and is the same safe shape — which is *why* the
isolation test below denies correctly. Do not read that denial as something this task
configured; it is the PG15 default doing its job.

### Isolation and privilege tests

All run from throwaway `--rm` pods in `default`, authenticating as `mealie` over
`finance-service-cluster-rw`. Per the credential rule these use `--env=PGPASSWORD=…` with a
password-free URI — never a password embedded in the connection string.

| # | Test | Expected | Observed |
|---|---|---|---|
| 1 | `CREATE TABLE pgprobe(i int); DROP TABLE pgprobe;` in `mealie` | succeed | `CREATE TABLE` / `DROP TABLE` — **pass** |
| 2 | `CREATE DATABASE probe;` as `mealie` | fail | `ERROR: permission denied to create database` |
| 3 | `CREATE TABLE public.pgexpert_probe(i int);` in `finance` | fail | `ERROR: permission denied for schema public` |
| 4 | `SELECT count(*) FROM public._prisma_migrations` in `finance` | fail | `ERROR: permission denied for table _prisma_migrations` |
| 5 | `CREATE TEMP TABLE t(i int);` in `finance` | **succeed** (baseline, not a failure) | `CREATE TABLE` |
| 6 | 21 concurrent sessions as `mealie` | 21st rejected | `SUCCESSES=20 FAILURES=1`, `FATAL: too many connections for role "mealie"` |

Notes that matter more than the table:

- **Test 1 is the one that had to pass.** Ownership being real is what the first boot
  depends on; `permission denied for schema public` here would have surfaced later as an
  opaque crash loop instead of a clear failure now.
- **Test 3 is not redundant with test 4.** Reads are not the whole surface. Had `finance`
  carried the pre-PG15 `GRANT ALL ON SCHEMA public TO PUBLIC`, `mealie` could have planted
  tables inside finance and consumed its disk while the read-only test in test 4 still
  passed. It does not, and no `pgexpert_probe` table exists in `finance` (confirmed: 0 rows
  in `pg_tables`). The deferred `REVOKE CREATE ON SCHEMA public FROM PUBLIC` on `finance` is
  therefore **not needed** — that grant is already absent.
- **Test 5 succeeding is expected and is not a leak.** `finance`'s `datacl` is still NULL, so
  PUBLIC holds `CONNECT` and `TEMP` on it — every role on this cluster can connect to
  `finance` and create temp objects there. That is the standing deferred item
  (`REVOKE CONNECT ON DATABASE finance FROM PUBLIC`), it belongs to the finance repo, and it
  predates Mealie. Recorded here as the observed baseline so a future reader does not
  rediscover it as a regression. For contrast, the three databases' ACLs today:
  `finance` → `(NULL)`, `attendance` → `{=Tc/attendance,attendance=CTc/attendance,…}`,
  `mealie` → `{mealie=CTc/mealie}`. **`mealie` is the only one of the three that is locked
  down.**
- **Test 6 is the first time `connectionLimit: 20` was proven rather than believed.** Exactly
  20 sessions connected and the 21st was refused, so `rolconnlimit` is genuinely enforced and
  finance's connection pool is protected from Mealie. The probe connects to the `-rw` service
  directly, not through the pooler; a future test routed via `finance-pooler-rw` would be
  measuring PgBouncer, not `rolconnlimit`.

`\du mealie` reports only `20 connections` — no `Superuser`, `Create role` or `Create DB`.

### Finance was undisturbed

Cluster health, per-pod restart counts and pod start times were captured before and after and
are **byte-identical** to the pre-change baseline: `ready=3/3`,
`primary=finance-service-cluster-1` (unchanged, also `targetPrimary`), zero restarts on all
three instances and both poolers, start times unchanged. Creating a database and revoking an
ACL are catalog operations — no rollout, no failover. Afterwards, zero `mealie` sessions
remain in `pg_stat_activity` and no probe pods remain in `default`.

## Deploying

**Order matters.** `deployment.yaml` must not be applied before the `mealie` database exists —
on a fresh rebuild the pod would come up, `init_db.main()` would hard-exit because there is no
database to connect to, and you would be staring at exactly the CrashLoopBackOff the "Steady-
state database loss" / boot-time-failure sections below spend a lot of words explaining. It
self-heals once the `Database` CR lands, but there is no reason to manufacture that confusing
state. The full sequence, in order:

1. **Cross-repo prerequisite — confirm the `mealie` role exists on `finance-service-cluster`
   first.** This step lives outside this repo and outside this apply sequence:
   ```powershell
   kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance -o jsonpath='{.spec.managed.roles}'
   ```
   The `mealie` role (see "The exact role block that was applied" above for the exact fields)
   must already be present. If it is not, apply it with `kubectl patch --type=merge` per that
   section — **do not** get there by running
   `kubectl apply -f finance-manager/k8s/database/cluster.yaml`. That file is committed but
   deliberately unapplied (see "Corrections to the spec and the plan" above); applying it
   stamps a `last-applied-configuration` annotation onto the live Cluster that makes every
   future apply of that file prune live-only fields, on a shared production database.
2. Namespace and Secret:
   ```powershell
   cd mealie/
   Copy-Item secret.yaml.template secret.yaml   # then edit secret.yaml and set a real password
   kubectl apply -f namespace.yaml -f secret.yaml
   ```
3. The `Database` CR (requires the role from step 1 to already exist):
   ```powershell
   kubectl apply -f cnpg-database.yaml          # deploys into ns finance
   ```
4. The ad-hoc SQL — **must be re-run if the database is ever recreated**; nothing re-applies it
   automatically. See "Ad-hoc SQL applied alongside the Database CR" above for the exact
   `REVOKE` and the three `ALTER ROLE … SET` timeout statements and how to run them.
5. PVC, Deployment, Service:
   ```powershell
   kubectl apply -f pvc.yaml -f deployment.yaml -f service.yaml
   ```
6. Middleware and IngressRoute:
   ```powershell
   kubectl apply -f middleware.yaml -f ingressroute.yaml
   ```
7. RecurringJob:
   ```powershell
   kubectl apply -f recurringjob.yaml           # deploys into ns longhorn-system
   ```
8. **Label the Longhorn Volume — required, the job does nothing without it.** A brand-new
   `mealie-data` PVC's Volume starts unlabeled, same as a recreated one. See "Backups" below
   for the labeling command; do it right after the PVC is bound, or the RecurringJob will run
   on schedule and silently snapshot nothing.

**`strategy: Recreate` is set** (Longhorn is RWO; a RollingUpdate would deadlock waiting for
the old pod to release the volume), so every `deployment.yaml` apply is a brief outage.

### Verified after first boot (2026-08-12)

- **Migration duration.** Every Alembic `Running upgrade …` line in the boot log — all ~55
  migrations, `Initial tables` through `add table for ai providers` — plus `Database contains
  no users, initializing...` and `end: database initialization` carry the **identical
  timestamp**. Log resolution is 1-second, so the true figure is somewhere under 1 second, not
  the ~55 discrete steps the migration count might suggest. This was against an **empty**
  database; a future re-migration on a populated database will take longer, but "first boot" —
  the case `statement_timeout='300s'` was sized for — completed in a fraction of a second. 300s
  is therefore enormous headroom, not a tight fit.
- **Schema landed in Postgres, not SQLite:**
  ```
  $ kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -d mealie -tAc \
      "SELECT count(*) FROM pg_tables WHERE schemaname='public';"
  66
  ```
  Non-zero — `DB_ENGINE=postgres` took effect. No `CREATE EXTENSION` failure appeared in the
  migration log, and `cnpg-database.yaml` was not modified to add one.
- **PostgreSQL 18 compatibility:**
  `kubectl logs … | Select-String sqlalchemy|psycopg|ProgrammingError|OperationalError|UndefinedFunction`
  against the successful boot returned nothing. No PG18-vs-PG17 issue surfaced on this
  migration set.
- **uid/gid:** `/proc/1/status` inside the running pod: `Uid: 911 911 911 911`,
  `Gid: 911 911 911 911` — PID 1 (the actual `mealie` process) runs as `911:911`, matching
  `fsGroup`/`PUID`/`PGID` in `deployment.yaml`. `kubectl exec … id` shows `uid=0(root)
  gid=0(root)` — that's the exec shell, not the app; don't use it to re-check this fact.
- **Volume writable:** `touch /app/data/.write-probe && echo WRITE-OK && rm …` → `WRITE-OK`.
  `fsGroup: 911` is correct.

### Two benign quirks seen on every apply

- **`kubectl apply -f secret.yaml` reports `configured`, not `unchanged`, on every re-apply —
  even with no file change.** This is a known `kubectl`/`stringData` quirk, not real drift:
  `stringData` is a write-only convenience field the API server converts to `data` and never
  persists as `stringData`, so the three-way merge sends a patch every time regardless of
  whether the value actually changed. Confirmed benign two ways: `kubectl diff -f secret.yaml`
  returns **no** output, and the password value reads back identical across repeated applies.
- **A `PodSecurity "restricted:latest"` warning appears on every apply/env change**
  (`allowPrivilegeEscalation != false, ...`). Namespace `mealie` carries no
  `pod-security.kubernetes.io/*` labels, so `enforce` is the cluster default `baseline`, per
  `namespace.yaml`'s comment. The warning is the cluster's separate `warn`/`audit` level
  surfacing at `restricted`, which does not block anything — every apply still reports
  `created`/`configured` and the pod runs. Not addressed here, and not a misconfiguration.

## Rotation

Changing the database password touches **two** Secret objects in **two** namespaces plus a
restart, and the order matters — reversing steps 1 and 3 breaks Mealie until CNPG catches up:

1. Update the `mealie-db` Secret in the **`finance`** namespace (the one CNPG reads for
   `managed.roles[].passwordSecret`).
2. Confirm the rotation reconciled before touching Mealie's copy:
   ```powershell
   kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance -o jsonpath='{.status.managedRolesStatus}'
   ```
   `mealie` must appear under `byStatus.reconciled`.
3. Update the `mealie-db` Secret in the **`mealie`** namespace (the copy Mealie's own
   `POSTGRES_PASSWORD` env reads from) — the same new password.
4. Restart the Mealie deployment:
   ```powershell
   kubectl rollout restart deploy/mealie -n mealie
   kubectl rollout status deploy/mealie -n mealie --timeout=600s
   ```

**This only works because the `finance` Secret carries `cnpg.io/reload: "true"`.** Without
that label CNPG never watches the Secret, step 2 never reconciles, and rotation silently
no-ops — Postgres keeps the old password while both Secrets and `managedRolesStatus` look
fine. Do not remove that label to "simplify" the Secret.

A mismatch between the two Secrets — or restarting Mealie before CNPG has reconciled the new
password — presents as Mealie failing authentication while CNPG still reports the role
healthy. If auth breaks right after a rotation, re-check step 2 before assuming anything else
is wrong; also re-check "The cross-repo dependency" above, since a role definition missing
from `finance-manager/k8s/database/cluster.yaml` produces the identical symptom.

**The only copy of the current password is the gitignored `mealie/secret.yaml` on one
workstation.** It is not backed up, and policy forbids reading Secrets back from the cluster
(`kubectl get`/`describe secret` is hard-denied) to reconstruct it. If that file is lost,
**rotate** — pick a new password and go through the steps above — rather than attempting any
form of recovery.

## Probes

Readiness is on `/api/app/about` (database-backed); liveness is on
`/api/app/about/theme` (not database-backed). **This is deliberate and it is the opposite of
what a naive "point both at the same health check" design would do**: a database blip marks
Mealie unready — pulled from the Service, recoverable — instead of killing the container and
restart-looping it.

### Why the two endpoints actually differ — tested, not assumed

Confirmed by breaking the database out from under a running container and re-requesting every
unauthenticated 200-yielding endpoint. A first attempt — a plain `mv` of `mealie.db` to
`mealie.db.bak` — was **misleading, not a pass**: on Linux, `mv` within the same filesystem is
a rename, and the app already held the SQLite file open by file descriptor/inode, so it kept
reading and writing the exact same data under the new name. To get a real answer, the renamed
file's *contents* were overwritten in place
(`dd if=/dev/zero of=/app/data/mealie.db.bak bs=1024 count=50 conv=notrunc`) — same inode, so
the app's already-open fd sees the corruption immediately, no restart needed.

| Endpoint | HTTP, DB healthy | HTTP, DB broken (rename only — misleading) | HTTP, DB broken (contents corrupted in place) | DB-backed? |
|---|---|---|---|---|
| `/api/app/about` | 200 | 200 | 500 (`sqlalchemy.exc.DatabaseError: file is not a database`) | **Yes** |
| `/api/app/about/startup-info` | 200 | 200 | 500 (same root cause) | **Yes** |
| `/api/app/about/theme` | 200 | 200 | 200, same static color JSON body | No |

No endpoint among the unauthenticated candidates is both DB-independent AND a meaningful
liveness signal beyond "the HTTP server is up" — `/theme` is DB-independent but proves
nothing about the app being functional beyond serving static config. It was chosen anyway,
deliberately, because the point of a *liveness* probe here is only "is the process alive
enough to not need a SIGKILL", and DB health is readiness's job.

### Steady-state database loss — tested and PASSED

A **running** (not restarting) Mealie pod was severed from its database by refusing new
connections and killing pooled ones for the `mealie` role only (`ALTER ROLE mealie
CONNECTION LIMIT 0` plus `pg_terminate_backend` scoped to `usename='mealie'`), then watched:

```
Baseline:            mealie-7b865ffcf9-lgf5m   READY=true   RESTARTS=0
19:41:46  READY=true   RESTARTS=0
19:42:01  READY=true   RESTARTS=0
19:42:16  READY=false  RESTARTS=0   <- readiness trips
19:42:31  READY=false  RESTARTS=0
19:42:46  READY=false  RESTARTS=0
19:43:01  READY=false  RESTARTS=0
```

`kubectl get events` at that point showed, most recently: `Warning Unhealthy
pod/mealie-7b865ffcf9-lgf5m Readiness probe failed: HTTP probe failed with statuscode: 500`
— a **readiness** failure, matching `/api/app/about`'s known DB-backed 500 behavior above —
and **no** `Killing` event for this pod.

Restored `CONNECTION LIMIT 20`; `pg_authid.rolconnlimit` read back `20`. The pod
self-recovered to `READY=true` within 15 seconds of the restore, **same pod name, restarts
still 0** — no restart anywhere in the test. `/api/app/about` returned `200` again
immediately after. Finance cluster: `ready=3/3`, unchanged before and after.

**This confirms the probe split does what it was designed to do:** a live database loss under
a running pod produces `NotReady` with self-recovery, never a restart-loop.

### What the split does NOT protect — Mealie hard-exits if the database is unreachable at boot

**This is a real distinction, and it will confuse a future operator if skipped.** The probe
split above protects the *steady-state* case only. If Postgres is down (or unreachable) when
the Mealie **pod starts**, Mealie's own `init_db.main()` hard-exits the process before either
probe is ever evaluated — CrashLoopBackOff results regardless of how the probes are
configured. That is Mealie's behaviour, not a misconfiguration here.

Reproduced with a deliberately bogus `POSTGRES_SERVER` (`kubectl set env`, which always
replaces the pod on this Deployment):

```
sqlalchemy.exc.OperationalError: (psycopg2.OperationalError) could not translate host name
"nonexistent.invalid" to address: Name or service not known
...
File ".../mealie/db/init_db.py", line 102, in main
    raise ConnectionError("Database connection failed - exiting application.")
ConnectionError: Database connection failed - exiting application.
ERROR - Application startup failed. Exiting.
```

`kubectl describe pod` confirmed a genuine process exit, not a killed-by-probe event:

```
Last State:  Terminated
  Reason:    Error
  Exit Code: 3
Restart Count: 3 (climbing — CrashLoopBackOff)
```

The container restarted 3 times in the first ~90 seconds — well before the liveness probe's
`initialDelaySeconds: 60` would even take its first look, and via `RestartPolicy: Always`
reacting to the process exiting on its own (`kubectl get events` showed no
`Unhealthy`/`Killing` pair for this pod, only `BackOff: Back-off restarting failed
container`). No probe configuration can prevent a restart loop in this scenario, because the
crash happens in application code before a probe ever runs.

Restored by reverting the env var; pod returned to `1/1 Running`, `about` and `theme` both
`200` again, 0 restarts on the restored pod, and
`kubectl get deploy mealie -n mealie -o jsonpath='{...containers[0].env[*]}'` matched
`deployment.yaml` exactly — no spurious diff on the next apply.

### One narrower scenario remains unverified, and is recorded as a gap, not a pass

An attempt was made to reproduce "already-`Ready` pod loses DNS/network path to the database"
(as opposed to the connection-limit method used above) entirely inside the pod's own network
namespace, by appending a bogus `/etc/hosts` entry for
`finance-service-cluster-rw.finance.svc.cluster.local` via `kubectl exec`, then reverting it
the same way. **This test was inconclusive**, for the same reason the `mv` trick was
misleading for SQLite above: the process already held live, pooled connections opened before
the redirect, so a hosts-file change only affects *new* DNS resolutions, not sockets already
established. `/api/app/about` kept returning `200` for the full observation window and
restart count stayed at 0 — that result proves the redirect didn't reach the process's live
connections, it does **not** prove the probe split is safe against this exact failure mode.
A real test needs the established TCP connections themselves broken (a genuine network
partition or connection reset), which was not attempted — it would require either elevated
privileges inside this `baseline`-PSA pod or an action against the shared finance-cluster
network path. The connection-limit-based test above is a different mechanism that does prove
the readiness/liveness split works for a real DB outage; this narrower DNS-only scenario is
the one still open.

## Ingress and TLS

`middleware.yaml` (`mealie-headers`) and `ingressroute.yaml` applied 2026-08-12.
`https://mealie.arnoldtech.io` is live, LAN-only, serving the cluster's `*.arnoldtech.io`
wildcard cert via the empty `tls: {}` → `TLSStore/default` fallback — no cert-manager
`Certificate` was created; one is neither needed nor wanted since the wildcard cert doesn't
live in this namespace.

**TLS — verified, not assumed:**

```
$ echo | openssl s_client -connect 192.168.130.150:443 -servername mealie.arnoldtech.io 2>/dev/null | openssl x509 -noout -subject -issuer -dates
subject=CN=*.arnoldtech.io
issuer=C=US, O=Let's Encrypt, CN=YR2
notBefore=Jun 30 10:12:15 2026 GMT
notAfter=Sep 28 10:12:14 2026 GMT
```

Wildcard, Let's Encrypt, **not** `CN=TRAEFIK DEFAULT CERT` — the `TLSStore` lookup succeeded.
`kubectl logs -n traefik deploy/traefik --tail=100 | Select-String "mealie|error"` showed no
error mentioning `mealie` — only the routine `'kubernetes.io/ingress.class' is a deprecated
annotation` warning, which every other IngressRoute on this cluster also carries. End-to-end:
`curl.exe -sS -o NUL -w "%{http_code}" https://mealie.arnoldtech.io/api/app/about` → `200`.

## CSP

`middleware.yaml` is a **copy** of the shared `traefik/default-headers` Middleware, owned by
this namespace so its Content-Security-Policy can be relaxed for Mealie without affecting
every other app on the shared one — `wger` does the same thing with `wger-headers`.

**Any deviation from the shared copy must be justified by a console violation quoted in a
comment beside it.** Checked with a real browser (Playwright's MCP tools — the
`claude-in-chrome` extension reported "not connected" and was not used), not static analysis.

**One real violation was found and fixed.** First load of `https://mealie.arnoldtech.io/`
(and `/admin/setup`) produced, verbatim, twice:

```
Loading a manifest from 'https://mealie.arnoldtech.io/manifest.webmanifest' violates the
following Content Security Policy directive: "default-src 'none'". Note that 'manifest-src'
was not explicitly set, so 'default-src' is used as a fallback. The action has been blocked.
```

Mealie's app shell references `<link rel="manifest" href="/manifest.webmanifest"
crossorigin="use-credentials">` (it is a PWA). The fix — `manifest-src 'self';` — is the one
deviation from `traefik/default-headers`; nothing else was added speculatively. Confirmed live
with `curl.exe -sSI https://mealie.arnoldtech.io`: the served header ends
`...form-action 'self'; manifest-src 'self';`. A cache-busted reload then showed zero console
errors; two immediate re-checks *without* a cache-busting query string still showed the old
violation, confirmed via `curl` to be stale browser HTTP disk cache of the document
(`Cache-Control: no-cache` still permits conditional reuse) — not a live config problem.

**`worker-src` — not added, and evidence says it isn't needed.** Static analysis of the
eagerly-loaded entry bundle confirms Mealie registers a Workbox service worker at `/sw.js` on
boot. Per the CSP3 spec, `worker-src` with no explicit value falls back to `script-src`
(set here to `'self' 'unsafe-inline' 'unsafe-eval' https:`) before falling back to
`default-src`, so a same-origin `/sw.js` is already permitted. Corroborated empirically: SW
registration runs on every page load tested, including the unauthenticated login page, and no
`worker-src` violation ever appeared.

**`blob:` in `img-src`/`media-src` — not needed. Settled 2026-08-13 by reading the shipped
bundle, after first-run setup was completed.**

Mealie never renders an image from a `blob:` URL. Uploads `POST` a `FormData` to
`/api/recipes/{slug}/image`, and the image is then displayed from that same server URL — which
`img-src 'self'` already covers.

Across all 92 JavaScript chunks the app serves (transitive crawl from the app shell reached a
fixed point — zero new chunks on the next round), `URL.createObjectURL` appears **exactly once**,
in `/_nuxt/B8RB6R9E.js`:

```js
function Wa(e,t){ let n=JSON.stringify(e),
  r=new Blob([n],{type:`application/json`}),
  i=URL.createObjectURL(r), a=document.createElement(`a`);
  a.download=t, a.href=i, a.click(), URL.revokeObjectURL(i) }
```

That is the JSON-export download helper — a `Blob` of `application/json` attached to an
`<a download>`. CSP has no directive governing `<a href>`, so it needs nothing. The only other
literal `blob:` in the bundle is in `/_nuxt/C1yRiue8.js`, inside `ufo` (Nuxt's URL parser), in a
regex that *detects* the scheme rather than creating one.

`B8RB6R9E.js` is also the chunk carrying the upload API client itself — the `FormData` calls and
the `recipesRecipeSlugImage` route builder — so the one chunk that could plausibly have needed
`blob:` for a preview is the same one proven not to use it that way.

To re-check after a Mealie upgrade, re-run the crawl rather than trusting this: fetch every
`/_nuxt/*.js` referenced by the app shell and `grep -l createObjectURL`. A second occurrence is
the signal to look again.

## Rate limiting and the SSRF gap

Implements the two recommendations on
[Mealie's security page](https://docs.mealie.io/documentation/getting-started/installation/security/),
applied 2026-08-14. That page recommends exactly two things: **rate limit the API** behind a
reverse proxy (Denial of Service), and **isolate the container's network access** (Server Side
Request Forgery). The first is done. The second **cannot be done as written on this cluster** —
see "The SSRF half" below. Nothing else on that page applies; it defines no environment
variables and no auth settings.

Applying this touched only `middleware.yaml` and `ingressroute.yaml`, and **did not restart
Mealie** — Traefik reloads CRDs live. This is one of the few changes in this directory that is
not an outage.

### The doc's endpoint list is wrong for v3.22.0 — read this before editing the matcher

Checked against this build's own `openapi.json`, not the doc:

| Doc says | Reality in v3.22.0 |
|---|---|
| `/api/recipes/create/url` | exists, `POST`, **authenticated** |
| `/api/recipes/create/ai` | **does not exist** |
| `/api/recipes/{id}/image` | it is `/api/recipes/{slug}/image` — `POST`/`PUT`/`DELETE`, **no GET** |
| *(omitted)* | `/api/recipes/create/url/bulk` — takes a *list* of URLs, the worst DoS shape of the set |
| *(omitted)* | `/api/recipes/create/url/stream`, `/api/recipes/create/html-or-json{,/stream}` |

Two consequences drive the config:

- The matcher uses `PathPrefix(/api/recipes/create/)` rather than enumerating paths, so it
  already covers the three endpoints the doc omits **and** picks up `/create/ai` for free
  whenever an upgrade adds it.
- **`/api/recipes/{slug}/image` has no GET**, so strict-limiting it cannot throttle image
  *browsing*. Mealie serves images from `/api/media/recipes/{id}/images/{file}` — a different
  path, left on the general tier. Do not widen the regexp toward `/api/media/...` or a recipe
  list view will start returning 429 for its own thumbnails.

### These are GLOBAL buckets, not per-client — the most important fact here

Traefik's `rateLimit` buckets by client IP by default. **No client IP survives the trip on this
cluster**, so every LAN client shares one bucket per tier.

Verified 2026-08-13 with a throwaway `traefik/whoami` behind its own temporary IngressRoute in
`ns mealie` (all three objects deleted afterwards). A request from `192.168.130.50` arrived at
the backend carrying:

```
X-Forwarded-For: 10.244.3.1
X-Real-Ip:       10.244.3.1
```

stable across four requests. `10.244.3.1` is the flannel gateway on `talos-mql-msp` — the node
running the Traefik pod (pod CIDR `10.244.3.0/24`, pod at `.215`) — i.e. Traefik's own node, not
the caller. The address is lost to a **double SNAT**: `svc/traefik` in `ns traefik` is
`externalTrafficPolicy: Cluster`, so kube-proxy masquerades on ingress, and the pod-network hop
rewrites it again.

**The one change that would make these limits per-client is setting `externalTrafficPolicy:
Local` on `svc/traefik`.** That is a change to *shared* cluster infrastructure affecting every
IngressRoute on the cluster, so it was deliberately not made as part of a Mealie change. If it
is ever made, these middlewares become per-client automatically and need no edit here — which is
why `sourceCriterion` is left at its default rather than pinned to something honestly global.
Do not "clarify" the config by pinning it.

### The two tiers

| Middleware | Applies to | Limit |
|---|---|---|
| `mealie-ratelimit` | everything else (route `priority: 1`) | 50/s, burst 400 |
| `mealie-ratelimit-scrape` | `/api/recipes/create/**` and `/api/recipes/{slug}/image` (route `priority: 100`) | 12/min, burst 5 |

Both route priorities are **pinned explicitly**. Traefik would otherwise rank them by rule
length, which happens to give the right answer today and would stop doing so the moment either
rule is edited.

`mealie-headers` is listed **before** the rate limit in both routes on purpose: middlewares run
in order, so a 429 still leaves carrying HSTS and the CSP instead of bare.

Bulk import is not affected by the strict tier — the UI sends a whole list to
`/api/recipes/create/url/bulk` as a **single** request, so a 40-recipe bulk import spends one
token, not 40.

### Verified 2026-08-14 — negative case first

A limit only ever observed passing has not been verified. The negative case is the proof:

| Test | Expected | Observed |
|---|---|---|
| 1 rapid POST `/api/recipes/create/url`, bucket idle | not 429 | `401` (auth rejects it; the limit did not) |
| +15 rapid POSTs, same path | 429 after burst | `401 401 401 401` then **`429` ×11** — five non-429 total, exactly `burst: 5` |
| 12 rapid POSTs `/api/recipes/probe-slug/image` | 429 after burst | `401` ×5 then **`429` ×7** — the `PathRegexp` arm routes to the strict tier |
| 25 rapid GETs `/api/media/recipes/{uuid}/images/original.webp` | **no** 429 | `422` ×25 (Mealie's own UUID validation — the requests reached the app), zero 429 |
| 30 rapid GETs `/api/app/about` | **no** 429 | `200` ×30 |
| Cache-cold load of `/` in a real browser | **no** 429 | **261 requests, all 200**, zero 429 |

The unauthenticated `POST` is a clean probe precisely *because* it 401s: the rate limit runs
ahead of the backend, so watching `401` flip to `429` proves the bucket without touching a
single recipe.

**261 is the number to size `burst` against, not the "92 chunks" in the CSP section above** —
that was a transitive crawl of the eagerly-loaded JS graph, a subset of what a browser really
requests. Two devices cold-loading at once is ~522 requests, more than the 400 bucket; it passes
only because the bucket refills at 50/s while they load. That headroom is thinner than the burst
figure looks. If a third simultaneous cold load ever 429s on static assets, raise `burst` before
suspecting anything else.

### The SSRF half — not implemented, and it is not implementable here

The doc's mitigation is "isolate the container … to ensure its access to internal resources is
limited only to what is required." **On this cluster there is no way to do that at the network
layer: the CNI is Flannel and NetworkPolicy is not enforced** (see the repo CLAUDE.md). A
`NetworkPolicy` object would apply cleanly, report no error, and do nothing — which is worse
than not having one, because it reads as protection. Do not add one here believing it helps.

What reduces the risk instead, stated as facts rather than reassurance:

- **All the affected endpoints require authentication.** Every one of `/api/recipes/create/*`
  and `/api/recipes/{slug}/image` carries a `security` key in `openapi.json` (checked, not
  assumed). An attacker must already hold valid credentials.
- `ALLOW_SIGNUP=false` in `deployment.yaml`, and there is one admin account.
- The instance is LAN-only — no ingress rule or DNS record exposes it beyond the LAN.

Together those put this deployment inside the escape clauses the security page opens with
("most of these will not apply to you if … use a strong password … disable sign-ups … don't
host for malicious users"). **The residual risk is accepted:** an authenticated user can make
the Mealie pod issue HTTP requests to anything it can route to, including the finance database's
network path, and nothing here stops that.

**The option not taken** was an egress proxy — a squid/tinyproxy Deployment that refuses RFC1918
destinations, with `HTTP_PROXY`/`HTTPS_PROXY` on the Mealie container pointed at it. It was
declined as disproportionate for a single-operator LAN recipe manager, and because it introduces
a failure mode worse than the risk it closes: a broken or restarting proxy silently breaks every
recipe import, with no error that points at the proxy. Revisit it if Mealie is ever exposed
beyond the LAN or gains non-household users — that, not any change in the code, is the trigger.

### Re-checking after a Mealie upgrade

The matcher is pinned to paths, and paths move between versions. After any image bump, re-run
the endpoint enumeration rather than trusting the table above:

```powershell
kubectl exec -n mealie deploy/mealie -- python3 -c "import json,urllib.request; d=json.load(urllib.request.urlopen('http://localhost:9000/openapi.json')); [print(('AUTH' if 'security' in op else 'NO-AUTH'), m.upper(), p) for p,v in sorted(d['paths'].items()) for m,op in v.items() if m in ('post','put','delete') and ('recipes/create' in p or (p.startswith('/api/recipes/') and p.endswith('/image')))]"
```

A new scraping endpoint outside `/api/recipes/create/` is the thing to watch for — the prefix
would not catch it. Then re-run the 429 test above; a matcher that silently stops matching
produces no error, only an unprotected endpoint.

## Backups

**Database: there is currently no CNPG backup configured, for any of the three tenants on
`finance-service-cluster` — finance, attendance, or mealie.** Verified 2026-08-12:

```
kubectl get scheduledbackups.postgresql.cnpg.io -A   → No resources found
kubectl get backups.postgresql.cnpg.io -A            → No resources found
kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance -o jsonpath='{.spec.backup}'
                                                       → (empty)
```

An earlier version of this README, and the design spec's §2 "Cluster facts" table, both
claimed a `finance-db-daily-backup` `ScheduledBackup` existed (`0 2 * * *`, retain 30d,
`volumeSnapshot` method) and covered the whole `finance-service-cluster` PGDATA volume. That
object is not live. `finance-manager/k8s/database/scheduled-backup.yaml` defines it, but the
file is committed and never applied — no kustomization references it, the same category of
trap `cluster.yaml` was in before Task 8 repaired it. The claim was carried from the design
spec into the plan into this README without ever being re-checked against the cluster; see
the corrections appended to both documents.

**Consequence, stated plainly: the `mealie` database has no restore path at all today** — not
one coupled to finance's schedule, none. The same is true for `finance` and `attendance`. This
is a pre-existing gap that predates Mealie; Mealie did not create it, but co-tenanting onto
this cluster means Mealie inherits it.

**CloudCasa (`cloudcasa-io`) coverage of the underlying PGDATA PVC is unverified — recorded as
unknown, not as absent.** CloudCasa deletes its CRs after each run, so
`kubectl get backups.cloudcasa.io -A` returning no resources (checked 2026-08-12) proves
nothing either way about whether an out-of-band snapshot policy covers this volume. Confirming
this one way or the other means checking CloudCasa's own policy configuration, which was not
done as part of this deployment.

**Volume** (`mealie-data` — recipe images and uploads only, not the database), via
`recurringjob.yaml`: a Longhorn `RecurringJob` in `longhorn-system` (not `mealie`) that
snapshots the volume daily at `0 10 * * *` (10:00 UTC / 03:00 America/Phoenix), retaining 7.
The schedule is deliberately offset from the other two daily jobs on this cluster so none of
them contend for Longhorn I/O: `wger-daily-snapshot` runs 04:00 UTC, `mealie-daily-snapshot`
runs 10:00 UTC, `valheim-daily-snapshot` runs 11:00 UTC — no finance-related job is in that
rotation, because none exists.

**What a Longhorn snapshot does and does not protect against — read this before assuming
`mealie-data` is "backed up."** `task: snapshot` is a same-disk, same-node Longhorn snapshot,
not a backup to a separate target (that would be `task: backup` against a configured backup
target, which is not set up here). Seven daily snapshots protect against **accidental
deletion or corruption inside Mealie** — an operator or the app itself removing or mangling a
recipe image, recoverable by rolling the volume back to a recent snapshot. They do **not**
protect against **disk or node loss**: a snapshot lives on the same Longhorn disk as the
volume it is a snapshot of, so losing that disk (or the node, if replicas do not survive it)
takes the snapshots down with the data they describe. This matches the `valheim`/`wger`
precedent in this repo — same mechanism, same limitation, nothing new introduced here — but
it is worth stating plainly because `/app/data` holds every uploaded recipe image and losing
it is the closest thing to real data loss this workload has, separate from the database
question above. Whether namespace `mealie` is covered by a CloudCasa policy that would survive
disk/node loss is, per the paragraph above, unverified.

### The label is on the Volume, not the PVC — check this first if snapshots stop appearing

A Longhorn `RecurringJob` selects volumes by the label
`recurring-job-group.longhorn.io/mealie=enabled` on the **Longhorn `Volume`** object, not on
the PVC. A PVC's underlying Volume starts with no such label, so a fresh or recreated
`mealie-data` PVC silently stops being snapshotted until the label is reapplied — the job
keeps running, reports no error, and simply matches nothing. This is the same failure mode
`valheim/recurringjob.yaml` already carries a warning about.

Find the PV and check its labels:

```powershell
$pv = kubectl get pvc mealie-data -n mealie -o jsonpath='{.spec.volumeName}'
kubectl get volumes.longhorn.io $pv -n longhorn-system -o jsonpath='{.metadata.labels}{"\n"}'
```

If `recurring-job-group.longhorn.io/mealie` is missing, reapply it:

```powershell
kubectl label volumes.longhorn.io $pv -n longhorn-system recurring-job-group.longhorn.io/mealie=enabled
```

**The volume also carries `recurring-job-group.longhorn.io/default: enabled`** (verified
2026-08-12), same as every Longhorn volume on this cluster. This label does not currently do
anything: **no `RecurringJob` is in group `default`** — `kubectl get recurringjobs.longhorn.io
-n longhorn-system` shows only three jobs (`mealie-daily-snapshot`, `valheim-daily-snapshot`,
`wger-daily-snapshot`), each scoped to its own single-item group, none named `default`
(verified 2026-08-12). The label matches no job today. Do not read its presence as evidence
of an extra snapshot source, and do not assume it will stay inert — if a `default`-group
`RecurringJob` is ever created, this volume picks it up automatically the next time it fires.

### Verified 2026-08-12

- **Negative case observed first, not assumed.** Immediately after `kubectl apply -f
  recurringjob.yaml` (`created`), the Volume behind `mealie-data`
  (`pvc-d9e34f78-eec3-4b28-bbd5-47688f7f409e`) carried `backup-target`, `longhornvolume`,
  `recurring-job-group.longhorn.io/default`, and three `setting.longhorn.io/*` labels — no
  `recurring-job-group.longhorn.io/mealie` key. The job existed and matched nothing, exactly
  as documented.
- **Labeled, then confirmed present**: the label appeared in a follow-up read of
  `.metadata.labels`.
- **A snapshot was made to fire for real, not inferred from config.** Cron was patched to
  ~3 minutes out (computed in UTC, per Longhorn's own cron evaluation timezone) after
  recording the 43 pre-existing snapshot names across the cluster. Polling every 30s found a
  new snapshot, `mealie-d-cd3488cb-d7b5-4b5d-b6d4-99b704507b6b`, with `spec.volume` equal to
  the mealie PV and (a few polls later) `status.readyToUse: true`. Not present in the
  pre-test snapshot list.
- **Cron restored**: `kubectl apply -f recurringjob.yaml` → `configured`; `.spec.cron` read
  back as `0 10 * * *`, matching the committed file.

Full raw command output is in
`.superpowers/sdd/2026-08-12-mealie-deployment/task-6-report.md`.

## Known gaps

These are deliberately left open, not overlooked — recorded here so a future operator knows
what to check rather than assuming it was verified:

**Both of the gaps originally recorded here are now closed** — kept below with their
resolutions rather than deleted, because how they closed is the useful part.

- **First-run setup — done by the operator on 2026-08-13.** It was deliberately not done
  unattended: advancing past "Account Details" sets a real email and password for the admin
  account of a production instance, which is the operator's to choose. (Mealie's own displayed
  defaults, `changeme@example.com` / `MyPassword`, were used only to sign in and confirm the
  `/admin/setup` redirect fires — nothing further.)
- **The `blob:` question in `img-src`/`media-src` — closed 2026-08-13, and the answer is that
  no widening is needed.** It was settled by reading the shipped bundle rather than by watching
  a console: Mealie displays uploaded images from `/api/recipes/{slug}/image`, never from a
  `blob:` URL, and the single `URL.createObjectURL` in all 92 chunks is a JSON-export download
  helper. Full evidence in the CSP section above. The CSP was **not** widened — the standing
  rule against speculative directives held, and it turned out to be right.

  Worth noting *why* the earlier guess was wrong: the previous version of this note assumed the
  preview code "likely lives in a lazy-loaded recipe-editing chunk that was never requested."
  A transitive crawl of the app shell reached a fixed point at 92 chunks with the upload API
  client among them, so there was no unreached chunk hiding the answer.
