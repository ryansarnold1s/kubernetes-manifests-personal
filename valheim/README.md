# Valheim Dedicated Server

LAN-only Valheim 1.0 server on the `k8` Talos cluster, on the
`indifferentbroccoli/valheim-server-docker` image.
Design: `../docs/superpowers/specs/2026-09-10-valheim-1.0-rebuild-design.md`.
The two 2026-07-26 specs describe the previous (lloesche-image) server and are history.

## Joining

**Start Game → Select Character → Join Game → Join IP →** `192.168.130.155:2456`

The server is never listed in the community browser (see `PUBLIC` in `configmap.yaml`).
World: `TreeFellMeAgain`. Password lives in the `valheim-secrets` Secret.
Crossplay is off: Steam clients only.

Every client needs BepInExPack and ValheimPlus 10.0.2, the same version as the server.
ValheimPlus runs here at its shipped defaults, which include `[Server] enforceMod=true`, so a
client without the same V+ version is refused. `serverSyncsConfig=true` is also a default, so
connecting clients receive the server's V+ config. Install Jotunn 2.30.0 on clients too, to
match the server. Versions and download links are in `mods-configmap.yaml`.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `valheim` |
| `configmap.yaml` | Every non-secret env var, with the why |
| `secret.yaml.template` | Template for the password Secret |
| `pvc.yaml` | `valheim-data` (`/valheim-saves`, the world), `valheim-server` (`/valheim`, game + BepInEx) |
| `deployment.yaml` | initContainer `fetch-mods` + game container |
| `service.yaml` | MetalLB LoadBalancer, UDP 2456-2457 |
| `mods-configmap.yaml` | Pinned BepInExPack + mod table, per-mod config pins, installer script |
| `recurringjob.yaml` | Longhorn daily snapshot (deploys to `longhorn-system`) |
| `tests/test-install-mods.sh` | Local bash harness for the installer; run before changing it |

`secret.yaml` is gitignored. Copy the template, set the password, apply.

## Applying

```powershell
cd valheim/                                   # relative paths from repo root silently no-op
Copy-Item secret.yaml.template secret.yaml    # first time only; then edit it
kubectl apply -f namespace.yaml -f configmap.yaml -f secret.yaml -f pvc.yaml -f mods-configmap.yaml -f deployment.yaml -f service.yaml -f recurringjob.yaml
```

Confirm every line says `created` or `configured`. `unchanged` means the wrong working
directory, not success, and a later `rollout status` will happily report the *previous*
rollout.

