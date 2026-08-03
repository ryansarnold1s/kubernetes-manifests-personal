# Automate the Cooking Station with LazyVikings — Design

**Date:** 2026-08-02
**Status:** Approved
**Scope:** One mod added, narrowed to cooking stations only. No ValheimPlus change.
**Depends on:** `2026-07-31-recycle-n-reclaim-design.md`

---

## 1. Goal

Make the cooking station fill itself from nearby containers, unattended, the way the
smelter already does. Install `blacks7ar-LazyVikings` 1.2.3 as the fourteenth server-side
BepInEx mod, with every station type disabled except **Cooking Station** and **Iron Cooking
Station**.

Non-goals, deliberately:

- Any change to ValheimPlus. All nine station types V+ automates today keep working, owned
  by V+.
- The other fourteen LazyVikings station types. Each is pinned **off**.
- Auto-popping cooked food. LazyVikings does not do it; see §7.

---

## 2. How this request changed shape

The original ask was to adopt `Grizzzly/CraftFromContainers` and revert whatever V+ does
today. Investigation invalidated both halves. Recording why, because the reasoning is the
part worth keeping.

### 2.1 It was reported as a bug; it was not a bug

Observed: raw meat in a chest beside a cooking station was never cooked.

V+ **does** implement cooking-station chest support — `CookingStation_FindCookableItem_Transpiler`
calls `PullCookableItemFromNearbyChests`. But `FindCookableItem()` runs when the **player
interacts**. Confirmed in game: standing at the grill with an empty inventory and pressing
the interact key **does** take meat from the adjacent chest. The feature works.

What V+ lacks is the *unattended* half. The asymmetry is visible in its own patch set:

| | Interact-driven chest pull | Unattended auto-fill engine |
|---|---|---|
| Smelter | `Smelter_FindCookableItem_Transpiler` | `Smelter_UpdateSmelter_Patch` + `autoFuel`/`autoDeposit` config |
| Cooking Station | `CookingStation_FindCookableItem_Transpiler` | **none** |

Corroborated by the config itself: **there is no `[CookingStation]` section in
`valheim_plus.cfg` at all** — only `[FireSource]` and `[Oven]`. V+ has no knob for this
because it has no feature for it.

⚠️ Two hypotheses were formed and killed before the real answer emerged. Both are recorded
so nobody re-runs them:

- **`checkFromWorkbench = true` redirecting the chest scan to the workbench.** Plausible
  because `[Workbench] workbenchRange` is pinned to 40 here while `[CraftFromChest] range`
  is 20, so a grill 20-40 m from its workbench would scan from too far away. **Killed** by
  test: a grill built in open forest with the workbench destroyed still did not auto-cook.
- **`ignorePrivateAreaCheck = false`**, the odd one out — every other station section sets
  it `true`. **Killed** by the same test, and by craft-from-chest working normally at a
  workbench with materials only in a chest.

### 2.2 CraftFromContainers would not have delivered it

`Grizzzly/CraftFromContainers` 3.8.1 replaces `Player.ConsumeResources` and the item-finding
path — the same interact-driven model as V+. It does not auto-fill an unattended station, so
it would not have solved the actual problem. Adopting it would also have cost:

- **`autoDeposit` across nine station types**, which it does not offer at all.
- **Server-side enforcement.** It is client-side with no ServerSync, so correct config would
  be convention rather than mechanism — the exact reason `CookingStationTweaks` was declined
  here on 2026-07-29.

Its own README warns: *"This mod replaces the `Player.ConsumeResources` method, so may
conflict with anything that tries to patch that"* — which V+ `[CraftFromChest]` does. It is
also 13 months old and pins `BepInExPack 5.4.2202` while this server runs `5.4.2333`.

**Nothing needs reverting.** Once LazyVikings is narrowed to cooking stations, V+ keeps every
feature it has today.

### 2.3 Also evaluated and rejected

| Candidate | Why not |
|---|---|
| `eideehi/Automatics` 1.7.0 | *"This mod has been developed with the sole intention of single-player usage. Please be aware that it is not supported for server operation."* Also does not cover cooking. |
| `Grizzzly/CookingStationTweaks` 0.7.1 | Has auto-**pop**, prevent-burning, slots, cook time — but **no auto-fill**. Solves a different problem. Already recorded as declined 2026-07-29. |

---

## 3. The artifact

Verified by reading the real download inside the live container, not the store page.

