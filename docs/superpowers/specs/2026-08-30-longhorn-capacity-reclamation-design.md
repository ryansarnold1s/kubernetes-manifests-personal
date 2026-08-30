# Longhorn Capacity Reclamation via Kubelet Image GC — Design

**Date:** 2026-08-30
**Status:** Approved
**Target cluster:** `k8` (Talos v1.13.4 / Kubernetes v1.35.4, Rancher-managed)
**Blocks:** `2026-08-30-icarus-server-deployment-design.md`

---

## 1. Goal

Restore Longhorn-schedulable capacity on the four Talos worker nodes by making kubelet garbage
collect its container image cache, and set `vm.max_map_count` for the pending ICARUS deployment.
Both are Talos machine-config changes that apply **without a node reboot**.

**Non-goals:** expanding any disk (deferred, §8), separating Longhorn from the containerd image
cache onto its own disk (declined, §9), changing any workload manifest.

### 1.1 How this design was reached

The ICARUS deployment design originally called for expanding every worker's EPHEMERAL partition
by 250 GiB — 1 TB of datastore — to create room for a 50 Gi install volume. That plan was
superseded during investigation. Longhorn replica *placement* did not match the free space: the
two nodes holding the **fewest** replicas had the **least** free space. That contradiction is what
led to `imagefs`, and to the finding in §2.2. **The capacity problem is not a Longhorn problem.**

---

## 2. Findings

All figures measured on 2026-08-30 via `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary`
and the Longhorn CRs. Recorded here because they are the pre-change baseline every verification in
§7 compares against.

### 2.1 Disk usage

Worker `nodefs` capacity is 398.6 GiB (`417993308Ki`); control-plane is 48.8 GiB (`49932Mi`).
`nodefs` and `imagefs` are the same filesystem — the Talos EPHEMERAL partition — on every node.

| Node | Role | nodefs used | % | of which images | images as % of used |
|---|---|---|---|---|---|
| `talos-0ag-qr8` | worker | 247.3 GiB | 62 % | **178.4 GiB** | 72 % |
| `talos-mql-msp` | worker | 295.2 GiB | 74 % | **164.7 GiB** | 56 % |
| `talos-uup-vn3` | worker | 295.1 GiB | 74 % | **151.8 GiB** | 51 % |
| `talos-z9a-dpj` | worker | 231.6 GiB | 58 % | **157.7 GiB** | 68 % |
| `talos-c2v-wpu` | control-plane | 10.0 GiB | 21 % | 7.0 GiB | 70 % |
| `talos-kwn-eng` | control-plane | 9.5 GiB | 19 % | 6.4 GiB | 67 % |
| `talos-pha-6st` | control-plane | 9.2 GiB | 19 % | 6.2 GiB | 65 % |

**652.6 GiB of container images across the four workers.** Pod ephemeral storage is negligible by
comparison — the largest consumer on `talos-mql-msp` is the Rancher pod at 2.14 GiB, and all 41
pods on that node together account for roughly 2.4 GiB.

### 2.2 Why the cache grew without bound

Kubelet's live configuration, read from `/api/v1/nodes/talos-mql-msp/proxy/configz`:

```
imageGCHighThresholdPercent : 85
imageGCLowThresholdPercent  : 80
imageMinimumGCAge           : 2m0s
imageMaximumGCAge           : 0s     (disabled)
```

No worker has ever reached 85 %, so **kubelet has never garbage collected a single image.** Every
image the cluster has ever pulled is still resident. The `node.status.images` list on
`talos-mql-msp` — capped at 50 entries, so this is the visible tip — shows nine concurrent
versions of `rancher/rancher` (v2.10.3, v2.11.2, v2.12.1, v2.12.2, v2.13.1, v2.14.0, v2.14.2,
v2.14.3, v2.15.0), four of `rancher-agent`, and four of `rocket.chat`. The 41 pods on that node
use 33 distinct images; of the Rancher versions only `v2.15.0` is among them.

### 2.3 Longhorn capacity

