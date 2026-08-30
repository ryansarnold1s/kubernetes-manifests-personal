# Longhorn Capacity Reclamation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reclaim Longhorn-schedulable capacity on the four Talos workers by lowering kubelet's image GC thresholds, and set `vm.max_map_count=262144` for the pending ICARUS deployment — both in one machine-config patch, with no node reboots.

**Architecture:** A single Talos machine-config strategic-merge patch sets `machine.sysctls.vm.max_map_count` and `machine.kubelet.extraConfig.imageGC{High,Low}ThresholdPercent`. It is applied one node at a time with `--mode=no-reboot`, control-plane first (where it provably does *not* trigger collection, isolating "did the patch apply" from "did collection work"), then the two workers over the 70 % threshold, measuring at the first one before continuing.

**Tech Stack:** Talos v1.13.4 (`talosctl`, **WSL only**), Kubernetes v1.35.4 (`kubectl`, PowerShell), Longhorn v1.11.3.

**Spec:** `docs/superpowers/specs/2026-08-30-longhorn-capacity-reclamation-design.md`

## Global Constraints

- `imageGCHighThresholdPercent: 70`, `imageGCLowThresholdPercent: 50` — exact values, no other kubelet keys touched.
- `imageMinimumGCAge` is **not** set. Leave at its `2m0s` default so a future default change is not silently pinned.
- `imageMaximumGCAge` is **not** set. Declined in spec §9 — it resets on kubelet restart, and a second lever would make the measurement ambiguous.
- `vm.max_map_count: "262144"` — quoted string.
- Apply mode is `--mode=no-reboot` on every invocation. It is chosen for its *failure* behaviour: it errors rather than rebooting a node.
- **One node at a time.** Never patch two nodes in a single command.
- **Rollback restores the policy, not the images.** Re-applying `85`/`80` stops further collection; deleted images are gone and re-pull on demand. This is why Task 6 is a hard stop.
- No workload manifest is modified by this plan.

## Node inventory

| Node | Role | IP | nodefs used (2026-08-30) | imagefs | Collects at 70 %? |
|---|---|---|---|---|---|
| `talos-c2v-wpu` | control-plane | `192.168.130.234` | 10.0 GiB (21 %) | 7.0 GiB | No |
| `talos-kwn-eng` | control-plane | `192.168.130.219` | 9.5 GiB (19 %) | 6.4 GiB | No |
| `talos-pha-6st` | control-plane | `192.168.130.242` | 9.2 GiB (19 %) | 6.2 GiB | No |
| `talos-mql-msp` | worker | `192.168.130.210` | 295.2 GiB (74 %) | 164.7 GiB | **Yes** |
| `talos-uup-vn3` | worker | `192.168.130.211` | 295.1 GiB (74 %) | 151.8 GiB | **Yes** |
| `talos-0ag-qr8` | worker | `192.168.130.246` | 247.3 GiB (62 %) | 178.4 GiB | No (policy only) |
| `talos-z9a-dpj` | worker | `192.168.130.245` | 231.6 GiB (58 %) | 157.7 GiB | No (policy only) |

Control-plane nodes carry the `node-role.kubernetes.io/control-plane` taint.

## Shell conventions

Every command below is labelled. They are not interchangeable.

- **`[WSL]`** — `talosctl` only. It is not on the Windows PATH. Repo path inside WSL is
  `/mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal`.
- **`[PowerShell]`** — `kubectl` and all verification. `KUBECONFIG` is already set for this shell
  via `.claude/settings.local.json`.

## Reusable verification helpers

Paste these into the PowerShell session once. Both were run against the live cluster on
2026-08-30 and reproduce the spec's §2 figures exactly.

