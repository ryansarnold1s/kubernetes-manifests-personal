# Add Recycle_N_Reclaim to the Valheim Server — Design

**Date:** 2026-07-31
**Status:** Approved
**Scope:** One mod added to the existing declarative mod set, plus its config pins and docs.
**Depends on:** `2026-07-26-valheim-bepinex-design.md`, `2026-07-29-valheim-odinhorse-carryweight-migration-design.md`

---

## 1. Goal

Install `Azumatt-Recycle_N_Reclaim` 1.4.0 as the thirteenth server-side BepInEx mod, so
players can un-craft items back into components at a crafting station and discard items
from the inventory screen.

Both halves of the mod are wanted — the `[3 - Reclaiming]` crafting-station tab *and* the
`[2 - Inventory Recycle]` trash slot and discard hotkeys.

Non-goals, deliberately:

- Per-item recycle rates via `Azumatt.Recycle_N_Reclaim_ExcludeLists.yml` (see §8).
- Any change to `install-mods.sh`, `deployment.yaml`, or the config mechanism.
- Removing or reconsidering any existing mod.

---

## 2. The artifact

Verified by reading the real download, not the Thunderstore page. Recon ran read-only
inside the live game container; the zip landed in the container's writable layer, never on
either PVC.

| Property | Value |
|---|---|
| Package | `Azumatt-Recycle_N_Reclaim` |
| Version | 1.4.0 (published 2026-03-09) |
| URL | `https://thunderstore.io/package/download/Azumatt/Recycle_N_Reclaim/1.4.0/` |
| sha256 | `919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16` |
| Size | 412,650 bytes |
| Zip contents | `Recycle_N_Reclaim.dll` at the root, plus `README.md`, `CHANGELOG.md`, `icon.png`, `manifest.json` |
| Layout | **`root`** — no `plugins/` dir, no `BepInEx/` nesting, no bundled `config/` |
| Sole dependency | `denikson-BepInExPack_Valheim-5.4.2333` — exactly the pack this server runs |

`YamlDotNet 13.0.0.0` is embedded in the DLL, so the installed `JsonDotNET` mod is unrelated
and no new dependency is introduced. The DLL also carries soft references to `AugaAPI` and
`Jewelcrafting`; neither is installed here, and neither is required.

---

## 3. Key finding: it kicks clients

The mod enforces client installation. This puts it in the same class as
AzuExtendedPlayerInventory and AzuContainerSizes, and makes the rollout a coordinated
window rather than a background change.

Two independent lines of evidence agree.

**The author says so.** The README bundled inside the zip, line 7:

> `Version checks with itself. If installed on the server, it will kick clients who do not have it installed.`

**Static evidence, with controls.** Marker counts extracted from the DLLs already on the
PVC alongside the candidate:

| DLL | `MinimumRequiredVersion` | `DisconnectClient` | `RemoveDisconnectedPeerFromVerified` | `RPC_*_Version` |
|---|---|---|---|---|
| **Recycle_N_Reclaim 1.4.0** | 1 | 1 | **1** | **1** |
| AzuEPI *(known kicker)* | 1 | 1 | **1** | **1** |
| AzuContainerSizes *(known kicker)* | 1 | 1 | **1** | **1** |
| PlantEverything *(known non-kicker)* | 1 | 1 | **0** | **0** |
| XPortal *(known non-kicker)* | 0 | 0 | **0** | **0** |

⚠️ The controls are the point, and they changed the answer. `MinimumRequiredVersion` and
`DisconnectClient` alone produce a **false positive on PlantEverything** — a mod known not
to enforce. Only the last two columns separate the known kickers from the known
non-kickers. Anyone re-running this check on a future mod should use those two markers and
should re-run both controls, not trust the first two columns.

---

## 4. Key finding: section names are numbered

The mod's config sections are `1 - General`, `2 - Inventory Recycle`, `3 - Reclaiming`,
`4 - UI` — the same numbered convention as the other Azumatt mods here (`2 - Inventory`,
`2 - Chests`). The Thunderstore page lists them as bare `General` / `Inventory Recycle` /
`Reclaiming` / `UI`.

Pinning from the page would have missed every section. `set_cfg`'s awk would then have
appended four duplicate sections that the mod ignores — **while logging ten successful
`[cfg ]` lines.** This is the same silent failure the CRLF and zero-width handling in
`install-mods.sh` were written for.