`storage-minimal-available-percentage: 25`, so Longhorn refuses any replica that would drop a disk
below 99.66 GiB free. `storage-over-provisioning-percentage: 200` and `storageReserved` of
119.6 GiB per disk are **not** the binding constraint at these volumes.

| Node | Replicas | Scheduled | Available | Headroom above the 25 % floor |
|---|---|---|---|---|
| `talos-z9a-dpj` | 31 | 335 GiB | 167.0 GiB | 67.3 GiB |
| `talos-0ag-qr8` | 27 | 305 GiB | 151.3 GiB | 51.6 GiB |
| `talos-uup-vn3` | 9 | 154 GiB | 103.5 GiB | **3.9 GiB** |
| `talos-mql-msp` | 7 | 123 GiB | 103.4 GiB | **3.8 GiB** |
| | | | | **126.6 GiB total** |

Two of four storage nodes can accept essentially no new replica, so a node failure today cannot
fully rebuild its replicas elsewhere. All 37 volumes are `robustness: healthy` at 2 replicas;
three are `detached` (the parked `enshrouded` workload).

### 2.4 Projection

With `high 70 / low 50`, only `mql` and `uup` currently exceed the high threshold and collect
immediately, each falling to ~199.3 GiB used. `0ag` (62 %) and `z9a` (58 %) are below it and stay
warm until they cross it.

| Node | Headroom now | Headroom after GC |
|---|---|---|
| `talos-mql-msp` | 3.8 GiB | ~99.6 GiB |
| `talos-uup-vn3` | 3.9 GiB | ~99.6 GiB |
| `talos-0ag-qr8` | 51.6 GiB | 51.6 GiB (unchanged) |
| `talos-z9a-dpj` | 67.3 GiB | 67.3 GiB (unchanged) |
| **Total** | **126.6 GiB** | **~318 GiB** |

More usable headroom than a 250 GiB-per-node expansion would have produced on two nodes, at no
datastore cost and with no reboot. All four workers could then accept ICARUS's 50 Gi install
volume rather than only `z9a`.

---

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Primary mechanism | Kubelet image GC thresholds | The cache is the problem; disk was treating the symptom |
| Thresholds | `high 70` / `low 50` | 50 % = 199 GiB, comfortably above the ~130 GiB Longhorn data floor on the worst node, so kubelet can reach the target rather than churn |
| `imageMinimumGCAge` | Not set | Leave at the `2m0s` default; restating it would pin a future default change |
| `imageMaximumGCAge` | Declined for now | §9 |
| Scope | All seven nodes | Inert on control-plane at 19–21 %, and protects them later |
| `vm.max_map_count` | Same patch | Also a no-reboot machine-config change; batching avoids a second pass |
| Apply mode | `--mode=no-reboot` | Chosen for its failure behaviour — it errors rather than rebooting a node |
| Disk expansion | Deferred behind a trigger | §8 |

---

## 4. The change

A single Talos machine-config patch, applied to all seven nodes:

```yaml
machine:
  sysctls:
    # ICARUS prerequisite. vm.* is NOT a namespaced sysctl, so no pod-level
    # securityContext.sysctls can set this - it must be machine config.
    # Measured at 65530 on 2026-08-30; the icarus image OOMs under Wine below 262144.
    vm.max_map_count: "262144"
  kubelet:
    extraConfig:
      # Was 85/80. No worker has ever reached 85%, so kubelet had never collected
      # anything and 652 GiB of superseded images had accumulated cluster-wide.
      # 50% of 398.6 GiB = 199 GiB, which sits above the ~130 GiB of Longhorn data
      # on the worst node - so kubelet can actually reach the low threshold instead
      # of retrying every housekeeping cycle and never getting there.
      imageGCHighThresholdPercent: 70
      imageGCLowThresholdPercent: 50
```

Kubelet restarts to pick up the new configuration. Running containers are not disrupted by a
kubelet restart.

---

## 5. Apply procedure

```
talosctl -n <node-ip> patch machineconfig --patch @patch.yaml --mode=no-reboot
```