```powershell
function Get-NodeDisk($n) {
  $j = kubectl get --raw "/api/v1/nodes/$n/proxy/stats/summary" | ConvertFrom-Json
  $c = kubectl get --raw "/api/v1/nodes/$n/proxy/configz" | ConvertFrom-Json
  [pscustomobject]@{
    Node=$n
    UsedGiB=[math]::Round($j.node.fs.usedBytes/1GB,1)
    Pct=[math]::Round(100*$j.node.fs.usedBytes/$j.node.fs.capacityBytes,0)
    ImgGiB=[math]::Round($j.node.runtime.imageFs.usedBytes/1GB,1)
    GCHigh=$c.kubeletconfig.imageGCHighThresholdPercent
    GCLow=$c.kubeletconfig.imageGCLowThresholdPercent
  }
}

function Get-LHHeadroom {
  $ns = kubectl get nodes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json
  $ns.items | ForEach-Object {
    $d = $_.status.diskStatus.PSObject.Properties.Value | Select-Object -First 1
    [pscustomobject]@{
      Node=$_.metadata.name
      AvailGiB=[math]::Round($d.storageAvailable/1GB,1)
      FloorGiB=[math]::Round($d.storageMaximum*0.25/1GB,1)
      HeadroomGiB=[math]::Round(($d.storageAvailable-$d.storageMaximum*0.25)/1GB,1)
    }
  }
}

function Get-MaxMapCount($n) {
  $sel = if ($n -in @('talos-c2v-wpu','talos-kwn-eng','talos-pha-6st')) {
    @{ns='kube-system'; lbl='app=flannel'}
  } else {
    @{ns='longhorn-system'; lbl='app=longhorn-manager'}
  }
  $pod = kubectl get pod -n $sel.ns -l $sel.lbl --field-selector "spec.nodeName=$n" -o jsonpath='{.items[0].metadata.name}'
  $v = kubectl exec -n $sel.ns $pod -- cat /proc/sys/vm/max_map_count 2>$null
  [pscustomobject]@{ Node=$n; Pod=$pod; MaxMapCount=$v }
}
```

**Note:** `kubectl exec` prints `Defaulted container "..." out of: ...` to stderr on these pods.
That is normal, not an error.

**Trap:** `node.status.images` is capped at 50 entries by kubelet, so **never sum it** to get a
cache total — it will understate wildly (50 entries summed to 27.2 GiB on a node whose real cache
was 164.7 GiB). Use `imagefs.usedBytes` from `Get-NodeDisk` for totals, and `node.status.images`
only for presence/absence of a specific tag.

---

## Task 1: Establish talosctl access and capture the machine-config baseline

**Files:**
- Create: `C:\Users\RyanArnold\AppData\Local\Temp\claude\...\scratchpad\talos-baseline\` (working dir, not committed)

**Interfaces:**
- Consumes: nothing.
- Produces: a confirmed working `talosctl` invocation, and the current `machine.sysctls` /
  `machine.kubelet` sub-trees saved for comparison and rollback.

- [ ] **Step 1: Confirm talosctl exists and can reach a node**

`[WSL]`
```bash
talosctl version --client
talosctl --nodes 192.168.130.234 --endpoints 192.168.130.234 version
```
Expected: a client version, and a server version reporting Talos `v1.13.4`.
If this fails, stop — everything downstream depends on it.

- [ ] **Step 2: Confirm the patch subcommand's exact flags**

`[WSL]`
```bash
talosctl patch machineconfig --help
```
Confirm before proceeding: that `--patch` accepts `@<file>`, that `--mode` accepts `no-reboot`,
and whether `--dry-run` is offered. **Do not assume these — this plan was written without
talosctl available, so this step exists to catch a flag-name drift rather than discover it
mid-apply.** If `--dry-run` exists, use it once in Task 4 Step 2 before the real apply.

- [ ] **Step 3: Save the current config sub-trees for every node**

`[WSL]`
```bash
mkdir -p /tmp/talos-baseline
for ip in 192.168.130.234 192.168.130.219 192.168.130.242 \
          192.168.130.210 192.168.130.211 192.168.130.246 192.168.130.245; do
  talosctl -n "$ip" get machineconfig -o yaml > "/tmp/talos-baseline/$ip.yaml"