⚠️ Establishing this took two recon passes. The first extracted printable strings with
`tr -cs '[:print:]'`, which shreds .NET's UTF-16 literals one character at a time. It
surfaced only ASCII *identifiers* (`RecyclingRate`, `Reclaiming`, `Debug`) and found nothing
containing a space — no `Inventory Recycle`, no `Lock Configuration`. **Any future string
mining of a .NET DLL must strip nulls first** (`tr -d '\000'`), or it will report absent
for every literal with a space in it and read as a clean negative result.

---

## 5. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Which halves | Both | Owner's call, made with the AzuEPI contention risk stated up front |
| `RecyclingRate` | `0.5` (mod default) | Recycling stays a real cost — for fixing mistakes and clearing junk, not a free material loop. Server-synced, so raising it later is one line |
| EpicLoot magic items | `ReturnEnchantedResources = false`, **both sections** | EpicLoot's Sacrifice at the Enchanter stays the only conversion path for magic gear, at EpicLoot's own balance. The mod's README confirms the interaction is real: *"If on and Epic Loot or Jewelcrafting is installed, discarding an item in the inventory will return resources for Epic Loot"* |
| Unknown recipes | `AllowRecyclingUnknownRecipes = false`, `ReturnUnknownResources = false` | Three mods here add loot drops. Without this, a lucky Meadows drop converts into out-of-tier materials and skips a biome |
| Zero yields | `PreventZeroResourceYields = true`, `UnstackableItemsAlwaysReturnAtLeastOneResource = true` | At 50%, a 1-unit item yields 0.5 → nothing. Silently eating cheap gear for no return contradicts the intent behind choosing 50% |
| Config authority | `Lock Configuration = true` | Matches this repo's rule that `MOD_CONFIG` is the source of truth and in-game edits are reverted on the next boot |
| Admin gating | `Lock to Admin = false` | The inventory-recycle half is wanted for players, not just admins |
| Install approach | Recon first, single apply | One read-only pass answered checksum, layout, enforcement, section names and prefab safety together, so the change is one edit and one restart |

### Rejected: pinning from the Thunderstore documentation

One apply and no recon, but §4 shows it would have silently failed on all four sections
and left the EpicLoot and progression guards inert while reporting success.

### Rejected: two-phase apply (add to `MODS`, boot, read the generated cfg, then pin)

Guaranteed-correct and has in-repo precedent (OdinHorse saddle storage). Rejected because
recon established the section names without it, and it costs two outage windows plus one
boot where the mod runs on **defaults** — enchanted resources returned, unknown recipes
recyclable — on a live world. Still the correct fallback if §7.3's verification shows the
pins did not land.

---

## 6. The change

### 6.1 `MODS` — one line

```
Recycle_N_Reclaim          1.4.0    https://thunderstore.io/package/download/Azumatt/Recycle_N_Reclaim/1.4.0/     919794da00dc630dc2171c9f1daefb9df97117ee15119b4d7fe1f7454aaa4d16  root
```

### 6.2 `MOD_CONFIG` — ten lines

