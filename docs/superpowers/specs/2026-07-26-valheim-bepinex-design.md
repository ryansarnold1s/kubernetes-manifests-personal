# Enable BepInEx on the Valheim Server — Design

**Date:** 2026-07-26
**Status:** Approved
**Scope:** Framework only. Mods are explicitly out of scope.
**Depends on:** `2026-07-26-valheim-server-deployment-design.md`

---

## 1. Goal

Enable the BepInEx modding framework on the running Valheim server so that mods
*can* be installed later, without installing any mods now and without disrupting
existing vanilla players.

Non-goals, deliberately: mod DLL delivery, `UPDATE_CRON` policy changes,
ValheimPlus, and any gameplay change.

---

## 2. Starting state

Verified in the running container before this design:

| Check | Result |
|---|---|
| `BEPINEX` env var | unset → image default `false` |
| `VALHEIM_PLUS` env var | unset → image default `false` |
| `/config/bepinex`, `/config/valheimplus` | neither exists |
| `/opt/valheim/` contents | `dl`, `lost+found`, `server` — no framework directory |

The server is fully vanilla. Nothing has been staged for modding.

---

## 3. Key finding: vanilla clients are unaffected

BepInEx on the server does not, by itself, impose any requirement on clients.
Mod compatibility is enforced per-mod — a client is rejected only when a mod
requiring client-side components is actually installed. With zero mods, vanilla
clients connect exactly as they do today.

This is what makes "framework only" a safe, standalone step rather than a
half-finished migration.

---

## 4. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Framework only | De-risks the later mod work by proving the framework is healthy before anything depends on it |
| Mechanism | Image's `BEPINEX=true` flag | The image manages install and re-checks on update; hand-installing into the PVC would mean owning updates forever and fighting the image's bootstrap |
| `UPDATE_CRON` | Unchanged | With zero mods there is nothing for a Valheim patch to break. It becomes a real decision when mods arrive |
| Timing | Immediate | Owner authorized the restart |

### Rejected: hand-installing BepInEx into the PVC

Pins an exact framework version, but there is no version constraint to satisfy
here, and it permanently transfers update responsibility from the image to us.

---

## 5. The change

A single key added to `valheim/configmap.yaml`:

```yaml
  BEPINEX: "true"
```

Applied with `kubectl apply` on the ConfigMap, followed by
`kubectl rollout restart` on the Deployment. No new manifests. No Deployment
edit. `valheim/deployment.yaml`, `service.yaml`, `pvc.yaml`, `namespace.yaml`,
and `recurringjob.yaml` are untouched.

### What happens on boot

The image fetches BepInExPack Valheim into `/opt/valheim` (the `valheim-server`
PVC — 10Gi, ~3GB used, ample headroom) and creates `/config/bepinex` on the
`valheim-data` PVC, so mod configuration will persist across restarts.

First boot is slower by the framework download. SteamCMD does **not**
re-download the game — the install already lives on the persistent volume.

### Restart cost

The Deployment is `strategy: Recreate` with `terminationGracePeriodSeconds: 120`.
The old pod terminates fully — flushing the world — before the new one starts.
Expect up to ~2 min of downtime (120s grace); observed ~25s. Players are
disconnected.

---

## 6. Primary risk: the readiness probe may break

The readiness and startup probes are `pgrep -f valheim_server`. (Now
`pgrep -f '[v]alheim_server'` — the unbracketed form shipped here was a no-op that
always returned 0. See the correction at the end of this section.)

BepInEx launches the server through a wrapper that sets `LD_PRELOAD` before
exec'ing the game binary. The process should still match the pattern, but this
is **not certain** and has not been verified against this image.

If it does not match:

- readiness never becomes true
- the Service's EndpointSlice empties
- **the server becomes unreachable while `kubectl get pods` reports the pod as
  Running**

This is precisely the failure mode the original probe design warned about, now
made live by this change.

**Mitigation:** verification below checks EndpointSlice readiness explicitly,
not merely pod status. A failure there is the rollback trigger, not something to
diagnose while the server is dark.

### Secondary risk

If BepInEx fails to initialize, the server may fail to start at all. The same
verification catches it, and the same rollback applies.

**Resolved in `bde652c`:** BepInEx 5.4.23.3 loaded (`Chainloader startup
complete`, `0 plugins to load`); `pgrep -f valheim_server` still matches under
the `LD_PRELOAD` wrapper; EndpointSlice `ready=true`, pod `1/1`, 0 restarts.
The risk did not materialize.

**Correction — the evidence above was worthless at the time, though the conclusion
happens to hold.** The probe as committed was `sh -c "pgrep -f valheim_server >
/dev/null"`, which matches its own shell's argv and returns 0 unconditionally. So
`ready=true` here was guaranteed regardless of whether BepInEx broke the match —
this section's entire mitigation ("verification checks EndpointSlice readiness
explicitly") was checking a signal that could not go false. The rollback trigger
was inert.

Re-verified independently after the probe fix: the live process is
`/opt/valheim/bepinex/valheim_server.x86_64 -nographics -batchmode ...`, so the
pattern genuinely does still match under the `LD_PRELOAD` wrapper. The conclusion
stands — it just wasn't established by the check that claimed to establish it.

The probes are now `pgrep -f '[v]alheim_server'` and can actually fail, which means
the EndpointSlice check described above is a real gate from here on. See §8 of
`2026-07-26-valheim-server-deployment-design.md`.

---

## 7. Verification

These three are blocking:

1. `BEPINEX=true` present in the running container's environment.
2. BepInEx initialization lines present in the pod logs — this is the
   authoritative evidence the framework actually loaded.
3. Pod is `1/1 Running` **and** the EndpointSlice shows `ready=true`.
   Both — pod status alone is insufficient, per §6.

Then, owner-performed:

4. A vanilla client can still join `192.168.130.155:2456`. This is the only
   check no agent can perform.

**Non-blocking observation:** `/config/bepinex` is expected to appear, but the
image may create it lazily — only once a mod writes configuration there. Its
absence on a zero-mod server is therefore not evidence of failure and must not
gate the change. Record what is observed; judge success on items 1-3.

**Resolved:** `/config/bepinex/` exists on the `valheim-data` PVC, containing
`BepInEx.cfg`, `BepInEx.cfg.default`, and an empty `plugins/`.

---

## 8. Rollback

Remove the `BEPINEX` key from `valheim/configmap.yaml` (or set it to `"false"`),
apply, and restart. Fully reversible: no world data is altered, and nothing
installed by the framework changes vanilla behaviour once it is no longer
loaded.

The `/config/bepinex` directory may remain on the PVC. It is inert when the
framework is disabled and can be left in place.

---

## 9. Documentation

`valheim/README.md` gains a short note recording:

- BepInEx is enabled with **zero mods installed**, and vanilla clients are
  therefore unaffected.
- `BEPINEX` and `VALHEIM_PLUS` are mutually exclusive — enabling both fails.
- `UPDATE_CRON` becomes a real decision once mods exist, because a Valheim patch
  routinely breaks BepInEx mods and the nightly update is unattended.
- Mod DLL delivery onto the PVC is not solved and is required before any mod can
  actually be installed.

---

## 10. Out of scope — the next decision

Installing an actual mod requires getting its `.dll` onto the `valheim-data`
PVC. Kubernetes offers no bind-mount equivalent, so this needs an init
container, a helper pod, or a custom image layer. That is a separate design.