**Post-deploy, required, after any PVC (re)creation:** a new `valheim-data` volume starts
unlabeled and the RecurringJob will look healthy while producing zero snapshots:

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl label volumes.longhorn.io -n longhorn-system $pv "recurring-job-group.longhorn.io/valheim=enabled" --overwrite
```

Then confirm a snapshot actually appears (Backups below).

## How the image behaves

Read from its scripts, not its README. Each of these shaped a manifest comment.

- **Two volumes.** `/valheim` is the SteamCMD install dir and holds BepInEx too;
  `/valheim-saves` is `-savedir`, so the world is `/valheim-saves/worlds_local/`.
- **`PUBLIC` is dead code.** `start.sh` tests `PUBLIC_ENABLED`, which nothing sets. The
  server is always private.
- **BepInExPack is installed by *our* initContainer, not the image.** The image only installs
  it when `/valheim/BepInEx` is absent, and our plugins directory defeats that check on the
  first boot. The initContainer also writes `/valheim/.bepinex_version`; without that marker
  `start.sh` exports the legacy doorstop variable names and BepInEx silently never loads.
  `BEPINEX_ENABLED=true` is still required: it is what makes `start.sh` export the
  `LD_PRELOAD`/doorstop env at all.
- **The image's `MODS` variable stays unset.** Set, its downloader would wipe and re-fetch
  every mod unverified on every boot and flatten each zip into one directory. The downloader
  still *runs* every boot (`start.sh` calls `install_mods` whenever `BEPINEX_ENABLED=true`);
  with `MODS` unset all it does is recreate an empty `BepInEx/plugins/thunderstore/`. That
  directory is the image's: the installer's prune skips it and does not count it toward the
  breaker.
- **`MAX_PLAYERS` stays unset.** Any value other than 10 silently installs the image's
  bundled MaxPlayerCount mod.
- **The game runs as root.** `init.sh` requires `PUID`/`PGID`, usermods the steam user,
  `chown -R`s both volumes, then starts the game without dropping privileges. Accepted for a
  single-operator LAN server in a `baseline` namespace. Do not add `runAsUser`; it breaks
  the entrypoint.
- **No cron, no zips, no adminlist handling.** Backups are Valheim's native rolling set
  (`KEEP_BACKUPS` and friends), Longhorn, and CloudCasa. `adminlist.txt` is written by the
  initContainer from `ADMINLIST_IDS`.
- **Game updates are deliberate.** `UPDATE_ON_START=false`; SteamCMD only runs when the
  binary is absent. See Common tasks for the update procedure.
- **`NO_BUILD_COST=true` is `-setkey nobuildcost`**, a global key persisted into the world
  save. Removing the env does not remove the key; reversal is `removekey nobuildcost` in the
  admin F5 console, then a restart.

## Operating notes

- **Never lower `terminationGracePeriodSeconds` below 120.** The image sends SIGINT and
  waits; Valheim needs time to flush the world. The image's compose example says 30s and is
  wrong for anything but an empty world.
- **`strategy: Recreate` is required.** RollingUpdate deadlocks on the ReadWriteOnce volumes.
- **Startup and readiness probes only, deliberately no liveness probe.** A liveness probe
  would SIGKILL the server mid-save.
- **Never unbracket the probe pattern.** `pgrep -f` matches full command lines, so an
  unbracketed `pgrep -f valheim_server` matches the probe's own `sh -c` process and returns
  0 no matter what. `[v]alheim_server` matches the real process but not the literal shell
  argv. Verify any change against a name that does not exist, not just a healthy server:

  ```powershell
  # want: exit=1
  kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'pgrep -f "[Z]ZZNOSUCH" > /dev/null; echo exit=$?'
  ```

  Single-quoted outer string: PowerShell would eat `$?` inside double quotes. Testing an
  *unbracketed* candidate inline is not valid either: your own test command's argv contains
  the pattern, so it self-matches exactly the way the probe does. Write it to a script file
  in the container and run that instead.
- **No CPU limit, deliberately.** CFS throttling shows up in-game as rubber-banding.
- **No `nodeSelector`/`affinity`.** The three small nodes are control-plane and tainted, so
  the four identical workers are already the only candidates.
- **Requests are headroom, not usage.** 2 CPU / 5Gi requested. Measure under player load
  before tuning; an empty world idles far below this.
- **`externalTrafficPolicy: Local` + pod reschedule = brief outage** while MetalLB
  re-announces from the new node. Expected.
- **Never write the live server password into a tracked file**, not even as a grep pattern.
  Derive it from the Secret at runtime if needed.
- **A first boot on a fresh `valheim-server` PVC can crash-loop, and it heals itself.** On
  2026-09-10 SteamCMD failed five times with
  `ERROR! Failed to install app '896660' (Missing configuration)`, the image exited 1 each
  time, and the pod sat in `CrashLoopBackOff`; the sixth attempt, about 8 minutes in,
  installed the game into the same directory. It is a transient Steam-side/first-run error:
  two throwaway pods running the identical command into empty directories downloaded fine
  minutes later, and the failed attempts left nothing that blocked the successful one. Do
  not scale down, delete the PVC or edit manifests in response — that only resets the
  backoff. Watch `kubectl logs -n valheim deploy/valheim -c valheim --previous` and wait;
  investigate only if it persists past the 20-minute startup window. Once the binary exists,
  `UPDATE_ON_START=false` means later boots never run SteamCMD at all.

### Memory and world growth

An OOMKill is SIGKILL and bypasses the grace period, so the 8Gi memory limit is a
world-corruption risk, not just an availability one. No monitoring stack exists; check by
hand, and under player load, not idle:

```powershell
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$top = (kubectl top pod -n valheim --no-headers | Where-Object { $_ -match '\S' }) -join "`n"
if ($top -match '(\d+)m\s+(\d+)Mi') {
  $cpu = $matches[1]; $memMi = [int]$matches[2]
  Write-Output "memory : ${memMi}Mi of 8192Mi limit  ($([math]::Round($memMi/8192*100,1))%)"
  Write-Output "cpu    : ${cpu}m"
}
$zdo = ((kubectl logs -n valheim $p -c valheim --tail=600 | Select-String "ZDOS:") | Select-Object -Last 1) -replace '.*ZDOS:(\d+).*','$1'
$db  = kubectl exec -n valheim $p -c valheim -- stat -c %s /valheim-saves/worlds_local/TreeFellMeAgain.db
Write-Output "ZDOs   : $zdo"
Write-Output "world  : $([math]::Round($db/1MB,1)) MiB"
```

The `-join` and blank-line filter are load-bearing: kubectl returns a string array.

| Reading | Meaning |
|---|---|
| under ~5500Mi | fine |
| ~5500–6500Mi sustained | raise the limit; it is not a reservation |
| over ~6500Mi | raise it now, before a save lands on the ceiling |

The previous world reached 1.5M ZDOs / 72 MiB and a 3–4s save freeze in six weeks. The
freeze is `PrepareSave` cloning world state in memory on the main thread; faster storage
does not help, and raising `SAVE_INTERVAL` only trades crash-loss for comfort.

## Modding (BepInEx)

`mods-configmap.yaml` is the whole story: `MODS` is the pinned table (BepInExPack itself is
the first row), `MOD_CONFIG` is the per-mod config, and `install-mods.sh` applies both from
the `fetch-mods` initContainer on every boot.

- **Add or upgrade:** edit the row, apply, `rollout restart`. Get the checksum from the real
  download (command in the file's header comment). A **new** mod costs two applies: it
  writes its `.cfg` on first boot, and `MOD_CONFIG` cannot name a section that does not
  exist yet. Enumerate the generated file before pinning anything; upstream docs
  understate the key set and get types wrong.
- **Remove:** delete the row, apply, restart. The prune refuses more than 2 removals in one
  boot; a truncated `MODS` block looks exactly like a mass removal. Only mods that register
  no prefabs are free to remove.
- **Test the installer before changing it:** `bash valheim/tests/test-install-mods.sh` from
  the repo root. It runs the script from the ConfigMap against a temp directory with fake
  zips and exercises install, skip, checksum refusal, prune (including the image-owned
  `thunderstore` directory it must skip), the breaker, the config applier on a CRLF file,
  and the adminlist. `install-mods.sh` must stay the **last** key in the ConfigMap; the
  harness extracts it by "everything after the key line".
- **Recon a candidate mod inside the running container first**, per the repo `CLAUDE.md`:
  sha256, zip layout, config section names, kick behaviour
  (`RemoveDisconnectedPeerFromVerified`), prefab registration, Thunderstore `date_updated`.

### ValheimPlus

Runs with the pre-1.0 server's tuning, restored 2026-09-10: all 184 of the old pins, plus every
other key in those sections at its 10.0.2 default, 270 pins in `MOD_CONFIG`. Its config is
`/valheim/BepInEx/config/org.bepinex.plugins.valheim_plus.cfg`, an ordinary BepInEx file
(`Key = Value`, `# Setting type:` headers) that V+ 10 creates on its first boot.

