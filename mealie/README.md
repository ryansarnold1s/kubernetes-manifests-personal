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
