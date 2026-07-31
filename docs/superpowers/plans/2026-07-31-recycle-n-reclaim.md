# Recycle_N_Reclaim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install `Azumatt-Recycle_N_Reclaim` 1.4.0 as the thirteenth server-side BepInEx mod on the Valheim server, with ten config pins that keep EpicLoot's economy and biome progression intact.

**Architecture:** No new mechanism. One line is added to the `MODS` block and ten lines to the `MOD_CONFIG` block of `valheim/mods-configmap.yaml`; the existing `fetch-mods` initContainer downloads the pinned artifact, verifies its SHA256, extracts it to the `valheim-data` PVC, and applies the config pins on every boot. Because the mod kicks clients that lack it, the apply is a coordinated window rather than a background change.

**Tech Stack:** Kubernetes (Talos), `kubectl`, PowerShell, BepInEx 5.4.2333, Thunderstore, Longhorn.

**Spec:** `docs/superpowers/specs/2026-07-31-recycle-n-reclaim-design.md`

## Global Constraints

- Repo root is `C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal`. **`cd valheim/` before any `kubectl apply`** — relative paths from the repo root silently no-op.
- `KUBECONFIG` is set in `.claude/settings.local.json`. **Never inline `$env:KUBECONFIG = …`** in a command: a command starting with an assignment never prefix-matches a `kubectl *` permission rule, so every call prompts.
- `kubectl apply` reporting `unchanged` is a **silent failure**, not a success. It must report `configured`.
- Deliver multi-line shell scripts to containers **base64-encoded**. Quoting does not survive PowerShell → `kubectl exec` → `sh`.
- `kubectl` output is a **string array** in PowerShell. `-join "`n"` before treating it as text; `.Length` is the line count, not a character count.
- The Deployment uses `strategy: Recreate` with a single replica, so **every restart is an outage**. `terminationGracePeriodSeconds: 120` — Valheim needs ~2 minutes to flush the world.
- After editing a config file in place, **re-read it and confirm section/key counts**. An appended duplicate is the signature of a failed match.
- **Verify the negative case.** A check only ever observed passing has not been verified.
- Commits go directly to `main`; no PR flow. Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it.

### Exact values (copied verbatim from the spec — do not retype from memory)

| Field | Value |
|---|---|
| Package | `Azumatt-Recycle_N_Reclaim` |
| Version | `1.4.0` |
| URL | `https://thunderstore.io/package/download/Azumatt/Recycle_N_Reclaim/1.4.0/` |
| sha256 | `919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16` |
| Size | 412,650 bytes |
| Layout | `root` |
| Config file | `Azumatt.Recycle_N_Reclaim.cfg` |
| Sections | `1 - General`, `2 - Inventory Recycle`, `3 - Reclaiming`, `4 - UI` |

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `valheim/mods-configmap.yaml` | Declares the mod (`MODS`) and its config pins (`MOD_CONFIG`); header note lists which mods kick clients | 1 |
| `valheim/README.md` | Operator-facing mod inventory, client-install requirements, per-mod config record | 2 |
| *(live cluster)* | Apply, rollout, installer-level verification | 3 |
| *(live cluster)* | Config-file verification: phantom-cfg test, value check, count stability | 4 |
| *(in-game)* | Behavioural verification of the four guards and the AzuEPI interaction; record results | 5 |

Tasks 1 and 2 are pure repo edits and safe to do any time. Task 3 opens the coordinated outage window. Tasks 4 and 5 must follow it in order.

---

## Task 1: Declare the mod in `mods-configmap.yaml`

**Files:**
- Modify: `valheim/mods-configmap.yaml` — header note (~line 44-46), `MODS` block (after line 69), `MOD_CONFIG` block (append after line 578)

