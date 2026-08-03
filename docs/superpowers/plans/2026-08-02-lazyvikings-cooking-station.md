# LazyVikings Cooking-Station Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cooking stations fill themselves from nearby containers unattended, by installing `blacks7ar-LazyVikings` 1.2.3 as the fourteenth BepInEx mod with every station type disabled except Cooking Station and Iron Cooking Station.

**Architecture:** No new mechanism. One line is added to `MODS` and seventeen to `MOD_CONFIG` in `valheim/mods-configmap.yaml`; the existing `fetch-mods` initContainer downloads the pinned artifact, verifies its SHA256, extracts it, and applies the config pins on every boot. Because the section and key names were recovered by static analysis, the pins are written *before* the mod's first boot — so there is never a boot where LazyVikings and ValheimPlus both automate the same station. ValheimPlus is not modified at all.

**Tech Stack:** Kubernetes (Talos), `kubectl`, PowerShell, BepInEx 5.4.2333, Thunderstore, Longhorn.

**Spec:** `docs/superpowers/specs/2026-08-02-lazyvikings-cooking-station-design.md`

## Global Constraints

- Repo root is `C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal`. **`cd valheim/` before any `kubectl apply`** — relative paths from the repo root silently no-op.
- `KUBECONFIG` is set in `.claude/settings.local.json`. **Never inline `$env:KUBECONFIG = …`** — a command starting with an assignment never prefix-matches a `kubectl *` permission rule, so every call prompts.
- `kubectl apply` reporting `unchanged` is a **silent failure**. It must report `configured`.
- Deliver multi-line shell scripts to containers **base64-encoded**. Quoting does not survive PowerShell → `kubectl exec` → `sh`. (Observed again this session: an inline `awk` with escaped quotes failed to parse.)
- Single replica, `strategy: Recreate`, `terminationGracePeriodSeconds: 120` — **every restart is a ~3-5 minute outage**.
- After editing a config file in place, **re-read it and confirm section/key counts moved by exactly the expected delta**. An appended duplicate is the signature of a failed match.
- **Verify the negative case.** A check only ever observed passing has not been verified.
- Commits go directly to `main`; no PR flow. Manifests carry inline comments explaining *why* a setting exists.

### Exact values (copied verbatim from the spec — do not retype from memory)

| Field | Value |
|---|---|
| Package | `blacks7ar-LazyVikings` |
| Version | `1.2.3` |
| URL | `https://thunderstore.io/package/download/blacks7ar/LazyVikings/1.2.3/` |
| sha256 | `25cc50aeb44be09d08998b937dde671b60f8a420656d5b36cc236c52c8588437` |
| Size | 78,183 bytes |
| Layout | `root` |
| Config file | `blacks7ar.LazyVikings.cfg` |
| Config key (all station sections) | `Enable` |
| **Values** | **`On` / `Off` — Toggle enum, NOT `true`/`false`** |

### Section names — exact, and in a format unique to this mod

`NN- Name`: zero-padded two digits, **no space before the dash, one space after**.

```
01- ServerSync            07- Fermenter              13- Spinning Wheel
02- General               08- Hot Tub                14- Stone Oven
03- Beehive               09- Iron Cooking Station   15- Windmill
04- Blast Furnace         10- Kiln                   16- Fireplace
05- Cooking Station       11- SapCollector           17- Steel Kiln
06- Eitr Refinery         12- Smelter                18- Steel Slack Tub
```

⚠️ This repo now has **three** section-naming conventions. Azumatt: `2 - Inventory Recycle`. ValheimPlus: bare `[Time]`. LazyVikings: `05- Cooking Station`. A pattern written for one silently misses the others.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `valheim/mods-configmap.yaml` | Declares the mod (`MODS`) and its 17 config pins (`MOD_CONFIG`); header note records it as client-recommended | 1 |
| `valheim/README.md` | Operator-facing mod inventory, three counts, per-mod config record, the V+ interact-vs-unattended finding | 2 |
| *(live cluster)* | Apply, rollout, parse check, config verification | 3 |
| *(in-game)* | Auto-cook works; V+ stations unchanged; record results | 4 |