One node at a time, verifying §7 between each. Order is deliberate:

1. **One control-plane node** (`c2v`, `kwn` or `pha`). At 19–21 % used they are below the high
   threshold, so the config lands and GC provably does *not* fire. This isolates "did the patch
   apply" from "did collection work" — two questions that are hard to separate afterwards.
2. **The remaining two control-plane nodes.**
3. **`talos-mql-msp`.** The first node that will actually collect, and the one measured. Stop here
   and confirm the reclaimed figure before continuing.
4. **`talos-uup-vn3`**, then **`talos-0ag-qr8`** and **`talos-z9a-dpj`** (policy only; neither is
   above 70 %, so neither collects yet).

---

## 6. Rollback, and its limit

Re-applying the patch with `85`/`80` stops further collection immediately.

**It does not bring deleted images back.** The policy is reversible; the reclamation is not. That
asymmetry is the entire reason for the node-at-a-time order in §5 and for stopping to measure at
`mql`.

---

## 7. Verification plan

Every check has a negative case; a check only ever observed passing has not been verified.

| Claim | Proof | Negative case |
|---|---|---|
| Patch reached kubelet | `/api/v1/nodes/<node>/proxy/configz` shows `70`/`50` | `85`/`80` recorded in §2.2 today |
| Sysctl applied | `cat /proc/sys/vm/max_map_count` = `262144`, via the `longhorn-manager` DaemonSet pod on each node | `65530` recorded today |
| GC fired where expected | `imagefs.usedBytes` falls on `mql`/`uup` | And provably does **not** fall on the control-plane nodes, which are below the threshold |
| GC deleted the right things | `rancher/rancher:v2.10.3` gone from `node.status.images` while **`v2.15.0` remains** | Catches both a GC that deleted nothing and one that deleted an in-use image |
| Space reached Longhorn | Longhorn `storageAvailable` rises on `mql`/`uup` | Per-node pre-values in §2.3 |
| Nothing broke | No `ImagePullBackOff` cluster-wide; all 37 volumes stay `robustness: healthy` | 3 volumes are legitimately `detached` (parked `enshrouded`) — do not read that as a regression |

Reading `imagefs` and `nodefs`:

```
kubectl get --raw "/api/v1/nodes/<node>/proxy/stats/summary"   # .node.fs, .node.runtime.imageFs
kubectl get --raw "/api/v1/nodes/<node>/proxy/configz"         # live KubeletConfiguration
```

---

## 8. Deferred: EPHEMERAL expansion

Not done now, but the analysis is preserved so it need not be re-derived.

**Trigger to revisit:** any worker returns above 70 % `nodefs` after GC has settled, **or**
Longhorn headroom falls below 30 GiB on two or more workers.

**Sizing if triggered:** ~250 GiB per storage worker = 1 TB of the 1.5 TB free on the ESXi
datastore, thick-provisioned, leaving ~500 GB of datastore margin. Growing by 250 GiB yields
`103.4 + 250 − (25 % × 648.6) = 191.3` GiB of headroom per node.

**Mechanism:** Talos's EPHEMERAL volume defaults to `minSize: 2GiB, grow: true` with no `maxSize`
and is always the last partition, so it fills space appearing after it. Expand the VMDK, reboot,
Talos resizes partition and filesystem. This is the **only** part of this work that needs a
reboot.

**Must be confirmed before expanding:**

1. `talosctl get volumeconfig EPHEMERAL` shows no explicit `maxSize`. Talos applies volume
   configuration only to volumes not yet provisioned, so a `maxSize` set at install time caps
   growth and cannot be changed retroactively without wiping the volume.
2. ESXi will not expand a VMDK that has snapshots.
3. Reboot one node at a time with Longhorn volumes healthy in between.

---

## 9. Considered and declined

