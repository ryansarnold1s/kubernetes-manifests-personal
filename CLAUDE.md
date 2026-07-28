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
kubectl rollout restart deploy/<name> -n <ns>         # ConfigMap edits need this; Deployment edits restart on their own
kubectl rollout status  deploy/<name> -n <ns> --timeout=600s
```

Single-replica stateful workloads use `strategy: Recreate`, so every apply is a brief outage — confirm
nobody is connected first.

## Environment

- `$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"` — needed for every kubectl call (machine-specific)
- Longhorn storage (RWO, reclaimPolicy Delete); MetalLB — use `metallb.io/` annotations, `metallb.universe.tf/` is deprecated
- CNI is Flannel: **NetworkPolicy is not enforced**. Use `spec.loadBalancerSourceRanges` instead
- Namespaces without PSA labels enforce `baseline`
- Longhorn RecurringJobs bind via a label on the **Volume**, not the PVC — a recreated PVC silently stops being snapshotted
- Off-cluster backup is CloudCasa (`cloudcasa-io`); it deletes its CRs after each run, so an empty `kubectl get backups.cloudcasa.io` proves nothing either way

## Verification

- **Verify the negative case.** A check only ever observed passing has not been verified — confirm it fails when it should. A no-op health probe shipped this way once
- `unchanged` from `kubectl apply` is a silent failure, not a success — usually the wrong cwd
- After editing a config file in place, re-read it and confirm section/key **counts are unchanged** — an appended duplicate is the signature of a failed match

## PowerShell + kubectl

- kubectl output is a string **array**: `-join "`n"` before treating as text (`.Length` is line count, not characters)
- `kubectl get X --no-headers` emits "No resources found" as a line — filter blanks before `Measure-Object`
- Deliver multi-line shell scripts to containers base64-encoded; quoting does not survive PowerShell → kubectl exec → sh
- jsonpath keys containing dots need escaping: `{.data.install-mods\.sh}`

## Conventions

- Commits go directly to `main`; no PR flow
- `**/secret.yaml` is gitignored — commit `secret.yaml.template` instead
- Manifests carry inline comments explaining *why* a setting exists, aimed at the future edit that would undo it. Keep that style