done
grep -A3 -E 'sysctls:|kubelet:' /tmp/talos-baseline/192.168.130.210.yaml
```
Expected: either no `sysctls:` key at all, or one without `vm.max_map_count`; and a `kubelet:`
block without `extraConfig.imageGC*`. **If either key already exists with a different value,
stop and reconcile** — this plan assumes it is adding them, not overwriting.

- [ ] **Step 4: Record how machine config is managed**

Note in the task's completion comment whether these nodes are managed by a stored
`controlplane.yaml`/`worker.yaml` pair, by Omni, or by ad-hoc patches. This determines whether
the patch in Task 3 also needs folding into a source-of-truth config file so it survives the next
`apply-config`. **A patch that a later full `apply-config` silently reverts is the main way this
change gets lost.**

---

## Task 2: Capture the pre-change baseline

This is the negative case for every verification in the plan. Capture it immediately before
changing anything — the spec's figures are from 2026-08-30 and may have drifted.

**Files:** none created; output recorded in the task completion comment.

**Interfaces:**
- Consumes: the helper functions above.
- Produces: per-node `UsedGiB`/`Pct`/`ImgGiB`/`GCHigh`/`GCLow`, Longhorn headroom per node and
  total, and the rancher-image canary list — all referenced by Tasks 4–9.

- [ ] **Step 1: Load the helpers**

`[PowerShell]` — paste the three functions from "Reusable verification helpers" above.

- [ ] **Step 2: Capture disk and kubelet config for all seven nodes**

`[PowerShell]`
```powershell
$nodes = @('talos-c2v-wpu','talos-kwn-eng','talos-pha-6st','talos-mql-msp','talos-uup-vn3','talos-0ag-qr8','talos-z9a-dpj')
$nodes | ForEach-Object { Get-NodeDisk $_ } | Format-Table -AutoSize
```
Expected: `GCHigh=85`, `GCLow=80` on **all seven**. If any node already reads `70`/`50`, this
plan has been partially applied — stop and determine which nodes.

- [ ] **Step 3: Capture Longhorn headroom**

`[PowerShell]`
```powershell
Get-LHHeadroom | Sort-Object HeadroomGiB | Format-Table -AutoSize
"TOTAL headroom GiB: {0:N1}" -f ((Get-LHHeadroom | Measure-Object -Property HeadroomGiB -Sum).Sum)
```
Expected on 2026-08-30: `mql` 3.8, `uup` 3.9, `0ag` 51.6, `z9a` 67.3, total **126.6 GiB**.

- [ ] **Step 4: Capture the GC canary**

`[PowerShell]`
```powershell
(kubectl get node talos-mql-msp -o json | ConvertFrom-Json).status.images |
  ForEach-Object { $_.names } | Where-Object { $_ -match 'rancher/rancher:' } | Sort-Object
```
Expected: nine tags — `v2.10.3`, `v2.11.2`, `v2.12.1`, `v2.12.2`, `v2.13.1`, `v2.14.0`,
`v2.14.2`, `v2.14.3`, `v2.15.0`. **`v2.15.0` is the one in use on that node and must survive.**

- [ ] **Step 5: Capture sysctl and volume health**

`[PowerShell]`
```powershell
$nodes | ForEach-Object { Get-MaxMapCount $_ } | Format-Table -AutoSize
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | Group-Object { $_.status.robustness } |
  Select-Object Name, Count
```
Expected: `MaxMapCount = 65530` on all seven. Volumes: 34 `healthy`, 3 `unknown` (the parked
`enshrouded` workload — **not** a regression; do not chase it).

---

## Task 3: Create the patch file and its home in the repo

**Files:**
- Create: `talos/image-gc-and-sysctl.patch.yaml`
- Create: `talos/README.md`
- Modify: `.gitignore`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 1 Step 3's confirmation that neither key is already set.
- Produces: `talos/image-gc-and-sysctl.patch.yaml`, the exact path Tasks 4–8 apply.

- [ ] **Step 1: Create the patch file**

Create `talos/image-gc-and-sysctl.patch.yaml`:

```yaml
# Talos machine-config patch. Applied per-node with:
#   talosctl -n <ip> patch machineconfig --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
#
# NEITHER change requires a reboot. machine.sysctls applies in immediate mode
# (SysctlConfigController -> SysctlSpecController, since Talos 0.12) and a kubelet
# config change only restarts kubelet, which does not disrupt running containers.
#
# See docs/superpowers/specs/2026-08-30-longhorn-capacity-reclamation-design.md
machine:
  sysctls:
    # ICARUS prerequisite. vm.* is NOT a namespaced sysctl, so no pod-level
    # securityContext.sysctls can set this -- it must be machine config.
    # Measured at 65530 on 2026-08-30; mornedhels/icarus-server OOMs under Wine
    # below 262144, reporting "Ran out of memory allocating 0 bytes" on a host
    # with free memory.
    vm.max_map_count: "262144"
  kubelet:
    extraConfig:
      # Was 85/80. No worker has ever reached 85%, so kubelet had never collected
      # a single image and 652.6 GiB of superseded images had accumulated across
      # the four workers -- nine concurrent rancher/rancher versions on one node,
      # exactly one of them in use.
      #
      # 50% of 398.6 GiB = 199 GiB, which sits ABOVE the ~130 GiB of Longhorn data
      # on the worst node. That is deliberate: kubelet compares against nodefs, and
      # Longhorn shares that filesystem, so a low threshold beneath the Longhorn
      # floor would make kubelet retry every housekeeping cycle and never converge.
      #
      # Do NOT add imageMaximumGCAge here without reading spec section 9 first --
      # it resets on every kubelet restart, so on this cluster it rarely fires.
      imageGCHighThresholdPercent: 70
      imageGCLowThresholdPercent: 50
