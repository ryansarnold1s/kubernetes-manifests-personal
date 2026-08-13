# Mealie Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Mealie v3.22.0 at `https://mealie.arnoldtech.io`, backed by a database on the existing `finance/finance-service-cluster` CloudNativePG cluster, reachable on the LAN through the cluster's existing Traefik ingress.

**Architecture:** A new `mealie/` workload directory in this repo holding a Deployment, Service, PVC, Traefik Middleware and IngressRoute in namespace `mealie`, plus two files that deploy elsewhere — a CNPG `Database` CR into `finance` and a Longhorn `RecurringJob` into `longhorn-system`. The database role is added to the live finance Cluster by a surgical patch, and the finance repo's stale `cluster.yaml` is repaired afterwards as a separate commit.

**Tech Stack:** Kubernetes (Talos), CloudNativePG 1.27.0 on PostgreSQL 18.3, Traefik IngressRoute CRDs, Longhorn RWO storage, cert-manager (already provisioned — no new certificate needed).

**Spec:** `docs/superpowers/specs/2026-08-12-mealie-deployment-design.md`

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include these.

- **Mealie image:** `ghcr.io/mealie-recipes/mealie:v3.22.0` — pinned, never `latest`.
- **DB host:** `finance-service-cluster-rw.finance.svc.cluster.local:5432` — fully qualified because it is cross-namespace, and `-rw` (not `-ro`) because Mealie writes.
- **Hostname:** `mealie.arnoldtech.io` — already resolves to `192.168.130.150` on the LAN. **No Cloudflare record is to be created.** LAN-only is a deliberate decision.
- **TLS:** `tls: {}` on the IngressRoute, which resolves to `TLSStore/default` → `local-arnoldtech-io-tls` (`*.arnoldtech.io`). **Do not create a cert-manager `Certificate`.**
- **Ingress annotation:** `kubernetes.io/ingress.class: traefik-external` on the IngressRoute — this is the ingressClass the `kubernetescrd` provider watches, and it is *not* the same string as the `traefik` IngressClass object.
- **Namespace PSA:** `mealie` gets **no** `pod-security.kubernetes.io` labels. The cluster default is `baseline`, which is the intended posture.
- **Deployment strategy:** `Recreate`. Longhorn is RWO; a RollingUpdate deadlocks.
- **Role privileges:** `mealie` is a plain login role — `superuser: false`, `createdb: false`, `createrole: false`, `connectionLimit: 20`.
- **`databaseReclaimPolicy: retain`** on the `Database` CR, set explicitly.
- **`TZ: America/Phoenix`**.
- **`ALLOW_SIGNUP: "false"`**.
- **Secrets:** `**/secret.yaml` is gitignored; commit `secret.yaml.template` only. `kubectl get/describe secret` is denied by policy on this machine — verify Secrets **functionally**, never by reading them back.
- **Commits go directly to `main`.** No PR flow. Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it.
- **Every `kubectl apply` must report `created` or `configured`.** `unchanged` is a silent failure — almost always the wrong working directory. `cd` into the workload directory first; relative paths from the repo root silently no-op.

---

## File Structure

| File | Namespace it targets | Responsibility |
|---|---|---|
| `mealie/README.md` | — | Operational detail, verified image facts, cross-repo dependency, recovery path |
| `mealie/namespace.yaml` | `mealie` | The namespace, with the PSA warning comment |
| `mealie/pvc.yaml` | `mealie` | `mealie-data`, 10Gi Longhorn RWO for `/app/data` |
| `mealie/secret.yaml.template` | `mealie` + `finance` | Committed placeholder for the two Secret objects |
| `mealie/secret.yaml` | `mealie` + `finance` | **Gitignored.** The real credential, in both namespaces |
| `mealie/deployment.yaml` | `mealie` | The Mealie workload |
| `mealie/service.yaml` | `mealie` | ClusterIP :9000 |
| `mealie/middleware.yaml` | `mealie` | `mealie-headers` — security headers + CSP |
| `mealie/ingressroute.yaml` | `mealie` | Traefik route + TLS store lookup |
| `mealie/cnpg-database.yaml` | **`finance`** | The `Database` CR |
| `mealie/recurringjob.yaml` | **`longhorn-system`** | Daily snapshot of `mealie-data` |
| `CLAUDE.md` | — | Add `mealie/` to the workload list |
| `finance-manager/k8s/database/cluster.yaml` | `finance` | **Different repo.** Repaired to match live, and carries the role |

---

### Task 1: Recon the Mealie image and record the facts

The spec deliberately leaves two things unpinned because the image is the source of truth, not the docs: the uid Mealie actually runs as, and whether any unauthenticated endpoint exists that genuinely touches the database. Both are settled here, before any manifest is written.

**Files:**
- Create: `mealie/README.md`

**Interfaces:**
- Produces: the verified runtime **uid/gid** (Task 4 uses it for `fsGroup`), and the verified **health endpoint path** plus whether it is DB-backed or shallow (Task 4 uses it for probes).

- [ ] **Step 1: Boot a throwaway Mealie on SQLite**

The `default` namespace enforces `baseline`, which this satisfies. SQLite avoids needing a database that does not exist yet.

```powershell
kubectl run mealie-recon -n default --restart=Never `
  --image=ghcr.io/mealie-recipes/mealie:v3.22.0 `
  --env="DB_ENGINE=sqlite" --env="ALLOW_SIGNUP=false"
kubectl wait --for=condition=Ready pod/mealie-recon -n default --timeout=300s
```

- [ ] **Step 2: Record the runtime uid/gid**

`PUID`/`PGID` default to 911, but confirm what the *process* runs as rather than trusting the env default.

