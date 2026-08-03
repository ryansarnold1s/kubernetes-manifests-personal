# kubernetes-manifests-personal

Talos k8s manifests, one directory per workload. Each has its own README with operational
detail and inline warnings — read it before changing anything in that directory.

- `valheim/` — game server, 12 BepInEx mods installed declaratively via an initContainer. The complex one
- `mumble/` — voice server
- `docs/superpowers/{specs,plans}` — design specs and implementation plans. When a shipped decision turns
  out wrong, append a correction rather than rewriting history; several already carry them

## Deploying

```powershell
cd <workload>/                                        # relative paths from repo root silently no-op
kubectl apply -f <file>.yaml --dry-run=server         # validate first
kubectl apply -f <file>.yaml                          # must say configured/created, not unchanged
kubectl rollout restart deploy/<name> -n <ns>         # ConfigMap edits need this. Deployment edits restart on their
                                                      # own — adding it after a Deployment apply starts a SECOND
                                                      # Recreate cycle and races the first
kubectl rollout status  deploy/<name> -n <ns> --timeout=600s
```

Single-replica stateful workloads use `strategy: Recreate`, so every apply is a brief outage — confirm
nobody is connected first. Valheim logs `Connections N` every 10 min:

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --tail=600 | Select-String "Connections \d+" | Select-Object -Last 1
```

Up to 10 min stale, so a `0` right after someone quits is real, but a `2` may be too.
`Closing socket` / `Got connection` lines are current — when the counter and the sockets
disagree, trust the sockets:

```powershell
kubectl logs -n valheim deploy/valheim -c valheim --since=5m | Select-String "Got connection|Closing socket"
```

## Environment

- `KUBECONFIG` is set in `.claude/settings.local.json` (gitignored, machine-specific) — needed for every kubectl call. **Set it there, don't inline `$env:KUBECONFIG = …` in commands**: a command that starts with an assignment never prefix-matches a `kubectl *` permission rule, so every call prompts
- Longhorn storage (RWO, reclaimPolicy Delete); MetalLB — use `metallb.io/` annotations, `metallb.universe.tf/` is deprecated
- CNI is Flannel: **NetworkPolicy is not enforced**. Use `spec.loadBalancerSourceRanges` instead
- Namespaces without PSA labels enforce `baseline`
- Longhorn RecurringJobs bind via a label on the **Volume**, not the PVC — a recreated PVC silently stops being snapshotted
- Off-cluster backup is CloudCasa (`cloudcasa-io`); it deletes its CRs after each run, so an empty `kubectl get backups.cloudcasa.io` proves nothing either way
- Longhorn snapshots can be taken declaratively: apply a `snapshots.longhorn.io` CR with `spec.volume: <pv-name>` and `spec.createSnapshot: true` (v1.11.3). No UI needed
- Enabling a ValheimPlus section makes **every** key in it live. Pin them all, including ones
  staying at vanilla, or a future V+ default change takes effect silently
- `.claude/settings.json` allows `kubectl get <kind>*`, which **cannot** be made to exclude secrets — prefix rules are defeated by comma-lists (`get pods,secrets`) and flag reordering. **Accepted deliberately**: single-operator home cluster, no untrusted users. Don't re-raise it as a finding

## Verification

- **Verify the negative case.** A check only ever observed passing has not been verified — confirm it fails when it should. A no-op health probe shipped this way once
- `unchanged` from `kubectl apply` is a silent failure, not a success — usually the wrong cwd
- After editing a config file in place, re-read it and confirm section/key **counts are unchanged** — an appended duplicate is the signature of a failed match
- **A container-generated config on the PVC is the source of truth for which keys exist**, not upstream docs — they routinely understate the set (V+ `[Player]`: docs 3 keys, installed build 26). Enumerate the live file before pinning anything
- It is also the source of truth for key **types**, not just names — read `# Setting type:` before pinning. `Toggle` → `On`/`Off`. Don't infer from a key that reads like a boolean
- **Two config mechanisms, two failure modes.** `valheim_plus.cfg` is parsed by V+'s own INI parser (`true`/`false`); `Azumatt.*` / `blacks7ar.*` are BepInEx-bound (`On`/`Off` Toggle enums). A rejected BepInEx value logs `could not be parsed` in the **game** container; a bad V+ value logs **nothing**. Running that check after a V+ change is a false gate — verify V+ by reading the value back off the PVC
- After any `MOD_CONFIG` change to a BepInEx mod, empty is the pass:
  `kubectl logs -n valheim deploy/valheim -c valheim | Select-String "could not be parsed"`
- **A `[cfg ]` line means the applier wrote the file, never that the mod accepted the value.** A rejected value is replaced by the mod's own default, correctly formatted, in the right section — the PVC config looks healthy either way
- Section-name conventions differ per mod: Azumatt `2 - Inventory Recycle`, V+ bare `[Time]`, blacks7ar `05- Cooking Station`. A pattern written for one silently misses the others

## Evaluating a new mod

Recon the artifact inside the running container before adding it — sha256, zip layout, config
section/key names, kick behaviour, prefab registration. The store page is routinely wrong.

- **Strip nulls before mining .NET strings**: `tr -d '\000' | tr -cs '[:print:]' '\n'`. Without it, every UTF-16 literal containing a space reads as absent — a clean-looking false negative
- Kick detection: `RemoveDisconnectedPeerFromVerified` and `RPC_*_Version` discriminate; `MinimumRequiredVersion` / `DisconnectClient` do **not** (PlantEverything has both and does not kick). Always run a known-kicker and a known-non-kicker control
- `AssetBundle`/`PrefabManager`/`CustomItem` all 0 → registers no prefabs → removal is clean, no orphaned ZDOs
- Client-side-only mods do nothing on a headless server; record them as declined-for-server in `MODS`, install per-client

## PowerShell + kubectl

- kubectl output is a string **array**: `-join "`n"` before treating as text (`.Length` is line count, not characters)
- `kubectl get X --no-headers` emits "No resources found" as a line — filter blanks before `Measure-Object`
- Deliver multi-line shell scripts to containers base64-encoded; quoting does not survive PowerShell → kubectl exec → sh
- jsonpath keys containing dots need escaping: `{.data.install-mods\.sh}`

## Conventions

- Commits go directly to `main`; no PR flow
- `**/secret.yaml` is gitignored — commit `secret.yaml.template` instead
- Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it. Keep that style