```

- [ ] **Step 2: Protect talosconfig from ever being committed**

Append to `.gitignore`:

```gitignore
# Talos client credentials - contains client certs and keys, never commit
**/talosconfig
```

- [ ] **Step 3: Write `talos/README.md`**

It must state: what the patch does; that it is applied per-node with `--mode=no-reboot`;
that **neither change needs a reboot**; the rollback command and the fact that rollback restores
the policy but not deleted images; and — critically — whatever Task 1 Step 4 established about
whether a later full `apply-config` would revert this patch.

- [ ] **Step 4: Add a `talos/` line to CLAUDE.md**

Under the workload list, noting that `talos/` is **not** a workload directory — it holds
machine-config patches applied with `talosctl` from WSL, not `kubectl`.

- [ ] **Step 5: Validate the YAML parses**

`[PowerShell]`
```powershell
kubectl create --dry-run=client -f talos/image-gc-and-sysctl.patch.yaml -o yaml 2>&1 | Select-Object -First 5
```
Expected: it will **fail** with a missing-kind error — that is fine and expected, because this is
a Talos patch, not a Kubernetes object. What you are checking is that the failure is about the
missing `kind`, **not** a YAML syntax error. A syntax error reports a parse failure with a line
number instead.

- [ ] **Step 6: Commit**

```bash
git add talos/ .gitignore CLAUDE.md
git commit -m "Add Talos patch for kubelet image GC thresholds and vm.max_map_count

Kubelet default imageGCHighThresholdPercent is 85 and no worker has ever
reached it, so 652.6 GiB of superseded images had accumulated. Lowering to
70/50 is projected to lift Longhorn schedulable headroom from 126.6 GiB to
~318 GiB. vm.max_map_count rides along as the ICARUS prerequisite; both
apply without a reboot."
```

---

## Task 4: Apply to one control-plane node — prove the patch lands, prove GC does *not* fire

`talos-c2v-wpu` is at 21 % used, far below the new 70 % threshold. It is chosen first precisely
because collection **must not** happen here. That separates "did the patch apply" from "did
collection work" — two questions that are very hard to untangle after the fact.

**Files:** none modified.

**Interfaces:**
- Consumes: `talos/image-gc-and-sysctl.patch.yaml` from Task 3.
- Produces: confidence that the patch syntax is accepted by Talos and that kubelet picks it up.

- [ ] **Step 1: Record this node's pre-state**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-c2v-wpu'; Get-MaxMapCount 'talos-c2v-wpu'
```
Expected: `Pct≈21`, `ImgGiB≈7.0`, `GCHigh=85`, `GCLow=80`, `MaxMapCount=65530`.

- [ ] **Step 2: Dry-run the patch, if Task 1 Step 2 found the flag**

`[WSL]`
```bash
cd /mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal
talosctl -n 192.168.130.234 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot --dry-run
```
Skip if `--dry-run` is not offered.

- [ ] **Step 3: Apply**

`[WSL]`
```bash
talosctl -n 192.168.130.234 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```
Expected: success with no reboot. **If it errors saying a reboot is required, stop.** That means
something in the patch is not immediate-mode applicable, and the premise of this plan is wrong —
do not re-run with a different `--mode` to force it through.