**`imageMaximumGCAge`.** Available in v1.35.4 and currently `0s`. It would collect on `0ag` and
`z9a` too, which a 70 % threshold never will. Declined for two reasons. KEP-4210 explicitly does
not track image age across kubelet restarts — applying this very patch restarts kubelet and resets
the clock to zero, and every future Talos upgrade resets it again, so on this cluster it would
rarely fire. And turning two levers simultaneously makes the §7 measurement meaningless: we would
not know which one freed the space. **Re-evaluate after the threshold change has been measured**,
at which point the reclaimed figure is known and a second variable can be introduced cleanly.

**A dedicated Longhorn disk** (second VMDK mounted at `/var/mnt/longhorn`). This is the only option
that genuinely separates Longhorn from the containerd image cache rather than giving them more
room to share. Declined as disproportionate: it needs a Talos user-volume document, Longhorn disk
registration, and replica migration node by node, and the image cache — the thing actually
consuming the partition — is being bounded by this change anyway.

**Expansion alone, no GC change.** The original plan. Rejected: it spends 1 TB to accommodate a
cache that grows without bound, and the same conversation recurs later with bigger disks.

---

## 10. Risks

| Risk | Assessment |
|---|---|
| Docker Hub anonymous pull rate limits during re-pulls | Real but bounded — re-pulls are demand-driven as pods need images, not a synchronized storm. Worth watching for `ImagePullBackOff` after the first collection |
| `gitea.arnoldtech.io` is an **in-cluster** registry hosting `finance-api` / `finance-frontend` | If those images are collected while gitea is down, those workloads cannot start. Bounded: gitea's own image comes from Docker Hub, so gitea itself can always start |
| Cold-start latency rises for workloads whose images were collected | Accepted; these are images unused long enough to be collection candidates |
| Kubelet restart on config apply | Non-disruptive to running containers |
| GC cannot reach the low threshold on a node whose Longhorn data alone exceeds it | Would show as repeated GC attempts in kubelet logs and no further reclamation. `low: 50` was chosen against the ~130 GiB (32.6 %) figure on the worst node specifically to avoid this |

---

## 11. Open items

1. ~~Install `talosctl` on the operator workstation — not currently present.~~ **Done
   2026-08-30** — `talosctl` v1.13.4 was already installed inside WSL at `/usr/local/bin`; the
   blocker was that WSL was not running. It also needs `export TALOSCONFIG="$HOME/talosconfig"`,
   because the default `$HOME/.talos/config` is an empty stub (`context: ""`). See
   `talos/README.md`.
2. ~~Locate the current Talos machine config / patch workflow before writing the patch file.~~
   **Done 2026-08-30 — and the answer was worse than assumed.** These nodes are **not** managed
   by Omni (no `siderolink`/`omni`/`kubespan` markers) and there is **no source-controlled full
   machine config**. The only stored configs are `~/controlplane.yaml` and `~/worker.yaml` in
   WSL, dated 2026-03-07 and pinning kubelet `v1.31.5` against a live cluster on `v1.35.4` —
   stale bootstrap artifacts, not a source of truth. Every live node read `version: 1`, written
   2026-07-27 and never patched until this change. Confirmed by `apply-config --dry-run` that a
   full apply **would silently revert all three keys** *and* attempt a kubelet downgrade, so
   there is nothing safe to fold this patch into. Recorded in `talos/README.md`.
3. ~~Re-measure after `mql` collects and record the actual reclaimed figure against the ~96 GiB
   projection in §2.4.~~ **Done 2026-08-30 — see §12.** The projection was wrong by +58 %
   (151.9 GiB actual vs ~96 GiB projected) because kubelet evicts the whole cache rather than
   trimming to the low threshold. §8's triggers survive it (they are absolute conditions, not
   derived arithmetic); the "settles near 50 %" expectation does not. Details and mechanism in
   §12.3.
4. ~~Update `2026-08-30-icarus-server-deployment-design.md` §4.~~ **Done 2026-08-30** — §4 now
   carries a correction note, §4.2 is rewritten around reclamation with an explicit capacity gate,
   and the §12 verification row was changed from "EPHEMERAL grew" to the headroom gate.

---

## 12. Results (measured 2026-08-30)

