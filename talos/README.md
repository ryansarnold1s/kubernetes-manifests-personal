# talos/

Talos machine-config patches. **Not a workload directory** — nothing here is deployed with
`kubectl`. Everything is applied per-node with `talosctl`.

`talosctl` is WSL-only on this workstation — it is not on the Windows PATH. Every `talosctl`
command below runs in a WSL shell, at:

```
/mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal
```

**Export `TALOSCONFIG` first, in every new WSL shell:**

```bash
export TALOSCONFIG="$HOME/talosconfig"
```

Without it every command fails with `talos config file is empty`. `talosctl` defaults to
`$HOME/.talos/config`, and on this workstation that file exists but is a **stub** —
`context: ""`, `contexts: {}`. The real credentials are in `~/talosconfig` (context `k8`,
endpoints `.234`/`.219`/`.242`). Do not "fix" this by deleting the stub without merging the
real config in first; an empty default is a clearer failure than a half-populated one.

Verified 2026-08-30: this is what makes the difference between the commands below working
and failing.

The `kubectl` verification command near the bottom runs in PowerShell, same as every other
workload in this repo.

## image-gc-and-sysctl.patch.yaml

Two unrelated changes, bundled because both are machine-config-only and both apply without a
reboot:

- **`imageGCHighThresholdPercent: 70` / `imageGCLowThresholdPercent: 50`** (Talos default is
  85/80). No worker has ever hit 85% disk usage, so kubelet had never collected a single stale
  container image, and 652.6 GiB of superseded images had piled up across the four workers —
  nine concurrent `rancher/rancher` versions on one node, one of them in use. Lowering the
  thresholds forces kubelet to actually reclaim.
- **`vm.max_map_count: "262144"`** (measured default 65530) — a prerequisite for the pending
  ICARUS deployment. `vm.*` is a non-namespaced sysctl, so it cannot be set from a pod's
  `securityContext.sysctls`; it has to be machine config. Below 262144, `mornedhels/icarus-server`
  OOMs under Wine with "Ran out of memory allocating 0 bytes" even on a host with free memory.

**Neither change requires a reboot.** `machine.sysctls` applies immediately
(`SysctlConfigController` -> `SysctlSpecController`, since Talos 0.12); a kubelet config change
only restarts the kubelet process, which does not disrupt already-running containers.

### Applying (WSL, per node)

```bash
export TALOSCONFIG="$HOME/talosconfig"
cd /mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal
talosctl -n <ip> patch machineconfig --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

Dry-run it first — `patch machineconfig` supports `--dry-run`, which prints the config diff and
changes nothing. On a clean node the diff adds exactly three keys and removes none:

```bash
talosctl -n <ip> patch machineconfig --patch @talos/image-gc-and-sysctl.patch.yaml \
  --mode=no-reboot --dry-run
```

A successful apply prints `Applied configuration without a reboot`.

| Node | Role | IP | Applied | Effect |
|---|---|---|---|---|
| talos-c2v-wpu | control-plane | 192.168.130.234 | 2026-08-30 | policy + sysctl only |
| talos-kwn-eng | control-plane | 192.168.130.219 | 2026-08-30 | policy + sysctl only |
| talos-pha-6st | control-plane | 192.168.130.242 | 2026-08-30 | policy + sysctl only |
| talos-mql-msp | worker | 192.168.130.210 | 2026-08-30 | **collected 151.9 GiB** (74.1 % → 35.9 %) |
| talos-uup-vn3 | worker | 192.168.130.211 | 2026-08-30 | **collected 141.9 GiB** (74.0 % → 38.4 %) |
| talos-0ag-qr8 | worker | 192.168.130.246 | 2026-08-30 | below threshold, cache untouched |
| talos-z9a-dpj | worker | 192.168.130.245 | 2026-08-30 | below threshold, cache untouched |

Applied one node at a time — see the plan for ordering and per-node gates. Do not script a
loop over the whole table without reading it first.

### What collection actually looks like

Two things will surprise you the first time, both observed on 2026-08-30 and both benign:

**1. It does not stop at the low threshold — it empties the cache.** The design projected each
node would trim to ~50 % and stop. Neither did: both crossed 50 % without pausing and evicted
everything not in use, landing at 35.9 % and 38.4 % with 14.7 GiB and 11.9 GiB of images left.
Kubelet's fs stats come from cadvisor and are cached, so mid-burst it keeps re-reading stale
usage and keeps deleting. **Plan for near-total cache eviction on any node that crosses 70 %,**
not a partial trim. In-use images are never touched — of nine cached `rancher/rancher` tags on
`mql-msp`, the one actually running (`v2.15.0`) survived and the other eight went.

**2. `ImageGCFailed` and `FreeDiskSpaceFailed` events fire, and they are not failures.** Expect
something like:

```
FreeDiskSpaceFailed  ... (75% of 398.6 GiB used). Failed to free sufficient space
                         by deleting unused images (freed 0 bytes)