- [ ] **Step 4: Verify the patch reached kubelet**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-c2v-wpu'
```
Expected: `GCHigh=70`, `GCLow=50`. This is read from the **running kubelet's** `/configz`, so it
proves the config took effect rather than merely that the command exited 0. Kubelet needs a few
seconds to restart; if it still reads 85/80, re-run once before treating it as a failure.

- [ ] **Step 5: Verify the sysctl applied with no reboot**

`[PowerShell]`
```powershell
Get-MaxMapCount 'talos-c2v-wpu'
```
Expected: `262144`. Negative case: `65530` recorded in Step 1.

- [ ] **Step 6: Verify GC did *not* fire**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-c2v-wpu'
```
Expected: `ImgGiB` still ≈7.0, unchanged from Step 1. **A drop here would mean collection ran on
a node at 21 % usage, which contradicts the threshold — stop and investigate before touching any
worker.**

**Rollback if needed:** re-apply with `imageGCHighThresholdPercent: 85` and
`imageGCLowThresholdPercent: 80`. Nothing has been deleted at this point, so rollback here is
complete.

---

## Task 5: Apply to the remaining two control-plane nodes

**Files:** none modified.

**Interfaces:**
- Consumes: Task 4's confirmation that the patch applies cleanly.
- Produces: all three control-plane nodes on the new policy.

- [ ] **Step 1: Apply to `talos-kwn-eng`**

`[WSL]`
```bash
talosctl -n 192.168.130.219 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 2: Verify it**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-kwn-eng'; Get-MaxMapCount 'talos-kwn-eng'
```
Expected: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`, `ImgGiB` still ≈6.4.

- [ ] **Step 3: Apply to `talos-pha-6st`**

`[WSL]`
```bash
talosctl -n 192.168.130.242 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 4: Verify it**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-pha-6st'; Get-MaxMapCount 'talos-pha-6st'
```
Expected: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`, `ImgGiB` still ≈6.2.

- [ ] **Step 5: Confirm the control plane is healthy**

`[PowerShell]`
```powershell
kubectl get nodes
kubectl get pods -n kube-system --field-selector status.phase!=Running
```
Expected: all seven nodes `Ready`; no non-Running kube-system pods (an empty result prints
`No resources found`).

---

## Task 6: Apply to `talos-mql-msp` — the measurement node. **HARD STOP AFTER THIS TASK.**

This is the first node where collection actually happens, and the only one measured before the
rest proceed. Deleted images do not come back, so this is the last point at which the projection
can be checked cheaply.

**Files:** none modified.

**Interfaces:**
- Consumes: Task 2's baseline for this node (295.2 GiB used, 164.7 GiB images, 3.8 GiB headroom).
- Produces: the measured reclamation figure, which Task 9 records and which validates or
  invalidates the spec's ~96 GiB projection.

- [ ] **Step 1: Re-record the pre-state immediately before applying**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-mql-msp'
Get-LHHeadroom | Where-Object Node -eq 'talos-mql-msp'
```
Expected: ≈`295.2` used, `74 %`, `164.7` images, headroom ≈`3.8` GiB.

- [ ] **Step 2: Apply**

`[WSL]`
```bash
talosctl -n 192.168.130.210 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 3: Confirm the config landed before waiting on GC**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-mql-msp'; Get-MaxMapCount 'talos-mql-msp'
```
Expected: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`. `ImgGiB` will still be ≈164.7 at this
instant — collection has not run yet.

- [ ] **Step 4: Wait for kubelet housekeeping, then measure**

Kubelet evaluates image GC on its housekeeping interval, so allow several minutes. Re-run until
`ImgGiB` stops falling across two consecutive checks:

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-mql-msp'
```
Expected once settled: `UsedGiB` ≈199, `Pct` ≈50, `ImgGiB` ≈69.

- [ ] **Step 5: Verify GC deleted the right things**

`[PowerShell]`
```powershell
(kubectl get node talos-mql-msp -o json | ConvertFrom-Json).status.images |
  ForEach-Object { $_.names } | Where-Object { $_ -match 'rancher/rancher:' } | Sort-Object
