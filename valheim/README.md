# Valheim Dedicated Server

LAN-only Valheim server on the `k8` Talos cluster.
Design: `../docs/superpowers/specs/2026-07-26-valheim-server-deployment-design.md`,
BepInEx: `../docs/superpowers/specs/2026-07-26-valheim-bepinex-design.md`

## Joining

**Start Game → Select Character → Join Game → Join IP →** `192.168.130.155:2456`

The server is not listed in the community browser: `SERVER_PUBLIC=false`.
World: `TreeFellMeFirst`. Password lives in the `valheim-secrets` Secret.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `valheim` |
| `configmap.yaml` | Non-secret server config |
| `secret.yaml.template` | Template for the password Secret |
| `pvc.yaml` | `valheim-data` (/config), `valheim-server` (/opt/valheim) |
| `deployment.yaml` | The server |
| `service.yaml` | MetalLB LoadBalancer, UDP 2456-2457 |
| `recurringjob.yaml` | Longhorn daily snapshot |

`secret.yaml` is gitignored. Copy the template, set the password, apply.

## Applying

```powershell
Copy-Item secret.yaml.template secret.yaml   # then edit secret.yaml and set a real password
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
```

Use absolute paths (or `cd` into `valheim/` first). Applying with a relative path from the
wrong working directory can silently no-op, and `kubectl rollout status` will still print a
success line — but for the *previous* rollout, not this one. Confirm the `apply` output says
`configured` (or `created`), not `unchanged`, before trusting a rollout status check.

`secret.yaml` is gitignored and does not exist on a fresh clone — the `Copy-Item` step above
is required before the first `apply`, not just on recovery.

