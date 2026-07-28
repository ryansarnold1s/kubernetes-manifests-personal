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
| `mods-configmap.yaml` | Pinned mod manifest + installer script for the `fetch-mods` initContainer |
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
- **Unattended auto-update is DISABLED** (`UPDATE_CRON: ""`). Valheim now updates only when the
  container restarts, i.e. when you run `kubectl rollout restart`. This is deliberate: a Valheim
  patch routinely breaks BepInEx mods, and mods are installed here. Update on purpose, with time
  to check the mod stack afterwards. **Do not delete the `UPDATE_CRON` key to "turn it off"** —
  see the warning in `configmap.yaml`; removing it enables 15-minute update checks.
- **A separate nightly restart is still active and was NOT disabled**: `RESTART_CRON` defaults to
  `10 5 * * *` and is not set in `configmap.yaml`, so the image's default applies. Confirmed live
  in the container's crontab:

  ```
  10 5 * * * /usr/local/bin/valheim-is-idle && /usr/local/bin/supervisorctl restart valheim-server
  ```

  This is much lower risk than the auto-update was — it restarts only the game process via
  supervisord, pulls no new Valheim version, and `RESTART_IF_IDLE` (default `true`) skips it
  entirely while anyone is online. Left on deliberately for memory hygiene on a long-running
  server. To disable it, add `RESTART_CRON: ""` to `configmap.yaml` — and note it takes an
  explicit empty string for the same `${VAR-default}` reason as `UPDATE_CRON`.
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

## World modifiers (native — no mods needed)

Currently set: **`SERVER_ARGS: "-modifier resources more"`** in `configmap.yaml` — one step
above normal drop rates.

Valheim has native difficulty/rate modifiers compiled into the server. Verified present in
this build's `assembly_valheim.dll`:

| Key | Values |
|---|---|
| `combat` | `veryeasy` `easy` `normal` `hard` `veryhard` |
| `deathpenalty` | `casual` `veryeasy` `easy` `normal` `hard` `hardcore` |
| `resources` | `muchless` `less` `normal` `more` `muchmore` |
| `raids` | `none` `muchless` `less` `normal` `more` `muchmore` |
| `portals` | `casual` `normal` `hard` `veryhard` |

Global keys are separate: `-setkey nobuildcost | nomap | passivemobs | playerevents`.

⚠️ **`resources` is a global drop multiplier**, not a mob-loot multiplier. It scales ore veins,
trees and foraging along with kills. There is no native way to boost mob drops alone.

⚠️ **There is no native durability modifier.** The only durability-related symbols in the
assembly are internal item fields (`maxDurability`, `useDurabilityDrain`, `durabilityPerLevel`)
— nothing exposed to the launch parser or the console. Adjusting durability requires a BepInEx
mod, which means solving the DLL-delivery gap below first.

### Changing a modifier

`SERVER_ARGS` is appended **unquoted** to the launch line by the image
(`/usr/local/bin/valheim-server`), so space-separated args work but a value containing a space
will not. Edit `configmap.yaml`, then:

```powershell
kubectl apply -f configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
```

**A malformed `-modifier` arg logs a parse error and is otherwise silently ignored — the server
starts normally and you get no in-game hint.** Always confirm the modifier was actually applied
rather than assuming the restart worked:

```powershell
# want one "Setting world modifier: <key>-><value>" line per modifier
kubectl logs -n valheim deploy/valheim --tail=500 | Select-String "Setting world modifier"
# want nothing
kubectl logs -n valheim deploy/valheim --tail=500 | Select-String "Failed to parse|couldn't be parsed"
```

**`SERVER_ARGS` is the source of truth on every boot — modifiers are not persisted into the
world save.** Verified on this world: `TreeFellMeFirst.fwl` is 56 bytes (version, name, seed,
uid — nothing else), and the 4.7MB `.db` contains no modifier or global-key state. So reverting
is just removing the arg and restarting; there is nothing left behind in the world to clean up,
and no need for the `resetworldkeys` console command.

The practical consequence: **whatever is in `SERVER_ARGS` wins after any restart.** A modifier
set at runtime via the `setworldmodifier` console command is session-local and any restart
silently replaces it with the ConfigMap value. If you want a change to stick, put it in
`configmap.yaml`.

## Modding (BepInEx)

`BEPINEX: "true"` is set in `configmap.yaml`. **Eight mods are installed**, fetched declaratively
by the `fetch-mods` initContainer from `mods-configmap.yaml`:

| Mod | Version | Client install |
|---|---|---|
| Jotunn | 2.29.2 | required (framework) |
| JsonDotNET | 13.0.4 | required (library) |
| EpicLoot | 0.12.15 | **required** |
| AzuExtendedPlayerInventory | 2.4.1 | **required — kicks clients without it** |
| AzuContainerSizes | 1.1.4 | **required — kicks clients without it** |
| Warfare | 1.8.9 | **required** (custom weapon/animation assets) |
| SkilledCarryWeight | 1.4.1 | recommended (server install enforces config) |
| PlantEverything | 1.20.0 | recommended (works without, minor cosmetic loss) |

