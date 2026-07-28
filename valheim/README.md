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
- **No `nodeSelector`, `affinity` or `priorityClassName` — and none is needed.** The cluster looks
  heterogeneous (four nodes at ~8 CPU / 23Gi, three at ~4 CPU / 7.1Gi), but the three small ones
  are control-plane and carry `node-role.kubernetes.io/control-plane=:NoSchedule`. This pod has
  only the two default `NoExecute` tolerations, so its eligible set is the four workers, which are
  identical. **Adding a `nodeAffinity` toward the large nodes would be a no-op** — the taint
  already enforces it. It would only become necessary if a small node were ever untainted, or if
  workers of differing size were added.
- **Requests are well above observed usage** — 2 CPU / 5Gi requested against ~44m CPU / ~1.3Gi
  observed at idle. Deliberate headroom for world simulation under player load, but it is a real
  reservation: a quarter of an 8-core worker is held whether or not anyone is playing.
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

`BEPINEX: "true"` is set in `configmap.yaml`. **Twelve mods are installed**, fetched declaratively
by the `fetch-mods` initContainer from `mods-configmap.yaml`:

| Mod | Version | Client install |
|---|---|---|
| Jotunn | 2.29.2 | required (framework) |
| JsonDotNET | 13.0.4 | required (library) |
| EpicLoot | 0.12.15 | **required** |
| AzuExtendedPlayerInventory | 2.4.1 | **required — kicks clients without it** |
| AzuContainerSizes | 1.1.4 | **required — kicks clients without it** |
| ValheimPlus (Grantapher fork) | 9.17.1 | **required — `enforceMod = true`** |
| Warfare | 1.8.9 | **required** (custom weapon/animation assets) |
| Armory | 1.3.1 | **required** (custom assets; depends on Warfare 1.8.9) |
| OdinsFoodBarrels | 1.2.3 | **required** — *"required on both server and client for config sync"* |
| XPortal | 1.2.24 | **required** — *"All players must run the same version"* |
| SkilledCarryWeight | 1.4.1 | recommended (server install enforces config) |
| PlantEverything | 1.20.0 | recommended (works without, minor cosmetic loss) |

**`TrashItems` is deliberately not installed server-side.** It is a client-side inventory-UI mod
with no server role. Install it per-client if wanted, but test it: AzuExtendedPlayerInventory
redraws the same inventory screen, and TrashItems pins `BepInExPack 5.4.800` and was last updated
2024-01, so it predates AzuEPI's current version by roughly two years. If the inventory UI
misbehaves, suspect it first.

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

### ValheimPlus

Installed as an **ordinary BepInEx plugin via the initContainer** — its only dependency is
`denikson-BepInExPack_Valheim-5.4.2333`, exactly the pack this server runs.

🚨 **Do NOT set `VALHEIM_PLUS=true` in `configmap.yaml`.** The image branches
`if [ "$VALHEIM_PLUS" = true ]; then ... elif [ "$BEPINEX" = true ]; then` — an if/elif, so
`VALHEIM_PLUS` wins and the `BEPINEX` branch never runs. Every other mod lives in the BepInEx
install path and would be silently bypassed. That is what "mutually exclusive" means here; it is
a statement about the image's two install *modes*, not about V+ being incompatible with BepInEx.

V+ ships with every gameplay section `enabled=false` — only `[ValheimPlus]` and `[Server]` are on,
and both are meta. So it is inert until you enable something. Three sections are **pinned off** in
`MOD_CONFIG` because they would fight the mods above:

| Pinned off | Collides with |
|---|---|
| `[Inventory]` | AzuEPI (`playerInventoryRows`) and AzuContainerSizes (every chest/cart/boat row+column) |
| `[Player]` | SkilledCarryWeight (`baseMaximumWeight`, `baseMegingjordBuff`) |
| `[Wagon]` | SkilledCarryWeight's cart-mass reduction (`wagonBaseMass`, `wagonExtraMassFromItems`) |

