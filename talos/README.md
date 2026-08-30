# talos/

Talos machine-config patches. **Not a workload directory** — nothing here is deployed with
`kubectl`. Everything is applied per-node with `talosctl`.

`talosctl` is WSL-only on this workstation — it is not on the Windows PATH. Every `talosctl`
command below runs in a WSL shell, at:

```
/mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal
```

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
cd /mnt/c/Users/RyanArnold/Documents/GitHub/kubernetes-manifests-personal
talosctl -n <ip> patch machineconfig --patch @talos/image-gc-and-sysctl.patch.yaml --mode=no-reboot
```

| Node | Role | IP |
|---|---|---|
| talos-c2v-wpu | control-plane | 192.168.130.234 |
| talos-kwn-eng | control-plane | 192.168.130.219 |
| talos-pha-6st | control-plane | 192.168.130.242 |
| talos-mql-msp | worker | 192.168.130.210 |
| talos-uup-vn3 | worker | 192.168.130.211 |
| talos-0ag-qr8 | worker | 192.168.130.246 |
| talos-z9a-dpj | worker | 192.168.130.245 |

Applied one node at a time — see the plan for ordering and per-node gates. Do not script a
loop over the whole table without reading it first.

## ⚠️ UNVERIFIED: does a later full `apply-config` revert this patch?

This is the single most likely way this change quietly disappears. `talosctl patch
machineconfig` writes a live overlay on top of whatever full machine config the node was last
given. Nobody has yet confirmed whether Talos treats that overlay as persistent across a
subsequent full `talosctl apply-config` (e.g. during a routine config sync, a node reprovision,
or an unrelated change pushed from source-controlled machine config), or whether a full apply
silently replaces the entire config and drops these two settings back to their Talos defaults
(85/80, 65530) with no error.

This was supposed to be settled before this file was written, by directly testing an
`apply-config` against a patched node and diffing the result. That test is currently **blocked**
— it needs `talosctl`, and `talosctl` needs this workstation booted into WSL, which had not
happened as of 2026-08-30. Treat the answer as unknown, not as "probably fine."

**Until this is resolved:** after *any* full `apply-config` runs against a node in this cluster
for any reason, re-run the verification command below against that node before assuming the
image-GC/sysctl settings are still in place. A later task closes this question and updates this
section with the answer — if you're reading this and that hasn't happened yet, assume nothing.

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
thresholds tells you nothing about whether the sysctl took. Verify that half separately (e.g. a
privileged debug pod reading `/proc/sys/vm/max_map_count` on the node, or `talosctl read` from
WSL) — ICARUS actually running without the Wine OOM is the real-world confirmation once it's
deployed.