**Interfaces:**
- Consumes: nothing — first task.
- Produces: the `MODS` entry named `Recycle_N_Reclaim` (this exact string becomes the plugin directory name `/config/bepinex/plugins/Recycle_N_Reclaim/` and the `.mod-state` marker filename, and is what the prune's `is_kept` matches against); and ten `MOD_CONFIG` lines targeting `Azumatt.Recycle_N_Reclaim.cfg`. Tasks 3 and 4 assert on both.

- [ ] **Step 1: Capture the "before" counts**

This is the failing-test equivalent: these numbers must be exactly these values *before* the edit, and exactly +1 / +10 after. If the before-counts don't match, stop — the file is not in the state this plan was written against.

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
$f = Get-Content mods-configmap.yaml
# Find the block boundaries rather than hardcoding line numbers — the file grows.
$start = ($f | Select-String -Pattern '^  MODS: \|$').LineNumber
$end   = ($f | Select-String -Pattern '^  MOD_CONFIG: \|$').LineNumber
$mods  = $f[$start..($end-2)] | Where-Object { $_ -match '^\s{4}\S' -and $_ -notmatch '^\s*#' }
"MODS entries      = $($mods.Count)"
$mods | ForEach-Object { "   " + ($_.Trim() -split '\s+')[0] }
"MOD_CONFIG lines  = $(($f | Where-Object { $_ -match '^\s{4}[A-Za-z_].*\.cfg\|' }).Count)"
"Recycle mentions  = $(($f | Select-String 'Recycle_N_Reclaim').Count)"
```

Expected: `MODS entries = 12`, `MOD_CONFIG lines = 170`, `Recycle mentions = 0`, and the twelve
names listed as `Jotunn, JsonDotNET, EpicLoot, AzuExtendedPlayerInventory, Warfare,
PlantEverything, AzuContainerSizes, ValheimPlus, Armory, OdinsFoodBarrels, XPortal, OdinHorse`.

> These three numbers were measured against the file on 2026-07-31. If `MOD_CONFIG lines`
> differs, the block has grown since — record what you see and assert `before + 10` in Step 6.
> `MODS entries = 12` and `Recycle mentions = 0` must match exactly; if they do not, stop, because
> the file is not in the state this plan was written against.

- [ ] **Step 2: Add the `MODS` entry**

Insert immediately after the `OdinHorse` line (currently line 69) and **before** the `# TrashItems is deliberately NOT here.` comment block — that block documents mods that are *not* installed, so the new entry must go above it.

Field widths in this block are: 4-space indent, name padded to 26, version padded to 8, then the URL, then the sha, then the layout. Whitespace is insignificant to the installer (it parses with `read -r name ver url sha layout`), so alignment is cosmetic — but match it.

```
    # Recycle_N_Reclaim: un-craft items back into components at a crafting station
    # ([3 - Reclaiming]) and discard items from the inventory screen
    # ([2 - Inventory Recycle]). Both halves are deliberately enabled -- see MOD_CONFIG.
    #
    # 🚨 KICKS CLIENTS THAT LACK IT. Its own README: "Version checks with itself. If
    # installed on the server, it will kick clients who do not have it installed."
    # Confirmed statically too: RemoveDisconnectedPeerFromVerified and RPC_*_Version are
    # present, matching AzuEPI and AzuContainerSizes and absent from PlantEverything and
    # XPortal. Note that MinimumRequiredVersion and DisconnectClient are NOT discriminating
    # -- PlantEverything has both and does not kick. Use the other two markers.
    #
    # Registers NO prefabs (AssetBundle/LoadAsset/PrefabManager/CustomItem/CustomPrefab/
    # ItemManager all zero, no bundled assets), so unlike EpicLoot/Warfare/Armory/
    # OdinsFoodBarrels/OdinHorse this one is free to remove without orphaning ZDOs.
    Recycle_N_Reclaim          1.4.0    https://thunderstore.io/package/download/Azumatt/Recycle_N_Reclaim/1.4.0/                    919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16  root
```

- [ ] **Step 3: Update the header CLIENT INSTALL note**

Find this text near line 44-46:

```
  # CLIENT INSTALL: every mod here except PlantEverything must also be on each client.
  # AzuExtendedPlayerInventory and AzuContainerSizes actively KICK clients that lack them.
  # See README.md for the full client list.
```

Replace with:

```
  # CLIENT INSTALL: every mod here except PlantEverything must also be on each client.
  # AzuExtendedPlayerInventory, AzuContainerSizes and Recycle_N_Reclaim actively KICK
  # clients that lack them.
  # See README.md for the full client list.
```

- [ ] **Step 4: Append the `MOD_CONFIG` block**

Append at the **end** of the `MOD_CONFIG` block — after the PlantEverything trailing note (currently ending line 578) and before the `install-mods.sh: |` key (line 580). Keep the blank line that separates the two ConfigMap keys.

```
    #
    # Recycle_N_Reclaim. Section names are NUMBERED -- "1 - General", "2 - Inventory
    # Recycle", "3 - Reclaiming", "4 - UI" -- NOT the bare names the Thunderstore page
    # lists. Verified against literals in the 1.4.0 DLL. Pinning the bare names would
    # append four duplicate sections that the mod ignores, while logging four successful
    # [cfg ] lines.
    #
    # ⚠️ ReturnEnchantedResources appears TWICE on purpose. The key genuinely exists in
    # both [2 - Inventory Recycle] and [3 - Reclaiming], governing the discard path and the
    # reclaim path independently. Deleting either line as a duplicate reopens one of them.
    #
    # Lock Configuration = true: clients cannot override server config locally, matching
    # this file's rule that MOD_CONFIG is the source of truth and in-game edits are
    # reverted on the next boot.
    #
    # ReturnEnchantedResources = false (both): EpicLoot's Sacrifice at the Enchanter stays
    # the ONLY conversion path for magic gear, at EpicLoot's own balance. The mod's README
    # confirms the overlap is real -- "If on and Epic Loot or Jewelcrafting is installed,
    # discarding an item in the inventory will return resources for Epic Loot".
    #
    # AllowRecyclingUnknownRecipes / ReturnUnknownResources = false: EpicLoot, Warfare and
    # Armory all add loot drops. Without these, a lucky Meadows drop converts into
    # out-of-tier materials and skips a biome.
    #
    # PreventZeroResourceYields / UnstackableItemsAlwaysReturnAtLeastOneResource = true:
    # at RecyclingRate 0.5 a 1-unit item yields 0.5 -> nothing. Without these, recycling
    # cheap gear silently consumes it for no return.
    #
    # RecyclingRate is pinned at the mod's own default so the value is recorded as a
    # decision rather than left to drift, the same reason baseMegingjordBuff is pinned at
    # its vanilla 150 above.
    #
    # NOT pinned, deliberately: RequireExactCraftingStationForRecycling (default on, the
    # author's note says it keeps behaviour close to vanilla); all keybinds (client-side
    # preference); EnableExperimentalCraftingTabUI (default on, and it appears to BE the
    # Reclaim tab -- ⚠️ first thing to toggle if the crafting UI misbehaves).
    #
    # ⚠️ NOT MANAGEABLE HERE: the mod also reads Azumatt.Recycle_N_Reclaim_ExcludeLists.yml,
    # whose recycleRates block overrides RecyclingRate per item. MOD_CONFIG is INI
    # key=value only and cannot manage a YAML side-file, so the global 0.5 applies to
    # everything. Per-item rates would need a new mechanism in install-mods.sh.
    Azumatt.Recycle_N_Reclaim.cfg|1 - General|Lock Configuration|true
    Azumatt.Recycle_N_Reclaim.cfg|2 - Inventory Recycle|Enabled|true
    Azumatt.Recycle_N_Reclaim.cfg|2 - Inventory Recycle|Lock to Admin|false
    Azumatt.Recycle_N_Reclaim.cfg|2 - Inventory Recycle|ReturnEnchantedResources|false
    Azumatt.Recycle_N_Reclaim.cfg|2 - Inventory Recycle|ReturnUnknownResources|false
    Azumatt.Recycle_N_Reclaim.cfg|3 - Reclaiming|RecyclingRate|0.5
    Azumatt.Recycle_N_Reclaim.cfg|3 - Reclaiming|ReturnEnchantedResources|false
    Azumatt.Recycle_N_Reclaim.cfg|3 - Reclaiming|AllowRecyclingUnknownRecipes|false
    Azumatt.Recycle_N_Reclaim.cfg|3 - Reclaiming|PreventZeroResourceYields|true
    Azumatt.Recycle_N_Reclaim.cfg|3 - Reclaiming|UnstackableItemsAlwaysReturnAtLeastOneResource|true
```

- [ ] **Step 5: Verify the fields parse the way the installer will parse them**

The installer reads `MODS` with `read -r name ver url sha layout` and `MOD_CONFIG` with `IFS='|' read -r file section key value`. Reproduce both parses locally so a mis-typed field is caught before it reaches the cluster.

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
$line = (Get-Content mods-configmap.yaml | Select-String '^\s{4}Recycle_N_Reclaim\s').Line.Trim()
$p = $line -split '\s+'
"name   = $($p[0])"
"ver    = $($p[1])"
"url    = $($p[2])"
"sha    = $($p[3])"
"layout = $($p[4])"
"fields = $($p.Count)"
```

Expected, exactly:
```
name   = Recycle_N_Reclaim
ver    = 1.4.0
url    = https://thunderstore.io/package/download/Azumatt/Recycle_N_Reclaim/1.4.0/
sha    = 919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16
layout = root
fields = 5
```

`fields = 5` is the important one — a stray space inside a field, or a missing one, changes it.

```powershell
Get-Content mods-configmap.yaml |
  Select-String 'Azumatt\.Recycle_N_Reclaim\.cfg\|' |
  ForEach-Object { $c = ($_.Line.Trim() -split '\|'); "$($c.Count) fields | $($c[1]) | $($c[2]) = $($c[3])" }
```

Expected: ten lines, every one starting `4 fields`, with sections reading exactly `1 - General`, `2 - Inventory Recycle` (×4), `3 - Reclaiming` (×5).

- [ ] **Step 6: Confirm the counts moved by exactly the expected delta**

Re-run the Step 1 block. Expected: `MODS entries = 13` (was 12), `MOD_CONFIG lines = 180` (was 170,
+10), and `Recycle_N_Reclaim` now appearing in the names list.

An unchanged count means the insert landed inside a comment block or outside the block scalar. A count that moved by more than the delta means something was duplicated.

- [ ] **Step 7: Validate against the API server**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
kubectl apply -f mods-configmap.yaml --dry-run=server
```

Expected: `configmap/valheim-mods configured` (with `--dry-run=server` appended). A YAML parse error surfaces here.

**Do not apply for real yet** — that is Task 3, and it opens the outage window.

- [ ] **Step 8: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/mods-configmap.yaml
git commit -m "Add Recycle_N_Reclaim 1.4.0 as the thirteenth mod"
```

---

## Task 2: Update `README.md`

**Files:**
- Modify: `valheim/README.md` — line ~257, the mod table (~260-273), the 🚨 vanilla-clients block (~281-285), the idempotence note (~318-319), and the "Per-mod configuration" section (~571)

**Interfaces:**
- Consumes: the mod name, version and client-requirement status established in Task 1.
- Produces: documentation only. Task 5 appends verified in-game results to the section created in Step 5 below.

- [ ] **Step 1: Confirm the "before" state**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
Select-String -Path README.md -Pattern 'Twelve mods|12 already present|Recycle_N_Reclaim|each run a version check'
```

Expected: a hit for `**Twelve mods**`, a hit for `12 already present`, a hit for `each run a version check`, and **no** hit for `Recycle_N_Reclaim`.

- [ ] **Step 2: Update the mod count**

Change `**Twelve mods** are installed` to `**Thirteen mods** are installed`.

- [ ] **Step 3: Add the table row**

Insert between the `OdinHorse` row and the `PlantEverything` row — required mods first, the one optional mod stays last:

```markdown
| Recycle_N_Reclaim | 1.4.0 | **required — kicks clients without it** |
```

- [ ] **Step 4: Update the 🚨 vanilla-clients block**

Find:

```
🚨 **Vanilla clients can no longer join.** AzuExtendedPlayerInventory *and* AzuContainerSizes each
run a version check that kicks clients without them, and EpicLoot and Warfare need client-side
assets.
```

Replace the first sentence so all three kicking mods are named:

```
🚨 **Vanilla clients can no longer join.** AzuExtendedPlayerInventory, AzuContainerSizes *and*
Recycle_N_Reclaim each run a version check that kicks clients without them, and EpicLoot and
Warfare need client-side assets.
```

Leave the rest of that paragraph unchanged.

- [ ] **Step 5: Update the idempotence note**

Change `re-running the installer reports `0 installed,\n12 already present`` to read `13 already present`. The line wraps in the source — search for `12 already present` and change only the number.

- [ ] **Step 6: Add a per-mod configuration entry**

Append to the `### Per-mod configuration` section:

```markdown
#### Recycle_N_Reclaim

Ten keys are pinned in `MOD_CONFIG`. Section names are **numbered** — `1 - General`,
`2 - Inventory Recycle`, `3 - Reclaiming`, `4 - UI` — not the bare names the Thunderstore
page lists. Pinning the bare names appends duplicate sections that the mod ignores, while
logging success.

| Setting | Value | Why |
|---|---|---|
| `[3 - Reclaiming] RecyclingRate` | `0.5` | Mod default, pinned so it is a recorded decision rather than drift |
| `ReturnEnchantedResources` (**both** sections) | `false` | EpicLoot's Sacrifice stays the only conversion path for magic gear |
| `AllowRecyclingUnknownRecipes`, `ReturnUnknownResources` | `false` | Three mods here add loot drops; without this a lucky drop skips a biome in materials |
| `PreventZeroResourceYields`, `UnstackableItemsAlwaysReturnAtLeastOneResource` | `true` | At 50%, a 1-unit item yields 0.5 → nothing, silently eating cheap gear |
| `[1 - General] Lock Configuration` | `true` | Clients cannot override server config locally |
| `[2 - Inventory Recycle] Enabled` | `true` | Both halves of the mod are wanted |

⚠️ **`ReturnEnchantedResources` is pinned twice on purpose.** It exists in both
`[2 - Inventory Recycle]` and `[3 - Reclaiming]`, covering the discard path and the reclaim
path independently. Deleting either as a duplicate reopens one of them.

⚠️ **Per-item recycle rates are not achievable.** The mod reads
`Azumatt.Recycle_N_Reclaim_ExcludeLists.yml`, whose `recycleRates` block overrides the
global rate per item. `MOD_CONFIG` is INI `key = value` only and cannot manage a YAML
side-file, so the global `0.5` applies to everything recyclable. Adding per-item rates
means a new mechanism in `install-mods.sh`.

If the crafting UI misbehaves, toggle `[4 - UI] EnableExperimentalCraftingTabUI` first — it
ships enabled and appears to *be* the Reclaim tab. If the *inventory* screen misbehaves,
disable `[2 - Inventory Recycle] Enabled`: that drops the half that contends with
AzuExtendedPlayerInventory and keeps the Reclaim tab.
```

- [ ] **Step 7: Confirm every edit landed**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
Select-String -Path README.md -Pattern 'Thirteen mods|13 already present|Recycle_N_Reclaim'
Select-String -Path README.md -Pattern 'Twelve mods|12 already present'
```

Expected: the first command hits `Thirteen mods`, `13 already present`, and several `Recycle_N_Reclaim` lines. The second command returns **nothing** — that is the negative case, proving no stale count survived.

- [ ] **Step 8: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/README.md
git commit -m "Document Recycle_N_Reclaim as a client-required mod"
```

---

## Task 3: Coordinated apply and rollout

**Files:**
- Modify: none. This task acts on the live cluster only.

**Interfaces:**
- Consumes: the committed `mods-configmap.yaml` from Task 1.
- Produces: a running pod with 13 plugin directories under `/config/bepinex/plugins/` and a `.mod-state` marker at `/config/bepinex/.mod-state/Recycle_N_Reclaim` containing `1.4.0 919794da…`. Task 4 asserts on the generated config file.

🚨 **This task opens an outage window and will kick any connected player who has not installed the mod.** Do not start it without the owner's go-ahead in the same session.

- [ ] **Step 1: Confirm nobody is connected**

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --tail=600 | Select-String "Connections \d+" | Select-Object -Last 1
```

Expected: `Connections 0`.

⚠️ This line is emitted every 10 minutes, so it is **up to 10 minutes stale**. A `0` seen right after someone quits is real; a `2` may already be false. Announce the window regardless of what this says — do not treat it as authoritative on its own.

- [ ] **Step 2: Confirm every player has the mod installed client-side**

Each player adds `Azumatt-Recycle_N_Reclaim-1.4.0` in r2modman **before** the apply. Get explicit confirmation from the owner that this is done.

This ordering covers both directions of mismatch: an updated client joining the not-yet-updated server, and an un-updated client joining the updated server.

- [ ] **Step 3: Capture the "before" state on the PVC**

The negative case for this task. The mod must be demonstrably absent first.

```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(@'
echo "--- staged plugins ---"; ls -1 /config/bepinex/plugins | sort
echo "--- count ---"; ls -1 /config/bepinex/plugins | wc -l
echo "--- marker present? ---"; ls -1 /config/bepinex/.mod-state/Recycle_N_Reclaim 2>&1
echo "--- cfg present? ---"; ls -1 /config/bepinex/Azumatt.Recycle_N_Reclaim.cfg 2>&1
'@ -replace "`r`n", "`n"))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected: 12 plugin directories, no `Recycle_N_Reclaim` among them, and **`No such file or directory`** for both the marker and the cfg. Those two errors are the point — they are what Step 7 proves changed.

- [ ] **Step 4: Optional — take a Longhorn snapshot of `valheim-data`**

Not required: the spec established the mod registers no prefabs, so there are no ZDOs to orphan. It is one manifest and this is a live world, so take it unless the owner declines.

```powershell
$pv = kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'
@"
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: pre-recycle-n-reclaim
  namespace: longhorn-system
spec:
  volume: $pv
  createSnapshot: true
"@ | Set-Content snapshot-pre-rnr.yaml
kubectl apply -f snapshot-pre-rnr.yaml
```

Delete `snapshot-pre-rnr.yaml` afterwards — it is a one-shot CR, not a tracked manifest.

- [ ] **Step 5: Apply**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim
kubectl apply -f mods-configmap.yaml
```

Expected: `configmap/valheim-mods configured`.

🚨 `unchanged` means the apply did nothing — almost always the wrong working directory. Stop and fix it; do not restart on top of an unapplied ConfigMap.

- [ ] **Step 6: Restart and wait**

```powershell
kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status  deploy/valheim -n valheim --timeout=600s
```

The restart is required because this is a **ConfigMap** edit — nothing about the pod spec changed, so the Deployment will not restart on its own. (Conversely: never add `rollout restart` after a *Deployment* apply — that starts a second Recreate cycle racing the first.)

Expect roughly 2-3 minutes: `terminationGracePeriodSeconds: 120` for the world flush, then the init container, then startup.

- [ ] **Step 7: Verify the installer log**

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods
```

Expected, all four:

| Line | Expected |
|---|---|
| Fetch | `[ok   ] Recycle_N_Reclaim 1.4.0` |
| Summary | `=== done: 1 installed, 12 already present ===` |
| Prune | `pruning mods no longer in MODS (0 to remove)` |
| Closing `ls -1` | 13 directories, including `Recycle_N_Reclaim` |

🚨 If the log shows `[FAIL ] Recycle_N_Reclaim checksum mismatch`, the pod will not start — this is deliberate. Do not "fix" it by editing the sha to match what was downloaded. Re-derive the checksum from a fresh download and confirm it equals `919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16`; if it does not, the artifact changed upstream and that needs a human decision, not a new pin.

🚨 If the prune line reports anything other than `0 to remove`, stop immediately. Nothing in this change removes a mod.

- [ ] **Step 8: Confirm the "before" state from Step 3 has flipped**

Re-run the Step 3 command block.

Expected: 13 plugin directories including `Recycle_N_Reclaim`; the marker file now exists and `cat` of it reads `1.4.0 919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16`; the cfg now exists.

- [ ] **Step 9: No commit**

This task changes nothing in the repo. Do not create an empty commit.

---

## Task 4: Verify the config file

**Files:**
- Modify: none unless the phantom-cfg test fails.

**Interfaces:**
- Consumes: the running pod and generated config from Task 3.
- Produces: confirmation that all ten pins are live in the file the mod actually reads. Task 5 depends on this — testing behaviour against inert pins wastes an outage window.

- [ ] **Step 1: The phantom-cfg test**

`set_cfg` **creates** a config file when one is absent. If the mod's real BepInEx GUID is not `Azumatt.Recycle_N_Reclaim`, the installer writes a file nobody reads, the mod runs on its own defaults, and **ten `[cfg ]` success lines are logged anyway.** This step is the only thing that catches it.

```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(@'
echo "=== all cfg files, newest first ==="
ls -lt /config/bepinex/*.cfg | head -20
F=/config/bepinex/Azumatt.Recycle_N_Reclaim.cfg
echo
echo "=== sections ==="; grep -c "^\[" "$F"
echo "=== keys ===";     grep -cE "^[A-Za-z].*=" "$F"
echo "=== ## comment headers ==="; grep -c "^##" "$F"
echo
echo "=== first 30 lines ==="; head -30 "$F"
'@ -replace "`r`n", "`n"))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Interpretation — this is the whole point of the step:

| Observation | Meaning | Action |
|---|---|---|
| `## comment headers` > 0, keys ≫ 10, sections ≥ 4 | The **mod** wrote this file. Correct GUID. | Continue to Step 2 |
| `## comment headers` == 0 **and** keys == 10 | `set_cfg` **invented** this file. Wrong GUID — the pins are inert. | Stop. Go to Step 5 |
| A different `Azumatt.*Recycle*.cfg` appears in the listing | The real GUID is that filename. | Stop. Go to Step 5 |

- [ ] **Step 2: Verify all ten pinned values, in their correct sections**

```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(@'
awk '/^\[/{s=substr($0,2,length($0)-2); next}
     /^[A-Za-z].*=/{gsub(/^[ \t]+|[ \t]+$/,""); print "[" s "] " $0}' \
  /config/bepinex/Azumatt.Recycle_N_Reclaim.cfg |
grep -E "Lock Configuration|^\[2 - Inventory Recycle\] Enabled|Lock to Admin|ReturnEnchantedResources|ReturnUnknownResources|RecyclingRate|AllowRecyclingUnknownRecipes|PreventZeroResourceYields|UnstackableItemsAlwaysReturnAtLeastOneResource"
'@ -replace "`r`n", "`n"))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected, exactly these ten:

```
[1 - General] Lock Configuration = true
[2 - Inventory Recycle] Enabled = true
[2 - Inventory Recycle] Lock to Admin = false
[2 - Inventory Recycle] ReturnEnchantedResources = false
[2 - Inventory Recycle] ReturnUnknownResources = false
[3 - Reclaiming] RecyclingRate = 0.5
[3 - Reclaiming] ReturnEnchantedResources = false
[3 - Reclaiming] AllowRecyclingUnknownRecipes = false
[3 - Reclaiming] PreventZeroResourceYields = true
[3 - Reclaiming] UnstackableItemsAlwaysReturnAtLeastOneResource = true
```

🚨 **Two `ReturnEnchantedResources` lines must appear, under different section headers.** One line means only one path is guarded. Zero lines under `[3 - Reclaiming]` with two under `[2 - Inventory Recycle]` means a section match failed and both writes landed in the same place.

- [ ] **Step 3: Count-stability check across a restart**

An appended duplicate section is the signature of a failed match, and it only shows up on the *second* application of `MOD_CONFIG` — the first run creates, the second run is where a mismatched section name duplicates.

```powershell
# capture BEFORE
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(@'
F=/config/bepinex/Azumatt.Recycle_N_Reclaim.cfg
echo "sections=$(grep -c '^\[' $F) keys=$(grep -cE '^[A-Za-z].*=' $F)"
grep "^\[" $F
'@ -replace "`r`n", "`n"))
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"

kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status  deploy/valheim -n valheim --timeout=600s

# capture AFTER — rerun the identical block
kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "echo $b64 | base64 -d | bash"
```

Expected: `sections=` and `keys=` **identical** before and after, and the section list has no repeats.

Also confirm the installer is idempotent:

```powershell
kubectl logs -n valheim deploy/valheim -c fetch-mods | Select-String "done:"
```

Expected: `=== done: 0 installed, 13 already present ===`.

- [ ] **Step 4: If everything passed, no commit**

Nothing in the repo changed. Proceed to Task 5.

- [ ] **Step 5: Failure path — fall back to the two-phase approach**

Only if Step 1 or Step 2 failed. Do **not** guess at a corrected section or file name and re-apply.

1. Read the real filename and real section headers off the PVC:
   ```powershell
   kubectl exec -n valheim deploy/valheim -c valheim -- bash -c "ls -1 /config/bepinex/*.cfg; grep -h '^\[' /config/bepinex/Azumatt*Recycl*.cfg"
   ```
2. Correct the ten `MOD_CONFIG` lines in `valheim/mods-configmap.yaml` to the observed strings.
3. If `set_cfg` created a phantom file, delete it so it cannot be mistaken for real later:
   ```powershell
   kubectl exec -n valheim deploy/valheim -c valheim -- rm -f /config/bepinex/<phantom-name>.cfg
   ```
4. Re-run Task 1 Steps 5-8, then Task 3 Steps 5-8, then this task from Step 1.
5. Commit the correction with a message recording what the real strings turned out to be — that is the fact worth keeping.

---

## Task 5: In-game verification and recording the result

**Files:**
- Modify: `valheim/mods-configmap.yaml` (append verification note to the `MOD_CONFIG` comment block), `valheim/README.md` (append verified results)

**Interfaces:**
- Consumes: a running server with verified-live pins from Task 4.
- Produces: the recorded in-game verification. This is the terminal task.

Requires a player in-game. Four of the six checks are **negative cases** — each guard must be seen *refusing*, not merely seen not-misbehaving.

- [ ] **Step 1: Positive control — reclaiming works at all**

Craft an item with a known recipe. At the correct crafting station, open the Reclaim tab and reclaim it.

Expected: roughly 50% of its components returned.

If this fails, nothing below is meaningful — the mod is not functioning. Check `EnableExperimentalCraftingTabUI` first, since it ships enabled and appears to be the Reclaim tab itself.

- [ ] **Step 2: Negative — EpicLoot magic items**

Take an EpicLoot magic (enchanted) item. Attempt to reclaim it at a station, **and** attempt to discard it via the inventory-recycle path. Both paths, because `ReturnEnchantedResources` is pinned separately in each.

Expected: **no enchanting materials returned** by either path. EpicLoot's Sacrifice at the Enchanter remains the only route.

🚨 If either path returns enchanting materials, the corresponding pin did not take. Re-check Task 4 Step 2 for two `ReturnEnchantedResources` lines under *different* sections.

- [ ] **Step 3: Negative — unknown recipes**

Obtain an item whose recipe the character has **not** unlocked (a drop from a higher biome works).

Expected: reclaiming is **refused**, and no out-of-tier materials are granted.

- [ ] **Step 4: Negative — zero yields**

Reclaim an item whose crafting cost is 1 unit of some material — at 50%, the naive result is 0.

Expected: **at least 1 returned, never 0.** This proves `PreventZeroResourceYields` and `UnstackableItemsAlwaysReturnAtLeastOneResource` both took.

- [ ] **Step 5: The AzuEPI interaction gate**

Open the inventory screen.

Expected: AzuExtendedPlayerInventory's **5 extra rows** and its quick slots still render and are usable, and the trash slot coexists without overlapping them.

🚨 This is the risk accepted before approval — `TrashItems` was declined in this repo precisely because AzuEPI redraws this screen. If it fails, the partial rollback is to pin `[2 - Inventory Recycle] Enabled` to `false`, which keeps the Reclaim tab and drops the contending half. Full removal is Task 5 Step 8.

- [ ] **Step 6: Client config sync**

A second player joins and checks the mod's in-game config display.

Expected: the same `RecyclingRate` of `0.5`, pushed by ServerSync. Also confirms the client-side install is accepted rather than kicked.

- [ ] **Step 7: Record the results**

Append to the Recycle_N_Reclaim comment block in `valheim/mods-configmap.yaml`, following the style of the existing `[Wagon]` verification note — record what was checked, on what date, and specifically that the negative cases were seen refusing:

```
    # ✅ VERIFIED IN-GAME <date of the session, YYYY-MM-DD>: reclaim returns ~50% at the
    # correct station; an EpicLoot magic item returned NO enchanting materials by either
    # the reclaim or the discard path; an item whose recipe was not yet unlocked was
    # REFUSED; a 1-unit item returned 1, not 0; AzuEPI's 5 extra rows and quick slots
    # still render alongside the trash slot. The middle three are the negative cases --
    # each guard was seen REFUSING, not merely seen not misbehaving.
```

Add the equivalent to the `#### Recycle_N_Reclaim` section of `valheim/README.md`.

If any check produced an unexpected result, record **that** instead. A recorded failure is worth more than an omission.

- [ ] **Step 8: Rollback path, if verification failed badly enough to remove the mod**

Delete the `MODS` line and the ten `MOD_CONFIG` lines, apply, restart. One mod, so the `>2` bulk-prune circuit breaker is not touched and `PRUNE_ALLOW_BULK` is **not** needed.

This removal is clean — the mod registers no prefabs, so nothing is orphaned in the world save. Two harmless residuals: `Azumatt.Recycle_N_Reclaim.cfg` stays on the PVC because the installer never deletes config files, and clients may leave the mod installed since there is nothing left server-side to kick on.

Also revert the Task 2 README edits and the header note from Task 1 Step 3.

- [ ] **Step 9: Commit**

```powershell
cd C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal
git add valheim/mods-configmap.yaml valheim/README.md
git commit -m "Record the in-game verification for Recycle_N_Reclaim"
```

---

## Spec coverage

| Spec section | Covered by |
|---|---|
| §2 artifact, checksum, layout | Task 1 Steps 2, 5; Task 3 Step 7 |
| §3 kicks clients | Task 1 Steps 2-3; Task 2 Steps 3-4; Task 3 Step 2 |
| §4 numbered section names | Task 1 Step 4; Task 4 Steps 1-3 |
| §5 all eight decisions | Task 1 Step 4 (pins + rationale comments) |
| §6.1 MODS line | Task 1 Step 2 |
| §6.2 ten MOD_CONFIG lines | Task 1 Step 4 |
| §6.3 not-pinned settings | Task 1 Step 4 comment block; Task 2 Step 6 |
| §6.4 files touched | Tasks 1, 2 |
| §7.1 pre-flight | Task 3 Steps 1-4 |
| §7.2 apply | Task 3 Steps 5-6 |
| §7.3 installer + phantom-cfg + counts | Task 3 Step 7; Task 4 Steps 1-3 |
| §7.4 in-game, negative cases | Task 5 Steps 1-6 |
| §8 ExcludeLists limitation | Task 1 Step 4 comment; Task 2 Step 6 |
| §9 rollback | Task 5 Step 8 |
| §10 risks | Task 4 Step 5; Task 5 Steps 5, 8 |
