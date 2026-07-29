# Add OdinHorse, Retire SkilledCarryWeight — Design

**Date:** 2026-07-29
**Status:** Approved
**Scope:** Swap SkilledCarryWeight for OdinHorse, port the lost carry-weight behaviour
to ValheimPlus, and make mod removal declarative.
**Depends on:** `2026-07-26-valheim-bepinex-design.md`

---

## 1. Goal

Install OdinHorse 1.6.5 on the Valheim server. It conflicts with the installed
SkilledCarryWeight mod, so SkilledCarryWeight is removed and the part of its
behaviour worth keeping — raised carry weight — is reimplemented in ValheimPlus,
which is already installed.

Removing a mod turns out to be something this repo cannot currently do without
manual intervention, so a declarative prune is added to `install-mods.sh` as part
of this work.

Non-goals: OdinHorse saddle storage (see §5), any other gameplay change, any
change to the V+ sections not named here.

---

## 2. Why the two mods conflict

OdinHorse adds a horse cart that is deliberately *"too heavy to be used to drag
with Player"*. That weight is the design constraint making the horse worth taming.

SkilledCarryWeight attacks it from two directions:

- **Cart Mass Reduction** scales cart mass down as max carry weight rises —
  `ModifiedMass = Max(Mass * (1 - MaxMassReduction), Mass * (MinCarryWeight/MaxCarryWeight) ^ Power)`
- **Quick Cart** binds a hotkey (default `G`) that attaches the player to any
  nearby cart

Together a player simply walks off with the horse cart. This is the incompatibility
OdinHorse's page warns about; it does not name a mechanism, and the above is the
mechanism.

**The conflict is not resolvable by configuration.** SkilledCarryWeight has to go.

---

## 3. Starting state

Verified in the running container on 2026-07-29, not inferred from manifests:

| Check | Result |
|---|---|
| Mods in `MODS` | 12 |
| `/config/bepinex/plugins/` | exactly those 12 dirs, nothing foreign |
| `/opt/valheim/bepinex/BepInEx/plugins/` | exactly those same 12 dirs |
| `/config/bepinex/.mod-state/` | exactly those same 12 markers |
| SkilledCarryWeight artifacts | 4 paths across both PVCs (§6) |
| World location | `/config/worlds_local/TreeFellMeFirst.db`, 5.2 MB, on `valheim-data` |
| World data on `valheim-server` | **none** — zero `.db`/`.fwl` files, no `worlds*` dir |
| `/opt/valheim/bepinex/BepInEx/config` | symlink → `/config/bepinex` (so configs live on `valheim-data`) |

That both plugin directories contain exactly the 12 mods in `MODS` and nothing
else is what makes a prune keyed off `MODS` safe — there is no foreign directory
it could destroy.

---

## 4. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| SkilledCarryWeight | Remove | Conflict is structural, not configurable |
| Carry weight replacement | V+ `[Player] baseMaximumWeight = 850` | Matches what SkilledCarryWeight gave at ~average skill 50 |
| Megingjord | Pin at vanilla `150` | Enabling `[Player]` makes the key live; pinning makes "unchanged" a decision in git rather than an accident |
| `autoRepair`, `autoEquipShield` | Enable both | Previously requested and refused *only* because `[Player]` was pinned off for SkilledCarryWeight. That objection dies with this change; see §5.1 |
| `[Workbench] disableRoofCheck` | Enable | Requested mid-execution. One added line — `[Workbench]` is already enabled for `workbenchRange`. See §5.2 |
| Tool durability `+150%` | Enable | Requested mid-execution. Reverses a deliberate "tools stay at vanilla" decision, so the comment asserting that must be rewritten, not just the values. See §5.3 |
| `[Gathering] +100%`, `[Experience] pickaxes +100%` | Enable both | Requested mid-execution as "increase tool damage", which V+ cannot do. These are the two honest substitutes. See §5.4 |
| V+ `[Wagon]` | **Stays disabled** | Its `wagonBaseMass=20` would stomp the horse cart back to draggable — reintroducing the exact bug this work removes |
| OdinHorse version | 1.6.5 | See §7 |
| OdinHorse config | None — ship at defaults | Saddle storage stays off; §5 |
| Mod removal | Declarative prune in `install-mods.sh` | The alternatives are untracked drift or a 20-minute reinstall that does not even finish the job (§6) |

### Rejected: deleting the `valheim-server` PVC