```powershell
kubectl exec -n default mealie-recon -- id
kubectl exec -n default mealie-recon -- sh -c "ps -o user,uid,gid,comm 2>/dev/null | head -20"
kubectl exec -n default mealie-recon -- sh -c "stat -c '%u %g %n' /app/data"
```

Expected: uid/gid `911`. If it differs, the real value is what Task 4 uses for `fsGroup`, `PUID` and `PGID`.

- [ ] **Step 3: Enumerate unauthenticated health-ish endpoints**

```powershell
kubectl exec -n default mealie-recon -- sh -c "curl -s localhost:9000/openapi.json" > "$env:TEMP\mealie-openapi.json"
```

Then list candidate GET routes that need no auth:

```powershell
(Get-Content "$env:TEMP\mealie-openapi.json" -Raw | ConvertFrom-Json).paths.PSObject.Properties |
  Where-Object { $_.Value.get -and -not $_.Value.get.security } |
  Select-Object -ExpandProperty Name | Sort-Object
```

- [ ] **Step 4: Test each candidate for a real response**

For every candidate from Step 3 (at minimum `/api/app/about`):

```powershell
kubectl exec -n default mealie-recon -- sh -c "curl -s -o /dev/null -w '%{http_code}  ' localhost:9000/api/app/about; echo /api/app/about"
```

- [ ] **Step 5: Determine whether any candidate is DB-backed — this is the important one**

Break the database *while the app runs* and re-test every candidate. On SQLite, move the file:

```powershell
kubectl exec -n default mealie-recon -- sh -c "mv /app/data/mealie.db /app/data/mealie.db.bak 2>/dev/null || find /app/data -name '*.db' -o -name '*.sqlite*'"
kubectl exec -n default mealie-recon -- sh -c "curl -s -o /dev/null -w '%{http_code}\n' localhost:9000/api/app/about"
```

Expected, and the whole point of this step: `/api/app/about` **still returns 200** with the database gone. Record which candidates — if any — return non-200. That set is the only honest readiness probe.

- [ ] **Step 6: Write `mealie/README.md` with the verified facts**

Get the digest first:

```powershell
kubectl get pod mealie-recon -n default -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
```

Then create `mealie/README.md` with exactly this skeleton, filling every `_recorded here_`
from what Steps 2–5 actually printed. Later tasks append their own sections to this file.

```markdown
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
| Digest | _recorded here_ | `kubectl get pod … -o jsonpath='{.status.containerStatuses[0].imageID}'` |
| Runtime uid:gid | _recorded here_ | `kubectl exec … -- id` |
| `/app/data` owner | _recorded here_ | `stat -c '%u %g %n' /app/data` |
| Unauthenticated GET routes | _recorded here_ | `curl localhost:9000/openapi.json` |
| Health endpoint used | _recorded here_ | see below |

### Does the health endpoint cover the database?

**_recorded here — answer this in one plain sentence._**

Tested by breaking the database out from under a running container and re-requesting
every unauthenticated endpoint. Endpoints that kept returning 200 with the database gone
are shallow: they prove the process is alive and nothing more.

Results:

| Endpoint | HTTP, DB healthy | HTTP, DB broken | DB-backed? |
|---|---|---|---|
| `/api/app/about` | _recorded here_ | _recorded here_ | _recorded here_ |

This matters because a probe that only ever passes has not been verified, and this repo
has shipped a no-op probe before.
```

- [ ] **Step 7: Delete the recon pod**

```powershell
kubectl delete pod mealie-recon -n default
kubectl get pod mealie-recon -n default 2>&1   # expected: NotFound
```

- [ ] **Step 8: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git add mealie/README.md
git commit -m "Record verified Mealie v3.22.0 image facts from container recon"
```

---

### Task 2: Add the `mealie` role to the live finance Cluster

This is the only task that touches a shared object serving a live application. It is reviewed before it is applied.

**Files:**
- Create: `mealie/secret.yaml.template`
- Create: `mealie/secret.yaml` (gitignored)
- Create: `$env:TEMP\mealie-role-patch.yaml` (not committed — the canonical home for this content is `finance-manager/k8s/database/cluster.yaml`, repaired in Task 8)

**Interfaces:**
- Consumes: nothing.
- Produces: a PostgreSQL login role `mealie` whose password matches Secret `mealie-db` in **both** the `finance` and `mealie` namespaces. Task 3 needs the role to exist (`Database.spec.owner`); Task 4 needs the `mealie`-namespace Secret.

- [ ] **Step 1: Get the `postgres-expert` review — this is a gate, not a formality**

Review the patch file (Step 3) and `mealie/cnpg-database.yaml` (Task 3) **file-only**. The agent must not connect to a database or edit anything.

Hand it these facts, which it cannot infer:
- Target is `finance/finance-service-cluster`: 3 instances, `postgresql:18.3-standard-trixie`, `max_connections: 100`, `enableSuperuserAccess: false`, `spec.managed.roles` currently **empty**.
- The finance application **is running** during the change; there is no maintenance window.
- Migrations here are forward-only; there is no down-migration.
- The finance app is **not** being redeployed alongside this.
- The new role is for a separate application in a different namespace, and **NetworkPolicy is not enforced on this cluster** (Flannel), so role privileges are the only isolation.

Ask it explicitly about: locks taken and for how long; whether the operator restarts or reloads Postgres to apply `managed.roles`; deadlock risk against concurrent finance queries; idempotency on an accidental second apply; and what the change *should* do but does not.

Also ask its opinion on `REVOKE CONNECT ON DATABASE finance FROM PUBLIC` — the spec flags this as out of scope for the finance repo to take separately, and its answer belongs in that recommendation, not in this change.

Record the review verdict in `mealie/README.md` before proceeding.

- [ ] **Step 2: Generate the password**

Alphanumeric only, deliberately: this value travels through a Postgres URI and PowerShell quoting, and punctuation causes silent misparses in both.

```powershell
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
$pw
```

Keep this value for Steps 3–6. It goes into two Secret objects and must be identical in both.

- [ ] **Step 3: Write the patch file**

Write this to `$env:TEMP\mealie-role-patch.yaml` — not into the repo:

```yaml
# Surgical patch: adds ONLY spec.managed.roles to finance-service-cluster.
# Applied with --type=merge so no other field of the live object is touched.
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
      # Bounded on purpose: the cluster runs max_connections=100 and already
      # serves the finance app. Mealie runs UVICORN_WORKERS=1, so 20 is ample
      # headroom while making it impossible for Mealie to exhaust the pool.
      connectionLimit: 20
      comment: "Owner of the mealie database. Added 2026-08-12 for the Mealie workload in ns mealie."
      passwordSecret:
        name: mealie-db