| Property | Value |
|---|---|
| Package | `blacks7ar-LazyVikings` |
| Version | 1.2.3 (published 2025-10-20) |
| URL | `https://thunderstore.io/package/download/blacks7ar/LazyVikings/1.2.3/` |
| sha256 | `25cc50aeb44be09d08998b937dde671b60f8a420656d5b36cc236c52c8588437` |
| Size | 78,183 bytes |
| Zip contents | `LazyVikings.dll` at the root, plus `CHANGELOG.md`, `README.md`, `icon.png`, `manifest.json` |
| Layout | **`root`** |
| Sole dependency | `denikson-BepInExPack_Valheim-5.4.2333` — exactly the pack this server runs |
| Config file | `blacks7ar.LazyVikings.cfg` (GUID `blacks7ar.LazyVikings`) |
| Prefab registration | **none** — `AssetBundle`/`LoadAsset`/`PrefabManager`/`CustomItem`/`CustomPrefab`/`ItemManager` all 0 |

**It auto-fills.** The method names are unambiguous: `_methodAddItemFromNearbyContainers`,
`GetNearbyItemsFromContainers`, `_methodDepositToContainers`,
`DeductItemFromAllNearbyContainers`, alongside `CookingStationPatch`, `UpdateCooking_Prefix`
and `_cookingStationAutomation`. It hooks the cooking update tick, not an interact path.

**It does not kick clients.** Using the two discriminating markers established on 2026-07-31:

| DLL | `MinimumRequiredVersion` | `DisconnectClient` | `RemoveDisconnectedPeerFromVerified` | `RPC_*_Version` |
|---|---|---|---|---|
| **LazyVikings 1.2.3** | 1 | 1 | **0** | **0** |
| AzuEPI *(known kicker)* | 1 | 1 | 1 | 1 |
| PlantEverything *(known non-kicker)* | 1 | 1 | **0** | **0** |
| XPortal *(known non-kicker)* | 0 | 0 | 0 | 0 |

Identical profile to PlantEverything. It still carries ServerSync
(`distributeConfigToPeers`, `ValidatedClients`), so config reaches clients without lockout.

**Staleness assessment.** 9.5 months since release, but: the author is actively publishing
(other mods updated the same day this was evaluated), the package is not deprecated, and it
patches with Harmony **Prefix** rather than transpilers — which survive game updates far
better. V+ is transpiler-heavy, which is why V+ needs frequent updates and this may not.

---

## 4. Key finding: section names are numbered, in a format of their own

The 18 sections are `NN- Name` — **zero-padded, no space before the dash, one space after**:

```
01- ServerSync            07- Fermenter              13- Spinning Wheel
02- General               08- Hot Tub                14- Stone Oven
03- Beehive               09- Iron Cooking Station   15- Windmill
04- Blast Furnace         10- Kiln                   16- Fireplace
05- Cooking Station       11- SapCollector           17- Steel Kiln
06- Eitr Refinery         12- Smelter                18- Steel Slack Tub
```

⚠️ This is a **third** naming convention. Azumatt's mods use `2 - Inventory Recycle`
(single digit, spaces both sides); ValheimPlus uses bare `[Time]`; this uses `05- Cooking
Station`. A regex written for one will silently miss the others — the first pass here
searched for `N - Name` and found nothing, which read as a clean negative.

The key is **`Enable`**, appearing exactly once in the string heap because .NET interns it
and all sixteen station sections reference the same literal. Same for `Lock Configuration`,
`Ignore Private Area Check`, `Leave One`, `Product Threshold`.

🚨 **Values are `On`/`Off`, not `true`/`false`.** Every description reads *"If On, …"* and
`Toggle` is present in the type metadata. This is the failure that cost two restarts on
Recycle_N_Reclaim on 2026-07-31; caught in advance this time.

---

## 5. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Which stations | Cooking Station + Iron Cooking Station only | The only gap V+ has. Everything else V+ already does, and it works |
| The other fourteen | `Enable = Off`, explicitly pinned | Each names a station V+ automates. Leaving one unpinned lets a future default flip put two mods on the same station |
| ValheimPlus | Untouched | Nothing to revert once LazyVikings is narrowed. Disabling ten working V+ sections on a live world to gain tidiness is a bad trade |
| Config authority | `01- ServerSync \| Lock Configuration \| On` | Matches this repo's rule that `MOD_CONFIG` is the source of truth |
| Install approach | Single apply, pins written before first boot | `set_cfg` creates the file when absent and BepInEx honours a partial config, so there is no boot where both mods automate the same stations |

### Rejected: two-phase apply (install, boot on defaults, then pin)