Initially attractive — that PVC is disposable and the repo already documents it as
the clean path. Investigation killed it on two counts:

1. **It does not remove the mod.** `/config/bepinex/plugins/SkilledCarryWeight/`
   lives on `valheim-data` and survives, and the bootstrap `rsync` copies it
   straight back into the fresh install. The `valheim-data` cleanup is required
   regardless, so the PVC delete would accomplish only one of three deletions.
2. **It is not lossless.** `/opt/valheim/bepinex/BepInEx/vplus-data/TreeFellMeFirst_mapSync.dat`
   (82 KB, actively written) is ValheimPlus's shared-map pool backing the enabled
   `Map|shareMapProgression|true`. Deleting the PVC resets it. Players keep their
   own client-side maps; the shared pool starts over.

Neither fact is recorded anywhere in the repo today. The `pvc.yaml` comment saying
the PVC "does not affect the world" is true and remains true — it is just not the
same claim as "loses nothing".

### Rejected: CookingStationTweaks

Proposed mid-execution (`Grizzzly/CookingStationTweaks` 0.7.1). Researched and declined.

The features are genuinely useful — `PreventBurning` and `AutoPop` default true, `SlotMultiplier`
2.5 taking cooking stations 2→5 slots and ovens 4→10 — and there is **no key collision with V+**,
whose `[Oven]` section covers only fuel (`autoFuel`, `autoRange`, `ignorePrivateAreaCheck`).
Grizzzly's is also the correct fork: 0.7.1 (2025-05) against yeldarb420's 0.6.0 (2024-06) and
digitiliad's deprecated 0.2.0.

**Declined because it has no enforcement mechanism.** It ships no `ServerSync` and no Jotunn
dependency, so unlike the rest of this stack it can neither kick mismatched clients
(AzuExtendedPlayerInventory, AzuContainerSizes) nor push config from the server (ValheimPlus,
`serverSyncsConfig = true`). Correct client configuration would be convention rather than
mechanism — the only mod in the set where that is true.

The failure mode is the one this repo already documents for AzuContainerSizes: *"Shrinking a
container that already holds items puts those items in slots that no longer exist."* A player
running a different `SlotMultiplier`, or none, sees a different slot count on a shared station,
and food in the extra slots is invisible and unrecoverable to them. Silent, per-player, and
awkward to diagnose.

Artifact facts recorded so this does not need re-researching: sha256
`62c11fa57ca3ff34d0ef09942da77966835ce042ca03e378e7eb749398714477`, 115,605 bytes, layout `root`,
sole dependency `denikson-BepInExPack_Valheim-5.4.2202` (server runs 5.4.2333). Config file is
`aedenthorn.CookingStationTweaks.cfg`; pinning it would need a second apply, since `MOD_CONFIG`
requires key names that do not exist until the mod first generates the file.

### Rejected: keeping SkilledCarryWeight and skipping OdinHorse

Viable, but the ask was OdinHorse. Recorded only to note that the horse cart is the
sole casualty — if the horse cart were abandoned, the two mods could coexist with
Cart Mass Reduction and Quick Cart disabled.

---

## 5. What is lost, and what replaces it

| SkilledCarryWeight behaviour | Disposition |
|---|---|
| Carry weight scaling with skill (~+550 at avg level 50) | Replaced by V+ `baseMaximumWeight = 850` — flat, not scaling |
| Cart mass reduction | **Deliberately dropped.** This is the conflict |
| Quick Cart hotkey (`G` attach/detach) | **Lost, no replacement.** V+ has no equivalent |

**The real cost is progression.** Carry weight stops being something skill levels
earn and becomes a constant. A brand-new character now starts with what previously
took roughly 50 average skill levels to reach. Nobody is downgraded unless their
average skill already exceeds 50. This is a gameplay judgement, made deliberately,
not a technical consequence.

Context for the number: `[Items] baseItemWeightReduction = -75` is already in force,
so everything weighs 25%. 850 is therefore ~3400 vanilla-equivalent hauling capacity.

### 5.1 What enabling `[Player]` unblocks

`README.md` records two settings as **requested and deliberately not applied**:

> *"Two requested settings were deliberately NOT applied — `autoEquipShield` and
> `autoRepair` both live in `[Player]`, which is pinned off because `baseMaximumWeight`
> there collides with SkilledCarryWeight."*

