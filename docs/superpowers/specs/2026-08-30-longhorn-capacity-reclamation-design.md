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

1. Install `talosctl` on the operator workstation — not currently present. Requires a workstation
   reboot to bring up WSL.
2. Locate the current Talos machine config / patch workflow before writing the patch file.
3. Re-measure after `mql` collects and record the actual reclaimed figure against the ~96 GiB
   projection in §2.4. If the projection is badly wrong, that invalidates §8's trigger thresholds
   too.
4. ~~Update `2026-08-30-icarus-server-deployment-design.md` §4.~~ **Done 2026-08-30** — §4 now
   carries a correction note, §4.2 is rewritten around reclamation with an explicit capacity gate,
   and the §12 verification row was changed from "EPHEMERAL grew" to the headroom gate.