```
Expected: **`v2.15.0` present** (it is in use by the Rancher pod on this node) and most of the
other eight gone. This check catches both failure modes at once — a GC that deleted nothing, and
a GC that deleted an in-use image.

- [ ] **Step 6: Verify the space reached Longhorn**

`[PowerShell]`
```powershell
Get-LHHeadroom | Sort-Object HeadroomGiB | Format-Table -AutoSize
```
Expected: `talos-mql-msp` headroom risen from ≈3.8 GiB to ≈99.6 GiB. **This is the number the
whole plan exists to produce.**

- [ ] **Step 7: Confirm nothing broke**

`[PowerShell]`
```powershell
kubectl get pods -A --field-selector status.phase!=Running
kubectl get events -A --field-selector reason=Failed --sort-by=.lastTimestamp | Select-Object -Last 15
kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json |
  ForEach-Object { $_.items } | Group-Object { $_.status.robustness } | Select-Object Name, Count
```
Expected: no `ImagePullBackOff`; volume robustness counts unchanged from Task 2 Step 5
(34 `healthy`, 3 `unknown`).

- [ ] **Step 8: STOP and evaluate against the projection**

Compare measured reclamation against the spec's ~96 GiB projection.

- **Within ~20 GiB:** proceed to Task 7.
- **Far below (say under 40 GiB):** stop. It means far more of the cache is in-use than the
  §2.2 analysis assumed, and the spec's §8 expansion trigger thresholds are built on the same
  arithmetic — so they are wrong too. Report and re-plan rather than continuing.
- **Kubelet keeps collecting without converging:** the Longhorn data floor on this node is higher
  than the ~130 GiB estimate. Raise `imageGCLowThresholdPercent` and re-apply.

---

## Task 7: Apply to `talos-uup-vn3`

**Files:** none modified.

**Interfaces:**
- Consumes: Task 6's confirmation that the measured reclamation matched the projection.
- Produces: the second collecting worker on the new policy.

- [ ] **Step 1: Record pre-state**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-uup-vn3'
Get-LHHeadroom | Where-Object Node -eq 'talos-uup-vn3'
```
Expected: ≈`295.1` used, `74 %`, `151.8` images, headroom ≈`3.9` GiB.

- [ ] **Step 2: Apply**

`[WSL]`
```bash
talosctl -n 192.168.130.211 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 3: Verify config, sysctl, and settled reclamation**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-uup-vn3'; Get-MaxMapCount 'talos-uup-vn3'
Get-LHHeadroom | Where-Object Node -eq 'talos-uup-vn3'
```
Expected once settled: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`, `UsedGiB` ≈199,
headroom ≈99.6 GiB.

- [ ] **Step 4: Confirm nothing broke**

`[PowerShell]`
```powershell
kubectl get pods -A --field-selector status.phase!=Running
```

---

## Task 8: Apply to `talos-0ag-qr8` and `talos-z9a-dpj` — policy only

Both are below 70 %, so neither collects now. The patch is applied so they are protected when
they do cross it, and so `vm.max_map_count` is uniform across every node ICARUS could land on.

**Files:** none modified.

**Interfaces:**
- Consumes: Task 7 complete.
- Produces: all seven nodes on the new policy; `vm.max_map_count` uniform cluster-wide.

- [ ] **Step 1: Apply to `talos-0ag-qr8`**

`[WSL]`
```bash
talosctl -n 192.168.130.246 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 2: Verify — including that GC did *not* fire**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-0ag-qr8'; Get-MaxMapCount 'talos-0ag-qr8'
```
Expected: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`, and `ImgGiB` still ≈178.4 — this node
is at 62 %, below the threshold, so its cache must be untouched.

- [ ] **Step 3: Apply to `talos-z9a-dpj`**