**Never place a legacy `valheim_plus.cfg` beside it**, by hand or through a `MOD_CONFIG` line
(the applier creates any file a line names). That is the V+ ≤9.x INI file; V+ 10 treats one
found next to its BepInEx config as an override that wins on every launch, makes settings
read-only in-game, and logs a deprecation warning.

`MOD_CONFIG` pins every key of every enabled section. `[Fermenter]` is the sentinel: its restored
values (1200 s duration, 12 items, auto-deposit and auto-fuel on) all differ from V+ 10.0.2's
defaults, so reading them back proves the applier reached the file. `[Inventory]` and `[Wagon]`
stay off as before; the mods they used to collide with are gone, so enabling them is now a free
choice. One 1.0 behaviour change: `Building.noWeatherDamage` now covers rain only. Verify after any
restart by reading the file back, never by the absence of a log line (whether V+ 10 logs
`could not be parsed` for a rejected value is not yet verified):

```powershell
kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'sed -n "/^\[Fermenter\]/,/^\[/p" /valheim/BepInEx/config/org.bepinex.plugins.valheim_plus.cfg | grep -v "^#"'
```

To change a value: edit its line in `MOD_CONFIG`, apply, restart, read back. To turn on a section
that is off, enumerate it in the live file first and pin **every** key in it. Enabling a section
makes every key in it live.

### Confirm the mod stack is healthy

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "BepInEx\]|Jotunn|ValheimPlus|could not be parsed" | Select-Object -First 12
```

Expect `[skip ]` ×3 and `(0 to remove)` on a normal restart, the BepInEx banner, a load line
each for Jotunn and ValheimPlus, and **no** `could not be parsed`. That absence is not proof
for V+ pins: whether V+ 10 logs it for a rejected value is unverified, so V+ is verified by
reading the file back (above).

## Connections

Valheim logs `Connections N` every 10 min; `Got connection` / `Closing socket` are current.
When they disagree, trust the sockets. Re-check in the same action as any restart.

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --since=5m | Select-String "Got connection|Closing socket"
kubectl logs -n valheim deploy/valheim -c valheim --tail=600 | Select-String "Connections \d+" | Select-Object -Last 1
```