Tasks 1–2 are repo edits, safe any time. Task 3 opens the outage window. Task 4 needs a human in-game.

---

## Task 1: Declare LazyVikings in `mods-configmap.yaml`

**Files:**
- Modify: `valheim/mods-configmap.yaml` — header CLIENT INSTALL note, `MODS` block, end of `MOD_CONFIG` block

**Interfaces:**
- Consumes: nothing — first task.
- Produces: the `MODS` entry named `LazyVikings` (this exact string becomes the plugin directory `/config/bepinex/plugins/LazyVikings/`, the `.mod-state` marker filename, and what the prune's `is_kept` matches); and seventeen `MOD_CONFIG` lines targeting `blacks7ar.LazyVikings.cfg`. Tasks 3 and 4 assert on both.

- [ ] **Step 1: Capture the "before" counts**

The failing-test equivalent. These must be exactly these values *before* the edit.

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
$f = Get-Content mods-configmap.yaml
$s = ($f | Select-String -Pattern '^  MODS: \|$').LineNumber
$e = ($f | Select-String -Pattern '^  MOD_CONFIG: \|$').LineNumber
$m = $f[$s..($e-2)] | Where-Object { $_ -match '^\s{4}\S' -and $_ -notmatch '^\s*#' }
"MODS entries      = $($m.Count)"
"MOD_CONFIG lines  = $(($f | Where-Object { $_ -match '^\s{4}[A-Za-z_].*\.cfg\|' }).Count)"
"LazyVikings hits  = $(($f | Select-String 'LazyVikings').Count)"
```

Expected, measured against the file on 2026-08-02: `MODS entries = 13`, `MOD_CONFIG lines = 183`, `LazyVikings hits = 0`.

> If `MODS entries` is not 13 or `LazyVikings hits` is not 0, **stop** — the file is not in the state this plan was written against.

- [ ] **Step 2: Add the `MODS` entry**

Insert immediately after the `Recycle_N_Reclaim` line and **before** the `# TrashItems is deliberately NOT here.` comment block — that block documents mods deliberately *not* installed, so an entry below it would be misleading.

Whitespace is insignificant to the installer (`read -r name ver url sha layout`), so alignment is cosmetic — but match the surrounding columns.

```
    # --- LazyVikings: unattended cooking-station automation, NARROWED to that alone -------
    #
    # Fills cooking stations from nearby containers WITHOUT player interaction. This is the
    # one thing ValheimPlus cannot do: V+ implements the interact-driven half
    # (CookingStation_FindCookableItem_Transpiler -> PullCookableItemFromNearbyChests, which
    # DOES work -- press E at a grill and it takes meat from a nearby chest) but has no
    # unattended engine. Its own patch set shows the gap: Smelter has both
    # FindCookableItem_Transpiler AND UpdateSmelter_Patch; CookingStation has only the former.
    # There is no [CookingStation] section in valheim_plus.cfg at all.
    #
    # 🚨 EVERY OTHER STATION TYPE IS PINNED OFF in MOD_CONFIG. This mod can also automate
    # Kilns, Smelters, Windmills, Fermenters, Beehives, SapCollectors, SpinningWheels,
    # EitrRefineries, Stone Ovens and Fireplaces -- all of which ValheimPlus ALREADY does.
    # Enabling any of them puts two mods on the same station. See the MOD_CONFIG block.
    #
    # Does NOT kick clients: RemoveDisconnectedPeerFromVerified and RPC_*_Version are both 0,
    # matching PlantEverything and XPortal, unlike AzuEPI and Recycle_N_Reclaim which have
    # both. It does carry ServerSync, so config still reaches clients.
    #
    # Registers no prefabs, so removal is clean. Patches with Harmony Prefix rather than
    # transpilers, which is why a 2025-10-20 release is still fine against current Valheim.
    LazyVikings                1.2.3    https://thunderstore.io/package/download/blacks7ar/LazyVikings/1.2.3/                        25cc50aeb44be09d08998b937dde671b60f8a420656d5b36cc236c52c8588437  root
```

- [ ] **Step 3: Update the header CLIENT INSTALL note**

Find:

```
  # CLIENT INSTALL: every mod here except PlantEverything must also be on each client.
  # AzuExtendedPlayerInventory, AzuContainerSizes and Recycle_N_Reclaim actively KICK
  # clients that lack them.
  # See README.md for the full client list.
```

Replace with:

```
  # CLIENT INSTALL: every mod here except PlantEverything and LazyVikings must also be on
  # each client. AzuExtendedPlayerInventory, AzuContainerSizes and Recycle_N_Reclaim actively
  # KICK clients that lack them. LazyVikings does not kick, but its automation runs on the
  # ZDO owner, so a player without it may see no auto-cooking -- install it anyway.
  # See README.md for the full client list.
```

- [ ] **Step 4: Append the seventeen `MOD_CONFIG` pins**

Append at the **end** of the `MOD_CONFIG` block scalar, after the Recycle_N_Reclaim pins and before the `install-mods.sh: |` key. Keep the blank line separating the two ConfigMap keys.

```
    #
    # --- LazyVikings: ONLY the two cooking stations are enabled ----------------------------
    #
    # ⚠️ SECTION NAMES ARE "NN- Name" -- zero-padded, NO space before the dash, one space
    # after. This is a THIRD convention in this file: Azumatt uses "2 - Inventory Recycle",
    # ValheimPlus uses bare [Time], this uses "05- Cooking Station". Recovered from literals
    # in the 1.2.3 DLL. A regex written for one convention silently misses the others -- the
    # first recon pass here searched for "N - Name" and found nothing, which read as a clean
    # negative result.
    #
    # 🚨 VALUES ARE On/Off, NOT true/false. Every description in the mod reads "If On, ..."
    # and the setting type is Toggle. This is the same failure that cost two restarts on
    # Recycle_N_Reclaim on 2026-07-31: BepInEx rejects true/false, keeps the mod's own
    # default, and the installer logs a successful [cfg ] line anyway. After applying, ALWAYS:
    #   kubectl logs -n valheim deploy/valheim -c valheim | Select-String "could not be parsed"
    # Empty is the pass.
    #
    # 🚨 THE FOURTEEN "Off" LINES ARE LOAD-BEARING. They are not redundant defaults. Each
    # names a station ValheimPlus ALREADY automates, and turning one On puts two mods on the
    # same station:
    #   03- Beehive        -> V+ [Beehive] autoDeposit
    #   04- Blast Furnace  -> not present here; off for consistency
    #   06- Eitr Refinery  -> V+ [EitrRefinery] autoDeposit/autoFuel
    #   07- Fermenter      -> V+ [Fermenter] autoDeposit/autoFuel
    #   08- Hot Tub        -> not automated here; off for consistency
    #   10- Kiln           -> V+ [Kiln] autoDeposit/autoFuel
    #   11- SapCollector   -> V+ [SapCollector] autoDeposit
    #   12- Smelter        -> V+ [Smelter] autoDeposit/autoFuel
    #   13- Spinning Wheel -> V+ [SpinningWheel] autoDeposit/autoFuel
    #   14- Stone Oven     -> V+ [Oven] autoFuel
    #   15- Windmill       -> V+ [Windmill] autoDeposit/autoFuel
    #   16- Fireplace      -> V+ [FireSource] autoFuel
    #   17- Steel Kiln     -> not present here; off for consistency
    #   18- Steel Slack Tub-> not present here; off for consistency
    # DO NOT "tidy up" these lines.
    #
    # 02- General is deliberately not pinned -- its keys were not enumerated and nothing here
    # depends on them. Per-station detection ranges are left at defaults; adjust as a
    # follow-up if the cooking-station pull radius proves wrong.
    blacks7ar.LazyVikings.cfg|01- ServerSync|Lock Configuration|On
    blacks7ar.LazyVikings.cfg|05- Cooking Station|Enable|On
    blacks7ar.LazyVikings.cfg|09- Iron Cooking Station|Enable|On
    blacks7ar.LazyVikings.cfg|03- Beehive|Enable|Off
    blacks7ar.LazyVikings.cfg|04- Blast Furnace|Enable|Off
    blacks7ar.LazyVikings.cfg|06- Eitr Refinery|Enable|Off
    blacks7ar.LazyVikings.cfg|07- Fermenter|Enable|Off
    blacks7ar.LazyVikings.cfg|08- Hot Tub|Enable|Off
    blacks7ar.LazyVikings.cfg|10- Kiln|Enable|Off
    blacks7ar.LazyVikings.cfg|11- SapCollector|Enable|Off
    blacks7ar.LazyVikings.cfg|12- Smelter|Enable|Off
    blacks7ar.LazyVikings.cfg|13- Spinning Wheel|Enable|Off
    blacks7ar.LazyVikings.cfg|14- Stone Oven|Enable|Off
    blacks7ar.LazyVikings.cfg|15- Windmill|Enable|Off
    blacks7ar.LazyVikings.cfg|16- Fireplace|Enable|Off
    blacks7ar.LazyVikings.cfg|17- Steel Kiln|Enable|Off
    blacks7ar.LazyVikings.cfg|18- Steel Slack Tub|Enable|Off
```

- [ ] **Step 5: Verify the fields parse the way the installer will parse them**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
$line = (Get-Content mods-configmap.yaml | Select-String '^\s{4}LazyVikings\s').Line.Trim()
$p = $line -split '\s+'
"name=$($p[0])  ver=$($p[1])  layout=$($p[4])  fields=$($p.Count)"
"sha  = $($p[3])"
```

Expected exactly: `name=LazyVikings  ver=1.2.3  layout=root  fields=5`, and the sha equal to `25cc50aeb44be09d08998b937dde671b60f8a420656d5b36cc236c52c8588437`. `fields=5` is the important one — a stray space inside a field changes it.

```powershell
Select-String -Path mods-configmap.yaml -Pattern 'blacks7ar\.LazyVikings\.cfg\|' |
  ForEach-Object { $c = ($_.Line.Trim() -split '\|'); "$($c.Count) fields | $($c[1]) | $($c[2]) = $($c[3])" }
```

Expected: seventeen lines, every one starting `4 fields`. Section names contain spaces and a hyphen — that is correct.

- [ ] **Step 6: Verify the On/Off split and the delta**

```powershell
$all = Select-String -Path mods-configmap.yaml -Pattern 'blacks7ar\.LazyVikings\.cfg\|'
"total = $($all.Count)   (expect 17)"
"On    = $(($all | Where-Object { $_.Line -match '\|On$'  }).Count)   (expect 3)"
"Off   = $(($all | Where-Object { $_.Line -match '\|Off$' }).Count)   (expect 14)"
"true/false present (must be 0): $(($all | Where-Object { $_.Line -match '\|(true|false)$' }).Count)"
```

Then re-run Step 1. Expected: `MODS entries = 14` (was 13), `MOD_CONFIG lines = 200` (was 183, +17).

🚨 The `true/false` count must be **0**. That is the negative case for the Toggle trap.

- [ ] **Step 7: Validate against the API server**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
kubectl apply -f mods-configmap.yaml --dry-run=server
```

Expected: `configmap/valheim-mods configured (server dry run)`.

**Do not apply for real yet** — that is Task 3.

- [ ] **Step 8: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/mods-configmap.yaml
git commit -m "Add LazyVikings 1.2.3, narrowed to cooking stations only"
```

---

## Task 2: Update `README.md`

**Files:**
- Modify: `valheim/README.md` — lines ~257, ~272 (table), ~341, ~774, and the per-mod configuration section

**Interfaces:**
- Consumes: the mod name, version and non-kicking status from Task 1.
- Produces: documentation only. Task 4 appends verified in-game results.

- [ ] **Step 1: Confirm the "before" state, and identify the decoy**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
Select-String -Path README.md -Pattern 'Thirteen|13 already present|13 plugins to load|13\.0\.4|LazyVikings'
```

Expected — exactly four hits, no `LazyVikings`:

| Line | Text | Action |
|---|---|---|
| ~257 | `**Thirteen mods are installed**` | → **Fourteen** |
| ~263 | `\| JsonDotNET \| 13.0.4 \|` | 🚨 **DO NOT TOUCH** — version number, not a count |
| ~341 | `13 already present` | → **14** |
| ~774 | ``Expect `13 plugins to load` `` | → **14** |

🚨 **The `JsonDotNET 13.0.4` row is a decoy.** A blind find-and-replace of `13` corrupts a dependency version that the README elsewhere calls out as the one people skip. Change only the three counts.

- [ ] **Step 2: Update the mod count**

Change `**Thirteen mods are installed**` to `**Fourteen mods are installed**`.

- [ ] **Step 3: Add the table row**

Insert between the `Recycle_N_Reclaim` row and the `PlantEverything` row — client-required mods first, the optional ones last:

```markdown
| LazyVikings | 1.2.3 | recommended (does not kick; automation runs on the ZDO owner) |
```

- [ ] **Step 4: Update the idempotence note**

Search for the literal `13 already present` and change only the digits to `14`. The line wraps in the source; do not reflow.

- [ ] **Step 5: Update the chainloader expectation**

Search for `13 plugins to load` and change only the digits to `14`. Change nothing else on that line.

- [ ] **Step 6: Add a per-mod configuration section**

Append to the `### Per-mod configuration` section:

```markdown
#### LazyVikings

Seventeen keys are pinned. Section names are `NN- Name` — **zero-padded, no space before the
dash**, e.g. `05- Cooking Station`. That is a third convention in this file, alongside
Azumatt's `2 - Inventory Recycle` and ValheimPlus's bare `[Time]`.

🚨 **Values are `On`/`Off`, not `true`/`false`** — Toggle enums, same as Recycle_N_Reclaim.
See "When a pin does not take" above.

**Only two stations are enabled:** `05- Cooking Station` and `09- Iron Cooking Station`, each
`Enable = On`. Plus `01- ServerSync | Lock Configuration | On`.

🚨 **The other fourteen station sections are pinned `Enable = Off`, and those lines are
load-bearing.** LazyVikings can also automate Kilns, Smelters, Windmills, Fermenters,
Beehives, SapCollectors, SpinningWheels, EitrRefineries, Stone Ovens and Fireplaces — all of
which **ValheimPlus already does**. Turning any of them on puts two mods on the same station.
Do not remove them as redundant.

**Why this mod exists here at all.** ValheimPlus already pulls from chests at a cooking
station — press E at a grill with meat in a nearby chest and it works. What V+ lacks is the
*unattended* half. Its own patches show the asymmetry: `Smelter` has both
`FindCookableItem_Transpiler` **and** `UpdateSmelter_Patch`, while `CookingStation` has only
the former, and there is no `[CookingStation]` section in `valheim_plus.cfg` at all.
LazyVikings supplies exactly that missing engine and nothing else.

⚠️ Automation runs on the **ZDO owner**, so a player without the mod standing near a cooking
station may see no auto-fill while a player with it does — the same caveat as PlantEverything.
It does not kick, so installing it is recommended rather than enforced.
```

- [ ] **Step 7: Confirm every edit landed and the decoy survived**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
"--- must all be present ---"
Select-String -Path README.md -Pattern 'Fourteen mods|14 already present|14 plugins to load|LazyVikings'
"--- must be EMPTY (stale counts) ---"
Select-String -Path README.md -Pattern 'Thirteen mods|13 already present|13 plugins to load'
"--- decoy must STILL be present ---"
Select-String -Path README.md -Pattern '13\.0\.4'
```

The middle command returning nothing is the negative case. The third **must still return the `JsonDotNET 13.0.4` row** — if it is gone, a blind replace corrupted it; restore it.

- [ ] **Step 8: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/README.md
git commit -m "Document LazyVikings and why it is narrowed to cooking stations"
```

---

## Task 3: Apply, rollout and verify the config

**Files:**
- Modify: none. Acts on the live cluster.

**Interfaces:**
- Consumes: the committed `mods-configmap.yaml` from Task 1.
- Produces: a running pod with 14 plugin directories and a mod-written `blacks7ar.LazyVikings.cfg` whose seventeen pinned keys hold their intended values. Task 4 depends on this.

🚨 **Opens a ~3-5 minute outage.** Do not start without the owner's go-ahead in the same session. No coordinated client window is needed — this mod does not kick.

- [ ] **Step 1: Confirm nobody is connected**

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --tail=800 | Select-String "Connections \d+" | Select-Object -Last 1
kubectl logs -n valheim deploy/valheim -c valheim --since=5m | Select-String "Got connection|Closing socket"
```

⚠️ The `Connections N` counter is emitted every 10 minutes and is **up to 10 minutes stale**. The socket lines are current — trust them over the counter. A counter reading `1` with a later `Closing socket` and no subsequent `Got connection` means the server is empty.

- [ ] **Step 2: Capture the "before" state on the PVC**

The negative case for this task.

```powershell
$s = @'
echo "--- plugin count ---"; ls -1 /config/bepinex/plugins | wc -l
echo "--- LazyVikings staged? ---"; ls -1d /config/bepinex/plugins/LazyVikings 2>&1
echo "--- cfg present? ---"; ls -1 /config/bepinex/blacks7ar.LazyVikings.cfg 2>&1
'@ -replace "`r`n", "`n"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected: `13`, and **`No such file or directory`** for both the plugin dir and the cfg. Those two errors are the point.

- [ ] **Step 3: Apply and restart**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
kubectl apply -f mods-configmap.yaml
kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status  deploy/valheim -n valheim --timeout=600s
```

The apply must say `configured`. The restart is required because this is a **ConfigMap** edit — nothing in the pod spec changed, so the Deployment will not restart on its own.

- [ ] **Step 4: THE PARSE CHECK — run this before believing anything else**

```powershell
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "could not be parsed"
```

**Empty is the pass.**

🚨 This single check catches both things the design *inferred* rather than observed: a wrong `Enable` key name, and a wrong value type. Any output here names a pin that was **discarded** while the installer logged `[cfg ]` success for it.

If it is not empty:
1. Read the real key names: `kubectl exec -n valheim deploy/valheim -c valheim -- head -60 /config/bepinex/blacks7ar.LazyVikings.cfg`
2. Correct the seventeen `MOD_CONFIG` lines to the observed strings and setting types.
3. Re-run Task 1 Steps 5-8, then this task from Step 3.
4. 🚨 **Treat the server as double-automating until fixed** — a rejected `Enable = Off` means that station fell back to the mod's default, which may be on. Check the smelter before letting anyone play.

- [ ] **Step 5: Verify the installer log**

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods | Select-String "LazyVikings|done:|pruning|FAIL"
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "plugins to load|Loading \[LazyVikings|Chainloader startup complete"
```

| Check | Expected |
|---|---|
| Fetch | `[ok   ] LazyVikings 1.2.3` |
| Summary | `=== done: 1 installed, 13 already present ===` |
| Prune | `pruning mods no longer in MODS (0 to remove)` |
| Chainloader | `14 plugins to load`, `Loading [LazyVikings 1.2.3]`, `Chainloader startup complete` |

🚨 If the prune reports anything other than `0 to remove`, stop. Nothing here removes a mod.

- [ ] **Step 6: The phantom-cfg test and the fourteen Off values**

⚠️ Run only **after** `Chainloader startup complete` appears in Step 5. The initContainer writes the config before the game starts, so reading it earlier shows only what `set_cfg` wrote, which looks identical to a wrong-GUID phantom.

```powershell
$s = @'
F=/config/bepinex/blacks7ar.LazyVikings.cfg
echo "=== authorship: mod-written has ## headers and many keys ==="
echo "## headers = $(grep -c '^##' $F)   (0 with exactly 17 keys => set_cfg invented it)"
echo "keys       = $(grep -cE '^[A-Za-z].*=' $F)"
echo "sections   = $(grep -c '^\[' $F)   (expect 18)"
echo
echo "=== every Enable value, by section ==="
awk '/^\[/{s=substr($0,2,length($0)-2)} /^Enable *=/{gsub(/^[ \t]+|[ \t]+$/,""); print "  ["s"] "$0}' $F
echo
echo "=== Lock Configuration ==="
awk '/^\[/{s=substr($0,2,length($0)-2)} /^Lock Configuration *=/{print "  ["s"] "$0}' $F
'@ -replace "`r`n", "`n"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected: `## headers` well above 0, `keys` far more than 17, `sections = 18`; `Enable = On` for exactly `05- Cooking Station` and `09- Iron Cooking Station`; **`Enable = Off` for all fourteen others**; `Lock Configuration = On`.

🚨 `## headers = 0` **and** `keys = 17` means `set_cfg` invented the file — wrong GUID, all pins inert. Stop and correct the filename.

- [ ] **Step 7: No commit**

Nothing in the repo changed.

---

## Task 4: In-game verification and recording

**Files:**
- Modify: `valheim/mods-configmap.yaml` (verification note), `valheim/README.md` (verified results)

**Interfaces:**
- Consumes: a running server with verified-live pins from Task 3.
- Produces: the recorded verification. Terminal task.

Requires a human in-game. **The containment checks matter more than the feature check.**

- [ ] **Step 1: Positive — auto-cook works**

Place raw meat in a chest beside a cooking station. Walk away, or simply wait without interacting.

Expected: the meat is added to the grill and cooked **unattended**, with no key press.

If nothing happens, check the per-station detection range — it is unpinned and at the mod's default, and the chest may simply be out of reach. Move the chest adjacent and retry before concluding the mod is broken.

- [ ] **Step 2: Negative — the smelter is untouched**

Put ore and coal in a chest near a smelter and watch it work.

Expected: **exactly the behaviour as before this change.** ValheimPlus still owns it.

🚨 This is the check the whole design rests on. If the smelter behaves differently — fills faster, drains two chests, double-feeds — then a `14- …|Enable|Off` pin did not take, and Task 3 Step 4's parse check should be re-run immediately.

- [ ] **Step 3: Negative — kiln, windmill and fermenter unchanged**

Spot-check each. Expected: unchanged from before.

- [ ] **Step 4: Client-consistency check**

Have one player **with** the mod and one **without** stand near a cooking station.

Expected: note whether both see auto-cooking. Automation runs on the ZDO owner, so they may differ — record what actually happens rather than assuming they agree. This is the PlantEverything caveat and it has never been verified for that mod either.

- [ ] **Step 5: Record the results**

Append to the LazyVikings comment block in `valheim/mods-configmap.yaml`, following the style of the `[Wagon]` and Recycle_N_Reclaim verification notes — what was checked, on what date, and specifically that the containment cases were seen unchanged:

```
    # ✅ VERIFIED IN-GAME <date of the session, YYYY-MM-DD>: raw meat in a chest beside a
    # cooking station was added and cooked with NO player interaction. Smelter, kiln, windmill
    # and fermenter all behaved exactly as before -- ValheimPlus still owns them and the
    # fourteen Off pins held. The station checks are the NEGATIVE cases and are the ones that
    # matter: a working grill only proves the feature, an unchanged smelter proves the
    # containment.
    # Client consistency: <record what the with-mod and without-mod players each saw>.
```

Add the equivalent to the `#### LazyVikings` section of `valheim/README.md`.

If any check produced an unexpected result, record **that** instead. A recorded failure is worth more than an omission.

- [ ] **Step 6: Rollback path, if verification failed**

Delete the `MODS` line and the seventeen `MOD_CONFIG` lines, apply, restart. One mod, so the `>2` bulk-prune breaker is untouched and `PRUNE_ALLOW_BULK` is **not** needed.

Clean — no prefab registration, so nothing is orphaned in the world save. ValheimPlus needs no restoration because it was never changed. Residual: the orphaned `blacks7ar.LazyVikings.cfg` stays on the PVC.

Also revert the Task 2 README edits and the Task 1 Step 3 header note.

- [ ] **Step 7: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/mods-configmap.yaml valheim/README.md
git commit -m "Record the in-game verification for LazyVikings"
```

---

## Spec coverage

| Spec section | Covered by |
|---|---|
| §1 goal, non-goals | Task 1 Steps 2, 4 |
| §2 why the request changed shape | Task 1 Step 2 comment; Task 2 Step 6 |
| §3 artifact, checksum, layout, no-kick | Task 1 Steps 2, 5; Task 3 Step 5 |
| §4 `NN- Name` sections, `Enable` key, On/Off | Task 1 Steps 4, 6; Task 3 Steps 4, 6 |
| §5 all five decisions | Task 1 Step 4 (pins + rationale) |
| §6.1 MODS line | Task 1 Step 2 |
| §6.2 seventeen pins, load-bearing Off lines | Task 1 Steps 4, 6 |
| §6.3 files touched, three README counts | Task 2 Steps 1-5 |
| §7.1 pre-flight | Task 3 Steps 1-2 |
| §7.2 apply | Task 3 Step 3 |
| §7.3 parse check first, phantom-cfg, all values | Task 3 Steps 4-6 |
| §7.4 in-game, negative cases | Task 4 Steps 1-4 |
| §8 client install | Task 1 Step 3; Task 2 Step 6; Task 4 Step 4 |
| §9 rollback | Task 4 Step 6 |
| §10 risks | Task 3 Step 4 (fallback); Task 4 Steps 2-3 |

---

## Correction — 2026-08-02, after Task 1 review

Task 1 completed and its comment block for the `MOD_CONFIG` pins was **wrong** in one row.

**Step 4's comment block above groups `04- Blast Furnace` with the genuinely-absent rows**
(`08- Hot Tub`, `17- Steel Kiln`, `18- Steel Slack Tub`) as "not present here; off for
consistency." That is false. Checked against the live ValheimPlus config: V+ names the Blast
Furnace `[Furnace]`, not the more intuitive `[BlastFurnace]`, and that section is
`enabled = true` with both `autoDeposit` and `autoFuel` on. `04- Blast Furnace` is one of the
eleven stations V+ already automates, not one of the three that are off merely for
consistency — enabling it would create exactly the double-automation the pin block exists to
prevent.

Corrected split: **eleven** rows already owned by ValheimPlus, **three** off for consistency
(`08- Hot Tub` — V+ `[HotTub]` exists but is `enabled = false`; `17- Steel Kiln` and
`18- Steel Slack Tub` — OdinSteelWorks pieces, not installed here). Fourteen `Off` pins
either way — none of the seventeen pin *lines* changed, only the comment block explaining
them.

**Step 4's code block above still shows the original wrong comment text.** It is left as
written because the task is complete and this repo appends corrections rather than rewriting
history — but do not copy that table. `valheim/mods-configmap.yaml` is the source of truth
and has been corrected there directly. The matching correction is recorded in
`docs/superpowers/specs/2026-08-02-lazyvikings-cooking-station-design.md` §11.

**Why Task 1's own verification (Steps 5-7) could not have caught this**: all three are
pin-value and parse checks — field counts, the On/Off/true-false split, and a server-side
dry run. None of them evaluate whether a comment's prose claim about what ValheimPlus owns
is factually correct; that requires cross-checking the live V+ config, which was outside
this task's scope. The review step that follows implementation is what caught it.