Applied to all seven nodes with `--mode=no-reboot`, one node at a time. **No node rebooted, no
pod was disrupted, and no workload lost an image it was using.**

### 12.1 Per-node before/after

| Node | Role | nodefs before | nodefs after | imagefs before | imagefs after | Reclaimed |
|---|---|---|---|---|---|---|
| `talos-c2v-wpu` | control-plane | 10.0 GiB (21 %) | 10.0 GiB (21 %) | 7.0 GiB | 7.0 GiB | — policy only |
| `talos-kwn-eng` | control-plane | 9.4 GiB (19 %) | 9.4 GiB (19 %) | 6.4 GiB | 6.4 GiB | — policy only |
| `talos-pha-6st` | control-plane | 9.2 GiB (19 %) | 9.2 GiB (19 %) | 6.2 GiB | 6.2 GiB | — policy only |
| `talos-mql-msp` | worker | 295.2 GiB (74.1 %) | **143.3 GiB (35.9 %)** | 164.7 GiB | **14.7 GiB** | **151.9 GiB** |
| `talos-uup-vn3` | worker | 295.1 GiB (74.0 %) | **153.2 GiB (38.4 %)** | 151.8 GiB | **11.9 GiB** | **141.9 GiB** |
| `talos-0ag-qr8` | worker | 247.3 GiB (62 %) | 247.3 GiB (62 %) | 178.4 GiB | 178.4 GiB | — below threshold |
| `talos-z9a-dpj` | worker | 231.6 GiB (58 %) | 231.6 GiB (58 %) | 157.7 GiB | 157.7 GiB | — below threshold |

**Total reclaimed: 293.8 GiB.**

### 12.2 Longhorn headroom — the number this work exists to produce

| Node | Before | §2.4 projected | **Actual** |
|---|---|---|---|
| `talos-mql-msp` | 3.8 GiB | ~99.6 GiB | **155.6 GiB** |
| `talos-uup-vn3` | 3.8 GiB | ~99.6 GiB | **145.8 GiB** |
| `talos-0ag-qr8` | 51.6 GiB | 51.6 GiB | 51.6 GiB |
| `talos-z9a-dpj` | 67.3 GiB | 67.3 GiB | 67.3 GiB |
| **Total** | **126.5 GiB** | ~318 GiB | **420.3 GiB** |

**ICARUS §4.2 capacity gate — PASSED.** It requires at least two workers with ≥60 GiB of
headroom; three now qualify (`mql-msp` 155.6, `uup-vn3` 145.8, `z9a-dpj` 67.3).

### 12.3 Correction to §2.4: the projection was wrong, in the safe direction

§2.4 predicted each collecting node would fall to "~199.3 GiB used" — kubelet trimming just far
enough to reach the 50 % low threshold, freeing ~96 GiB. **That is not what kubelet does.** Both
collecting nodes blew straight past 50 % and evicted essentially the entire cache, stopping only
when nothing evictable was left:

| | Projected | `mql-msp` | `uup-vn3` |
|---|---|---|---|
| Final nodefs | ~50 % | 35.9 % | 38.4 % |
| Final imagefs | ~69 GiB | 14.7 GiB | 11.9 GiB |
| Reclaimed | ~96 GiB | 151.9 GiB | 141.9 GiB |

Both nodes converged to the same place: only in-use images remain (14.7 and 11.9 GiB against
28 and 18 running pods).

**Mechanism.** Kubelet's fs statistics come from cadvisor and are cached, so within a collection
burst it keeps re-reading a stale pre-collection usage figure and keeps deleting. The node events
show this directly — three one-off events on `mql-msp`, none recurring afterwards:

- `FreeDiskSpaceFailed` at kubelet restart, `freed 0 bytes` — nothing was eligible yet, since
  `imageMinimumGCAge` is 2m and every image had only just become unreferenced.
- `FreeDiskSpaceFailed` / `ImageGCFailed` one round later, `freed 63019273231 bytes` (58.7 GiB),
  still reporting *"75 % of 398.6 GiB used"* — that percentage is the usage kubelet observed at
  the **start** of the round, not standing state.