`[WSL]`
```bash
talosctl -n 192.168.130.245 patch machineconfig \
  --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

- [ ] **Step 4: Verify — including that GC did *not* fire**

`[PowerShell]`
```powershell
Get-NodeDisk 'talos-z9a-dpj'; Get-MaxMapCount 'talos-z9a-dpj'
```
Expected: `GCHigh=70`, `GCLow=50`, `MaxMapCount=262144`, `ImgGiB` still ≈157.7 (node is at 58 %).

---

## Task 9: Final verification, record results, and evaluate the ICARUS gate

**Files:**
- Modify: `docs/superpowers/specs/2026-08-30-longhorn-capacity-reclamation-design.md`
- Modify: `docs/superpowers/specs/2026-08-30-icarus-server-deployment-design.md`
- Modify: `talos/README.md`

**Interfaces:**
- Consumes: measured figures from Tasks 4–8.
- Produces: a recorded outcome, and a yes/no on the ICARUS §4.2 capacity gate.

- [ ] **Step 1: Full cluster roll-up**

`[PowerShell]`
```powershell
$nodes = @('talos-c2v-wpu','talos-kwn-eng','talos-pha-6st','talos-mql-msp','talos-uup-vn3','talos-0ag-qr8','talos-z9a-dpj')
$nodes | ForEach-Object { Get-NodeDisk $_ } | Format-Table -AutoSize
$nodes | ForEach-Object { Get-MaxMapCount $_ } | Format-Table -AutoSize
Get-LHHeadroom | Sort-Object HeadroomGiB | Format-Table -AutoSize
"TOTAL headroom GiB: {0:N1}" -f ((Get-LHHeadroom | Measure-Object -Property HeadroomGiB -Sum).Sum)
```
Expected: `GCHigh=70`/`GCLow=50` and `MaxMapCount=262144` on **all seven**; total headroom risen
from 126.6 GiB toward ~318 GiB.

- [ ] **Step 2: Evaluate the ICARUS capacity gate**

The gate in the ICARUS spec §4.2 is: **at least two workers with ≥60 GiB of Longhorn headroom.**
Record pass/fail explicitly. If it passes, the ICARUS deployment is unblocked; if it does not, say
so rather than proceeding.

- [ ] **Step 3: Watch for delayed re-pull failures**

`[PowerShell]`
```powershell
kubectl get pods -A --field-selector status.phase!=Running
kubectl get events -A --sort-by=.lastTimestamp |
  Select-String -Pattern 'ImagePullBackOff|ErrImagePull|Failed to pull' | Select-Object -Last 20
```
Re-check after the next natural workload restart, not just immediately — a collected image only
fails when something actually needs to pull it. Pay particular attention to `finance-api` and
`finance-frontend`, whose registry `gitea.arnoldtech.io` is **in-cluster** (spec §10).

- [ ] **Step 4: Record the actual outcome in the spec**

Append a **Results** section to
`docs/superpowers/specs/2026-08-30-longhorn-capacity-reclamation-design.md` with the measured
per-node before/after and the total headroom achieved. Your CLAUDE.md asks for corrections to be
appended rather than history rewritten — if the measured figures differ from §2.4's projection,
record both and say which was wrong. Do not edit §2.4's numbers to match reality after the fact.

- [ ] **Step 5: Update the ICARUS spec's gate status**

In `2026-08-30-icarus-server-deployment-design.md` §4.2, record whether the gate passed and with
what headroom, so the ICARUS implementation does not have to re-derive it.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/ talos/README.md
git commit -m "Record measured results of the kubelet image GC change

Longhorn schedulable headroom went from 126.6 GiB to <measured> GiB across
the four workers. Records the actual per-node reclamation against the
projection in spec section 2.4, and the ICARUS capacity gate outcome."
```

- [ ] **Step 7: Re-evaluate the deferred levers**

Now that the measured figure is known, the spec's two deferred decisions can be revisited with
data instead of estimates:

- **`imageMaximumGCAge`** (spec §9) — would collect on `0ag` and `z9a`, which the 70 % threshold
  never will. Its restart-reset caveat still applies.
- **EPHEMERAL expansion** (spec §8) — trigger is any worker back above 70 % after settling, or
  headroom under 30 GiB on two or more workers.

Record whether either is now warranted. No action in this plan either way.

---

## Self-review notes

**Spec coverage:** §3 decisions → Task 3 patch file. §4 the change → Task 3. §5 apply procedure →
Tasks 4–8 in the specified order. §6 rollback → stated in Global Constraints and Task 4. §7
verification → every check appears, each with its negative case. §8 deferred expansion → Task 9
Step 7. §9 declined levers → Task 9 Step 7 and a warning comment in the patch file. §10 risks →
Task 9 Step 3 covers Docker Hub re-pulls and the in-cluster gitea registry. §11 open items 1–2 →
Task 1; open item 3 → Task 6 Step 8 and Task 9 Step 4.

**Known gap, deliberate:** Task 1 Step 2 confirms `talosctl` flag names at execution time rather
than asserting them. This plan was written on a workstation without `talosctl`, and inventing
plausible flags would be worse than saying so.
