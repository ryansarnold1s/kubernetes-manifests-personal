# Enable BepInEx Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the BepInEx modding framework on the live Valheim server — framework only, zero mods — without disrupting vanilla players.

**Architecture:** One key added to the existing `valheim-config` ConfigMap, applied and followed by a `Recreate` rollout. No new manifests, no Deployment edit. The image installs and manages the framework itself.

**Tech Stack:** Kubernetes 1.35, Talos 1.13, `lloesche/valheim-server:sha-732221f4d5b5`, `kubectl` on Windows PowerShell.

**Spec:** `docs/superpowers/specs/2026-07-26-valheim-bepinex-design.md`

## Global Constraints

- Every `kubectl` invocation must be prefixed with `$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"` — the default `~/.kube/config` points at Docker Desktop, not this cluster.
- **Use ABSOLUTE paths for every `kubectl -f`.** A relative path from the wrong working directory silently no-ops while `kubectl rollout status` still prints a success line for the *previous* rollout. This trap has already been hit once on this repo.
- **Never use `kubectl logs --follow`** — it blocks indefinitely. Take bounded `--tail` snapshots instead.
- All work on branch `valheim-server`. Do **not** commit to `main`. Do **not** push.
- The ONLY manifest change permitted is adding `BEPINEX: "true"` to `valheim/configmap.yaml`. `deployment.yaml`, `service.yaml`, `pvc.yaml`, `namespace.yaml`, `recurringjob.yaml` must be untouched.
- Do **not** set `VALHEIM_PLUS`. It is mutually exclusive with `BEPINEX`; enabling both fails.
- Do **not** change `UPDATE_CRON`. With zero mods there is nothing for a Valheim patch to break; it becomes a real decision only when mods arrive.
- Do **not** install any mod. This plan is framework-only.
- The restart is authorized by the repo owner. Expect ~2 minutes of downtime (`Recreate` + 120s grace) plus a first-boot framework download.

---

## File Structure

| File | Change |
|---|---|
| `valheim/configmap.yaml` | Add one key: `BEPINEX: "true"` |
| `valheim/README.md` | Add a BepInEx section documenting state, exclusivity, and the deferred decisions |

---

### Task 1: Enable the framework

**Files:**
- Modify: `valheim/configmap.yaml`

**Interfaces:**
- Consumes: the existing ConfigMap `valheim-config` and Deployment `valheim` in namespace `valheim`.
- Produces: a running server with BepInEx loaded. Task 2 documents the resulting state.

- [ ] **Step 1: Confirm the framework is currently OFF (the failing check)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- sh -c 'echo "BEPINEX=[${BEPINEX:-<unset>}]"'
```

Expected: `BEPINEX=[<unset>]` — the starting state. If it already reads `true`, stop and report: someone enabled it outside this plan.

- [ ] **Step 2: Record the current pod name, so you can prove the rollout actually happened**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pods -n valheim -o jsonpath='{.items[*].metadata.name}'
```

Note the name. After the rollout it MUST be different. An unchanged pod name means the apply or restart silently did nothing.

- [ ] **Step 3: Add the key to `valheim/configmap.yaml`**

Insert into the `data:` block, after the `ADMINLIST_IDS: ""` line:

```yaml
  BEPINEX: "true"
```

Change nothing else in the file. The value must be the quoted string `"true"` — an unquoted YAML boolean is invalid in a ConfigMap `data` map and the API server will reject it.

- [ ] **Step 4: Apply the ConfigMap (absolute path)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim\configmap.yaml"
```

Expected: `configmap/valheim-config configured`

If it says `unchanged`, the file edit did not save — fix it before continuing. `configured` is the only acceptable output.

- [ ] **Step 5: Confirm the key reached the cluster**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get configmap valheim-config -n valheim -o jsonpath='{.data.BEPINEX}'
```

Expected: `true`

A ConfigMap change does NOT restart pods on its own — `envFrom` is resolved only at pod start. The running server is still vanilla at this point. That is why Step 6 exists.