ImageGCFailed        ... (75% of 398.6 GiB used). ... (freed 63019273231 bytes)
```

The first fires at kubelet restart because `imageMinimumGCAge` is 2m and nothing is eligible yet.
The percentage in both is the usage kubelet saw at the **start** of that round, not standing
state. Before treating either as a real fault, check the event `count` and whether any fired
*after* usage settled — on `mql-msp` each had `count: 1` and none recurred once collection
finished, with `DiskPressure` staying `False` throughout.

Collection begins roughly **5 minutes** after the kubelet restart, not immediately, and takes
about 3–4 minutes to run out. Do not conclude the patch failed because nothing happened in the
first minute.

## ⚠️ ANSWERED 2026-08-30: yes, a full `apply-config` DOES revert this patch

This was the open question when this file was first written. It is now settled by direct test,
not inference. **A full `talosctl apply-config` silently drops all three settings.**

Measured with `apply-config --dry-run` against `192.168.130.234` while that node was patched and
the other six were not — `--dry-run` prints the diff and changes nothing, so this costs nothing
to re-run:

```bash
export TALOSCONFIG="$HOME/talosconfig"
talosctl -n <ip> apply-config -f ~/controlplane.yaml --mode=no-reboot --dry-run
```

Every one of our keys came back as a **removal**:

```diff
-        extraConfig:
-            imageGCHighThresholdPercent: 70
-            imageGCLowThresholdPercent: 50
-    sysctls:
-        vm.max_map_count: "262144"
```

So `patch machineconfig` is an overlay on the node's stored config, and a full apply replaces
that config wholesale. There is no error and no warning — the node simply returns to 85/80 and
65530, and ICARUS starts OOMing under Wine again.

### The stored configs are stale — do not apply them

The same dry-run surfaced a second, larger problem. The only full machine configs on this
workstation are `~/controlplane.yaml` and `~/worker.yaml` in WSL (plus a stray copy at
`C:\Users\RyanArnold\Documents\worker.yaml`). They are dated **2026-03-07** and pin kubelet
**v1.31.5**, while the cluster runs **v1.35.4**:

```diff
-        image: ghcr.io/siderolabs/kubelet:v1.35.4
+        image: ghcr.io/siderolabs/kubelet:v1.31.5
```

Applying them today would attempt a four-minor-version kubelet downgrade on top of reverting
this patch. **They are a bootstrap artifact, not a source of truth.** The live machine config
exists only on the nodes themselves; every node read `version: 1`, written 2026-07-27 and never
patched again until this change.

**Therefore:**

- There is no source-controlled full machine config to fold this patch into. Folding it into the
  stale files would not help — they are unsafe to apply for an unrelated reason.
- Before *any* future `apply-config`, regenerate the config from current cluster state first, and
  re-add these three keys to it. Do not reach for `~/worker.yaml`.
- After any full `apply-config` for any reason, re-run the verification commands below on that
  node. The patch will be gone.

## Rollback

Rolling back removes the two overrides this patch added, which returns kubelet to its
compiled-in 85%/80% thresholds and the sysctl to whatever the kernel's default is on that node
(measured 65530 before this patch). Run per node, from WSL:

```bash
talosctl -n <ip> patch machineconfig --mode=no-reboot --patch '[
  {"op": "remove", "path": "/machine/kubelet/extraConfig/imageGCHighThresholdPercent"},
  {"op": "remove", "path": "/machine/kubelet/extraConfig/imageGCLowThresholdPercent"},
  {"op": "remove", "path": "/machine/sysctls/vm.max_map_count"}
]'
```

**Rollback restores the policy, not the disk space.** Images kubelet already garbage-collected
under the 70/50 thresholds are gone — rollback only stops *further* collection at the lower
threshold, it does not re-download or restore anything that was already reclaimed. If ICARUS has
been deployed by the time you roll back, removing `vm.max_map_count` un-pins the value it needs
and it will start OOMing again under Wine.

## Verifying the patch took effect

```powershell
kubectl get --raw "/api/v1/nodes/<node>/proxy/configz"
```

This reads the kubelet's live config straight from the node — proof the setting took effect, not
just that a command exited 0. Look for `imageGCHighThresholdPercent: 70` and
`imageGCLowThresholdPercent: 50` in the returned JSON.

This only proves the **kubelet** half. `vm.max_map_count` is a machine-level sysctl, not a
kubelet setting, so it does not appear in `configz` at all — `configz` returning correct
thresholds tells you nothing about whether the sysctl took.

Verify that half by reading `/proc/sys/vm/max_map_count` through any pod already running on the
node. `vm.*` is non-namespaced, so any pod sees the host value — no privileged debug pod needed.
There is no single label that covers all seven nodes; workers run `longhorn-manager`, control
plane nodes do not:

```powershell
# workers
$pod = kubectl get pod -n longhorn-system -l app=longhorn-manager `
  --field-selector "spec.nodeName=<node>" -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n longhorn-system $pod -- cat /proc/sys/vm/max_map_count

# control plane -- note the label is k8s-app=flannel, NOT app=flannel.
# `app=flannel` matches zero pods and returns blank rather than erroring.
$pod = kubectl get pod -n kube-system -l k8s-app=flannel `
  --field-selector "spec.nodeName=<node>" -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n kube-system $pod -- cat /proc/sys/vm/max_map_count
```

Expected `262144`; the pre-patch value was `65530`. Confirm against a pod that was **already
running before the patch** — the sysctl applies to the live kernel with no reboot and no pod
restart, so an unrestarted pod reading `262144` is the proof.

ICARUS actually running without the Wine OOM is the real-world confirmation once it's deployed.