**Post-deploy, required — a brand-new `valheim-data` PVC's Longhorn Volume starts unlabeled,
same as a recreated one.** The RecurringJob applied above will look healthy and produce zero
snapshots until the volume is labeled. Do this immediately after the PVCs are bound:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim=enabled" --overwrite
```

Then confirm a snapshot actually appears (see Backups below for the verification command).
Do not treat a healthy-looking RecurringJob as proof — see the `wger-daily-snapshot` cautionary
tale in the plan.

## Operating notes

- **Never lower `terminationGracePeriodSeconds` below 120.** Valheim needs ~2 minutes to
  flush the world on SIGTERM. A shorter value corrupts the world on every restart.
- **`strategy: Recreate` is required.** RollingUpdate deadlocks on the ReadWriteOnce volume.
- **Startup and readiness probes only, deliberately no liveness probe.** Both run
  `pgrep -f '[v]alheim_server'` in-container: `startupProbe` (period 10s, failureThreshold 120
  = 20 min) covers the cold SteamCMD install and slow first world load, `readinessProbe`
  (period 30s, failureThreshold 3) tracks whether the game process is up. A liveness probe is
  deliberately omitted — it would SIGKILL the server mid-save. Supervisord restarts the game
  process internally; the Deployment restarts the container if the startup probe never succeeds.
- **Never unbracket the probe pattern.** `pgrep -f` matches full command lines, so the
  unbracketed `pgrep -f valheim_server` matches the probe's *own* `sh -c` process and returns 0
  no matter what — a probe that cannot fail. The `> /dev/null` is what causes it: with a
  redirect, bash keeps the parent shell (argv and all) alive instead of exec-replacing itself.
  That is why the bare form passes a manual "is the server up?" check and still never fails.
  `[v]alheim_server` matches the real process but not the literal shell argv. Verify any change
  against a name that does not exist, not just against a healthy server:

  ```powershell
  # want: exit=1
  kubectl exec -n valheim deploy/valheim -- sh -c 'pgrep -f "[Z]ZZNOSUCH" > /dev/null; echo exit=$?'
  ```

  Note the single-quoted outer string — PowerShell would eat a `$?` inside double quotes. The
  bracketed form is safe to test inline like this. Testing an **unbracketed** candidate is not:
  your own test command's argv contains the pattern, so the test self-matches exactly the way
  the probe does and reports success. For those, write the command to a script file inside the
  container first and run the file, so no ancestor process argv carries the pattern.
- **No CPU limit, deliberately.** CFS throttling shows up in-game as rubber-banding.
- **Do not add `SYS_NICE` back, and do not label the namespace privileged.** The cluster
  enforces Pod Security Admission at `baseline` for any namespace without PSA labels, and
  `valheim` carries none — it runs at that stricter default on purpose. `SYS_NICE` is not in
  baseline's permitted capability set, so it was dropped. Seven namespaces in this cluster
  (`cattle-system`, `enshrouded`, `kubevirt`, `longhorn-system`, `metallb-system`, `pihole`,
  `traefik`) carry `pod-security.kubernetes.io/enforce: privileged` and could add it back —
  privileged is the norm for infra namespaces here, not a two-off exception; `valheim`
  deliberately does not run under that label. If something seems to need `SYS_NICE`, fix it
  another way rather than loosening the namespace.
- Server auto-updates nightly at 05:00 America/Phoenix (`UPDATE_CRON`), which restarts it
  and disconnects anyone online.
- **`SAVEINTERVAL` is unset**, so the image default of 1800s (30 min) applies. Up to ~30
  minutes of world progress can be lost on an ungraceful termination (e.g. node failure).
  The ConfigMap is unchanged; noted here for awareness.
- **`externalTrafficPolicy: Local` + pod reschedule = brief outage.** If the pod moves to a
  different node (eviction, node drain, etc.), MetalLB has to re-announce the address from
  the new node. There's a short gap where `192.168.130.155:2456` is unreachable until that
  completes — this is expected, not a misconfiguration.
- **Never write the live server password into a tracked file** — not even as a search/grep
  pattern in a doc or plan. This has already leaked into a tracked file once (`mumble/configmap.yaml`,
  known and owner-accepted) and been hardcoded into a credential-check step in this repo's own
  plan once more. Derive it from the `valheim-secrets` Secret at runtime instead, e.g.:
  `[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl get secret valheim-secrets -n valheim -o jsonpath='{.data.server-password}')))`.

## Modding (BepInEx)

`BEPINEX: "true"` is set in `configmap.yaml`. The framework is installed and
loaded; **no mods are installed.**

- **Vanilla clients are unaffected.** BepInEx on the server imposes no
  requirement on clients by itself. Compatibility is enforced per-mod — a client
  is rejected only when a mod requiring client-side components is installed.
- **`BEPINEX` and `VALHEIM_PLUS` are mutually exclusive.** Enabling both fails.
- **Mod config** lives in `/config/bepinex` on the `valheim-data` PVC, so it
  survives restarts. Mod config can also be set from the ConfigMap using
  `BEPINEXCFG_<Section>_<Variable>` keys.
- **Mod DLLs go in `/config/bepinex/plugins/`** on the `valheim-data` PVC
  (verified present, currently empty — confirmed via `kubectl exec`). At
  container bootstrap, the image rsyncs this directory into the live
  BepInEx install (`/opt/valheim/bepinex/BepInEx/plugins`); that sync only
  runs on startup, so a DLL dropped in while the server is running is **not**
  picked up until the next restart, not instantly. This sharpens the
  `UPDATE_CRON` hazard below: the same unattended nightly restart that can
  break a mod against a new Valheim patch is also the only moment a
  newly-delivered plugin actually takes effect, untested.
- Enabling or disabling the framework costs a `Recreate` restart (up to ~2
  min, 120s grace; observed ~25s).

### Before installing any mod — remaining gap

The destination and its persistence are solved (above): drop a `.dll` in
`/config/bepinex/plugins/` on `valheim-data` and it survives restarts and
gets synced into the live install on the next boot. What's not solved is
**how the DLL gets onto that PVC in the first place** — Kubernetes has no
bind-mount equivalent for a workstation file, so this needs an init
container, a helper pod, or a custom image layer. This README already has a
working helper-pod recipe for the same PVC (a `busybox` pod mounting
`valheim-data` at `/config`, see Restore below) that the same pattern could
adapt for plugin delivery instead of designing one from scratch. Choosing a
repeatable, ideally declarative version of that transport is the remaining
decision — not "nothing exists."

`UPDATE_CRON` remains a separate hazard: it is currently `0 5 * * *` and
unattended. A Valheim patch routinely breaks BepInEx mods, so a nightly
auto-update can leave a broken mod stack running overnight. Decide the policy
before mods exist, not after.

### Confirm the framework is healthy

```powershell
kubectl logs -n valheim deploy/valheim --tail=200 | Select-String BepInEx
```

Expect `Chainloader startup complete` and `0 plugins to load` (BepInEx
5.4.23.3).

### If the server goes unreachable after a framework change

The readiness probe is `pgrep -f '[v]alheim_server'`. BepInEx execs the game binary
through an `LD_PRELOAD` wrapper — if that ever stops matching, readiness never
becomes true and the Service drops its endpoints while the pod still reports
`Running`. Under BepInEx today the match is on
`/opt/valheim/bepinex/valheim_server.x86_64 -nographics -batchmode ...`, confirmed
in the live container.

⚠️ **This failure mode only became possible once the probe was fixed.** The
originally committed probe was unbracketed and matched its own shell, so it always
returned 0 — readiness could never go false and endpoints could never drop. Any
"endpoints looked healthy" observation recorded before that fix proves nothing
about this scenario. Check endpoints, not pod status:

```powershell
kubectl get endpointslice -n valheim -l kubernetes.io/service-name=valheim -o jsonpath='{range .items[*]}{.endpoints[*].conditions.ready}{"\n"}{end}'
```

To disable the framework: remove the `BEPINEX` key from `configmap.yaml`, apply,
and `kubectl rollout restart deploy/valheim -n valheim`.

## Backups

Two layers:

1. **In-app** — hourly zipped backups in `/config/backups`, 3-day retention, skipped while
   idle. List them:
   `kubectl exec -n valheim deploy/valheim -- ls -la /config/backups`
2. **Longhorn snapshots** — `valheim-daily-snapshot`, cron `0 11 * * *`, retain 7, on the
   `valheim-data` volume only. **This is 11:00 UTC = 04:00 America/Phoenix** —
   `longhorn-manager` evaluates RecurringJob crons with no TZ configured, so it always runs
   in UTC regardless of the ConfigMap's `TZ`; the `11` is a manual UTC-offset conversion, not
   a timezone-aware `04:00`. Arizona does not observe DST, so this UTC value is stable
   year-round and never needs a seasonal adjustment. This is unlike `UPDATE_CRON` and
   `BACKUPS_CRON` above, which run inside the container and do honor `TZ`. Verified working: real snapshots
   have been observed on the volume, named `valheim--<uuid>` (not `valheim-daily-snapshot-*`).
   Because `retain: 7` rotates older ones out, a snapshot name you saw before may legitimately
   be gone later — that alone is not evidence of a problem.

⚠️ **The snapshot job binds via a label on the Longhorn Volume, not the PVC.** If
`valheim-data` is ever deleted and recreated, the new volume will NOT be labeled and
snapshots silently stop. Re-apply:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim=enabled" --overwrite
```