**24 sections are enabled** for gameplay tuning: Stamina, StaminaUsage, Food, Map, Time,
FireSource, Turret, Armor, Items, Building, StructuralIntegrity, CraftFromChest, Workbench, and
every production station (Smelter, Furnace, Kiln, Fermenter, Beehive, Windmill, SpinningWheel,
EitrRefinery, Oven, SapCollector). See `MOD_CONFIG` for the exact values.

🚨 **Three V+ settings read backwards from their names.** Verified against the comments in the
generated config — getting any of them wrong silently produces the *opposite* effect:

| Setting | Trap |
|---|---|
| `productionSpeed` | **Seconds per item, not a percentage.** "Twice as fast" means *halving* it. Setting 30 → 60 makes smelters twice as **slow**. |
| `baseItemWeightReduction` | **Reduces on negative** despite the name: *"-50 will reduce item weight by 50%, 50 will increase."* |
| `nightPercent` | **Absolute, not a modifier:** *"0 is all daytime, 100 is all nighttime."* Not a percent change. Set to **10** — with `totalDayTimeInSeconds = 1800` that is 3 min of night per cycle, down from 9 at the default 30. Deliberately not 0, so night mobs, light sources and sleeping still matter. |

**Two requested settings were deliberately NOT applied** — `autoEquipShield` and `autoRepair` both
live in `[Player]`, which is pinned off because `baseMaximumWeight` there collides with
SkilledCarryWeight. Enabling `[Player]` to get them would put V+ and SkilledCarryWeight on the same
carry-weight property with unknown patch ordering. See "If you want the `[Player]` features" below.

Two knock-on effects worth knowing, neither a collision:

- `[Items] baseItemWeightReduction = -75` compounds with SkilledCarryWeight — lighter items *and*
  a higher cap.
- `[Armor]` is **+50%, scaled back from +100%**, because it multiplies on top of two other sources:
  Armory's upgraded biome-tier armor variants and EpicLoot's enchanted gear. V+'s own example is
  base armor 14 → 21 at +50%, → 28 at +100%, before either of those applies.

### If you want the `[Player]` features

`autoRepair` and `autoEquipShield` require `[Player] enabled = true`. That section also carries
`baseMaximumWeight` (300) and `baseMegingjordBuff` (150). Both are already the vanilla values, so
enabling the section *should* be neutral and let SkilledCarryWeight keep adding on top — but V+ and
SkilledCarryWeight would then both patch max carry weight, and which wins depends on Harmony patch
order, which is not documented by either mod.

If you try it, change only `valheim_plus.cfg|Player|enabled|true` in `MOD_CONFIG` and **verify
in-game that carry weight still scales with skill levels** before trusting it. Revert by setting it
back to `false` — the pin is reapplied every boot, so nothing is stuck.

**V+ owns `valheim_plus.cfg` and rewrites it on every load** — it normalises line endings to LF,
reformats `enabled=false` into `enabled = false`, and prepends a UTF-8 BOM. That is fine and
expected; the applier reads whatever V+ last wrote and reapplies the pins before the next load.

`[Server]` defaults to `enforceMod = true` and `serverSyncsConfig = true`. The first makes V+ a
mandatory client install; the second is actually useful — the server pushes its config to clients,
so nobody can locally re-enable `[Inventory]` and desync. `maxPlayers = 10` there now governs the
player cap.

### Per-mod configuration

Mod settings are declared in the `MOD_CONFIG` block of `mods-configmap.yaml`, not hand-edited on
the volume:

```
<cfg filename>|<Section>|<Key>|<Value>
```