- [ ] **Step 6: Roll the Deployment**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl rollout restart deploy/valheim -n valheim; kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Expected: `deployment "valheim" successfully rolled out`

This is a `Recreate` rollout: the old pod terminates completely — flushing the world, up to 120s — before the new pod starts. A gap in service here is expected and correct.

- [ ] **Step 7: Verify the pod is genuinely new**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get pods -n valheim
```

Expected: a pod name DIFFERENT from the one recorded in Step 2, `1/1 Running`, `RESTARTS 0`.

- [ ] **Step 8: Verify the framework is enabled in the running container**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- sh -c 'echo "BEPINEX=[${BEPINEX:-<unset>}]"'
```

Expected: PASS — `BEPINEX=[true]`

- [ ] **Step 9: Verify BepInEx actually loaded (authoritative evidence)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl logs -n valheim deploy/valheim --tail=200 | Select-String -Pattern "BepInEx|doorstop|preloader" -CaseSensitive:$false
```

Expected: PASS — one or more lines showing BepInEx downloading, unpacking, or initialising.

The env var being set proves only that configuration reached the container. These log lines are the evidence the framework actually loaded. If the env var is `true` but no BepInEx lines appear, the framework failed to initialise — go to Step 12.

- [ ] **Step 10: THE CRITICAL CHECK — verify the readiness probe still passes**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl get endpointslice -n valheim -l kubernetes.io/service-name=valheim -o jsonpath='{range .items[*]}{.endpoints[*].addresses}{" ready="}{.endpoints[*].conditions.ready}{"\n"}{end}'
```

Expected: PASS — one pod IP with `ready=true`

**This is the gate for the whole task.** The probes are `pgrep -f valheim_server`, and BepInEx execs the game binary through an `LD_PRELOAD` wrapper. If that changes the matched command line, readiness never becomes true, the EndpointSlice empties, and **the server is unreachable while `kubectl get pods` still shows `Running`.**

> 🛑 **CORRECTION — this gate was inert when the task ran.** The probe was unbracketed
> (`pgrep -f valheim_server`), which matches its own `sh -c` argv and returns 0 unconditionally.
> Readiness could not go false, so the EndpointSlice check below would have reported `ready=true`
> even if BepInEx had broken the match entirely. The probes are now
> `pgrep -f '[v]alheim_server'` and this gate is real. Re-verified independently: the pattern
> does still match under the `LD_PRELOAD` wrapper.

An empty result, or `ready=false`, means roll back — go to Step 12. Do not attempt to diagnose or "fix forward" while the server is dark.

- [ ] **Step 11: Record the observation about `/config/bepinex` (non-blocking)**

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl exec -n valheim deploy/valheim -- sh -c 'ls -la /config/bepinex 2>/dev/null || echo "/config/bepinex not present"'
```

Record whichever result you get. **This does not gate anything.** The image may create that directory lazily — only once a mod writes configuration into it — so its absence on a zero-mod server is not evidence of failure. Judge success on Steps 8, 9 and 10.

- [ ] **Step 12: ROLLBACK — only if Step 9 or Step 10 failed**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" checkout valheim/configmap.yaml
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"; kubectl apply -f "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal\valheim\configmap.yaml"; kubectl rollout restart deploy/valheim -n valheim; kubectl rollout status deploy/valheim -n valheim --timeout=600s
```

Then re-check Step 10 to confirm the server is reachable again, and report the failure with the Step 9 log output. Do not commit. Do not proceed to Task 2.