Collection then ran for ~3 more minutes and stopped. No further GC events fired, `DiskPressure`
stayed `False`, and usage settled below the low threshold. **`ImageGCFailed` here is a transient
artifact of collection in progress, not a standing fault** — check the event `count` and whether
any occurred after usage settled before treating it as one.

**What this does and does not invalidate.** §8's revisit triggers are stated as absolute
conditions (a worker back above 70 % nodefs, or headroom under 30 GiB on two or more workers),
not as arithmetic derived from the ~96 GiB figure, so they remain valid — there is simply far
more margin before they fire. What *is* superseded is any expectation that a node stabilises near
50 % after collecting: plan for near-total cache eviction on any node that crosses 70 %.

**The cost of that overshoot** is a colder cache than intended — 293.8 GiB of images will re-pull
on demand rather than the ~190 GiB projected. No `ImagePullBackOff` or `ErrImagePull` appeared on
any node immediately after either collection, but re-pulls are demand-driven, so §10's Docker Hub
rate-limit and in-cluster-`gitea` risks stay live until the next natural restart of each workload.

### 12.4 Verified negative cases

Both directions were confirmed, not just the ones that were expected to pass:

- **GC did not fire where it must not.** All three control-plane nodes (19–21 % used) and both
  below-threshold workers kept their caches byte-for-byte. The two below-threshold workers were
  watched across a full `ImageGCPeriod` after patching rather than checked once immediately —
  an instant check proves nothing, because kubelet has not yet run a cycle.
- **GC did not delete an in-use image.** `rancher/rancher` had nine tags cached on `mql-msp`;
  after collection exactly one remained — `v2.15.0`, the version actually running on that node.
  The other eight were evicted.
- **The sysctl applied to the live kernel with no reboot and no pod restart.** Each node's
  `max_map_count` was read from a pod that had been running *before* the patch
  (`kube-flannel-*`, `longhorn-manager-*`); all seven returned `262144`, up from `65530`.
- **Volume health was unchanged throughout** — 34 `healthy` / 3 `unknown` before and after, the
  3 `unknown` being the parked `enshrouded` workload as expected.

### 12.5 Deferred levers, re-evaluated against the measurement

Both §8 and §9 deferrals were revisited with the measured figures. **Neither is warranted now.**

**EPHEMERAL expansion (§8) — not triggered, and not close.** The trigger is any worker back above
70 % nodefs after settling, *or* headroom below 30 GiB on two or more workers. Post-change the
worst worker sits at 62 % and the smallest headroom is 51.6 GiB, so neither condition is within
reach. The reclamation delivered 420.3 GiB of headroom against the ~318 GiB that the expansion
analysis was written to beat, at no datastore cost and with no reboot — expansion is now further
away than when it was first deferred, not closer.

**`imageMaximumGCAge` (§9) — still declined.** It remains the only lever that would collect on
`0ag-qr8` and `z9a-dpj`, which between them still hold 336.1 GiB of image cache that the 70 %
threshold will never touch (they sit at 62 % and 58 %). That is a large idle cache, and it is
tempting now that collection is proven safe. Declined anyway, for three reasons:

1. **The capacity it would free is not needed.** The ICARUS gate passes with three workers and
   ~100 GiB more total headroom than projected. Reclaiming another ~300 GiB buys nothing today.
2. **§12.3 raises its cost.** Kubelet does not trim — it empties. Setting a max age would
   eventually evict essentially both remaining caches, and the cost of a cold cache is paid on
   demand, against Docker Hub rate limits and an in-cluster registry (§10). Two nodes with warm
   caches are a useful hedge while the other two are cold.
3. **The restart-reset caveat is unchanged.** It resets on every kubelet restart, so on this
   cluster it fires rarely and unpredictably — a lever that is both unnecessary and hard to
   reason about.

**Revisit if** `0ag-qr8` or `z9a-dpj` crosses 70 % on its own (the existing threshold then
handles it without a new lever), or if headroom on two or more workers falls below 30 GiB.