🚨 **Vanilla clients can no longer join.** AzuExtendedPlayerInventory *and* AzuContainerSizes each
run a version check that kicks clients without them, and EpicLoot and Warfare need client-side
assets. Every player must run the matching set, plus `BepInExPack_Valheim 5.4.2333`. r2modman
pinned to these exact versions is the low-drift path. This reverses what this README said before
mods existed — BepInEx alone imposed nothing on clients, but these specific mods do.

⚠️ **`JsonDotNET` is the one people skip**, because it reads as a library rather than a mod. Without
it the client logs `Could not load [Epic Loot] because it has missing dependencies:
com.ValheimModding.NewtonsoftJsonDetector`, EpicLoot never loads, and Jotunn then refuses the
connection with **`ErrorVersion`** — which looks like a game-version mismatch and is not one.
If a client gets `ErrorVersion`, check its BepInEx log for a failed plugin load before suspecting
the server.

- **`BEPINEX` and `VALHEIM_PLUS` are mutually exclusive.** Enabling both fails.
- **Mod config** lives in `/config/bepinex` on the `valheim-data` PVC, so it survives restarts.
  It can also be set from the ConfigMap using `BEPINEXCFG_<Section>_<Variable>` keys.
- **`BepInEx/config` in the live install is a symlink to `/config/bepinex`** (verified with
  `readlink -f`). Anything a mod zip ships under `config/` therefore only has to be written to
  the PVC — the installer does this, and it is how Warfare's `TherzieTranslations` YAMLs land.
- **Mod DLLs go in `/config/bepinex/plugins/<Name>/`**, which the image rsyncs into
  `/opt/valheim/bepinex/BepInEx/plugins` at container bootstrap. That sync runs **once per boot**,
  which is exactly why the fetch runs as an initContainer — anything delivered later sits inert
  until the next restart.

### How the mods get there

`deployment.yaml` runs a `fetch-mods` initContainer before the game container. It reads the
pinned manifest from `mods-configmap.yaml`, downloads each package, **verifies its SHA256**, and
extracts it to the PVC. Two package layouts exist and are handled explicitly — some zips ship a
`plugins/` dir, others put the `.dll` at the root — so the `layout` column is not decoration.

It is **idempotent**: markers in `/config/bepinex/.mod-state` are keyed on version+sha256, so a
normal restart downloads nothing (verified: re-running the installer reports `0 installed,
6 already present`). This matters — Warfare alone is 182MB.

A **checksum mismatch fails the pod deliberately.** This is executable code running inside the
server. Because installs are idempotent, that only ever gates a first install or a version bump,
so a Thunderstore outage cannot take down an already-provisioned server.

### Adding, upgrading, removing

Edit the `MODS` block in `mods-configmap.yaml`, then apply and restart:

```powershell
kubectl apply -f mods-configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
```

Get a checksum for a new version with:

```powershell
kubectl exec -n valheim deploy/valheim -- sh -c 'curl -fsSL -o /tmp/m.zip "<url>" && sha256sum /tmp/m.zip'
```

⚠️ **Removing a mod needs a second step.** Deleting its line stops it being fetched, but the
image syncs with `rsync -a` and **no `--delete`**, so the stale DLL survives in the live install.
Also delete `/opt/valheim/bepinex/BepInEx/plugins/<Name>/`, or delete the `valheim-server` PVC to
force a clean reinstall — that PVC is disposable and does not hold the world.

### Per-mod configuration

Mod settings are declared in the `MOD_CONFIG` block of `mods-configmap.yaml`, not hand-edited on
the volume:

```
<cfg filename>|<Section>|<Key>|<Value>
```

Currently set: `Extra Inventory Rows = 5` (AzuEPI's maximum — 5 extra rows for everyone).

**The image's `BEPINEXCFG_<Section>_<Var>` env mechanism cannot do this.** It only ever writes
`BepInEx.cfg` — `env2cfg --config "$config_path/BepInEx.cfg"` in `common` — never per-mod files.
Without `MOD_CONFIG`, these settings exist only as untracked edits on the PVC.

The applier touches **only the keys listed**; everything else in a `.cfg` keeps whatever the mod
wrote. It handles a key already present, a key missing from an existing section, a missing
section, and a missing file — that last case matters because a mod that has never run has no
config yet, and BepInEx honours a partial file and fills in the rest on first load.

It runs on **every boot, so this file wins.** A value changed in-game or via a config manager is
reverted on the next restart. Change it here, not there.

Settings marked `[Synced with Server]` in a `.cfg` propagate to clients automatically — no client
action needed for those. Config filenames available to target:

```
Azumatt.AzuExtendedPlayerInventory.cfg    Azumatt.AzuContainerSizes.cfg
Searica.Valheim.SkilledCarryWeight.cfg    randyknapp.mods.epicloot.cfg
Therzie.Warfare.cfg                       advize.PlantEverything.cfg
```

Verify a setting landed and survived the mod's own save cycle:

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods | Select-String "\[cfg"
kubectl exec -n valheim deploy/valheim -c valheim -- grep -B2 "^Extra Inventory Rows" /config/bepinex/Azumatt.AzuExtendedPlayerInventory.cfg
```

### Confirm the mod stack is healthy

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods          # installer result
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "plugins to load|Loading \["
```

Expect `6 plugins to load`, a `Loading [...]` line per mod, and `Chainloader startup complete`
(BepInEx 5.4.23.3).

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