- [ ] **Step 13: Commit (only if Steps 8, 9 and 10 all passed)**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/configmap.yaml
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "feat(valheim): enable BepInEx modding framework"
```

---

### Task 2: Document the resulting state

**Files:**
- Modify: `valheim/README.md`

**Interfaces:**
- Consumes: the verified-working BepInEx server from Task 1.
- Produces: documentation only. No cluster changes.

- [ ] **Step 1: Add a BepInEx section to `valheim/README.md`**

Place it after the Operating notes section, in the README's existing voice. Content to cover, concisely:

````markdown
## Modding (BepInEx)

`BEPINEX: "true"` is set in `configmap.yaml`. The framework is installed and
loaded; **no mods are installed.**

- **Vanilla clients are unaffected.** BepInEx on the server imposes no
  requirement on clients by itself. Compatibility is enforced per-mod — a client
  is rejected only when a mod requiring client-side components is installed.
- **`BEPINEX` and `VALHEIM_PLUS` are mutually exclusive.** Enabling both fails.
- **Mod config** lives in `/config/bepinex` on the `valheim-data` PVC, so it
  survives restarts. Mod config can also be set from the ConfigMap using
  `BEPINEXCFG_<Section>_<Variable>` keys.
- Enabling or disabling the framework costs a `Recreate` restart (~2 min).

### Before installing any mod — two unsolved decisions

1. **Getting mod DLLs onto the PVC.** Kubernetes has no bind-mount equivalent,
   so mods need an init container, a helper pod, or a custom image layer. Not
   yet designed.
2. **`UPDATE_CRON` becomes a hazard.** It is currently `0 5 * * *` and
   unattended. A Valheim patch routinely breaks BepInEx mods, so a nightly
   auto-update can leave a broken mod stack running overnight. Decide the policy
   before mods exist, not after.

### If the server goes unreachable after a framework change

The readiness probe is `pgrep -f '[v]alheim_server'` (originally unbracketed, which
made it a no-op that always passed — see the correction earlier in this plan).
BepInEx execs the game binary through an `LD_PRELOAD` wrapper — if that ever stops
matching, readiness never becomes true and the Service drops its endpoints while the
pod still reports `Running`. Check endpoints, not pod status:

```powershell
kubectl get endpointslice -n valheim -l kubernetes.io/service-name=valheim -o jsonpath='{range .items[*]}{.endpoints[*].conditions.ready}{"\n"}{end}'
```

To disable the framework: remove the `BEPINEX` key from `configmap.yaml`, apply,
and `kubectl rollout restart deploy/valheim -n valheim`.
````

- [ ] **Step 2: Verify no secret became tracked**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" ls-files valheim/
```

Expected: `secret.yaml.template` present, `secret.yaml` ABSENT.

- [ ] **Step 3: Verify no credential leaked into the docs**

Derive the password from the Secret at runtime. Do **not** write the literal
password into this plan as a search pattern — the plan is itself a tracked file,
so hardcoding it here would commit the credential and defeat the very check this
step performs.

```powershell
$env:KUBECONFIG = "C:\Users\RyanArnold\Downloads\kubeconfig"
$pw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl get secret valheim-secrets -n valheim -o jsonpath='{.data.server-password}')))
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" grep -n -- "$pw"
```

Deliberately repo-wide, not scoped to `docs/` or `valheim/` — the one known
live instance of this password is in `mumble/configmap.yaml`, outside both of
those paths, so a scoped grep would structurally miss the exposure it exists
to catch.

Expected: exactly one hit, `mumble/configmap.yaml` — pre-existing and
owner-accepted. Any hit in `docs/` or `valheim/` is a failure; the live
password must not appear in tracked files there.

- [ ] **Step 4: Commit**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" add valheim/README.md
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" commit -m "docs(valheim): document BepInEx framework state and deferred mod decisions"
```

- [ ] **Step 5: Confirm only the two intended files changed**

```powershell
git -C "C:\Users\RyanArnold\Documents\GitHub\kubernetes-manifests-personal" diff --stat 88cbcc5..HEAD -- valheim/
```

Expected: exactly `valheim/configmap.yaml` and `valheim/README.md`. Any other manifest appearing here is a defect.

---

## Owner-performed verification

One check no agent can run: **join the server from a vanilla Valheim client** at `192.168.130.155:2456` and confirm you still get in. Per spec §3 this should work unchanged, but it is the only end-to-end proof that enabling the framework did not disturb client compatibility.

Report this as PENDING until the owner confirms it.

## Out of scope

- Installing any mod, and the DLL-delivery mechanism that would require
- Changing `UPDATE_CRON`
- `VALHEIM_PLUS`
- Merging or pushing the branch — the owner's decision