## Backups

1. **In-app:** Valheim's rolling auto-backups in `/valheim-saves/worlds_local/`
   (`<world>_backup_auto-<stamp>.db/.fwl`): one at 2h, then three 12h apart.
   `kubectl exec -n valheim deploy/valheim -c valheim -- ls -la /valheim-saves/worlds_local`
2. **Longhorn snapshots:** `valheim-daily-snapshot`, cron `0 11 * * *` (UTC; Longhorn ignores
   the container `TZ`; 04:00 Arizona year-round), retain 7, on `valheim-data` only. Bound by
   a label on the Longhorn **Volume**, so a recreated PVC needs the label step under Applying.

   ```powershell
   $pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
   kubectl get snapshots.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
     ForEach-Object { $_.items } | Where-Object { $_.spec.volume -eq $pv } |
     ForEach-Object { $_.metadata.name }
   ```

   Expect names like `valheim--<uuid>`, up to 7, rotating. To take one on demand, apply a
   `snapshots.longhorn.io` CR with `spec.volume: <pv-name>` and `spec.createSnapshot: true`.
3. **Off-cluster:** CloudCasa (`cloudcasa-io`). It deletes its CRs after each run, so an empty
   `kubectl get backups.cloudcasa.io` proves nothing. Confirm in the console that a policy
   covers the `valheim` namespace **and** captures PVC data, not just manifests.

## Restore

**In-app auto-backup.** The world PVC is ReadWriteOnce, so the server pod must be fully gone
before a helper can mount it:

```powershell
kubectl scale deploy/valheim -n valheim --replicas=0
kubectl wait --for=delete pod -n valheim -l app=valheim --timeout=180s
kubectl run valheim-restore-helper -n valheim --image=busybox --restart=Never --overrides='{
  "apiVersion": "v1",
  "spec": {
    "containers": [{
      "name": "restore-helper", "image": "busybox",
      "command": ["sh", "-c", "cd /saves/worlds_local && cp TreeFellMeAgain_backup_auto-<stamp>.db TreeFellMeAgain.db && cp TreeFellMeAgain_backup_auto-<stamp>.fwl TreeFellMeAgain.fwl && ls -la && sleep 600"],
      "volumeMounts": [{ "name": "data", "mountPath": "/saves" }]
    }],
    "volumes": [{ "name": "data", "persistentVolumeClaim": { "claimName": "valheim-data" } }]
  }
}'
kubectl logs -n valheim valheim-restore-helper
kubectl delete pod -n valheim valheim-restore-helper
kubectl get pod -n valheim valheim-restore-helper     # expect NotFound before the next line
kubectl scale deploy/valheim -n valheim --replicas=1
```

**Longhorn snapshot.** Scale to 0, wait for the Volume to show `Detached`, revert from the
Longhorn UI (Volume → Snapshots → Revert), scale back to 1.

**Pull the world off the volume** (pod must be running; `kubectl cp` goes through it):

```powershell
kubectl cp valheim/$(kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'):/valheim-saves/worlds_local ./worlds_local-backup -c valheim
```

## Access control

Private-only hides the server from the browser; it is not access control. Anything that can
route to `192.168.130.155:2456` with the password can join. NetworkPolicy cannot help
(Flannel). For a real allowlist use `spec.loadBalancerSourceRanges` in `service.yaml`, and
list any VPN subnet explicitly.

## Common tasks

Add admins: edit `ADMINLIST_IDS` in `configmap.yaml`, then

```powershell
kubectl apply -f configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
```

Update the game to a new Valheim release, deliberately:

1. Check each row of `MODS` on Thunderstore for a release after the game patch.
2. Set `UPDATE_ON_START: "true"` in `configmap.yaml`, apply, `rollout restart`, watch the
   game log for the new `Valheim version:` line and the mod load lines.
3. Set it back to `"false"`, apply. (The next restart is then a normal one.)

Stop without deleting anything: `kubectl scale deploy/valheim -n valheim --replicas=0`.
Follow logs: `kubectl logs -n valheim deploy/valheim -c valheim --follow`.

## Rollback

Remove the workload, keep the world: `kubectl delete -f deployment.yaml -f service.yaml`.
Both PVCs stay bound. Re-apply to restore service.

Tear down completely — **this destroys the world**:

```powershell
kubectl delete -f deployment.yaml -f service.yaml -f recurringjob.yaml
kubectl delete -f pvc.yaml   # DESTRUCTIVE: storageClass longhorn has reclaimPolicy Delete
kubectl delete -f namespace.yaml
```