```

- [ ] **Step 4: Write `mealie/secret.yaml.template`**

```yaml
# Two Secret objects, one password. They MUST hold the same value.
#
# CNPG resolves managed.roles[].passwordSecret in the CLUSTER's namespace
# (finance), and requires type kubernetes.io/basic-auth. Mealie reads its own
# copy from its own namespace. A mismatch presents as Mealie failing auth while
# the CNPG Cluster still reports the role healthy — see README.md (Rotation).
#
# Copy to secret.yaml (gitignored) and replace both placeholders.
---
apiVersion: v1
kind: Secret
metadata:
  name: mealie-db
  namespace: finance
type: kubernetes.io/basic-auth
stringData:
  username: mealie
  password: "Place_Holder"
---
apiVersion: v1
kind: Secret
metadata:
  name: mealie-db
  namespace: mealie
type: Opaque
stringData:
  password: "Place_Holder"
```

- [ ] **Step 5: Create `mealie/secret.yaml` and confirm it is ignored**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
(Get-Content secret.yaml.template -Raw) -replace '"Place_Holder"', "`"$pw`"" | Set-Content secret.yaml -NoNewline
```

Confirm **both** placeholders were replaced — a single remaining `Place_Holder` is the
signature of a partial substitution, and it fails later as an auth error that looks like a
Mealie bug:

```powershell
(Select-String -Path secret.yaml -Pattern 'Place_Holder').Count          # expected: 0
(Select-String -Path secret.yaml -Pattern "password: `"$pw`"").Count     # expected: 2
```

Then prove git will not take it:

```powershell
git check-ignore -v secret.yaml
```

Expected: a line naming the `**/secret.yaml` rule. **If this prints nothing, stop** — the file is not ignored and must not be committed.

- [ ] **Step 6: Apply the finance-namespace Secret only**

The `mealie` namespace does not exist yet, so apply just the first document:

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
kubectl apply -f secret.yaml --dry-run=server
```

Expected: the `finance` Secret reports `created`; the `mealie` one errors with `namespaces "mealie" not found`. That error is expected here and is resolved in Task 4.

```powershell
kubectl create secret generic mealie-db -n finance `
  --type=kubernetes.io/basic-auth `
  --from-literal=username=mealie --from-literal=password=$pw
```

- [ ] **Step 7: Capture the finance cluster's health BEFORE the patch**

```powershell
kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance `
  -o jsonpath='{.status.phase}{"  ready="}{.status.readyInstances}{"/"}{.status.instances}{"  primary="}{.status.currentPrimary}{"\n"}'
```

Record the output. Expected: `Cluster in healthy state  ready=3/3  primary=finance-service-cluster-1`.

- [ ] **Step 8: Apply the patch**

```powershell
kubectl patch cluster.postgresql.cnpg.io finance-service-cluster -n finance `
  --type=merge --patch-file "$env:TEMP\mealie-role-patch.yaml"
```

Expected: `cluster.postgresql.cnpg.io/finance-service-cluster patched`.

- [ ] **Step 9: Verify the role authenticates — positive case**

Connect from a throwaway pod in a *different* namespace, using the password from the application's side. This proves cross-namespace reachability and the credential together.

```powershell
kubectl run pg-probe -n default --rm -i --restart=Never `
  --image=ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie -- `
  psql "postgresql://mealie:$pw@finance-service-cluster-rw.finance.svc.cluster.local:5432/postgres" `
  -c "SELECT current_user, current_database();"
```

Expected: one row, `current_user = mealie`.

- [ ] **Step 10: Verify the negative case**

A check only ever observed passing has not been verified.

```powershell
kubectl run pg-probe-neg -n default --rm -i --restart=Never `
  --image=ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie -- `
  psql "postgresql://mealie:definitely-the-wrong-password@finance-service-cluster-rw.finance.svc.cluster.local:5432/postgres" `
  -c "SELECT 1;"
```

Expected: **failure** — `password authentication failed for user "mealie"`. If this *succeeds*, the role was created without a password (`disablePassword` semantics or a `trust` hba rule) and Step 9 proved nothing. Stop and investigate.

- [ ] **Step 11: Verify finance is undisturbed**

```powershell
kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance `
  -o jsonpath='{.status.phase}{"  ready="}{.status.readyInstances}{"/"}{.status.instances}{"  primary="}{.status.currentPrimary}{"\n"}'
kubectl get pods -n finance -l cnpg.io/cluster=finance-service-cluster
```

Expected: identical to Step 7 — same primary, 3/3 ready, and **no pod restarts**. A restart or failover means the patch was not as surgical as believed; record it in the README and re-check the finance app.

- [ ] **Step 12: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git status --short   # confirm mealie/secret.yaml is NOT listed
git add mealie/secret.yaml.template mealie/README.md
git commit -m "Add mealie DB credential template and record the finance role patch"
```

---

### Task 3: Create the `mealie` database

**Files:**
- Create: `mealie/cnpg-database.yaml`

**Interfaces:**
- Consumes: the `mealie` role from Task 2 — `spec.owner` must name an existing role.
- Produces: database `mealie` on `finance-service-cluster`, owned by `mealie`. Task 4's Deployment connects to it.

- [ ] **Step 0: Recover the password into `$pw`**

Steps 6 and 7 need it. `$pw` was generated in Task 2 and does **not** survive into this
task's shell, and `kubectl get secret` is denied by policy — so read it back from the
gitignored local file, which is the only readable copy:

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
$pw = ((Select-String -Path secret.yaml -Pattern '^\s*password:\s*"(.+)"$').Matches[0].Groups[1].Value)
$pw.Length   # expected: 32
```

- [ ] **Step 1: Write the manifest**

```yaml
# NOTE: this file deploys into the `finance` namespace, NOT `mealie`. CNPG's
# Database CR is namespace-scoped to its Cluster, so it has to live alongside
# finance-service-cluster. It is kept here because it is Mealie's object and
# Mealie's lifecycle owns it.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: mealie
  namespace: finance
spec:
  cluster:
    name: finance-service-cluster
  name: mealie
  # The role added to the Cluster's spec.managed.roles. It must already exist —
  # CNPG will not create it from here.
  owner: mealie
  encoding: UTF8
  # Explicit, not defaulted: deleting this CR must never drop the database.
  databaseReclaimPolicy: retain
```

- [ ] **Step 2: Validate server-side**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
kubectl apply -f cnpg-database.yaml --dry-run=server
```

Expected: `database.postgresql.cnpg.io/mealie created (server dry run)`.

- [ ] **Step 3: Apply**

```powershell
kubectl apply -f cnpg-database.yaml
```

Expected: `created`. Not `unchanged`.

- [ ] **Step 4: Confirm the operator applied it**

```powershell
kubectl get database.postgresql.cnpg.io mealie -n finance -o jsonpath='{.status}{"\n"}'
```

Expected: `applied: true` and no `message`. If `applied` is false, the message names the cause — most likely the owner role is missing, which means Task 2 did not actually take.

- [ ] **Step 5: Confirm ownership in Postgres itself**

Do not trust the CR status alone.

```powershell
kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -tAc "\l mealie"
kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -tAc "SELECT datname, pg_get_userbyid(datdba) AS owner, pg_encoding_to_char(encoding) FROM pg_database WHERE datname='mealie';"
```

Expected: `mealie|mealie|UTF8`.

- [ ] **Step 6: Verify the role is not over-privileged — negative cases**

```powershell
kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -tAc "\du mealie"
```

Expected: no `Superuser`, `Create role`, or `Create DB` attribute.

```powershell
kubectl run pg-probe-priv -n default --rm -i --restart=Never `
  --image=ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie -- `
  psql "postgresql://mealie:$pw@finance-service-cluster-rw.finance.svc.cluster.local:5432/mealie" `
  -c "CREATE DATABASE probe;"
```

Expected: **failure** — `permission denied to create database`.

- [ ] **Step 7: Verify table-level isolation from finance**

First find a real finance-owned table (do not guess a name):

```powershell
$tbl = kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -d finance -tAc "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') LIMIT 1;"
$tbl = $tbl.Trim()
$tbl
```

If `$tbl` comes back empty the finance database has no user tables, and this check cannot
run — record that in the README rather than reporting it as a pass.

Then attempt to read it as `mealie`:

```powershell
kubectl run pg-probe-iso -n default --rm -i --restart=Never `
  --image=ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie -- `
  psql "postgresql://mealie:$pw@finance-service-cluster-rw.finance.svc.cluster.local:5432/finance" `
  -c "SELECT count(*) FROM $tbl;"
```

Expected: **failure** — `permission denied for table`.

Note what this does *not* prove: the connection to the `finance` database itself **will succeed**, because Postgres grants `CONNECT` to `PUBLIC` by default. That is expected and is not a finding. The assertion under test is table-level denial. Record both facts in the README so a future reader does not mistake the successful connection for a leak.

- [ ] **Step 8: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git add mealie/cnpg-database.yaml
git commit -m "Add CNPG Database CR for mealie on finance-service-cluster"
```

---

### Task 4: Deploy Mealie

**Files:**
- Create: `mealie/namespace.yaml`, `mealie/pvc.yaml`, `mealie/deployment.yaml`, `mealie/service.yaml`

**Interfaces:**
- Consumes: the `mealie` database (Task 3), Secret `mealie-db` in ns `mealie` (Task 2, applied here once the namespace exists), and the uid + health endpoint recorded in `mealie/README.md` (Task 1).
- Produces: Service `mealie` on port 9000 in ns `mealie`, which Task 5's IngressRoute targets.

- [ ] **Step 1: Write `namespace.yaml`**

```yaml
# Deliberately no pod-security.kubernetes.io labels here. The cluster default is
# baseline, which is the intended posture for this namespace — Mealie needs no
# privileged capabilities, no host networking and no hostPath. Do not add
# `enforce: privileged` to work around an unrelated failure.
apiVersion: v1
kind: Namespace
metadata:
  name: mealie
  labels:
    app: mealie
```

- [ ] **Step 2: Write `pvc.yaml`**

```yaml
# /app/data holds recipe images, user uploads and Mealie's own backup exports.
# The database lives on finance-service-cluster, NOT here.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mealie-data
  namespace: mealie
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 3: Write `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mealie
  namespace: mealie
  labels:
    app: mealie
spec:
  type: ClusterIP
  selector:
    app: mealie
  ports:
  - name: http
    port: 9000
    targetPort: http
    protocol: TCP
```

- [ ] **Step 4: Write `deployment.yaml`**

Substitute the uid/gid and health path recorded in `mealie/README.md` by Task 1 if they differ from the values below.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mealie
  namespace: mealie
  labels:
    app: mealie
spec:
  replicas: 1
  # Longhorn is RWO: a RollingUpdate deadlocks because the new pod cannot attach
  # the volume until the old one releases it. Every apply is a brief outage.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: mealie
  template:
    metadata:
      labels:
        app: mealie
    spec:
      securityContext:
        # Must match PGID below, or the Longhorn volume is not group-writable
        # and Mealie fails to write uploads. Value verified from the image in
        # README.md (Verified image facts).
        fsGroup: 911
      containers:
      - name: mealie
        image: ghcr.io/mealie-recipes/mealie:v3.22.0
        ports:
        - name: http
          containerPort: 9000
        env:
        - name: DB_ENGINE
          value: postgres
        - name: POSTGRES_SERVER
          # Fully qualified because this is cross-namespace. `-rw` is the CNPG
          # primary service; `-ro` would silently break every write on failover.
          value: finance-service-cluster-rw.finance.svc.cluster.local
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_DB
          value: mealie
        - name: POSTGRES_USER
          value: mealie
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mealie-db
              key: password
        # POSTGRES_URL_OVERRIDE is deliberately unset — it would put the
        # password into a plain env value instead of a secretKeyRef.
        - name: BASE_URL
          # Used for notification links and OIDC callbacks. Must match the
          # IngressRoute host, scheme included.
          value: https://mealie.arnoldtech.io
        - name: ALLOW_SIGNUP
          value: "false"
        - name: TZ
          value: America/Phoenix
        - name: PUID
          value: "911"
        - name: PGID
          value: "911"
        volumeMounts:
        - name: data
          mountPath: /app/data
        readinessProbe:
          httpGet:
            path: /api/app/about
            port: http
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /api/app/about
            port: http
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            # Recipe scraping is bursty; the limit sits well above the request
            # on purpose.
            memory: "1Gi"
            cpu: "1000m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: mealie-data
```

- [ ] **Step 5: Apply namespace, then the Secret, then storage**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml      # both documents now apply cleanly
kubectl apply -f pvc.yaml
kubectl get pvc mealie-data -n mealie
```

Expected: all report `created`/`configured`, and the PVC reaches `Bound`.

- [ ] **Step 6: Apply the workload**

```powershell
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl rollout status deploy/mealie -n mealie --timeout=600s
```

Do **not** add `kubectl rollout restart` after a Deployment apply — a Deployment edit restarts on its own, and the extra restart starts a second Recreate cycle that races the first.

- [ ] **Step 7: Confirm Mealie actually reached Postgres**

The pod becoming Ready is not proof — the probe may be shallow.

```powershell
kubectl logs -n mealie deploy/mealie --tail=200 | Select-String -Pattern "alembic|migration|postgres|database|error|Traceback" -CaseSensitive:$false
```

Expected: migrations run to completion, no traceback. Then confirm from the database side that Mealie created its schema:

```powershell
kubectl exec -n finance finance-service-cluster-1 -c postgres -- psql -d mealie -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public';"
```

Expected: a non-zero count. **Zero means Mealie is running on SQLite** despite `DB_ENGINE=postgres` — check for a typo in the env block.

- [ ] **Step 8: Verify PostgreSQL 18 compatibility explicitly**

The spec flags this as a risk: Mealie's own docs target `postgres:17`, so 18 is one major ahead of what upstream tests.

```powershell
kubectl logs -n mealie deploy/mealie --tail=400 | Select-String -Pattern "sqlalchemy|psycopg|ProgrammingError|OperationalError|UndefinedFunction" -CaseSensitive:$false
```

Expected: empty. Any hit here is a real finding — record it in the README and stop rather than working around it.

- [ ] **Step 9: Verify the probe's negative case — the step that matters**

Establish honestly whether the readiness probe covers database health.

```powershell
kubectl set env deploy/mealie -n mealie POSTGRES_SERVER=nonexistent.invalid
kubectl rollout status deploy/mealie -n mealie --timeout=300s
kubectl get pods -n mealie -l app=mealie
```

Two possible outcomes, and **both are acceptable — but only one may be claimed**:

- The pod never becomes Ready → the probe *is* DB-backed. Record that.
- The pod becomes Ready anyway → the probe is **shallow**. It covers process liveness only. Record that in `mealie/README.md` as a known limitation, in as many words, and do not describe the probe as a health check for the database anywhere.

Then restore:

```powershell
kubectl set env deploy/mealie -n mealie POSTGRES_SERVER=finance-service-cluster-rw.finance.svc.cluster.local
kubectl rollout status deploy/mealie -n mealie --timeout=300s
```

Confirm the restored value matches `deployment.yaml` exactly, or the next apply will show a spurious diff:

```powershell
kubectl get deploy mealie -n mealie -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
```

- [ ] **Step 10: Verify the volume is writable by the runtime uid**

```powershell
kubectl exec -n mealie deploy/mealie -- sh -c "id; touch /app/data/.write-probe && echo WRITE-OK && rm /app/data/.write-probe"
```

Expected: `WRITE-OK`. A permission error means `fsGroup` does not match the runtime gid from Task 1.

- [ ] **Step 11: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git status --short   # confirm mealie/secret.yaml is NOT listed
git add mealie/namespace.yaml mealie/pvc.yaml mealie/deployment.yaml mealie/service.yaml mealie/README.md
git commit -m "Deploy Mealie v3.22.0 against the shared CNPG cluster"
```

---

### Task 5: Expose Mealie through Traefik

**Files:**
- Create: `mealie/middleware.yaml`, `mealie/ingressroute.yaml`

**Interfaces:**
- Consumes: Service `mealie:9000` in ns `mealie` (Task 4).
- Produces: `https://mealie.arnoldtech.io` serving Mealie over the `*.arnoldtech.io` wildcard.

- [ ] **Step 1: Write `middleware.yaml`**

A faithful copy of `traefik/default-headers`. Mealie gets its own rather than referencing the shared one because its CSP is expected to need a delta, and editing the shared middleware would change every other app on the cluster. wger set this precedent with `wger-headers`.

```yaml
# A copy of traefik/default-headers, owned by this namespace so its CSP can be
# relaxed for Mealie without affecting every other app that uses the shared one.
# wger does the same thing with wger-headers.
#
# Any deviation from the shared copy MUST be justified by a console violation
# quoted in a comment beside it — see README.md (CSP).
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: mealie-headers
  namespace: mealie
spec:
  headers:
    browserXssFilter: true
    contentTypeNosniff: true
    customFrameOptionsValue: SAMEORIGIN
    customRequestHeaders:
      # Mealie builds absolute links from this alongside BASE_URL. Without it
      # Mealie sees plain HTTP and emits http:// links behind an HTTPS ingress.
      X-Forwarded-Proto: https
    forceSTSHeader: true
    referrerPolicy: no-referrer
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 15552000
    contentSecurityPolicy: >-
      default-src 'none';
      script-src 'self' 'unsafe-inline' 'unsafe-eval' https:;
      style-src 'self' 'unsafe-inline' https:;
      img-src 'self' data: https:;
      font-src 'self' https: data:;
      connect-src 'self' https:;
      frame-src 'self' https:;
      media-src 'self' https:;
      object-src 'none';
      frame-ancestors 'self';
      base-uri 'self';
      form-action 'self';
```

- [ ] **Step 2: Write `ingressroute.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mealie
  namespace: mealie
  annotations:
    # This is the ingressClass the kubernetescrd provider watches. It is NOT the
    # same string as the `traefik` IngressClass object used by plain Ingresses.
    kubernetes.io/ingress.class: traefik-external
spec:
  entryPoints:
  - websecure
  routes:
  - kind: Rule
    match: Host(`mealie.arnoldtech.io`)
    middlewares:
    - name: mealie-headers
      namespace: mealie
    services:
    - name: mealie
      port: 9000
  # Empty on purpose. An empty tls block makes Traefik fall back to
  # TLSStore/default in ns traefik, which holds the *.arnoldtech.io wildcard.
  # Do NOT add a secretName and do NOT create a cert-manager Certificate —
  # a TLS secret would have to live in this namespace, and the wildcard does not.
  tls: {}
```

- [ ] **Step 3: Apply**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
kubectl apply -f middleware.yaml
kubectl apply -f ingressroute.yaml
kubectl get ingressroute mealie -n mealie
```

- [ ] **Step 4: Confirm Traefik accepted the route**

```powershell
kubectl logs -n traefik deploy/traefik --tail=100 | Select-String -Pattern "mealie|error" -CaseSensitive:$false
```

Expected: no errors mentioning `mealie`. A misspelled middleware name shows up here and nowhere else — the route simply 404s in the browser.

- [ ] **Step 5: Verify TLS serves the wildcard — with its negative case**

```powershell
& openssl s_client -connect 192.168.130.150:443 -servername mealie.arnoldtech.io -showcerts </dev/null 2>&1 | Select-String -Pattern "subject=|issuer="
```

Expected: subject `CN=arnoldtech.io` (or with `*.arnoldtech.io` in the SANs) and issuer Let's Encrypt.

Expected **not** to see: `CN=TRAEFIK DEFAULT CERT`. That self-signed placeholder is what a failed `TLSStore` lookup looks like, and in a browser that has already been click-throughed it is indistinguishable from success.

- [ ] **Step 6: Verify end-to-end over HTTP**

```powershell
curl.exe -sS -o NUL -w "%{http_code}\n" https://mealie.arnoldtech.io/api/app/about
```

Expected: `200`.

- [ ] **Step 7: Verify the CSP does not break the UI — browser required**

Use the Chrome browser tools. Open `https://mealie.arnoldtech.io`, complete first-run setup, sign in, open a recipe, and upload an image, then read the console:

- Load the page and read console messages filtered on `Content Security Policy`.
- **Zero CSP violations is the pass.**

If violations appear, add the minimal directive that clears each one to `middleware.yaml`, **quoting the violation text verbatim in a comment beside it**. The likely candidates, to be confirmed rather than pre-applied, are `worker-src 'self' blob:`, `manifest-src 'self'`, and `blob:` added to `img-src`/`media-src` — Mealie is a PWA with a service worker and blob-backed image previews. Re-apply and re-check until the console is clean.

- [ ] **Step 8: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git add mealie/middleware.yaml mealie/ingressroute.yaml mealie/README.md
git commit -m "Expose Mealie via Traefik IngressRoute on the wildcard cert"
```

---

### Task 6: Snapshot `mealie-data`

The database is already covered by the existing `finance-db-daily-backup` ScheduledBackup. This task covers the *volume* — recipe images and uploads, which live only here.

**Files:**
- Create: `mealie/recurringjob.yaml`

**Interfaces:**
- Consumes: PVC `mealie-data` (Task 4).
- Produces: a daily Longhorn snapshot of the Mealie volume.

- [ ] **Step 1: Write `recurringjob.yaml`**

```yaml
# NOTE: this file deploys into `longhorn-system`, NOT `mealie`.
#
# This job does nothing until the Longhorn Volume backing mealie-data carries
# the label recurring-job-group.longhorn.io/mealie=enabled — a new or recreated
# PVC's volume starts unlabeled. The label goes on the VOLUME, not the PVC. If
# snapshots aren't appearing, check that before anything else. See
# mealie/README.md (Backups) for the labeling and verification commands.
#
# 03:00 local, offset from the finance database's 02:00 UTC ScheduledBackup so
# the two do not contend for Longhorn I/O.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: mealie-daily-snapshot
  namespace: longhorn-system
spec:
  cron: "0 10 * * *"
  task: snapshot
  groups:
  - mealie
  retain: 7
  concurrency: 1
```

- [ ] **Step 2: Apply**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\mealie"
kubectl apply -f recurringjob.yaml
kubectl get recurringjob mealie-daily-snapshot -n longhorn-system
```

- [ ] **Step 3: Confirm the negative case first — unlabeled means nothing happens**

```powershell
$pv = kubectl get pvc mealie-data -n mealie -o jsonpath='{.spec.volumeName}'
$pv
kubectl get volumes.longhorn.io $pv -n longhorn-system -o jsonpath='{.metadata.labels}{"\n"}'
```

Expected: no `recurring-job-group.longhorn.io/mealie` key. This is the documented failure mode, observed deliberately so the next step's success means something.

- [ ] **Step 4: Label the Volume**

```powershell
kubectl label volumes.longhorn.io $pv -n longhorn-system recurring-job-group.longhorn.io/mealie=enabled
kubectl get volumes.longhorn.io $pv -n longhorn-system -o jsonpath='{.metadata.labels}{"\n"}'
```

Expected: the label is now present.

- [ ] **Step 5: Prove a snapshot actually fires**

Waiting a day is not verification. Record the snapshots that exist now, then move the cron
to three minutes out. Longhorn's cron is evaluated in **UTC**, so compute it rather than
reading a wall clock:

```powershell
$before = (kubectl get snapshots.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') -split "`n" | Where-Object { $_ }
$before.Count

$t = [System.DateTime]::UtcNow.AddMinutes(3)
$cron = "{0} {1} * * *" -f $t.Minute, $t.Hour
$cron
$patch = '{"spec":{"cron":"' + $cron + '"}}'
kubectl patch recurringjob mealie-daily-snapshot -n longhorn-system --type=merge -p $patch
```

Then poll — Longhorn labels snapshots by volume, so filter on `spec.volume` rather than
guessing a label key:

```powershell
kubectl get snapshots.longhorn.io -n longhorn-system `
  -o jsonpath='{range .items[*]}{.metadata.name}{"  vol="}{.spec.volume}{"  ready="}{.status.readyToUse}{"\n"}{end}' |
  Select-String -SimpleMatch "vol=$pv"
```

Expected, within ~4 minutes: at least one line whose `vol=` is `$pv` and `ready=true`,
which was **not** in `$before`. Re-run the poll every 30s until it appears; if nothing has
appeared after 6 minutes, the Volume label from Step 4 did not take — recheck it before
anything else.

- [ ] **Step 6: Restore the real cron**

```powershell
kubectl apply -f recurringjob.yaml
kubectl get recurringjob mealie-daily-snapshot -n longhorn-system -o jsonpath='{.spec.cron}{"\n"}'
```

Expected: `0 10 * * *`. **This step is mandatory** — leaving the test cron in place means the manifest and the live object disagree, and the next `kubectl apply` would look like a no-op change.

- [ ] **Step 7: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git add mealie/recurringjob.yaml
git commit -m "Add daily Longhorn snapshot for mealie-data"
```

---

### Task 7: Finish the documentation

**Files:**
- Modify: `mealie/README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: findings recorded by Tasks 1–6.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Complete `mealie/README.md`**

It already carries the verified image facts (Task 1) and findings appended by Tasks 2–6. Add these sections:

- **Overview** — what Mealie is, the URL, and that it is LAN-only by deliberate decision.
- **Where the database lives** — `finance/finance-service-cluster`, the `-rw` service, and the fact that **two files in this directory deploy into other namespaces** (`cnpg-database.yaml` → `finance`, `recurringjob.yaml` → `longhorn-system`).
- **The cross-repo dependency** — the `mealie` role lives in `spec.managed.roles` on a Cluster defined in `finance-manager/k8s/database/cluster.yaml`. Deleting or reverting that role breaks Mealie's login with an error that looks like a Mealie bug.
- **Deploying** — the apply order, and that `strategy: Recreate` means every apply is a brief outage.
- **Rotation** — changing the password means updating **both** Secret objects and restarting the deployment; a mismatch shows as Mealie failing auth while CNPG reports the role healthy.
- **Backups** — DB via `finance-db-daily-backup`; volume via `mealie-daily-snapshot`, plus the Volume-label gotcha and the label command.
- **CSP** — the middleware is a copy of the shared one; the deltas and their justifications.
- **Probe coverage** — state plainly whether the readiness probe covers the database, per Task 4 Step 9. If it is shallow, say so.

- [ ] **Step 2: Add `mealie/` to the repo CLAUDE.md workload list**

In the bullet list under the intro, after the `mumble/` line:

```markdown
- `mealie/` — recipe manager. Its database is a `Database` CR on the **shared** `finance-service-cluster`
  in the `finance` namespace, and the owning role lives in that Cluster's `spec.managed.roles` — which is
  defined in the *finance-manager* repo, not this one. Two files in `mealie/` deploy outside the `mealie`
  namespace; read the README before applying
```

- [ ] **Step 3: Verify the docs match reality**

Re-read `mealie/README.md` against the live cluster. Every command in it must run as written.

```powershell
kubectl get all,ingressroute,middleware,pvc -n mealie
kubectl get database.postgresql.cnpg.io mealie -n finance
kubectl get recurringjob mealie-daily-snapshot -n longhorn-system
```

- [ ] **Step 4: Commit**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal"
git add mealie/README.md CLAUDE.md
git commit -m "Document the mealie workload and its cross-repo database dependency"
```

---

### Task 8: Repair the stale finance cluster manifest

Separate repo, separate commit. This defuses a landmine that predates Mealie: applying the current file would scale the finance database from 3 instances to 1.

**Files:**
- Modify: `C:\Users\RyanArnold\Documents\GitHub\finance-manager\k8s\database\cluster.yaml`

**Interfaces:**
- Consumes: the role definition applied in Task 2.
- Produces: nothing. This is the last task.

- [ ] **Step 1: Re-read the live object as the source of truth**

Do not copy the values from this plan — re-read them, in case anything changed during the work.

```powershell
kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance `
  -o jsonpath='{"instances="}{.spec.instances}{"\nimage="}{.spec.imageName}{"\nstorage="}{.spec.storage.size}{"\nsc="}{.spec.storage.storageClass}{"\nsuperuser="}{.spec.enableSuperuserAccess}{"\nparams="}{.spec.postgresql.parameters}{"\nroles="}{.spec.managed.roles}{"\n"}'
```

- [ ] **Step 2: Rewrite `cluster.yaml`**

Preserve the existing bootstrap block exactly — it must never change, or CNPG would attempt a re-bootstrap.

```yaml
# NOTE: this file had drifted badly from the live cluster and was repaired on
# 2026-08-12. It previously said instances: 1 and storage: 10Gi, so applying it
# would have scaled the production database down to a single replica. The values
# below were recovered by reading the live object.
#
# Nothing reconciles this file automatically — there is no kustomization
# referencing it. It is the record of intent; keep it in step with reality.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: finance-service-cluster
  namespace: finance
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie
  enableSuperuserAccess: false
  storage:
    size: 15Gi
    storageClass: longhorn
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "100"
  bootstrap:
    initdb:
      database: finance
      owner: finance
      secret:
        name: postgresdb-cluster-secret
  managed:
    roles:
    # Owner of the `mealie` database, used by the Mealie workload in namespace
    # `mealie` (kubernetes-manifests-personal/mealie/). Removing this role does
    # not fail loudly here — it breaks Mealie's login instead.
    - name: mealie
      ensure: present
      login: true
      superuser: false
      createdb: false
      createrole: false
      inherit: true
      # Bounded so Mealie cannot exhaust max_connections=100 and take finance down.
      connectionLimit: 20
      comment: "Owner of the mealie database. Added 2026-08-12 for the Mealie workload in ns mealie."
      passwordSecret:
        name: mealie-db
```

- [ ] **Step 3: Diff it against the live object BEFORE applying — this is the gate**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\finance-manager"
kubectl diff -f k8s/database/cluster.yaml
```

Expected: **no changes**, or changes confined to fields the operator defaults. Specifically expected **not** to appear: any change to `instances`, `storage`, `bootstrap`, or `imageName`.

**If the diff shows `instances` changing, stop.** The file is still wrong and applying it would scale the production database down.

- [ ] **Step 4: Server-side dry run**

```powershell
kubectl apply -f k8s/database/cluster.yaml --dry-run=server
```

Expected: `configured` (server dry run), no validation errors.

- [ ] **Step 5: Apply, then confirm finance is untouched**

```powershell
kubectl apply -f k8s/database/cluster.yaml
kubectl get cluster.postgresql.cnpg.io finance-service-cluster -n finance `
  -o jsonpath='{.status.phase}{"  ready="}{.status.readyInstances}{"/"}{.status.instances}{"  primary="}{.status.currentPrimary}{"\n"}'
kubectl get pods -n finance -l cnpg.io/cluster=finance-service-cluster
```

Expected: `Cluster in healthy state`, 3/3 ready, same primary as Task 2 Step 7, and **no new pod restarts**.

- [ ] **Step 6: Confirm Mealie still works after the apply**

The role was applied twice by two different mechanisms; prove the second did not disturb the first.

```powershell
curl.exe -sS -o NUL -w "%{http_code}\n" https://mealie.arnoldtech.io/api/app/about
kubectl logs -n mealie deploy/mealie --tail=50 | Select-String -Pattern "auth|password|error" -CaseSensitive:$false
```

Expected: `200`, and no authentication errors.

- [ ] **Step 7: Commit in the finance-manager repo**

```powershell
cd "C:\Users\RyanArnold\Documents\GitHub\finance-manager"
git add k8s/database/cluster.yaml
git commit -m "Repair stale finance cluster manifest and add the mealie role"
```

---

## Notes for the executor

- **Do not run `ghost:` security scans or open a PR.** This repo commits directly to `main` and ships no application code; the global security-gate workflow targets code repositories.
- **Check connections before restarting shared things, in the same action as the restart.** This does not apply to `mealie` itself while it is new and unused, but Task 2 and Task 8 touch a database serving a live application.
- **`unchanged` from `kubectl apply` is a silent failure**, not a success — almost always the wrong working directory.
- **After editing a config file in place, re-read it and confirm section/key counts are unchanged.** An appended duplicate is the signature of a failed match.