The obvious approach when section and key names are unknown, and the documented fallback
from the Recycle_N_Reclaim design. Rejected because recon recovered both, and because phase
one would boot LazyVikings on its **defaults** — potentially automating all fourteen
stations V+ already owns, on a live world. Still the correct fallback if §7.3 shows the pins
did not land.

---

## 6. The change

### 6.1 `MODS` — one line

```
LazyVikings                1.2.3    https://thunderstore.io/package/download/blacks7ar/LazyVikings/1.2.3/     25cc50aeb44be09d08998b937dde671b60f8a420656d5b36cc236c52c8588437  root
```

### 6.2 `MOD_CONFIG` — seventeen lines

```
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

🚨 **The fourteen `Off` lines are load-bearing, not redundant.** Each names a station
ValheimPlus already automates:

| LazyVikings section | Already owned by |
|---|---|
| `03- Beehive` | V+ `[Beehive] autoDeposit` |
| `06- Eitr Refinery` | V+ `[EitrRefinery] autoDeposit`/`autoFuel` |
| `07- Fermenter` | V+ `[Fermenter] autoDeposit`/`autoFuel` |
| `10- Kiln` | V+ `[Kiln] autoDeposit`/`autoFuel` |
| `11- SapCollector` | V+ `[SapCollector] autoDeposit` |
| `12- Smelter` | V+ `[Smelter] autoDeposit`/`autoFuel` |
| `13- Spinning Wheel` | V+ `[SpinningWheel] autoDeposit`/`autoFuel` |
| `14- Stone Oven` | V+ `[Oven] autoFuel` |
| `15- Windmill` | V+ `[Windmill] autoDeposit`/`autoFuel` |
| `16- Fireplace` | V+ `[FireSource] autoFuel` |
| `04- Blast Furnace`, `08- Hot Tub`, `17- Steel Kiln`, `18- Steel Slack Tub` | not present / not automated here; off for consistency |

Turning any of them `On` puts two mods on the same station. Do not "tidy up" these lines.

`02- General` is not pinned — its contents were not enumerated, and nothing in this design
depends on it. Range and private-area keys are left at defaults for the two enabled
sections; the ranges are per-station (`_cookingStationRadius` etc.) and the defaults are
untested here, so they are a follow-up if the pull radius proves wrong.

### 6.3 Files touched

| File | Change |
|---|---|
| `valheim/mods-configmap.yaml` | §6.1 + §6.2 plus comments; header CLIENT INSTALL note gains LazyVikings as recommended-not-required |
| `valheim/README.md` | Thirteen → Fourteen; table row; per-mod config section; the §2 finding about V+ interact-vs-unattended |

⚠️ Three counts in `README.md` move together and are easy to miss individually — the prose
count ("**Thirteen mods** are installed"), the installer idempotence note ("`13 already
present`") and the chainloader expectation ("Expect `13 plugins to load`"). The last of
these was left stale by the Recycle_N_Reclaim change and only caught in final review. Grep
for `13` in that file and account for every hit before committing.

`deployment.yaml`, `install-mods.sh` and every ValheimPlus setting are untouched.

---

## 7. Rollout and verification

### 7.1 Pre-flight

Confirm nobody is connected. ⚠️ The `Connections N` counter is up to 10 minutes stale —
corroborate with socket events, which are current:

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --since=5m | Select-String "Got connection|Closing socket"
```

This mod does **not** kick, so no coordinated client window is required. Players may install
`blacks7ar-LazyVikings-1.2.3` at leisure; see §8.

### 7.2 Apply

From `valheim/`: server dry-run → apply (must report `configured`, never `unchanged`) →
`rollout restart` → `rollout status --timeout=600s`.

### 7.3 Verify — the parse check first

🚨 **This is the gate, and it must run before anything else is believed.**

```powershell
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "could not be parsed"
```

**Empty is the pass.** This single check catches both things §4 inferred rather than
observed — a wrong `Enable` key name and a wrong value type. A `[cfg ]` line in the
installer log means the applier wrote the file; it never means the mod accepted the value.

Then:

| Check | Expected |
|---|---|
| `fetch-mods` log | `[ok ] LazyVikings 1.2.3`; `1 installed, 13 already present`; `0 to remove`; 14 plugin dirs |
| Chainloader | `14 plugins to load`; `Loading [LazyVikings …]`; `Chainloader startup complete` |
| Config authorship | `blacks7ar.LazyVikings.cfg` carries `##` headers and **far more than 17 keys**. Exactly 17 keys with no `##` means `set_cfg` invented it — wrong GUID, pins inert |
| All 18 section headers present | and each read back at its intended value |
| Fourteen disabled sections | every one reads `Enable = Off` |