Currently set — `Extra Inventory Rows = 5` (AzuEPI's maximum), plus containers at roughly 2x
vanilla:

| Container | Vanilla | Now | Slots |
|---|---|---|---|
| Personal Chest | 2x3 | 4x4 | 6 → 16 |
| Wood Chest | 2x5 | 4x6 | 10 → 24 |
| Iron Chest | 4x6 | 6x8 | 24 → 48 |
| Blackmetal Chest | 4x8 | 8x8 | 32 → 64 |
| Cart | 3x6 | 5x8 | 18 → 40 |
| Karve | 2x2 | 4x4 | 4 → 16 |
| Longboat | 3x6 | 5x8 | 18 → 40 |

Headroom remains: columns cap at 8 everywhere, rows go to 20 (chests) and 30 (carts/ships).

⚠️ **Only ever grow a container.** Every AzuContainerSizes default is also its range minimum, so
the values above are all increases. Shrinking a container that already holds items leaves those
items in slots that no longer exist — take a Longhorn snapshot before reducing one.

**Carry weight** — all 24 skills contribute at `Coefficient 0.5` (default was 0.25 across only 7).
The formula is `extra = Σ(Coefficient × level^Power)` with `Power` left at 1, so it stays linear.
Base carry weight is 300, so an average level 50 across skills is roughly +550. `[None]` is
excluded — it is the enum's null entry, not a skill. Some entries (Cooking, Crafting, Farming,
Dodge) may never gain XP in vanilla; they sit at level 0 and contribute nothing, so enabling
them is free.

🚨 **Zero-width characters are load-bearing in `SkilledCarryWeight.cfg`.** Searica prefixes keys
and sections with U+200B (`E2 80 8B`) to force sort order in the config manager. The real key is
`<ZWSP>Enabled`, not `Enabled`, and the first three sections are `[<ZWSP><ZWSP><ZWSP>Global]`,
`[<ZWSP><ZWSP>Cart Mass]`, `[<ZWSP>Quick Cart]` — while `Coefficient`, `Power` and the skill
sections are plain. A literal match therefore fails, and the applier would append a **second,
plain `Enabled` line that the mod ignores while reporting success.**

The applier's `norm()` strips zero-width characters before comparing and preserves the original
key text on write, so `MOD_CONFIG` can use plain `Enabled`. **Do not remove those `norm()` calls
as dead weight.** The proof it matched rather than appended is the key count: 83 before, 83
after, across 48 edits. If you ever suspect a silent no-op, that count is the check:

**The applier normalises four things that would each cause a silent no-op**, all found the hard
way against real mod configs — every one would have appended a duplicate while logging success:

| Quirk | Seen in | Handling |
|---|---|---|
| U+200B zero-width space in keys/sections | SkilledCarryWeight | stripped before compare, preserved on write |
| UTF-8 BOM at file start | ValheimPlus | stripped before compare |
| CRLF line endings | ValheimPlus | stripped before compare, `\r` re-appended on write |
| `key=value` vs `Key = Value` spacing | V+ vs BepInEx | detected per line, original style reproduced |

The integrity check that catches all four is the same: **section and key counts must be unchanged**
across an apply. A duplicate appended section or key is the signature of a failed match.

```powershell
kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'C=/config/bepinex/Searica.Valheim.SkilledCarryWeight.cfg; echo "keys=$(grep -c = $C) true=$(grep -c "Enabled = true" $C)"'
```

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
writes, not against loss of the volume.

**Off-cluster DR: CloudCasa.** The agent is deployed in `cloudcasa-io` and verified active — it
exchanges `BACKUP` / `OFFLOAD` / `DELETE_BACKUP` messages with the service, and its logs show real
backup data in object storage plus retention deletions running. This supersedes the earlier
"off-cluster DR is not configured" note.

⚠️ **Coverage of this namespace is NOT verifiable from inside the cluster.** CloudCasa keeps policy
and run history server-side and deletes its CRs after each run, so `kubectl get backups.cloudcasa.io`
returns nothing even while backups are working — an empty result there proves nothing either way.
Confirm in the CloudCasa console:

1. **A policy includes the `valheim` namespace.** The namespace was created 2026-07-26; a policy
   that enumerates namespaces explicitly rather than "all namespaces" predates it and will not
   cover it. Same failure shape as the `wger` snapshot label above — a healthy-looking backup
   system that silently excludes this workload.
2. **It has run successfully since 2026-07-26.**
3. **It captures PVC data, not just resource manifests.** A namespace backup that only stores YAML
   would restore a Deployment and an empty PVC. The world is volume data on `valheim-data`.

The mod stack adds ~250MB to that same PVC, so the volume now holds more than just the world.

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