```
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

⚠️ `ReturnEnchantedResources` is pinned **twice on purpose.** The key genuinely exists in
both `[2 - Inventory Recycle]` and `[3 - Reclaiming]`, governing the discard path and the
reclaim path independently. Deleting either line as a duplicate reopens one of them.

Both blocks carry house-style comments explaining why each pin exists, aimed at the future
edit that would undo it.

### 6.3 Not pinned, deliberately

| Setting | Why not |
|---|---|
| `RequireExactCraftingStationForRecycling` | Author's default is on, with the note that it keeps behaviour close to vanilla |
| `EnableExperimentalCraftingTabUI` | Default on, and it appears to *be* the Reclaim tab. **First thing to toggle if the crafting UI misbehaves** |
| All keybinds | Client-side preference, not a server concern |

### 6.4 Files touched

| File | Change |
|---|---|
| `valheim/mods-configmap.yaml` | §6.1 + §6.2, plus comments; header CLIENT INSTALL note gains a third kicking mod |
| `valheim/README.md` | Twelve → Thirteen; new table row; 🚨 block names three kickers; `0 installed, 12 already present` → 13; per-mod config entry recording the pins and §8 |

`deployment.yaml` and `install-mods.sh` are **not** touched. No new layout, no new config
format, and the bulk-prune circuit breaker is not involved — it only fires on removals.

---

## 7. Rollout and verification

### 7.1 Pre-flight

1. Confirm nobody is connected:
   `kubectl logs -n valheim deploy/valheim -c valheim --tail=600 | Select-String "Connections \d+" | Select-Object -Last 1`
   ⚠️ Up to 10 minutes stale. A `0` right after someone quits is real; a `2` may not be.
   Announce the window regardless.
2. Everyone installs `Azumatt-Recycle_N_Reclaim-1.4.0` in r2modman **before** the apply, so
   the coordinated window covers both directions of version mismatch.
3. Optional but cheap: Longhorn snapshot of `valheim-data`. Apply a `snapshots.longhorn.io`
   CR with `spec.createSnapshot: true` and `spec.volume` set to the PV backing the PVC
   (`kubectl get pvc valheim-data -n valheim -o jsonpath='{.spec.volumeName}'`). §9 shows
   there are no prefabs to orphan, so this is insurance, not a requirement.

### 7.2 Apply

From `valheim/` — relative paths from the repo root silently no-op.

```powershell
kubectl apply -f mods-configmap.yaml --dry-run=server
kubectl apply -f mods-configmap.yaml          # must say "configured", not "unchanged"
kubectl rollout restart deploy/valheim -n valheim
kubectl rollout status  deploy/valheim -n valheim --timeout=600s
```

The `rollout restart` is required because this is a ConfigMap edit. It is **not** a
Deployment edit, so there is no first Recreate cycle for it to race.

### 7.3 Verify — installer level

| Check | Expected |
|---|---|
| `fetch-mods` log | `[ok ] Recycle_N_Reclaim 1.4.0`; `1 installed, 12 already present` |
| Prune line | `pruning mods no longer in MODS (0 to remove)` |
| Closing `ls -1` | 13 plugin directories |
| Second restart | `0 installed, 13 already present` — proves idempotence |

**The phantom-cfg test.** `set_cfg` *creates* a config file when one is absent. If the mod's
real BepInEx GUID is not `Azumatt.Recycle_N_Reclaim`, the installer writes a file nobody
reads, the mod runs on its own defaults, and **ten `[cfg ]` success lines are logged
anyway.** So list `/config/bepinex/*.cfg` and inspect the file:

- A cfg the **mod** wrote carries its full key set with `##` comment headers. Correct.
- A cfg **`set_cfg` invented** contains exactly our ten keys and nothing else. Wrong GUID —
  the pins are inert, and the fix is the §5 two-phase fallback.

**Count check.** Capture `grep -c '^\['` (sections) and the key count from the cfg, restart
once more, and confirm both are unchanged. An appended duplicate section is the signature
of a failed match.

**Value check.** All ten pinned keys read back with the intended value, in the intended
section.

### 7.4 Verify — in-game

Rows 2–4 are the guards §5 pinned. A guard only ever observed passing has not been
verified; each must be seen refusing.

| Check | Expected |
|---|---|
| Reclaim a known-recipe item at the correct station | ~50% of components returned |
| **Reclaim an EpicLoot magic item** | enchanting materials **not** returned |
| **Reclaim an item whose recipe is not unlocked** | refused; no unknown resources granted |
| **Reclaim a 1-unit item** | at least 1 returned, not 0 |
| Open the inventory screen | AzuEPI's 5 extra rows and quick slots still render and work; the trash slot coexists without overlap |
| Second player joins | sees the same `RecyclingRate` — confirms the ServerSync push |

⚠️ The inventory-screen row is the one that was flagged before approval. `TrashItems` was
declined in this repo precisely because AzuEPI redraws that screen. This mod occupies the
same territory by explicit choice, so that row is a real gate, not a formality. If it
fails, disable `[2 - Inventory Recycle] Enabled` first — that keeps the Reclaim tab and
drops the contending half — before considering full removal.

---

## 8. Known limitation: no per-item rates

The mod reads `Azumatt.Recycle_N_Reclaim_ExcludeLists.yml`, whose `recycleRates` block
overrides the global `RecyclingRate` per item or group (values 0.0–1.0).

`MOD_CONFIG` is pipe-delimited INI `key = value` and **cannot manage a YAML side-file.**
This design ships no exclusions and no per-item rates. Adding them later means a new
mechanism in `install-mods.sh` — a separate piece of work, not a config line.

Until then, the global 50% applies to everything recyclable.

---

## 9. Rollback

Delete the `MODS` line and the ten `MOD_CONFIG` lines, apply, restart. The installer prunes
the plugin directory from both the staged copy on `valheim-data` and the live install on
`valheim-server`, and drops the `.mod-state` marker. One mod, so the `>2` bulk-prune
breaker is not touched.

**This removal is clean.** Recon found `AssetBundle`, `LoadAsset`, `PrefabManager`,
`CustomItem`, `CustomPrefab` and `ItemManager` all at **0**, and no bundled asset files. The
mod registers no prefabs, so it belongs in the "pure runtime-patch mods are free to remove"
category the README defines — unlike EpicLoot, Warfare, Armory, OdinsFoodBarrels and
OdinHorse, whose placed instances persist as ZDOs.

Two residuals, both harmless: the orphaned `Azumatt.Recycle_N_Reclaim.cfg` stays on the PVC
because the installer never deletes config files, and clients may leave the mod installed —
with the server no longer running it, there is nothing to kick on.

---

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Inventory-screen contention with AzuEPI | Medium | Accepted knowingly. Gated by §7.4; partial rollback is disabling `[2 - Inventory Recycle] Enabled`, which keeps the Reclaim tab |
| Wrong BepInEx GUID → inert pins, logged as success | Medium | The phantom-cfg test in §7.3 |
| Section names wrong → duplicate sections, logged as success | Low | Resolved by §4; the §7.3 count check catches any residual |
| A player joins without the mod during the window | Low | They are kicked, cleanly and reversibly. §7.1 coordinates it |
| Balance turns out wrong at 50% | Low | Server-synced single value; one line and a restart |

---

## 11. Correction — 2026-07-31, applied same day

**§6.2's ten pin lines were wrong.** They used `true`/`false`. Every boolean-looking key in
this mod is `Setting type: Toggle`, a two-member enum whose acceptable values are `Off` and
`On`. BepInEx rejected nine of the ten with `Requested value 'true' was not found` and kept
the mod's own default. Only `RecyclingRate` — a genuine float — applied as written.

The corrected values are `On` where §6.2 said `true` and `Off` where it said `false`;
`RecyclingRate` is unchanged at `0.5`. Live values verified after re-apply.

### Why the design's own verification did not catch it

§7.3 was built around the wrong failure mode. It assumed a bad pin would show up as a
**missing or duplicated section** in the config file, and the phantom-cfg test and count
check were both aimed there. Neither could see this:

- **A rejected value is not absent from the file.** BepInEx overwrites it with the mod's
  default, correctly formatted, in the correct section. The file passes every structural
  check in §7.3 while carrying values nobody chose.
- **§7.3's value check reads the file back.** That confirms what the mod *is* using, not
  whether it matches what was asked for. When the default coincides with the intent — six
  of nine here — the check passes and proves nothing.

The failure was visible in exactly one place, which §7.3 never consulted: the game
container's log.

```powershell
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "could not be parsed"
```

**This check belongs in the verification of any `MOD_CONFIG` change, for any mod.** Empty is
the pass. It is now documented in `valheim/README.md` under "When a pin does not take".

### What was actually at risk

Six of the nine rejected pins coincidentally matched the mod's defaults. Three did not, and
all three were decisions from §5:

| Pin | Intended | Ran as | Consequence |
|---|---|---|---|
| `[2 - Inventory Recycle] ReturnEnchantedResources` | `Off` | `On` | EpicLoot guard inactive on the discard path |
| `[3 - Reclaiming] ReturnEnchantedResources` | `Off` | `On` | EpicLoot guard inactive on the reclaim path |
| `[2 - Inventory Recycle] Lock to Admin` | `Off` | `On` | Inventory discard admin-only — the half §1 wanted for players |

Nobody played during the window, so no magic item was recycled under the wrong setting.

### The generalisable lesson

A `[cfg ]` line in the installer log means the applier wrote the file. It never means the
mod accepted the value. §4 already warned that `[cfg ]` success lines are not evidence —
that warning was written about wrong *section names* and turned out to apply just as well
to wrong *value types*, a case it did not anticipate.

Before pinning a new key, read its `# Setting type:` line in the generated `.cfg` on the
PVC. Do not infer the type from a key that reads like a boolean.