Verify snapshots are genuinely being produced — a healthy-looking RecurringJob is not proof:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl get snapshots.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | Where-Object { $_.spec.volume -eq $pv } |
  ForEach-Object { $_.metadata.name }
```

Expect names like `valheim--6bff2bbb-...`, up to 7 of them, rotating — not a fixed
`valheim-daily-snapshot-*` name.

Longhorn snapshots live on the same volume, so they protect against corruption and bad
writes, not against loss of the volume. Off-cluster DR is not configured.

## Restore

**In-app backup** — a running pod holds the ReadWriteOnce `valheim-data` volume attached, so
you cannot scale to 0 and then `kubectl exec` into the same pod — scaling to 0 terminates the
only pod, and the exec either fails with "no pod found" or races a `Terminating` pod mid-save.
The volume must fully detach, then a short-lived helper pod does the unzip:

1. Scale the Deployment to 0 and **wait for the pod to be fully gone** — the volume can take
   up to the full 120s `terminationGracePeriodSeconds` to detach, and nothing else can mount
   it until it does. Confirm with:

   ```powershell
   kubectl scale deploy/valheim -n valheim --replicas=0
   kubectl wait --for=delete pod -n valheim -l app=valheim --timeout=180s
   ```

   `kubectl wait --for=delete` returns as soon as the pod object is gone. If it times out,
   check `kubectl get pod -n valheim -l app=valheim` before proceeding — do not continue
   while a pod is still `Terminating`.

2. Run a short-lived helper pod that mounts the **`valheim-data`** PVC (not `valheim-server`
   — that PVC only holds the disposable game install) at `/config`, and unzip the archive
   from inside it:

   ```powershell
   kubectl run valheim-restore-helper -n valheim --image=busybox --restart=Never --overrides='{
     "apiVersion": "v1",
     "spec": {
       "containers": [{
         "name": "restore-helper",
         "image": "busybox",
         "command": ["sh", "-c", "cd /config/worlds_local && unzip -o /config/backups/<archive>.zip && sleep 3600"],
         "volumeMounts": [{ "name": "data", "mountPath": "/config" }]
       }],
       "volumes": [{ "name": "data", "persistentVolumeClaim": { "claimName": "valheim-data" } }]
     }
   }'
   ```

   Substitute `<archive>` with the file found via the `ls` command under Backups above. Wait
   for the pod to reach `Running`/`Completed` (`kubectl get pod -n valheim valheim-restore-helper`),
   then confirm the unzip succeeded, e.g.:

   ```powershell
   kubectl logs -n valheim valheim-restore-helper
   kubectl exec -n valheim valheim-restore-helper -- ls -la /config/worlds_local
   ```

3. Delete the helper pod once you've confirmed the restore:

   ```powershell
   kubectl delete pod -n valheim valheim-restore-helper
   ```

   ⚠️ **The helper pod must be fully gone before scaling the Deployment back up.**
   `valheim-data` is ReadWriteOnce — the server pod cannot attach the volume while the helper
   pod still holds it. Confirm with `kubectl get pod -n valheim valheim-restore-helper`
   (expect `NotFound`) before step 4.

4. Scale the Deployment back to 1:

   ```powershell
   kubectl scale deploy/valheim -n valheim --replicas=1
   ```

**Longhorn snapshot** — the volume must be detached before a revert, which only happens with
the pod scaled to 0:

```powershell
kubectl scale deploy/valheim -n valheim --replicas=0
```

Then, once the Volume shows `Detached` in the Longhorn UI, revert to the chosen snapshot
either from the Longhorn UI (Volume → Snapshots → Revert) or by editing the Volume CR
directly. Scale back to 1 once the revert completes:

```powershell
kubectl scale deploy/valheim -n valheim --replicas=1
```

**Pulling the world off the volume** (e.g. before any destructive step, or to back it up
off-cluster). **Precondition: the server pod must still be running** — `kubectl cp` copies
through a live pod's API server proxy and fails against a scaled-to-0 Deployment or a
`Terminating` pod:

```powershell
kubectl cp valheim/$(kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'):/config/worlds_local ./worlds_local-backup
```

## Access control

`SERVER_PUBLIC=false` is not access control — it only hides the server from the browser.
Anything that can route to `192.168.130.155:2456` and knows the password can join. There is
no source-IP allowlist; the router decides reachability.

NetworkPolicy cannot help here — this cluster runs Flannel, which does not enforce it. To
add a real allowlist, use `spec.loadBalancerSourceRanges` in `service.yaml` (enforced by
kube-proxy). If you do, list any VPN tunnel subnet explicitly, or VPN clients on `10.x` or
`100.64.x` will be locked out.

## Common tasks

Add admins — edit `ADMINLIST_IDS` in `configmap.yaml` (space-separated SteamID64), then:

```powershell
kubectl apply -f configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
```

Stop the server without deleting anything:

```powershell
kubectl scale deploy/valheim -n valheim --replicas=0
```

Follow logs:

```powershell
kubectl logs -n valheim deploy/valheim --follow
```

## Rollback

Remove the workload while keeping the world intact:

```powershell
kubectl delete -f deployment.yaml -f service.yaml
```

This leaves both PVCs bound, so the world survives any manifest mistake. Re-apply to
restore service.

To tear down completely — **this destroys the world** — delete the PVCs explicitly:

```powershell
kubectl delete -f deployment.yaml -f service.yaml -f recurringjob.yaml
kubectl delete -f pvc.yaml   # DESTRUCTIVE: storageClass longhorn has reclaimPolicy Delete
kubectl delete -f namespace.yaml
```

Take a manual Longhorn snapshot or copy `/config/worlds_local` off the volume first — see
"Pulling the world off the volume" under Restore above for the exact `kubectl cp` command.
