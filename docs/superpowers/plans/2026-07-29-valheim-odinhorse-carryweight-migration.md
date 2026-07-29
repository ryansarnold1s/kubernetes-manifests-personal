# OdinHorse Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install OdinHorse 1.6.5 on the Valheim server, remove the incompatible
SkilledCarryWeight mod, and reimplement its carry-weight bonus in ValheimPlus.

**Architecture:** Three sequential applies against a live Kubernetes workload. Task 1
makes mod removal declarative and proves it deletes nothing when it should delete
nothing. Task 2 uses that prune to remove SkilledCarryWeight and ports carry weight to
ValheimPlus. Task 3 adds OdinHorse. The ordering is deliberate: OdinHorse never
coexists with SkilledCarryWeight, so the conflict never has a window to occur.

**Tech Stack:** Kubernetes (Talos), Longhorn storage, `lloesche/valheim-server` image,
BepInEx, bash (initContainer), PowerShell + kubectl (operator side).

**Spec:** `docs/superpowers/specs/2026-07-29-valheim-odinhorse-carryweight-migration-design.md`

## Global Constraints

- `$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"` — required for every kubectl call
- **`cd valheim/` before applying.** Relative paths from the repo root silently no-op
- `kubectl apply` must report **`configured`**, never `unchanged`. `unchanged` is a silent failure, usually the wrong cwd
- Every apply restarts a single-replica `strategy: Recreate` workload — **a brief outage. Confirm nobody is connected first**
- Multi-line shell delivered to containers **must be base64-encoded**. Quoting does not survive PowerShell → kubectl exec → sh
- kubectl output is a **string array** — `-join "\`n"` before treating as text; `.Length` is line count, not characters
- After editing a config file in place, **re-read it and confirm section/key counts are unchanged**. An appended duplicate is the signature of a failed match
- **Verify the negative case.** A check only ever observed passing has not been verified
- Commits go directly to `main`; no PR flow
- Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it. Keep that style

**Pinned artifact facts** (captured 2026-07-29, checksum reproducible across two independent downloads):

| Field | Value |
|---|---|
| OdinHorse version | `1.6.5` |
| URL | `https://thunderstore.io/package/download/OdinPlus/OdinHorse/1.6.5/` |
| sha256 | `23a455aa79c074f2098107ea9f09f044460442d152732d928f511a16023209bc` |
| layout | `root` |

---

## Pre-flight (do this once, before Task 1)

- [ ] **Step 1: Confirm nobody is connected**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
(kubectl logs -n valheim deploy/valheim --tail=200 | Select-String "Got connection|Closing socket") -join "`n"
```

Every apply in this plan is an outage. Do not proceed while players are online.

- [ ] **Step 2: Take a manual Longhorn snapshot**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
kubectl get volumes.longhorn.io $pv -n longhorn-system -o jsonpath='{.metadata.labels}'
```

Expected: the output contains `"recurring-job-group.longhorn.io/valheim":"enabled"`. If it does
not, **stop** — the world is not being snapshotted and that must be fixed first (see
`valheim/README.md`, Applying / Backups).

Then take the point-in-time snapshot through the Longhorn UI against volume `$pv`. The daily
job is a floor, not a substitute for one taken against the exact pre-change state.

- [ ] **Step 3: Record the baseline**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n valheim $p -c valheim -- ls -1 /config/bepinex/plugins
kubectl exec -n valheim $p -c valheim -- ls -1 /opt/valheim/bepinex/BepInEx/plugins
```

Expected: **12 names in each**, identical lists —
`Armory AzuContainerSizes AzuExtendedPlayerInventory EpicLoot Jotunn JsonDotNET
OdinsFoodBarrels PlantEverything SkilledCarryWeight ValheimPlus Warfare XPortal`

---

## Task 1: Declarative mod prune

Makes mod removal a one-step operation. Ships with `MODS` **unchanged**, so its first
production run must delete nothing — that is the negative case, and it is proved before any
real mod is removed.

**Files:**
- Modify: `valheim/mods-configmap.yaml` (header comment; `install-mods.sh` key)
- Modify: `valheim/deployment.yaml` (initContainer `volumeMounts`)
- Modify: `valheim/README.md` ("Adding, upgrading, removing" section)

**Interfaces:**
- Consumes: `$MODS`, `$PLUGINS`, `$STATE` — already defined in `install-mods.sh`
- Produces: `prune_dir <root> <label>` shell function and `$keep` (newline-separated mod names) and `$LIVE_PLUGINS`, used by nothing outside this script

- [ ] **Step 1: Mount the server PVC in the initContainer**

In `valheim/deployment.yaml`, find the `fetch-mods` initContainer's `volumeMounts` block:

```yaml
        volumeMounts:
        - name: config
          mountPath: /config
        - name: mod-scripts
          mountPath: /scripts
          readOnly: true
```

Replace with:

```yaml
        volumeMounts:
        - name: config
          mountPath: /config
        # The prune in install-mods.sh has to reach the LIVE install, not just the staged copy.
        # The image's bootstrap sync is `rsync -a` with no --delete, so a mod removed only from
        # /config/bepinex/plugins survives here and keeps running. Both PVCs are ReadWriteOnce,
        # but this is the same pod that already mounts both, and strategy: Recreate guarantees
        # there is never a second pod contending for them.
        - name: server
          mountPath: /opt/valheim
        - name: mod-scripts
          mountPath: /scripts
          readOnly: true
```

- [ ] **Step 2: Add the prune to `install-mods.sh`**

In `valheim/mods-configmap.yaml`, find the end of the install loop and the start of the
config loop:

```bash
    echo "=== valheim mod installer ==="
    while read -r name ver url sha layout; do
      [ -z "${name:-}" ] && continue
      case "$name" in \#*) continue ;; esac
      install_one "$name" "$ver" "$url" "$sha" "$layout"
    done <<< "$MODS"

    echo "=== applying per-mod config ==="