The stated objection was patch-order ambiguity between V+ and SkilledCarryWeight on
the same carry-weight property. With SkilledCarryWeight removed there is no second
mod patching it, so the objection no longer applies. Both are enabled:

```
valheim_plus.cfg|Player|autoRepair|true
valheim_plus.cfg|Player|autoEquipShield|true
```

`autoRepair` pairs with the `+100%` `[Durability]` already in force — fewer repair
trips, and the remaining ones are automatic. `autoUnequipShield` is a **separate key**
and stays at `false`.

**Precondition verified against the live generated `valheim_plus.cfg`, not upstream
docs.** The installed Grantapher 9.17.1 `[Player]` section carries **24 keys**, not the
3 the upstream documentation implies. All 24 were checked: every one sits at a
vanilla-equivalent default (`deathPenaltyMultiplier = 0` and `fallDamageScalePercent = 0`
are modifiers at no-op; `maxFallDamage = 100` is annotated *"Game default is 100"*;
`guardianBuffDuration = 300` / `guardianBuffCooldown = 1200` match vanilla). Enabling the
section is therefore neutral apart from the four keys pinned here.

⚠️ **Re-verify this if V+ is ever upgraded.** A new release adding a non-neutral default
to `[Player]` would silently take effect, because the section is now enabled rather than
pinned off.

`serverSyncsConfig = true` means both settings propagate to clients — no client-side
action for these two.

### 5.2 Workbench roof requirement

Requested during execution, after the design was approved. Recorded here so the change is not
archaeology later.

Vanilla requires a workbench to be roofed and unexposed before it will function. The installed
V+ exposes this in a section that is **already enabled**, so it costs one line:

```
valheim_plus.cfg|Workbench|disableRoofCheck|true
```

Read from the live generated `valheim_plus.cfg` at 9.17.1, not upstream docs:

```
; Disables the roof and exposure requirement to use a workbench.
disableRoofCheck = false
```

`[Workbench]` is already `enabled = true` for `workbenchRange = 40` and
`workbenchAttachmentRange = 10`, so no new section is turned on and no new keys become live
beyond this one.

**It compounds with `autoRepair` from §5.1.** Auto-repair triggers on interacting with a
workbench; while the roof check stands, that only works under a roof. Both together are what
make repair automatic anywhere.