⚠️ Run the config checks only **after** `Chainloader startup complete` appears. The
initContainer writes the file before the game starts, so reading it too early shows only
what `set_cfg` wrote.

### 7.4 Verify — in game

| Check | Expected |
|---|---|
| Raw meat in a chest beside a cooking station, player walks away | meat is added and cooked **unattended** |
| **Smelter with ore in a nearby chest** | behaves exactly as before — V+ still owns it, no double-feeding |
| **Kiln, windmill, fermenter** | unchanged |

⚠️ The second and third rows are the **negative cases**, and they matter more than the
first. The whole design rests on LazyVikings staying out of stations V+ owns. A working
grill proves the feature; an unchanged smelter proves the containment.

Note that automation runs on the **ZDO owner**, so behaviour may differ depending on who is
nearby — the same caveat this repo already records for PlantEverything. Verify with a client
that has the mod and one that does not before assuming they agree.

---

## 8. Client install

Recommended, not required — it does not kick. Config is pushed by ServerSync, so a client
with the mod gets the server's settings automatically.

Because automation runs on the ZDO owner, a player without the mod standing near a cooking
station may see no auto-fill while a player with it does. That is the PlantEverything
pattern, and it is why client install is recommended rather than optional-and-ignored.

---

## 9. Rollback

Delete the `MODS` line and the seventeen `MOD_CONFIG` lines, apply, restart. The installer
prunes the plugin directory from both the staged copy and the live install and drops the
`.mod-state` marker. One mod, so the `>2` bulk-prune breaker is untouched.

**Clean.** No prefab registration, so nothing orphans in the world save — LazyVikings is a
pure runtime-patch mod. V+ needs no restoration because it was never changed.

Residual: the orphaned `blacks7ar.LazyVikings.cfg` stays on the PVC; the installer never
deletes config files.

---

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `Enable` key name inferred from string interning, not observed | Medium | §7.3 parse check catches it on the first boot; fallback is the two-phase apply from §5 |
| Toggle `On`/`Off` inferred from *"If On, …"* phrasing | Medium | Same parse check. This exact failure mode cost two restarts on 2026-07-31 |
| A disabled section silently flips on in a future version | Medium | All fourteen pinned explicitly and reapplied every boot |
| Double-automation of a V+ station | High if it occurs | §7.4 negative cases; the fourteen `Off` pins are the control |
| Per-station detection range wrong for cooking stations | Low | Not pinned; adjust as a follow-up once observed |
| Mod is 9.5 months old | Low | Author actively publishing; Prefix patches, not transpilers; not deprecated; dependency matches |

---

## 11. Correction — 2026-08-02, after Task 1 review

**§6.2's table (row for `04- Blast Furnace`, `08- Hot Tub`, `17- Steel Kiln`,
`18- Steel Slack Tub`) was wrong.** It grouped all four under "not present / not automated
here; off for consistency" — but `04- Blast Furnace` is not in that group.

Checked against the live ValheimPlus config: V+ names the Blast Furnace `[Furnace]`, not
`[BlastFurnace]`, and that section is `enabled = true` with both `autoDeposit = true` and
`autoFuel = true`. It belongs with the ten already-owned rows above it, not with the three
genuinely-absent ones. The naming mismatch (`[Furnace]` vs. the intuitive `[BlastFurnace]`)
is almost certainly why the original table missed it.

The corrected split is **eleven** rows already owned by ValheimPlus (`03- Beehive`,
`04- Blast Furnace` → V+ `[Furnace] autoDeposit`/`autoFuel`, `06- Eitr Refinery`,
`07- Fermenter`, `10- Kiln`, `11- SapCollector`, `12- Smelter`, `13- Spinning Wheel`,
`14- Stone Oven`, `15- Windmill`, `16- Fireplace`) and **three** pinned off for consistency
rather than collision (`08- Hot Tub` — V+ `[HotTub]` exists but is `enabled = false`;
`17- Steel Kiln` and `18- Steel Slack Tub` — OdinSteelWorks pieces, and that mod is not
installed here). Fourteen total either way; the `Off` pins in `mods-configmap.yaml` did not
change, only which bucket `04- Blast Furnace` belongs in.

The manifest (`valheim/mods-configmap.yaml`) is the source of truth and has been corrected
directly, along with its comment block. This section is left as an append per this repo's
convention of not rewriting shipped decisions — the wrong table above is left as written.