```

Insert the prune between them, so the block reads:

```bash
    echo "=== valheim mod installer ==="
    while read -r name ver url sha layout; do
      [ -z "${name:-}" ] && continue
      case "$name" in \#*) continue ;; esac
      install_one "$name" "$ver" "$url" "$sha" "$layout"
    done <<< "$MODS"

    # --- prune: mods no longer listed in MODS --------------------------------------------
    # Deleting a line from MODS used to be insufficient. The staged copy survived here, and the
    # image's bootstrap sync is `rsync -a` with NO --delete, so the stale DLL also survived in
    # the live install -- a "removed" mod kept running. Both copies are pruned here, which is
    # what makes removal declarative.
    #
    # ⚠️ $PLUGINS is on valheim-data, the SAME Longhorn volume as /config/worlds_local. Every rm
    # below uses ${VAR:?}, so an unset or empty path aborts the script instead of expanding to a
    # bare root path. Do NOT rewrite these as plain "$VAR" -- that is the one bug in this file
    # that could reach the world save.
    LIVE_PLUGINS=/opt/valheim/bepinex/BepInEx/plugins

    keep=$(while read -r name _rest; do
             [ -z "${name:-}" ] && continue
             case "$name" in \#*) continue ;; esac
             printf '%s\n' "$name"
           done <<< "$MODS")

    # A malformed or truncated MODS must never be read as "delete everything".
    if [ -z "$keep" ]; then
      echo "[FAIL ] MODS parsed to an empty set -- refusing to prune" >&2
      exit 1
    fi

    prune_dir() {
      local root=$1 label=$2 d n
      if [ ! -d "$root" ]; then
        echo "[prune] $label: $root absent, nothing to do"
        return 0
      fi
      for d in "$root"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        if ! printf '%s\n' "$keep" | grep -qxF "$n"; then
          echo "[prune] $label: removing $n (not in MODS)"
          rm -rf "${root:?}/${n:?}"
        fi
      done
    }

    echo "=== pruning mods no longer in MODS ==="
    prune_dir "$PLUGINS"      "staged"
    prune_dir "$LIVE_PLUGINS" "live"

    # Orphaned install markers go too, so re-adding a mod later reinstalls it cleanly instead of
    # being skipped by a stale version+sha marker.
    for m in "$STATE"/*; do
      [ -f "$m" ] || continue
      n=$(basename "$m")
      if ! printf '%s\n' "$keep" | grep -qxF "$n"; then
        echo "[prune] marker: removing $n"
        rm -f "${STATE:?}/${n:?}"
      fi
    done

    echo "=== applying per-mod config ==="
```

Note `grep -qxF`: `-x` matches the whole line, `-F` treats the name as a fixed string rather
than a regex.

- [ ] **Step 3: Rewrite the `REMOVING A MOD` header comment**

Near the top of `valheim/mods-configmap.yaml`, replace:

```
# REMOVING A MOD: deleting a line here is NOT sufficient. The image syncs with `rsync -a` and no
# --delete, so the stale DLL survives in the live install at /opt/valheim/bepinex/BepInEx/plugins.
# Also delete that directory, or delete the valheim-server PVC to force a clean reinstall (that
# PVC is disposable -- it does not hold the world).
```

with:

```
# REMOVING A MOD: delete the line, apply, restart. The installer prunes any plugin directory not
# listed in MODS from BOTH the staged copy here and the live install at
# /opt/valheim/bepinex/BepInEx/plugins, and drops its .mod-state marker. This used to require a
# manual rm -rf in two places, because the image syncs with `rsync -a` and no --delete.
#
# Deleting the valheim-server PVC does NOT remove a mod, despite being the disposable one -- the
# staged copy here survives and the bootstrap rsync restores it.
#
# ⚠️ The prune handles FILES, not world data. A mod that registered prefabs -- EpicLoot, Warfare,
# Armory, OdinsFoodBarrels, OdinHorse -- has its items or creatures persisted as ZDOs in the world
# save, and dropping it orphans them. Only pure runtime-patch mods are free to remove.
```

- [ ] **Step 4: Test the empty-set guard before deploying it**

This tests the exact expression from Step 2 against an empty `MODS`, without touching any real
directory.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$script = @'
MODS=""
keep=$(while read -r name _rest; do
         [ -z "${name:-}" ] && continue
         case "$name" in \#*) continue ;; esac
         printf '%s\n' "$name"
       done <<< "$MODS")
if [ -z "$keep" ]; then echo "GUARD FIRES (correct)"; else echo "GUARD FAILED -- keep=[$keep]"; fi

MODS="Jotunn 1.0 http://x aaa root"
keep=$(while read -r name _rest; do
         [ -z "${name:-}" ] && continue
         case "$name" in \#*) continue ;; esac
         printf '%s\n' "$name"
       done <<< "$MODS")
if [ -z "$keep" ]; then echo "FALSE POSITIVE -- guard fired on a valid set"; else echo "VALID SET PARSES (correct): $keep"; fi
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
kubectl exec -n valheim $p -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected, both lines:
```
GUARD FIRES (correct)
VALID SET PARSES (correct): Jotunn
```

If the second line reads `FALSE POSITIVE`, the guard would block every legitimate boot. Do not
deploy.

- [ ] **Step 5: Plant a synthetic directory to prove the prune deletes**

`ZZZ-prune-test` is not in `MODS`, so the prune must remove it. Planted in both plugin
directories plus a marker.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$script = @'
mkdir -p /config/bepinex/plugins/ZZZ-prune-test
mkdir -p /opt/valheim/bepinex/BepInEx/plugins/ZZZ-prune-test
echo canary > /config/bepinex/plugins/ZZZ-prune-test/canary.txt
echo canary > /opt/valheim/bepinex/BepInEx/plugins/ZZZ-prune-test/canary.txt
echo "1.0.0 deadbeef" > /config/bepinex/.mod-state/ZZZ-prune-test
echo "planted:"
ls -d /config/bepinex/plugins/ZZZ-prune-test /opt/valheim/bepinex/BepInEx/plugins/ZZZ-prune-test /config/bepinex/.mod-state/ZZZ-prune-test
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
kubectl exec -n valheim $p -c valheim -- sh -c "echo $b64 | base64 -d | sh"
```

Expected: all three paths listed.

- [ ] **Step 6: Validate, apply, and wait for the single rollout**

⚠️ **Do NOT add `kubectl rollout restart` to this step.** Unlike Tasks 2 and 3, this task
changes `deployment.yaml`, which alters the pod template — so the apply *already* triggers a
rollout. An explicit restart on top would start a **second** `Recreate` cycle and race the
first. With `terminationGracePeriodSeconds: 120` that roughly doubles the outage for no gain.

Apply the ConfigMap **first** so the rollout the Deployment triggers already picks up the new
`install-mods.sh`:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
cd valheim
kubectl apply -f mods-configmap.yaml --dry-run=server
kubectl apply -f deployment.yaml --dry-run=server
kubectl apply -f mods-configmap.yaml
kubectl apply -f deployment.yaml
kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Expected: `configmap/valheim-mods configured`, then `deployment.apps/valheim configured`, then
a successful rollout. **If either apply says `unchanged`, stop** — you are in the wrong
directory or the edit did not save.

- [ ] **Step 7: Confirm exactly one rollout occurred**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
kubectl get rs -n valheim -l app=valheim --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,CREATED:.metadata.creationTimestamp
```

Expected: exactly one ReplicaSet with `DESIRED=1`, and only **one** new ReplicaSet created
during this task. Two new ones means a double restart happened — worth knowing, though not
itself a failure.

- [ ] **Step 8: Verify the positive case — the synthetic dir is gone**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
(kubectl logs -n valheim $p -c fetch-mods | Select-String "prune") -join "`n"
```

Expected: three lines naming `ZZZ-prune-test` —
```
[prune] staged: removing ZZZ-prune-test (not in MODS)
[prune] live: removing ZZZ-prune-test (not in MODS)
[prune] marker: removing ZZZ-prune-test
```

Then confirm the files are actually gone:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n valheim $p -c valheim -- sh -c 'ls -d /config/bepinex/plugins/ZZZ-prune-test /opt/valheim/bepinex/BepInEx/plugins/ZZZ-prune-test /config/bepinex/.mod-state/ZZZ-prune-test 2>&1 || true'
```

Expected: `No such file or directory` for all three.

- [ ] **Step 9: Verify the negative case — all 12 real mods survived**

This is the check that matters. A prune only ever observed deleting has not been verified.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$staged = kubectl exec -n valheim $p -c valheim -- ls -1 /config/bepinex/plugins
$live   = kubectl exec -n valheim $p -c valheim -- ls -1 /opt/valheim/bepinex/BepInEx/plugins
$marks  = kubectl exec -n valheim $p -c valheim -- ls -1 /config/bepinex/.mod-state
"staged=$($staged.Count) live=$($live.Count) markers=$($marks.Count)"
Compare-Object $staged $live
```

Expected: `staged=12 live=12 markers=12`, and `Compare-Object` returns **nothing** (identical
lists). Confirm the 12 names match the Pre-flight Step 3 baseline exactly.

- [ ] **Step 10: Confirm the world is untouched**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n valheim $p -c valheim -- ls -la /config/worlds_local
```

Expected: `TreeFellMeFirst.db` present, ~5.2 MB, alongside its `.fwl` and the auto-backups.

- [ ] **Step 11: Update the README removal section**

In `valheim/README.md`, replace:

```markdown
⚠️ **Removing a mod needs a second step.** Deleting its line stops it being fetched, but the
image syncs with `rsync -a` and **no `--delete`**, so the stale DLL survives in the live install.
Also delete `/opt/valheim/bepinex/BepInEx/plugins/<Name>/`, or delete the `valheim-server` PVC to
force a clean reinstall — that PVC is disposable and does not hold the world.
```

with:

```markdown
**Removing a mod is a single step.** Delete its line from `MODS`, apply, restart. The
initContainer prunes any plugin directory not listed in `MODS` from **both** the staged copy on
`valheim-data` and the live install on `valheim-server`, and drops its `.mod-state` marker. This
used to need a manual `rm -rf` in two places, because the image syncs with `rsync -a` and **no
`--delete`**.

⚠️ **Deleting the `valheim-server` PVC does not remove a mod**, despite being the disposable one.
The staged copy on `valheim-data` survives and the bootstrap rsync restores it. That PVC also
holds `bepinex/BepInEx/vplus-data/<World>_mapSync.dat`, the V+ shared-map pool — disposable with
respect to the world is not the same as lossless.

🚨 **The prune handles files, not world data.** A mod that registered prefabs — EpicLoot,
Warfare, Armory, OdinsFoodBarrels, OdinHorse — has its items or creatures persisted as ZDOs in
`TreeFellMeFirst.db`, and dropping it orphans them. Only pure runtime-patch mods are free to
remove.
```

- [ ] **Step 12: Commit**

```bash
git add valheim/mods-configmap.yaml valheim/deployment.yaml valheim/README.md
git commit -m "Make mod removal declarative with a prune in install-mods.sh

Deleting a line from MODS was never sufficient: the staged copy survived on
valheim-data and the image's bootstrap sync is rsync -a with no --delete, so
the stale DLL survived in the live install and kept running. The initContainer
now prunes any plugin dir not in MODS from both locations, plus its marker.

Mounts the server PVC in fetch-mods so the prune can reach the live install.

Every rm uses \${VAR:?}: \$PLUGINS is on valheim-data, the same Longhorn volume
as /config/worlds_local, so an unset path variable is the one bug here that
could reach the world save. An empty MODS aborts rather than pruning.

Verified both directions on the live cluster: a planted ZZZ-prune-test dir was
removed from both plugin dirs and .mod-state, while all 12 real mods survived
untouched and the two dir listings stayed identical."
```

---

## Task 2: Remove SkilledCarryWeight, port carry weight to ValheimPlus

Uses the Task 1 prune against a real mod. SkilledCarryWeight is a pure runtime Harmony patch —
it registers no prefabs and persists nothing in the world save — which is what makes it safe to
remove. **This does not generalise to the other mods.**

**Files:**
- Modify: `valheim/mods-configmap.yaml` (`MODS`, `MOD_CONFIG`, `install-mods.sh` comment)
- Modify: `valheim/README.md` (mod table, V+ pin table, `[Player]` sections, quirks table, cfg list)

**Interfaces:**
- Consumes: the `prune_dir` / `$keep` machinery from Task 1
- Produces: `[Player]` enabled in `valheim_plus.cfg` with `baseMaximumWeight=850`,
  `baseMegingjordBuff=150`, `autoRepair=true`, `autoEquipShield=true`

- [ ] **Step 1: Remove the SkilledCarryWeight line from `MODS`**

Delete this line from `valheim/mods-configmap.yaml`:

```
    SkilledCarryWeight         1.4.1    https://thunderstore.io/package/download/Searica/SkilledCarryWeight/1.4.1/                  efdd59934335b3170f34c5efbd24c78a269a53325c253163ddbb15adf2c3ce55  root
```

- [ ] **Step 2: Delete the SkilledCarryWeight `MOD_CONFIG` block**

Delete the comment block and all 48 setting lines — everything from the bare `    #` separator
that follows `Azumatt.AzuContainerSizes.cfg|4 - Carts|Cart Columns|8` through
`Searica.Valheim.SkilledCarryWeight.cfg|WoodCutting|Coefficient|0.5`.

That is the comment beginning `# SkilledCarryWeight: every skill contributes, Coefficient 0.5`
plus one `Enabled` and one `Coefficient` line for each of 24 skills (Axes, Blocking, BloodMagic,
Bows, Clubs, Cooking, Crafting, Crossbows, Dodge, ElementalMagic, Farming, Fishing, Jump, Knives,
Pickaxes, Polearms, Ride, Run, Sneak, Spears, Swim, Swords, Unarmed, WoodCutting).

Leave the `Azumatt.AzuContainerSizes.cfg|4 - Carts|Cart Columns|8` line and the following
`    #` that opens the ValheimPlus block.

**After this edit, verify no `Searica` string remains in the file:**

```bash
grep -c "Searica" valheim/mods-configmap.yaml
```

Expected: `0`

- [ ] **Step 3: Rewrite the ValheimPlus pin block**

Replace this entire block:

```
    # ValheimPlus: pin the three sections that would fight the mods above. V+ ships with EVERY
    # gameplay section enabled=false (only [ValheimPlus] and [Server] are on, and both are meta),
    # so these are already false -- pinning them makes it explicit and drift-proof, because
    # MOD_CONFIG is reapplied on every boot.
    #
    #   [Inventory] -> playerInventoryRows collides with AzuExtendedPlayerInventory, and
    #                  wood/personal/iron/blackmetal/cart/karve/longboat rows+columns collide
    #                  with every value set in AzuContainerSizes above. V+'s own README: "Player
    #                  inventory slot configuration is not compatible with Equipment and Quick
    #                  slots mod unless the Inventory section is disabled."
    #   [Player]    -> baseMaximumWeight / baseMegingjordBuff collide with SkilledCarryWeight.
    #   [Wagon]     -> wagonBaseMass / wagonExtraMassFromItems collide with SkilledCarryWeight's
    #                  CarryWeightAffectsCart mass reduction.
    #
    # Everything else in V+ is free to enable -- building, hotkeys, food, stamina, map, etc.
    # Two to watch if you do: [Items] baseItemWeightReduction and [Stamina] overweight drain both
    # affect carrying, though neither changes a value we set, and both default to no-op.
    valheim_plus.cfg|Inventory|enabled|false
    valheim_plus.cfg|Player|enabled|false
    valheim_plus.cfg|Wagon|enabled|false
```

with:

```
    # ValheimPlus: [Inventory] and [Wagon] are pinned OFF because they would fight other mods.
    # V+ ships with EVERY gameplay section enabled=false (only [ValheimPlus] and [Server] are on,
    # and both are meta), so these are already false -- pinning them makes it explicit and
    # drift-proof, because MOD_CONFIG is reapplied on every boot.
    #
    #   [Inventory] -> playerInventoryRows collides with AzuExtendedPlayerInventory, and
    #                  wood/personal/iron/blackmetal/cart/karve/longboat rows+columns collide
    #                  with every value set in AzuContainerSizes above. V+'s own README: "Player
    #                  inventory slot configuration is not compatible with Equipment and Quick
    #                  slots mod unless the Inventory section is disabled."
    #   [Wagon]     -> ⚠️ THIS PIN IS LOAD-BEARING FOR OdinHorse. It is not leftover caution.
    #                  wagonBaseMass sets the base mass of the wagon object outright (default 20).
    #                  OdinHorse's horse cart is deliberately too heavy for a player to drag --
    #                  that weight is the entire reason taming a horse is worth doing. Enabling
    #                  this section would stomp it back to draggable. This pin previously read as
    #                  a SkilledCarryWeight collision; that mod is gone and the pin still stays.
    #
    # Everything else in V+ is free to enable -- building, hotkeys, food, stamina, map, etc.
    valheim_plus.cfg|Inventory|enabled|false
    valheim_plus.cfg|Wagon|enabled|false
    #
    # [Player]: ENABLED. This section was pinned off while SkilledCarryWeight owned carry weight.
    # That mod has been removed -- it was incompatible with OdinHorse's horse cart -- so V+ now
    # owns carry weight outright and nothing else patches it.
    #
    # ⚠️ baseMaximumWeight and baseMegingjordBuff are ABSOLUTE VALUES, not percentages. This
    # inverts [Armor] and [Durability] further down this file, where the numbers ARE percentage
    # modifiers. 850 means 850 units, NOT +850%. Vanilla is 300 and 150 respectively.
    #
    # 850 replaces what SkilledCarryWeight gave at roughly average skill level 50 (300 base plus
    # ~550 summed across 24 skills). The tradeoff is deliberate and worth knowing before anyone
    # "restores progression": carry weight is now a CONSTANT rather than something skill levels
    # earn, so a new character starts with what previously took ~50 average levels to reach.
    # [Items] baseItemWeightReduction is -75, so everything weighs 25% -- 850 is roughly 3400
    # vanilla-equivalent hauling capacity.
    #
    # baseMegingjordBuff is pinned at its vanilla 150 deliberately. Enabling the section makes
    # every key in it live, so "unchanged from vanilla" is recorded as a decision rather than
    # left to chance.
    #
    # autoRepair and autoEquipShield were requested when this server was set up and refused ONLY
    # because [Player] was pinned off over the SkilledCarryWeight collision. That objection died
    # with the mod. autoUnequipShield is a SEPARATE key and stays at its default false.
    #
    # ⚠️ RE-VERIFY THIS SECTION ON ANY V+ UPGRADE. All 24 keys in [Player] were checked against
    # the generated valheim_plus.cfg at 9.17.1 and every one sits at a vanilla-equivalent default
    # (deathPenaltyMultiplier and fallDamageScalePercent are modifiers at 0; maxFallDamage 100 is
    # annotated "Game default is 100"; guardianBuffDuration 300 / Cooldown 1200 match vanilla).
    # That is what makes enabling the section neutral apart from the four pinned below. A future
    # release adding a non-neutral default would now take effect SILENTLY -- a pinned-off section
    # could not do that.
    valheim_plus.cfg|Player|enabled|true
    valheim_plus.cfg|Player|baseMaximumWeight|850
    valheim_plus.cfg|Player|baseMegingjordBuff|150
    valheim_plus.cfg|Player|autoRepair|true
    valheim_plus.cfg|Player|autoEquipShield|true
```

- [ ] **Step 4: Update the zero-width-character comment in `install-mods.sh`**

`norm()` must stay — it also strips the `\r` that `valheim_plus.cfg` depends on, and every V+
pin above would silently append a duplicate section without it. Only the justification changes.

Replace:

```
    # ⚠️ ZERO-WIDTH CHARACTERS ARE REAL HERE, do not "clean up" the norm() calls below.
    # SkilledCarryWeight prefixes keys and sections with U+200B (E2 80 8B) purely to force sort
    # order in the config manager: its key is "<ZWSP>Enabled", and its first sections are
    # "[<ZWSP><ZWSP><ZWSP>Global]", "[<ZWSP><ZWSP>Cart Mass]", "[<ZWSP>Quick Cart]", while
    # Coefficient, Power and the skill sections are plain. A literal comparison does not match,
    # so an "Enabled" entry would append a SECOND, plain Enabled line that the mod ignores --
    # the applier would report success and change nothing. norm() strips zero-width characters
    # before comparing; the original key text (ZWSP included) is preserved on write so the mod
    # still reads it. Verified on the real file: ZWSP survives, no duplicate key, key count
    # unchanged 83/83.
```

with:

```
    # ⚠️ DO NOT "clean up" the norm() calls below. The CRLF handling is load-bearing TODAY (see
    # the note further down); the zero-width handling is now defensive, and both stay.
    # SkilledCarryWeight was the mod that needed the zero-width stripping: it prefixed keys and
    # sections with U+200B (E2 80 8B) to force sort order in its config manager, so its real key
    # was "<ZWSP>Enabled" and a literal comparison would append a SECOND, plain Enabled line that
    # the mod ignored -- while the applier reported success and changed nothing. That mod has
    # been removed, so nothing currently installed exercises this path. It is kept because the
    # failure mode is silent and expensive to rediscover, and because Thunderstore mods that
    # abuse zero-width characters for sort order are not rare.
```

- [ ] **Step 4b: Enable `disableRoofCheck` in the `[Workbench]` block**

A separate region of `MOD_CONFIG` from Step 3 — find the existing Workbench block:

```
    # Workbench: radius and attachment radius both doubled (meters, absolute).
    valheim_plus.cfg|Workbench|enabled|true
    valheim_plus.cfg|Workbench|workbenchRange|40
    valheim_plus.cfg|Workbench|workbenchAttachmentRange|10
```

Replace it with:

```
    # Workbench: radius and attachment radius both doubled (meters, absolute).
    #
    # disableRoofCheck removes vanilla's requirement that a workbench be roofed and unexposed
    # before it will function at all. V+'s own description: "Disables the roof and exposure
    # requirement to use a workbench." Vanilla default is false.
    #
    # This is NOT the same thing as workbenchRange above -- range governs how far from a bench
    # you can build, while the roof check governs whether the bench works in the first place.
    # A sheltered bench already worked at 40m without this.
    #
    # Pairs with [Player] autoRepair: repair fires on interacting with a workbench, so while the
    # roof check stands, auto-repair only works under a roof. Both together are what make it
    # automatic anywhere.
    #
    # No new section is enabled here -- [Workbench] was already on for the two range values.
    valheim_plus.cfg|Workbench|enabled|true
    valheim_plus.cfg|Workbench|workbenchRange|40
    valheim_plus.cfg|Workbench|workbenchAttachmentRange|10
    valheim_plus.cfg|Workbench|disableRoofCheck|true
```

- [ ] **Step 4c: Raise tool durability to +150%**

Another separate region of `MOD_CONFIG`. Find the tail of the `[Durability]` comment block and
its settings:

```
    # Tools are deliberately left at vanilla 0: pickaxes, hammer, cultivator, hoe, torch. The ask
    # was weapons and armor. `axes` IS included -- an axe is a weapon -- which also makes
    # woodcutting cheaper as a side effect.
    valheim_plus.cfg|Durability|enabled|true
    valheim_plus.cfg|Durability|weapons|100
    valheim_plus.cfg|Durability|axes|100
    valheim_plus.cfg|Durability|bows|100
    valheim_plus.cfg|Durability|shields|100
    valheim_plus.cfg|Durability|armor|100
```

Replace with:

```
    # Tools are at +150%, HIGHER than the +100% on combat gear above. ⚠️ That asymmetry is
    # deliberate -- do not "correct" it to match, for the same reason [Armor] and [Durability]
    # deliberately differ. Combat-gear durability is still adjacent to balance: it governs how
    # long you last in a fight before a weapon breaks. Tool durability is pure convenience --
    # it changes only how often you walk back to a workbench. Tools being the MORE generous
    # number follows from that distinction rather than contradicting it.
    #
    # This reverses an earlier decision. These five keys previously sat at vanilla 0 with a
    # comment saying tools were deliberately excluded because "the ask was weapons and armor".
    # Raising them was then asked for explicitly, with the convenience-vs-balance split above on
    # the table.
    #
    # `axes` stays at 100 with the WEAPONS, not with the tools. An axe is a weapon that also
    # chops wood and was raised on that basis; moving it here would be a combat-balance change
    # wearing a tools-change disguise.
    #
    # `torch` is grouped with the tools. It is a light source rather than a tool, but its
    # durability is burn time -- the same kind of convenience number.
    valheim_plus.cfg|Durability|enabled|true
    valheim_plus.cfg|Durability|weapons|100
    valheim_plus.cfg|Durability|axes|100
    valheim_plus.cfg|Durability|bows|100
    valheim_plus.cfg|Durability|shields|100
    valheim_plus.cfg|Durability|armor|100
    valheim_plus.cfg|Durability|pickaxes|150
    valheim_plus.cfg|Durability|hammer|150
    valheim_plus.cfg|Durability|cultivator|150
    valheim_plus.cfg|Durability|hoe|150
    valheim_plus.cfg|Durability|torch|150
```

⚠️ `150` is a **percentage modifier**, not an absolute — V+'s own annotation is *"The value 50
will increase the durability from 100 to 150."* So this takes tool durability 100 → **250**.

- [ ] **Step 4d: Enable `[Gathering]` and `[Experience]`**

Both sections are currently `enabled = false` and every key in them is `0`. Append these two
blocks to the end of `MOD_CONFIG`, after the `[SapCollector]` lines:

```
    # --- Gathering: double the yield from every node broken with a tool ---------------------
    # This was asked for as "increase tool damage". V+ CANNOT do that -- verified by enumerating
    # all 58 sections and every key containing "damage": the complete set is monster scaling,
    # unarmed, fall, structural and hull. There is no [Damage] section and no per-weapon-type
    # modifier. So this is a yield change, not a damage change: a rock still takes the same
    # number of swings, you just mine fewer rocks. [Experience] below is the damage half.
    #
    # ⚠️ COMPOUNDS with `-modifier resources more` in configmap.yaml -- a NATIVE global drop
    # multiplier already one step above normal. The effective multiplier is therefore MORE than
    # 2x, not exactly 2x. There are two independent sources; know which one you are changing.
    #
    # dropChance stays at 0 deliberately. It is a different mechanic: it raises the CHANCE on
    # nodes that have no guaranteed drop (dungeon scrap piles), not the AMOUNT from ore veins.
    #
    # feather is included for consistency, with a quirk worth knowing: it also affects drops
    # from shooting gulls and crows, not only trees.
    #
    # ⚠️ Enabling this section makes every key in it live. The ones not listed sit at 0, which is
    # a no-op -- same situation as [Player]. RE-VERIFY ON ANY V+ UPGRADE: a release adding a
    # non-neutral default here would now take effect silently.
    valheim_plus.cfg|Gathering|enabled|true
    valheim_plus.cfg|Gathering|wood|100
    valheim_plus.cfg|Gathering|fineWood|100
    valheim_plus.cfg|Gathering|coreWood|100
    valheim_plus.cfg|Gathering|elderBark|100
    valheim_plus.cfg|Gathering|yggdrasilWood|100
    valheim_plus.cfg|Gathering|blackwood|100
    valheim_plus.cfg|Gathering|stone|100
    valheim_plus.cfg|Gathering|grausten|100
    valheim_plus.cfg|Gathering|blackMarble|100
    valheim_plus.cfg|Gathering|tinOre|100
    valheim_plus.cfg|Gathering|copperOre|100
    valheim_plus.cfg|Gathering|copperScrap|100
    valheim_plus.cfg|Gathering|ironScrap|100
    valheim_plus.cfg|Gathering|silverOre|100
    valheim_plus.cfg|Gathering|chitin|100
    valheim_plus.cfg|Gathering|feather|100
    valheim_plus.cfg|Gathering|flametalOre|100
    valheim_plus.cfg|Gathering|proustitePowder|100
    # --- Experience: faster Pickaxes skill --------------------------------------------------
    # This is the ONLY route V+ offers to genuinely more pickaxe DAMAGE. Skill level scales tool
    # damage in vanilla, so levelling Pickaxes faster means fewer swings per rock. Unlike
    # [Gathering] above, this really is a damage increase rather than a yield increase.
    #
    # Self-limiting: once Pickaxes reaches 100 this contributes nothing further.
    #
    # Only pickaxes is raised. Every other skill stays at 0 (no-op); the section being enabled
    # makes them live, so adding another later is a one-line change. Same re-verify-on-upgrade
    # caveat as [Gathering] above.
    valheim_plus.cfg|Experience|enabled|true
    valheim_plus.cfg|Experience|pickaxes|100
```

- [ ] **Step 5: Apply, restart, and watch the prune remove a real mod**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
cd valheim
kubectl apply -f mods-configmap.yaml --dry-run=server
kubectl apply -f mods-configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Expected from apply: `configmap/valheim-mods configured`.

- [ ] **Step 6: Verify SkilledCarryWeight is gone from both PVCs**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
(kubectl logs -n valheim $p -c fetch-mods | Select-String "prune") -join "`n"
kubectl exec -n valheim $p -c valheim -- sh -c 'find /config /opt/valheim -iname "*SkilledCarryWeight*" -not -name "*.cfg" 2>/dev/null; echo "(end)"'
```

Expected: prune log lines naming `SkilledCarryWeight` for `staged`, `live` and `marker`; and the
`find` returns only `(end)`.

`Searica.Valheim.SkilledCarryWeight.cfg` is **expected to remain** — an orphaned config with no
DLL to read it, deliberately left in place.

- [ ] **Step 7: Verify the 11 remaining mods survived**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$staged = kubectl exec -n valheim $p -c valheim -- ls -1 /config/bepinex/plugins
$live   = kubectl exec -n valheim $p -c valheim -- ls -1 /opt/valheim/bepinex/BepInEx/plugins
"staged=$($staged.Count) live=$($live.Count)"
Compare-Object $staged $live
```

Expected: `staged=11 live=11`, `Compare-Object` returns nothing.

- [ ] **Step 8: Verify the `[Player]` section landed without duplicates**

Per the Global Constraints, an appended duplicate is the signature of a failed match.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$script = @'
C=/config/bepinex/valheim_plus.cfg
echo "=== [Player] section count (must be 1) ==="
grep -c '^\[Player\]' "$C" | tr -d '\r'
echo "=== [Player] values ==="
awk '/^\[Player\]/{f=1} f&&/^\[/&&!/^\[Player\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|baseMaximumWeight|baseMegingjordBuff|autoRepair|autoEquipShield|autoUnequipShield) '
echo "=== [Wagon] must still be disabled ==="
awk '/^\[Wagon\]/{f=1} f&&/^\[/&&!/^\[Wagon\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|wagonBaseMass) '
echo "=== [Workbench] roof check ==="
awk '/^\[Workbench\]/{f=1} f&&/^\[/&&!/^\[Workbench\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|workbenchRange|disableRoofCheck) '
echo "=== [Durability] tools vs combat gear ==="
awk '/^\[Durability\]/{f=1} f&&/^\[/&&!/^\[Durability\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|weapons|axes|bows|shields|armor|pickaxes|hammer|cultivator|hoe|torch) '
echo "=== [Gathering] enabled + a sample of yields ==="
awk '/^\[Gathering\]/{f=1} f&&/^\[/&&!/^\[Gathering\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|dropChance|stone|copperOre|silverOre|wood) '
echo "=== [Gathering] count of keys at 100 (expect 18) ==="
awk '/^\[Gathering\]/{f=1} f&&/^\[/&&!/^\[Gathering\]/{f=0} f' "$C" | tr -d '\r' | grep -cE '= 100$'
echo "=== [Experience] pickaxes ==="
awk '/^\[Experience\]/{f=1} f&&/^\[/&&!/^\[Experience\]/{f=0} f' "$C" | tr -d '\r' | grep -E '^(enabled|pickaxes|woodCutting|swords) '
echo "=== total section count ==="
grep -c '^\[' "$C" | tr -d '\r'
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
kubectl exec -n valheim $p -c valheim -- sh -c "echo $b64 | base64 -d | sh"
```

Expected:
```
=== [Player] section count (must be 1) ===
1
=== [Player] values ===
enabled = true
baseMaximumWeight = 850
baseMegingjordBuff = 150
autoRepair = true
autoEquipShield = true
autoUnequipShield = false
=== [Wagon] must still be disabled ===
enabled = false
wagonBaseMass = 20
=== [Workbench] roof check ===
enabled = true
workbenchRange = 40
disableRoofCheck = true
=== [Durability] tools vs combat gear ===
enabled = true
axes = 100
pickaxes = 150
hammer = 150
cultivator = 150
hoe = 150
weapons = 100
armor = 100
bows = 100
shields = 100
torch = 150
```

and:

```
=== [Gathering] enabled + a sample of yields ===
enabled = true
dropChance = 0
wood = 100
stone = 100
copperOre = 100
silverOre = 100
=== [Gathering] count of keys at 100 (expect 18) ===
18
=== [Experience] pickaxes ===
enabled = true
pickaxes = 100
woodCutting = 0
swords = 0
```

⚠️ The `[Durability]` keys print in the file's own order, not the order you wrote them. Four
things to check specifically:
- **`axes = 100`** — it must stay with the weapons, not drift to 150 with the tools
- **exactly five keys at 150** — `pickaxes`, `hammer`, `cultivator`, `hoe`, `torch`. Combat gear
  (`weapons`, `axes`, `bows`, `shields`, `armor`) all stay at 100
- **`[Gathering] dropChance = 0`** — it must NOT have been swept to 100 with the yields; it is a
  different mechanic and was deliberately left alone
- **`[Experience] woodCutting = 0` and `swords = 0`** — only `pickaxes` was raised. These two
  confirm the section was enabled without other skills being touched

A `[Player]` count of `2` means the applier appended rather than matched — investigate before
proceeding. `autoUnequipShield = false` confirms only the intended keys were touched.
`workbenchRange = 40` still present alongside `disableRoofCheck = true` confirms the Step 4b
edit added a key rather than replacing the block.

- [ ] **Step 9: Verify in-game**

Join the server and confirm:
- Max carry weight reads **850** (plus 150 with Megingjord equipped), and does **not** change
  when a skill levels up
- Interacting with a workbench repairs equipment automatically
- Equipping a one-handed weapon auto-equips the best shield
- **An uncovered workbench — no roof, open sky — still functions for crafting and repair.**
  Test this on a bench with no shelter at all, not one that merely looks exposed; vanilla's
  check is about roof cover and exposure, and a partial roof already passed it before

The carry-weight check is the negative case: the old behaviour scaled with skill, so observing
a flat number is what proves SkilledCarryWeight is actually gone rather than merely unlisted.

- [ ] **Step 10: Update `README.md`**

Six separate edits. Work through them in order.

**(a)** Mod table — delete the row:

```markdown
| SkilledCarryWeight | 1.4.1 | recommended (server install enforces config) |
```

**(b)** V+ collision table — replace these two rows:

```markdown
| `[Player]` | SkilledCarryWeight (`baseMaximumWeight`, `baseMegingjordBuff`) |
| `[Wagon]` | SkilledCarryWeight's cart-mass reduction (`wagonBaseMass`, `wagonExtraMassFromItems`) |
```

with a single row (`[Player]` is no longer pinned):

```markdown
| `[Wagon]` | OdinHorse's horse cart (`wagonBaseMass` would stomp its deliberate heaviness back to draggable) |
```

**(c)** Replace the "Two requested settings" paragraph:

```markdown
**Two requested settings were deliberately NOT applied** — `autoEquipShield` and `autoRepair` both
live in `[Player]`, which is pinned off because `baseMaximumWeight` there collides with
SkilledCarryWeight. Enabling `[Player]` to get them would put V+ and SkilledCarryWeight on the same
carry-weight property with unknown patch ordering. See "If you want the `[Player]` features" below.

Two knock-on effects worth knowing, neither a collision:

- `[Items] baseItemWeightReduction = -75` compounds with SkilledCarryWeight — lighter items *and*
  a higher cap.
```

with:

```markdown
**`autoRepair` and `autoEquipShield` are now enabled.** Both live in `[Player]`, which was pinned
off while SkilledCarryWeight owned carry weight — enabling it would have put two mods on the same
property with undocumented patch ordering. SkilledCarryWeight has been removed, so that objection
is gone and both settings are on. `autoUnequipShield` is a separate key, left at `false`.

One knock-on effect worth knowing, not a collision:

- `[Items] baseItemWeightReduction = -75` compounds with the raised cap — lighter items *and*
  more of them. At `baseMaximumWeight = 850` that is roughly 3400 vanilla-equivalent capacity.
```

**(d)** Replace the whole `### If you want the [Player] features` section (from that heading
through the paragraph ending `nothing is stuck.`) with:

```markdown
### `[Player]` is enabled

V+ owns carry weight outright — `baseMaximumWeight = 850`, `baseMegingjordBuff = 150` (vanilla).
Both are **absolute values, not percentages**, unlike `[Armor]` and `[Durability]`.

⚠️ **Carry weight no longer scales with skill.** SkilledCarryWeight made it a progression reward;
850 is roughly what it granted at average skill level 50, so an established character sees no
change while a new one starts at the old endgame. That was a deliberate trade, not an oversight.

🚨 **Re-verify `[Player]` on any V+ upgrade.** All 24 keys were checked at 9.17.1 and every one
sits at a vanilla-equivalent default, which is what makes enabling the section neutral apart from
the four pinned in `MOD_CONFIG`. A future release adding a non-neutral default would take effect
**silently** — a pinned-off section could not do that.
```

**(e)** Replace the "Carry weight" paragraph and the zero-width block that follows it. This spans
from `**Carry weight** — all 24 skills contribute` through `across 48 edits. If you ever suspect a
silent no-op, that count is the check:` — **stop there.** The next paragraph
(`**The applier normalises four things...**`) and its quirks table are handled in (f), and the
PowerShell block further down is a separate edit, also in (f). Replace that span with:

```markdown
**Carry weight** — `[Player] baseMaximumWeight = 850`, flat. This replaced SkilledCarryWeight,
which summed `Coefficient × level` across 24 skills for roughly +550 over a 300 base at average
level 50. See "`[Player]` is enabled" above.

🚨 **Zero-width characters can be load-bearing in a mod's `.cfg`.** SkilledCarryWeight prefixed
keys and sections with U+200B (`E2 80 8B`) to force sort order in its config manager — its real
key was `<ZWSP>Enabled`, not `Enabled` — so a literal match failed and the applier appended a
**second, plain `Enabled` line the mod ignored while reporting success.** That mod is gone, so
nothing installed exercises this path today, but `norm()` still strips zero-width characters
because the failure mode is silent. **Do not remove those `norm()` calls as dead weight** — they
also strip the `\r` that `valheim_plus.cfg` depends on, and every V+ pin would break without it.
```

**(f)** Config filename list — remove `Searica.Valheim.SkilledCarryWeight.cfg` and reflow:

```
Azumatt.AzuExtendedPlayerInventory.cfg    Azumatt.AzuContainerSizes.cfg
randyknapp.mods.epicloot.cfg              Therzie.Warfare.cfg
advize.PlantEverything.cfg
```

Then update the quirks table row:

```markdown
| U+200B zero-width space in keys/sections | SkilledCarryWeight | stripped before compare, preserved on write |
```

to:

```markdown
| U+200B zero-width space in keys/sections | SkilledCarryWeight (removed; handling kept) | stripped before compare, preserved on write |
```

Finally, the PowerShell block that targets the now-orphaned SkilledCarryWeight config:

```powershell
kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'C=/config/bepinex/Searica.Valheim.SkilledCarryWeight.cfg; echo "keys=$(grep -c = $C) true=$(grep -c "Enabled = true" $C)"'
```

**Repoint it rather than deleting it** — the paragraph above it introduces the count check as the
integrity test, so removing the example leaves that paragraph dangling. Target the file the pins
now actually depend on:

```powershell
kubectl exec -n valheim deploy/valheim -c valheim -- sh -c 'C=/config/bepinex/valheim_plus.cfg; echo "sections=$(grep -c "^\[" $C) keys=$(grep -c "=" $C) player=$(grep -c "^\[Player\]" $C)"'
```

`player=1` is the check that matters — a `2` means the applier appended a duplicate `[Player]`
section instead of matching the existing one.

**(g)** Document the workbench change. Find the README's Workbench/production discussion and add:

```markdown
**Workbenches no longer need a roof.** `[Workbench] disableRoofCheck = true` removes vanilla's
requirement that a bench be sheltered and unexposed before it functions — V+'s own description
is *"Disables the roof and exposure requirement to use a workbench."* This is distinct from
`workbenchRange = 40`, which governs how far from a bench you can build; a sheltered bench
already worked at 40m without it.

It compounds with `[Player] autoRepair`: repair fires on interacting with a workbench, so while
the roof check stood, auto-repair only worked under a roof.
```

No section count change — `[Workbench]` was already among the enabled sections, so the README's
**"25 sections are enabled"** figure stays correct.

**(h)** Tool durability — **two** README passages assert tools are at vanilla and both now
contradict the config. Fix both.

First, replace:

```markdown
mod. **That gap is now closed** — ValheimPlus's `[Durability]` section does it, and is set to
+100% on combat gear; see "ValheimPlus" below. Do not go looking for a `-modifier` for this.
```

with:

```markdown
mod. **That gap is now closed** — ValheimPlus's `[Durability]` section does it, and is set to
+100% on combat gear and +150% on tools; see "ValheimPlus" below. Do not go looking for a
`-modifier` for this.
```

Second, replace:

```markdown
before "fixing" it. `[Durability]` covers `weapons`, `axes`, `bows`, `shields`, `armor`; tools
(`pickaxes`, `hammer`, `cultivator`, `hoe`, `torch`) are deliberately left at vanilla 0.
```

with:

```markdown
before "fixing" it. `[Durability]` is **+100% on combat gear** (`weapons`, `axes`, `bows`,
`shields`, `armor`) and **+150% on tools** (`pickaxes`, `hammer`, `cultivator`, `hoe`, `torch`).

⚠️ **Tools are deliberately the more generous number.** Combat-gear durability is still adjacent
to balance — it governs how long you last in a fight before a weapon breaks. Tool durability is
pure convenience: it changes only how often you walk back to a workbench. `axes` sits with the
weapons at +100%, not with the tools, because an axe is a weapon that also chops wood. `torch`
sits with the tools because its durability is burn time.
```

⚠️ These values are **percentage modifiers** — `150` takes durability 100 → 250.

**(i)** Document the mining changes. Add near the V+ section list:

```markdown
**Mining yield and pickaxe skill.** `[Gathering]` is at **+100%** on every resource dropped from
a node broken with a tool, and `[Experience] pickaxes` is at **+100%**.

These were asked for as "increase tool damage". 🚨 **V+ cannot do that** — verified by
enumerating all 58 sections and every key containing `damage`: the complete set is monster
scaling, unarmed, fall, structural and hull. There is no `[Damage]` section and no
per-weapon-type modifier. Do not go looking for one.

The two settings split the goal:
- `[Gathering]` is a **yield** change — a rock takes the same swings, you mine fewer rocks
- `[Experience] pickaxes` is the only real **damage** route, since skill level scales tool
  damage in vanilla. It is self-limiting: at Pickaxes 100 it stops contributing

⚠️ **`[Gathering]` compounds with `-modifier resources more`** in `configmap.yaml`, a native
global drop multiplier already one step above normal. The effective multiplier is **more than
2×**. Two independent sources — know which one you are changing.

`dropChance` is deliberately left at `0`: it raises the *chance* on nodes without a guaranteed
drop (dungeon scrap piles), not the *amount* from ore veins.
```

Both are newly-enabled sections, so update the **"25 sections are enabled"** count to **27** and
add `Gathering` and `Experience` to the list.

**Verify no stale references remain** (the mod table row for OdinHorse is added in Task 3):

```bash
grep -n "SkilledCarryWeight" valheim/README.md
```

Expected: only the historical mentions in (e) and the quirks table — no line implying the mod is
installed, and no `[Player]`-is-pinned-off claim.

- [ ] **Step 11: Commit**

⚠️ The title must name the whole change. This task grew well past the SkilledCarryWeight
migration during execution, and a commit titled only for the migration would hide four unrelated
gameplay changes from anyone reading `git log`.

```bash
git add valheim/mods-configmap.yaml valheim/README.md
git commit -m "Remove SkilledCarryWeight; move carry weight and QoL settings to V+

SkilledCarryWeight is incompatible with OdinHorse: its Cart Mass Reduction
scales cart mass down as max carry weight rises, and its Quick Cart hotkey
attaches the player to any nearby cart. OdinHorse's horse cart is deliberately
too heavy to drag, so together they let a player walk off with it. Not
resolvable by configuration.

Carry weight moves to V+ [Player] baseMaximumWeight=850, matching what
SkilledCarryWeight granted at average skill level 50. It is now a constant
rather than a progression reward -- a deliberate trade.

[Wagon] stays pinned off. Its justification changes rather than disappearing:
wagonBaseMass=20 would stomp the horse cart back to draggable.

Enabling [Player] also unblocks autoRepair and autoEquipShield, which the
README recorded as requested and refused solely over the carry-weight patch
ordering. All 24 keys in the section were verified vanilla-equivalent against
the generated cfg at 9.17.1, so enabling it is neutral apart from the four
pinned -- flagged for re-verification on any V+ upgrade.

Also enables [Workbench] disableRoofCheck, removing vanilla's requirement that
a workbench be roofed and unexposed to function. One line -- the section was
already enabled for workbenchRange. Compounds with autoRepair, which fires on
workbench interaction and would otherwise only work under a roof.

Raises tool durability to +150% (pickaxes, hammer, cultivator, hoe, torch),
reversing an earlier decision to leave them at vanilla 0. Deliberately higher
than the +100% on combat gear: combat durability is adjacent to balance, tool
durability is pure convenience. axes stays at 100 with the weapons -- it is a
weapon that also chops wood. Both README passages asserting tools were at
vanilla are rewritten rather than left contradicting the config.

Enables [Gathering] at +100% and [Experience] pickaxes at +100%. Both were
asked for as \"increase tool damage\", which V+ cannot do -- verified by
enumerating all 58 sections and every key containing damage. [Gathering] is a
yield change (same swings, fewer rocks); [Experience] is the only real damage
route, since skill level scales tool damage in vanilla, and it self-limits at
Pickaxes 100. [Gathering] COMPOUNDS with -modifier resources more already set
in configmap.yaml, so the effective multiplier exceeds 2x. dropChance stays at
0 -- it is a chance mechanic, not an amount mechanic.

Three sections move from disabled to enabled ([Player], [Gathering],
[Experience]). Each was checked key-by-key against the generated cfg: all
unlisted keys sit at vanilla-equivalent no-ops. Flagged in-file for
re-verification on any V+ upgrade, since an enabled section adopts new
defaults silently where a disabled one cannot.

Safe to remove because SkilledCarryWeight is a pure runtime patch that
registers no prefabs and persists nothing in the world save. This does not
generalise to EpicLoot, Warfare, Armory or OdinsFoodBarrels."
```

---

## Task 3: Add OdinHorse 1.6.5

**Files:**
- Modify: `valheim/mods-configmap.yaml` (`MODS`)
- Modify: `valheim/README.md` (mod table, client install section)

**Interfaces:**
- Consumes: the `[Wagon]` pin from Task 2 (without it the horse cart is draggable)
- Produces: nothing other tasks depend on

- [ ] **Step 1: Add the `MODS` line**

Add to `valheim/mods-configmap.yaml`, after the `XPortal` line. The sha256 column aligns at
character 133, matching the majority of existing rows:

```
    OdinHorse                  1.6.5    https://thunderstore.io/package/download/OdinPlus/OdinHorse/1.6.5/                          23a455aa79c074f2098107ea9f09f044460442d152732d928f511a16023209bc  root
```

`layout=root` because the zip contains exactly `CHANGELOG.md`, `icon.png`, `manifest.json`,
`OdinHorse.dll`, `README.md` — a bare DLL at the root, no `plugins/`, `BepInEx/` or `config/`
directory. Verified against the artifact, not assumed.

Add a comment above it in the file's existing style:

```
    # OdinHorse: rideable/tameable/breedable horses plus a horse cart. Pinned at 1.6.5 rather
    # than an older "more proven" release because 1.6.2 was the server-side fix ("error when
    # using Mod on Server. Any array-typed config, fixed at the ServerSync.cs layer") -- anything
    # before that is actively wrong for a dedicated server. Everything since is cosmetic.
    #
    # Saddle storage ships DISABLED by default for performance and is deliberately left that way.
    # Turning it on needs a second apply: MOD_CONFIG needs exact section/key names, and those do
    # not exist until the mod generates its .cfg on first boot.
    #
    # ⚠️ Requires the [Wagon] pin in MOD_CONFIG to stay disabled -- see the note there.
```

Then add a rejection note beside the existing `TrashItems` one, matching its style — the repo
documents mods it deliberately does not install so they do not get re-proposed:

```
    # CookingStationTweaks (Grizzzly, 0.7.1) is deliberately NOT here. Evaluated 2026-07-29 and
    # declined. Its features are useful and it does NOT collide with V+ -- [Oven] there covers
    # only fuel, this covers slots, cook time, burning and auto-pop. Grizzzly's is the right
    # fork: 0.7.1 (2025-05) vs yeldarb420 0.6.0 (2024-06) vs digitiliad 0.2.0 (deprecated).
    #
    # It was declined because it has NO enforcement mechanism. It ships no ServerSync and no
    # Jotunn, so unlike everything else here it can neither kick mismatched clients (AzuEPI,
    # AzuContainerSizes do) nor push config from the server (ValheimPlus does, via
    # serverSyncsConfig). Correct client config would be convention, not mechanism.
    #
    # The failure mode is the one already documented for AzuContainerSizes below: a player on a
    # different SlotMultiplier -- or without the mod -- sees a DIFFERENT slot count on a shared
    # station, and food in the extra slots is invisible and unrecoverable to them. Silent and
    # per-player. If it is ever reconsidered, the artifact is sha256
    # 62c11fa57ca3ff34d0ef09942da77966835ce042ca03e378e7eb749398714477, 115605 bytes, layout
    # root, and its config file is aedenthorn.CookingStationTweaks.cfg.
```

- [ ] **Step 2: Validate and apply**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
cd valheim
kubectl apply -f mods-configmap.yaml --dry-run=server
kubectl apply -f mods-configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Expected: `configmap/valheim-mods configured`.

- [ ] **Step 3: Verify the install and checksum**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
(kubectl logs -n valheim $p -c fetch-mods | Select-String "OdinHorse|prune|installed") -join "`n"
```

Expected: `[fetch] OdinHorse 1.6.5` then `[ok   ] OdinHorse 1.6.5`, a summary of
`1 installed, 11 already present`, and **no** `[prune]` lines. A checksum mismatch fails the
init container and the pod will not start — that is intentional.

- [ ] **Step 4: Verify the DLL landed in both locations**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
$staged = kubectl exec -n valheim $p -c valheim -- ls -1 /config/bepinex/plugins
$live   = kubectl exec -n valheim $p -c valheim -- ls -1 /opt/valheim/bepinex/BepInEx/plugins
"staged=$($staged.Count) live=$($live.Count)"
Compare-Object $staged $live
kubectl exec -n valheim $p -c valheim -- ls -la /opt/valheim/bepinex/BepInEx/plugins/OdinHorse
```

Expected: `staged=12 live=12`, `Compare-Object` returns nothing, and `OdinHorse.dll` is present.

- [ ] **Step 5: Confirm the plugin actually loaded**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
(kubectl exec -n valheim $p -c valheim -- cat /opt/valheim/bepinex/BepInEx/LogOutput.log | Select-String "OdinHorse|Loading \[") -join "`n"
```

Expected: a `Loading [OdinHorse 1.6.5]` line and **no** exception trace following it. A DLL on
disk that failed to load is the failure this catches — `ls` alone would not.

- [ ] **Step 6: Verify in-game — including the negative case**

- A horse spawns / can be tamed
- The horse cart can be built and attached to a horse
- 🚨 **A player on foot cannot drag the horse cart.** This is the whole point of the migration.
  If it *can* be dragged, `[Wagon]` has been enabled or SkilledCarryWeight is still active
  somewhere — stop and investigate before players build around it

- [ ] **Step 7: Update `README.md`**

**(a)** Add to the mod table, replacing the row deleted in Task 2 so the count stays at twelve:

```markdown
| OdinHorse | 1.6.5 | **required** (custom creature/item assets) |
```

⚠️ **Restore the mod-count assertions to twelve.** An earlier draft of this plan claimed the
"Twelve mods are installed" prose needed no change because one mod goes out and one comes in.
That is wrong *between* the two tasks: Task 2 removes SkilledCarryWeight and leaves the count at
**eleven**, so Task 2 corrected these three to eleven and Task 3 must put them back:

- `README.md` — "**Eleven mods are installed**" → twelve
- `README.md` — the installer idempotency example, `0 installed, 11 already present` → `12`
- `README.md` — "Expect `11 plugins to load`" → `12`

Confirm the last one against a real chainloader log line rather than inferring it:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
(kubectl exec -n valheim $p -c valheim -- cat /opt/valheim/bepinex/BepInEx/LogOutput.log | Select-String "plugins to load") -join "`n"
```

**(b)** Add to the client install section, after the existing `JsonDotNET` warning:

```markdown
🚨 **SkilledCarryWeight must be UNINSTALLED client-side.** Removing it from the server is
necessary but **not sufficient** — it functions as a client-side mod, so a player who keeps it
retains local Cart Mass Reduction and the Quick Cart hotkey and can still drag OdinHorse's horse
cart no matter what the server does. There is no server-side control for this.
```

- [ ] **Step 8: Commit**

```bash
git add valheim/mods-configmap.yaml valheim/README.md
git commit -m "Add OdinHorse 1.6.5

Rideable, tameable, breedable horses plus a horse cart. layout=root, verified
against the artifact: the zip holds a bare OdinHorse.dll with no plugins/,
BepInEx/ or config/ dir. manifest.json declares no dependencies. Checksum
reproducible across two independent downloads.

Pinned at 1.6.5 rather than an older release because 1.6.2 was the server-side
ServerSync fix -- anything earlier is actively wrong for a dedicated server.
Everything since is cosmetic.

Saddle storage stays at its default off. Enabling it needs a second apply,
since MOD_CONFIG needs section/key names that do not exist until the mod
generates its .cfg.

Depends on the [Wagon] pin staying disabled: wagonBaseMass would override the
horse cart's deliberate heaviness."
```

---

## Post-implementation

- [ ] **Client rollout.** Every player must uninstall SkilledCarryWeight and install OdinHorse
  1.6.5 via r2modman. The uninstall is mandatory — see Task 3 Step 7(b)
- [ ] **Confirm the world is intact** one final time:

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$p = kubectl get pod -n valheim -l app=valheim -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n valheim $p -c valheim -- ls -la /config/worlds_local
```

Expected: `TreeFellMeFirst.db` present and recently written.

⚠️ **From this point OdinHorse is sticky.** Tamed horses, bred offspring and horse carts persist
as ZDOs in `TreeFellMeFirst.db`. Removing the mod later orphans them — unlike SkilledCarryWeight,
which registered nothing and was free to drop.