Not included: `[Hatchery] requireShelter` (*"whether or not an egg requires a roof and fire to
grow"*) is the same family of restriction but a different feature, and was not asked for.

### 5.3 Tool durability

Requested during execution. `[Durability]` is already enabled at `+100%` on combat gear
(`weapons`, `axes`, `bows`, `shields`, `armor`); the five tool keys sit at vanilla `0`:

```
valheim_plus.cfg|Durability|pickaxes|150
valheim_plus.cfg|Durability|hammer|150
valheim_plus.cfg|Durability|cultivator|150
valheim_plus.cfg|Durability|hoe|150
valheim_plus.cfg|Durability|torch|150
```

⚠️ **These are percentage modifiers.** V+'s own annotation: *"The value 50 will increase the
durability from 100 to 150."* So `150` means 100 → **250**, i.e. 2.5×, not "150 units".

**This deliberately puts tools above combat gear (+150% vs +100%), and that asymmetry needs
defending in the manifest** or someone will "correct" it. The existing comment already
establishes the reasoning that makes it consistent: durability on combat gear stays adjacent to
balance — it governs how long you last in a fight before a weapon breaks — while tool durability
is pure convenience, changing only how often you walk back to a workbench. Tools being the more
generous number follows from that distinction rather than contradicting it.

**`axes` stays at 100 with the weapons, not with the tools.** An axe is a weapon that also chops
wood, and it was raised on that basis. Moving it would be a combat-balance change disguised as a
tools change.

**`torch` is grouped with the tools.** It is a light source rather than a tool, but its
durability is burn time — the same kind of convenience number.

🚨 **This reverses a documented decision.** The current manifest says *"Tools are deliberately
left at vanilla 0: pickaxes, hammer, cultivator, hoe, torch. The ask was weapons and armor."*
That comment is aimed at exactly this edit. It must be **rewritten**, not left standing next to
contradicting values — a comment that argues against the code beside it is worse than no comment.

### 5.4 Mining yield and pickaxe skill rate

Asked for as *"change how much damage tools do such as pickaxes by 100%"*.

🚨 **ValheimPlus cannot do this.** Verified by enumerating all 58 sections and every key
containing "damage" in the live generated config. The complete set is `[Game]
gameDifficultyDamageScale` (monster scaling per nearby player), `[Player] baseUnarmedDamage`
(fists only), `fallDamageScalePercent` / `maxFallDamage`, `[StructuralIntegrity]
disableDamageTo*`, and `[Ship] waterImpactDamage`. There is no `[Damage]` section and no
per-weapon-type modifier. The only three `pickaxes` keys in the file are `[Experience]`,
`[Durability]` and `[StaminaUsage]`.

Since pickaxe damage is what governs how many swings a node takes, the underlying goal is read
as *less tedious mining*. Two substitutes were chosen:

**`[Gathering]` at `+100%`** — doubles the yield from every node broken with a tool. Not a
damage change: the rock takes the same swings, but fewer rocks are needed.

⚠️ **This compounds with `-modifier resources more`** in `configmap.yaml`, a *native* global
drop multiplier already one step above normal. The effective multiplier therefore exceeds 2×.
Anyone tuning drops later must know there are two independent sources.

`dropChance` stays at `0` deliberately — it is a different mechanic, raising the *chance* on
nodes without a guaranteed drop (dungeon scrap piles) rather than the *amount* from ore veins.

**`[Experience] pickaxes` at `+100%`** — the only route V+ offers to genuinely more pickaxe
damage. Skill level scales tool damage in vanilla, so faster Pickaxes leveling means fewer
swings per rock. **Self-limiting:** once the skill reaches 100 it contributes nothing further.

Both sections are currently `enabled = false`, so both get enabled. Every other key in each sits
at `0`, which is a no-op — the same "enabling the section is neutral apart from what we pin"
situation as `[Player]` in §5.1, and it carries the same ⚠️ **re-verify on any V+ upgrade**
caveat, for the same reason: an enabled section adopts new non-neutral defaults silently where a
disabled one cannot.

Rejected: adding a mod that edits item stats directly. It is the only way to set tool damage
outright, but it means a new pinned dependency, a new client-side install for every player, and
new supply-chain surface. That would be its own spec, not a fold-in to this migration.

**OdinHorse saddle storage stays off.** Version 1.6.1 added it *"disabled by default
for performance optimization"*. Enabling it would require a second apply — `MOD_CONFIG`
needs exact section and key names, and those do not exist until the mod generates its
`.cfg` on first boot. Deferred as its own change if wanted later.

---

## 6. The changes

### 6.1 `valheim/mods-configmap.yaml` — `MODS`

Remove:

```
SkilledCarryWeight  1.4.1  https://thunderstore.io/package/download/Searica/SkilledCarryWeight/1.4.1/  efdd...  root
```

Add OdinHorse 1.6.5. Checksum and layout captured from the real artifact on 2026-07-29
via the procedure in the file's own header — **not** guessed:

| Field | Value |
|---|---|
| sha256 | `23a455aa79c074f2098107ea9f09f044460442d152732d928f511a16023209bc` |
| size | 9,174,319 bytes |
| layout | `root` |

The checksum was confirmed **reproducible across two independent downloads**. Layout is
`root` because the zip contains exactly `CHANGELOG.md`, `icon.png`, `manifest.json`,
`OdinHorse.dll`, `README.md` — a bare DLL at the zip root, with no `plugins/`,
`BepInEx/` or `config/` directory. This matches the header's rule that layouts are
"verified against each zip's actual contents, not assumed."

`manifest.json` reads `"dependencies": []`, confirming from the artifact itself what the
Thunderstore API reports.

Net mod count stays **12** — one out, one in.

### 6.2 `valheim/mods-configmap.yaml` — `MOD_CONFIG`

Delete every `Searica.Valheim.SkilledCarryWeight.cfg|…` entry — 48 of them, one
`Enabled` and one `Coefficient` per skill across 24 skills — together with the
comment block introducing them (the one explaining the `Coefficient 0.5` formula and
the `<ZWSP>Enabled` caveat). As of this writing that is lines 92–152, but match on
content: line numbers shift as the other edits in this section land.

Change the `[Player]` pin from off to on, and add the two values:

```
valheim_plus.cfg|Player|enabled|true
valheim_plus.cfg|Player|baseMaximumWeight|850
valheim_plus.cfg|Player|baseMegingjordBuff|150
valheim_plus.cfg|Player|autoRepair|true
valheim_plus.cfg|Player|autoEquipShield|true
```

⚠️ **Both keys are absolute values, not percentages** — vanilla defaults are 300 and
150 respectively. This inverts the convention of `[Armor]` and `[Durability]`
immediately above them in the same file, where the numbers *are* percentage modifiers.
This needs a comment in the repo's existing style, aimed at the future edit that would
read `850` as "+850%".

Rewrite the justification comment above the V+ pins. It currently attributes three
pins to SkilledCarryWeight collisions:

- `[Inventory]` — drop the SkilledCarryWeight clause, **keep** the AzuEPI and
  AzuContainerSizes clauses; the pin survives on those grounds alone
- `[Player]` — reason disappears entirely; the section is now enabled
- `[Wagon]` — reason is **replaced**, not deleted. The pin must survive because
  `wagonBaseMass=20` would override OdinHorse's deliberately-heavy horse cart

Also revisit the two "watch if you enable" notes on `[Items] baseItemWeightReduction`
and `[Stamina]` overweight drain, which are framed against SkilledCarryWeight.

### 6.3 `valheim/mods-configmap.yaml` — `install-mods.sh`

Add a prune, running after the install loop:

- Build the desired set from `MODS`
- **Guard: refuse to prune if the desired set is empty.** A malformed `MODS` must not
  be able to wipe the install
- **Guard: every deletion uses the `${PLUGINS:?}` idiom already established in
  `install_one`.** `/config/bepinex/plugins` is on `valheim-data` — the same Longhorn
  volume as `/config/worlds_local/TreeFellMeFirst.db`. An unset or empty path variable
  in an `rm -rf` is the one bug in this change that could reach the world. `:?` makes
  the shell abort rather than expand to a bare root path. This is not optional and it
  is not stylistic
- Delete any directory in `/config/bepinex/plugins/` not in the set, plus its
  `.mod-state` marker
- Delete any directory in `/opt/valheim/bepinex/BepInEx/plugins/` not in the set
- **Guard: skip the live path when absent** — normal on a cold `valheim-server` PVC

Both paths are required. Pruning only the staged copy leaves the live one, because
the image's bootstrap sync is `rsync -a` with no `--delete` — the exact reason the
current header comment calls manual deletion necessary.

Leave the zero-width-character `norm()` logic **in place**. Its comment is written
entirely around SkilledCarryWeight's `U+200B` prefixes and that mod is leaving, but
`norm()` also strips the `\r` that `valheim_plus.cfg` depends on. Without it every V+
pin in this file would miss its section and silently append a duplicate. Update the
comment to record that the ZWSP handling is now defensive rather than load-bearing,
and that the CRLF handling still is.

### 6.4 `valheim/deployment.yaml`

Mount the `server` PVC in the `fetch-mods` initContainer at `/opt/valheim`, so the
prune can reach the live install. Both PVCs are ReadWriteOnce Longhorn volumes and
the pod already mounts both; `strategy: Recreate` means there is no second pod to
contend with.

### 6.5 `valheim/README.md`

- Mod table: swap the SkilledCarryWeight row for OdinHorse 1.6.5, client install
  **required** (both-sides mod)
- The "**Twelve mods are installed**" prose is already correct — count is unchanged
- Client section: add the explicit **uninstall** instruction for SkilledCarryWeight
- The `REMOVING A MOD` header comment in `mods-configmap.yaml` becomes a description
  of the prune rather than a manual footgun

---

## 7. Version choice: OdinHorse 1.6.5

1.6.5 is three days old (2026-07-26, 3,126 downloads). Pinned anyway because **1.6.2
was a server-specific fix** — *"Fixed issue causing error when using Mod on Server.
Any array-typed config, fixed at the ServerSync.cs layer"* — so anything older than
1.6.2 is actively wrong for a dedicated server. Everything after 1.6.2 is cosmetic:
saddle storage option (1.6.1), horse colours (1.6.3, 1.6.4), breeding colour
inheritance (1.6.5).

Zero declared dependencies. Jotunn is already installed regardless.

---

## 8. Client rollout — mandatory, out of band

Every player must:

1. **Uninstall SkilledCarryWeight**
2. **Install OdinHorse 1.6.5**

Step 1 is not optional politeness. SkilledCarryWeight functions as a client-side mod,
so a player who keeps it retains local Cart Mass Reduction and Quick Cart and can
still walk off with the horse cart regardless of what the server does. Removing it
server-side is necessary but **not sufficient**.

This is consistent with the README's existing position that vanilla clients cannot
join and every player runs a matching pinned set via r2modman.

---

## 9. Verification

Per CLAUDE.md, a check only ever observed passing has not been verified.

**The prune needs both directions tested:**

- **Positive:** a mod dropped from `MODS` is removed from both plugin directories and
  its `.mod-state` marker is gone
- **Negative:** all 12 mods listed in `MODS` survive a prune untouched

A prune only ever observed not-deleting is not verified. The empty-set guard needs
its own check.

**Other verification:**

- `kubectl apply` must report `configured`, never `unchanged`
- After editing `mods-configmap.yaml`, re-read it and confirm key counts changed by
  exactly the expected amount — an appended duplicate is the signature of a failed match
- Confirm `Searica.Valheim.SkilledCarryWeight.cfg` no longer has a running consumer,
  and that carry weight in-game reflects 850 rather than a skill-derived number
- Confirm the horse cart cannot be dragged by a player

**Before applying:** take a manual Longhorn snapshot. OdinHorse's own page asks for a
backup before install, and this is a live world with a 5.2 MB save. Single-replica
`Recreate` means the apply is an outage — confirm nobody is connected.

---

## 10. Risks

| Risk | Assessment |
|---|---|
| Prune deletes a wanted mod | Guarded two ways and verified in both directions. Highest-consequence part of this change; review closely |
| Prune reaches the world | `/config/bepinex/plugins` shares the `valheim-data` volume with `TreeFellMeFirst.db`. This is the only path in this change that could touch the world. Guarded by `${PLUGINS:?}` and the empty-set check; see §6.3 and §11 |
| Removing OdinHorse *later* orphans world data | **Adding a prefab mod is closer to one-way than removing SkilledCarryWeight is.** Tamed horses, bred offspring and horse carts persist as ZDOs in `TreeFellMeFirst.db`. Pulling OdinHorse afterwards loses them and can throw load errors. Not a risk of this change — a risk this change creates. Weigh it before installing, not after |
| initContainer gains write access to the game install | Necessary for the prune. Scoped to directories not in `MODS` |
| Flat carry weight feels like lost progression | Accepted deliberately; see §5 |
| A player keeps SkilledCarryWeight client-side | Horse cart is draggable for that player. No server-side mitigation exists — §8 is the only control |
| OdinHorse 1.6.5 is three days old | Mitigated by §7; the server-relevant fix landed three versions earlier |
| Orphaned `Searica.Valheim.SkilledCarryWeight.cfg` on the PVC | Harmless with no DLL to read it. Left in place |

---

## 11. World data safety

The owner's stated condition for proceeding is that `TreeFellMeFirst` loses no data.
Recorded here as an acceptance criterion, with the reasoning that satisfies it.

**Nothing in this change writes to `/config/worlds_local`.** The world file is never
a target of any step.

**Removing SkilledCarryWeight orphans nothing in the world DB.** It is a pure runtime
Harmony patch — carry weight, cart mass, a hotkey. It registers no prefabs and no
items, so nothing of it is persisted in `TreeFellMeFirst.db`. This is specific to this
mod and does not generalise: removing EpicLoot, Warfare, Armory or OdinsFoodBarrels
*would* orphan item prefabs, and that would be genuine data loss.

**The only path that could reach the world is the prune**, because
`/config/bepinex/plugins` shares the `valheim-data` volume with the save. Guarded by
`${PLUGINS:?}` and the empty-set check (§6.3), and verified in both directions (§9).

**The restart is the already-exercised path.** `terminationGracePeriodSeconds: 120`
exists because Valheim needs ~2 minutes to flush the world on SIGTERM.

**Safety net verified live on 2026-07-29**, rather than assumed:

| Check | Result |
|---|---|
| `recurring-job-group.longhorn.io/valheim` on the Volume | `enabled` — present. The silent-unlabeled failure mode CLAUDE.md warns about is not in play |
| Longhorn snapshots retained | 7, newest 2026-07-29T11:00:00Z, `readyToUse=true` |
| In-game auto-backups in `worlds_local` | 4, newest 06:10 same day |
| Off-cluster | CloudCasa (`cloudcasa-io`) |

A manual Longhorn snapshot immediately before applying is still required (§9). The
daily job is a floor, not a substitute for one taken against the exact pre-change state.
