# gameops Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A LAN-only web page showing the live state of every Valheim server on the cluster — up/down, players, versions, mod drift, resources, volume and snapshot health — read-only, with no database.

**Architecture:** One NestJS service reads the Kubernetes API with a read-only ServiceAccount, derives a `ServerStatus` per Deployment labelled `game=valheim`, caches it in memory for 5s, and serves both `GET /api/servers` and the built React assets from the same container. Log parsing is isolated in pure functions with no Kubernetes types, so the risky part is unit-testable against real captured fixtures. Every field is independently nullable: a value whose source is unavailable is `null` and renders as "unknown", never `0`.

**Tech Stack:** NestJS + jest/supertest (API), React + Vite + Tailwind + TanStack Query + vitest (web), `@kubernetes/client-node` 2.0.0, multi-stage Docker on `dhi.io/node:24-debian13-dev`, image to `gitea.arnoldtech.io/arnold-tech/gameops`, manifests applied by hand from this repo.

**Spec:** `docs/superpowers/specs/2026-09-12-valheim-manager-design.md`

## Global Constraints

Exact values, copied from the spec. Every task inherits these.

- **Names:** repo `gameops`, image `gitea.arnoldtech.io/arnold-tech/gameops:<semver>`, namespace `gameops`, manifest directory `gameops/` in `kubernetes-manifests-personal`, hostname `gameops.arnoldtech.io`.
- **Discovery:** a server is any Deployment with label `game=valheim`. No hardcoded server list, ever.
- **Read-only:** the ClusterRole holds only `get`, `list`, `watch`. It must never name `secrets`, `pods/exec`, or any write verb.
- **Absent ≠ zero:** every derived field is `T | null`. A parser that cannot find its evidence returns `null`. Rendering shows "unknown".
- **RBAC:** core `pods`, `pods/log`, `configmaps`, `services`, `persistentvolumeclaims`; `apps` `deployments`; `longhorn.io` `volumes`, `snapshots`, `recurringjobs`; `metrics.k8s.io` `pods`.
- **Pod hardening:** `runAsNonRoot`, `runAsUser: 1000`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, `enableServiceLinks: false`. Namespace enforces `restricted`.
- **Ingress:** Traefik IngressRoute, annotation `kubernetes.io/ingress.class: traefik-external`, entryPoint `websecure`, and an **empty `tls: {}`** so it inherits the `*.arnoldtech.io` wildcard (per `mealie/ingressroute.yaml`). Never add a `secretName`, never create a cert-manager Certificate.
- **Image pull:** `imagePullSecrets: [{name: gitea-registry-secret}]`. That Secret is namespaced and is created by the operator in `gameops` by hand; it is never committed.
- **Metrics units:** the raw metrics API returns **nanocores** (`111027021n`) and **KiB** (`1545632Ki`), NOT the `114m`/`1509Mi` that `kubectl top` prints. Convert: millicores = nanocores / 1e6; MiB = KiB / 1024.
- **Git Bash mangles `--raw` paths.** `kubectl get --raw "/apis/..."` fails from Git Bash even with a doubled slash; it works from PowerShell. Verification steps that call `--raw` must say PowerShell.
- **Never read, log, or render any Secret value.** Not the server password, not the registry credential. Verified by RBAC, not by fetching one to check.
- **Commits go straight to `main`** in both repos. Every commit in `kubernetes-manifests-personal` ends with the attribution lines from the session's system reminder.
- **Touching a game server restarts it.** Task 8 is the only task that modifies `valheim/` or `valheim-public/`; it is gated on an empty server, checked in the same action as the apply.

---

## File Structure

**App repo `gameops`** (new, lives beside the other repos in `C:/Users/RyanArnold/Documents/GitHub/`):

| File | Responsibility | Task |
|---|---|---|
| `api/src/types.ts` | `ServerStatus` and its member types; the contract every other file speaks | 2 |
| `api/src/parsers/logs.ts` | Pure functions: log text → facts. No Kubernetes types, no I/O | 2 |
| `api/src/parsers/mods.ts` | Pinned `MODS` table parsing + drift comparison | 3 |
| `api/src/kube/kube.service.ts` | The only file that talks to `@kubernetes/client-node` | 4 |
| `api/src/servers/servers.service.ts` | Assembles `ServerStatus` from kube + parsers; 5s cache | 4 |
| `api/src/servers/servers.controller.ts` | `GET /api/servers`, `GET /api/health` | 5 |
| `api/test/fixtures/*.log` | **Real** captured server logs | 2 |
| `web/src/App.tsx`, `web/src/components/*` | Card grid, polling, "unknown" rendering | 6 |
| `Dockerfile` | Multi-stage: build web, build api, distroless runtime | 1 |

**This repo (`kubernetes-manifests-personal`)**:

| File | Responsibility | Task |
|---|---|---|
| `gameops/namespace.yaml` | Namespace, PSA `restricted` | 7 |
| `gameops/rbac.yaml` | ServiceAccount + ClusterRole + ClusterRoleBinding | 7 |
| `gameops/deployment.yaml` | The app, hardened | 7 |
| `gameops/service.yaml` | ClusterIP :3000 | 7 |
| `gameops/ingressroute.yaml` | `gameops.arnoldtech.io`, wildcard TLS | 7 |
| `gameops/README.md` | Operator doc | 7 |
| `valheim/deployment.yaml`, `valheim-public/deployment.yaml` | add `game=valheim` label | 8 |

---

### Task 1: Repo scaffold that builds and serves

**Files:**
- Create: `gameops/api/` (NestJS), `gameops/web/` (Vite React TS), `gameops/Dockerfile`, `gameops/.dockerignore`, `gameops/README.md`, `gameops/.gitignore`
- Test: `gameops/api/test/health.e2e-spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: a NestJS app on port 3000 serving `GET /api/health` → `{status:'ok'}` and static files from `web/dist`; `npm test` green in both workspaces; an image that builds locally.

- [ ] **Step 1: Scaffold both halves**

From `C:/Users/RyanArnold/Documents/GitHub/`:

```bash
mkdir gameops && cd gameops
npx @nestjs/cli new api --package-manager npm --skip-git --strict
npm create vite@latest web -- --template react-ts
cd web && npm install && npm install -D tailwindcss @tailwindcss/postcss postcss vitest @testing-library/react @testing-library/jest-dom jsdom && cd ..
cd api && npm install @kubernetes/client-node@2.0.0 && cd ..
git init && git branch -M main
```

- [ ] **Step 2: Write the failing health test**

Create `api/test/health.e2e-spec.ts`:

```typescript
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../src/app.module';

describe('health', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    await app.init();
  });

  afterAll(async () => await app.close());

  it('GET /api/health returns ok', async () => {
    const res = await request(app.getHttpServer()).get('/api/health').expect(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});
```

- [ ] **Step 3: Run it — it must fail**

Run: `cd api && npx jest test/health.e2e-spec.ts`
Expected: FAIL — 404, because no controller serves `/api/health` yet.

- [ ] **Step 4: Implement**

Replace `api/src/app.controller.ts` with:

```typescript
import { Controller, Get } from '@nestjs/common';

@Controller('api')
export class AppController {
  @Get('health')
  health(): { status: string } {
    return { status: 'ok' };
  }
}
```

In `api/src/main.ts`, bind to all interfaces so the container is reachable:

```typescript
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  await app.listen(3000, '0.0.0.0');
}
bootstrap();
```

- [ ] **Step 5: Run it — it must pass**

Run: `cd api && npx jest test/health.e2e-spec.ts`
Expected: PASS, 1 test.

- [ ] **Step 6: Write the Dockerfile**

Create `gameops/Dockerfile`:

```dockerfile
# Multi-stage. Base image matches attendance-tracker; this workstation has a dhi.io login.
FROM dhi.io/node:24-debian13-dev AS web-build
WORKDIR /web
COPY web/package*.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM dhi.io/node:24-debian13-dev AS api-build
WORKDIR /api
COPY api/package*.json ./
RUN npm ci --no-audit --no-fund
COPY api/ ./
RUN npm run build

FROM dhi.io/node:24-debian13-dev AS prod-deps
WORKDIR /api
COPY api/package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM dhi.io/node:24-debian13-dev AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=prod-deps /api/node_modules ./node_modules
COPY --from=api-build /api/dist ./dist
COPY --from=web-build /web/dist ./public
# readOnlyRootFilesystem is set in the Deployment; nothing here writes to disk.
USER 1000
EXPOSE 3000
CMD ["node", "dist/main"]
```

Create `gameops/.dockerignore`:

```
**/node_modules
**/dist
.git
```

- [ ] **Step 7: Serve the built web assets from the API**

In `api/src/app.module.ts`, serve `./public` (the Dockerfile copies `web/dist` there):

```typescript
import { Module } from '@nestjs/common';
import { ServeStaticModule } from '@nestjs/serve-static';
import { join } from 'path';
import { AppController } from './app.controller';

@Module({
  imports: [
    ServeStaticModule.forRoot({
      rootPath: join(process.cwd(), 'public'),
      exclude: ['/api/{*splat}'],
    }),
  ],
  controllers: [AppController],
})
export class AppModule {}
```

Install it: `cd api && npm install @nestjs/serve-static`

- [ ] **Step 8: Verify the image builds and runs**

```bash
cd gameops
docker build -t gameops:dev .
docker run --rm -d -p 3000:3000 --name gameops-dev gameops:dev
curl -s localhost:3000/api/health
docker rm -f gameops-dev
```

Expected: `{"status":"ok"}`. If the `dhi.io` pull fails, run `docker login dhi.io` and retry; do not silently switch base images.

- [ ] **Step 9: Commit**

```bash
cd gameops && git add -A
git commit -m "Scaffold gameops: NestJS API, Vite web, multi-stage image

Health endpoint with an e2e test, static serving of the built web assets,
and a multi-stage Dockerfile on the same hardened base attendance-tracker
uses."
```

---

### Task 2: Log parsers, with real fixtures

This is the risky core. Every function here is pure: log text in, facts out.

**Files:**
- Create: `gameops/api/src/types.ts`, `gameops/api/src/parsers/logs.ts`
- Create: `gameops/api/test/fixtures/modded.log`, `gameops/api/test/fixtures/vanilla.log`, `gameops/api/test/fixtures/rotated.log`
- Test: `gameops/api/test/logs.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `parseGameVersion(log: string): { game: string; network: number } | null`
  - `parseLoadedMods(log: string): LoadedMod[] | null`
  - `parseConnections(log: string): { count: number; source: 'sockets' | 'counter' } | null`
  - `parseZdoCount(log: string): number | null`
  - `parseLastSave(log: string): SaveInfo | null`
  - types `LoadedMod`, `SaveInfo`, `ServerStatus` in `types.ts`

- [ ] **Step 1: Capture the real fixtures from the live cluster**

Run from the repo root of `kubernetes-manifests-personal` (PowerShell):

```powershell
$g = "C:/Users/RyanArnold/Documents/GitHub/gameops/api/test/fixtures"
New-Item -ItemType Directory -Force $g | Out-Null
kubectl logs -n valheim deploy/valheim -c valheim --tail=4000 | Out-File -Encoding utf8 "$g/modded.log"
kubectl logs -n valheim-public deploy/valheim-public -c valheim --tail=4000 | Out-File -Encoding utf8 "$g/vanilla.log"
```

Then build the rotated fixture — the boot lines removed, everything else kept:

```powershell
Get-Content "$g/vanilla.log" | Where-Object { $_ -notmatch "Valheim version:" } | Out-File -Encoding utf8 "$g/rotated.log"
```

These are real logs, not invented ones. They contain both `Connections` formats, a `World save (5/5)` sequence, and (in `modded.log`) the BepInEx and ValheimPlus load lines.

- [ ] **Step 2: Define the types**

Create `api/src/types.ts`:

```typescript
export interface LoadedMod {
  name: string;
  version: string;
}

export interface PinnedMod {
  name: string;
  version: string;
  sha256: string;
  layout: string;
}

export interface ModDrift {
  status: 'ok' | 'drift' | 'unknown';
  differences: string[];
}

export interface SaveInfo {
  at: string;
  totalMs: number;
}

export interface VolumeInfo {
  actualBytes: number;
  requestedBytes: number;
  snapshotGroupLabelled: boolean;
  snapshotCount: number;
}

export interface ServerStatus {
  name: string;
  namespace: string;
  deployment: string;
  modded: boolean;
  ready: boolean;
  restarts: number;
  startedAt: string | null;
  cpuMillicores: number | null;
  memoryMiB: number | null;
  memoryLimitMiB: number | null;
  gameVersion: string | null;
  networkVersion: number | null;
  pinnedMods: PinnedMod[] | null;
  loadedMods: LoadedMod[] | null;
  drift: ModDrift;
  playersConnected: number | null;
  playersSource: 'sockets' | 'counter' | null;
  zdoCount: number | null;
  lastSave: SaveInfo | null;
  volume: VolumeInfo | null;
  address: string | null;
  ports: number[];
  updateOnStart: boolean | null;
}
```

- [ ] **Step 3: Write the failing tests**

Create `api/test/logs.spec.ts`:

```typescript
import { readFileSync } from 'fs';
import { join } from 'path';
import {
  parseGameVersion,
  parseLoadedMods,
  parseConnections,
  parseZdoCount,
  parseLastSave,
} from '../src/parsers/logs';

const fixture = (name: string) =>
  readFileSync(join(__dirname, 'fixtures', name), 'utf8');

const modded = fixture('modded.log');
const vanilla = fixture('vanilla.log');
const rotated = fixture('rotated.log');

describe('parseGameVersion', () => {
  it('reads the version and network version', () => {
    // real line: "09/11/2026 16:16:29: Valheim version: l-1.0.12 (network version 40)"
    expect(parseGameVersion(modded)).toEqual({ game: 'l-1.0.12', network: 40 });
  });

  it('returns null when the boot line has rotated out — never a guess', () => {
    expect(parseGameVersion(rotated)).toBeNull();
  });
});

describe('parseLoadedMods', () => {
  it('reads BepInEx and ValheimPlus versions from the modded server', () => {
    const mods = parseLoadedMods(modded);
    expect(mods).toEqual(
      expect.arrayContaining([
        { name: 'BepInExPack_Valheim', version: '5.4.2350' },
        { name: 'ValheimPlus', version: '0.10.1.0' },
      ]),
    );
  });

  it('returns an empty list for a vanilla server, not null', () => {
    // The vanilla server genuinely loads no mods: absence here is a FACT, not missing evidence.
    expect(parseLoadedMods(vanilla)).toEqual([]);
  });

  it('returns null when the boot lines are gone — absence of evidence, not evidence of absence', () => {
    expect(parseLoadedMods(rotated)).toBeNull();
  });
});

describe('parseConnections', () => {
  it('prefers socket events over the 10-minute counter', () => {
    const log = [
      '09/11/2026 15:53:14: Got connection SteamID 76561197963378853',
      '09/11/2026 16:35:39: Got connection SteamID 76561198274743071',
      '09/11/2026 15:53:51: Closing socket 76561197963378853',
    ].join('\n');
    expect(parseConnections(log)).toEqual({ count: 1, source: 'sockets' });
  });

  it('falls back to the bare counter format', () => {
    // This format has NO ZDOS suffix and appears 32 times in the real log.
    expect(parseConnections('09/11/2026 16:36:15: Connections 4')).toEqual({
      count: 4,
      source: 'counter',
    });
  });

  it('reads the periodic status format too', () => {
    expect(
      parseConnections('09/12/2026 09:46:44:  Connections 4 ZDOS:108465  sent:573 recv:1516'),
    ).toEqual({ count: 4, source: 'counter' });
  });

  it('returns null when the log shows neither', () => {
    expect(parseConnections('09/12/2026 09:46:44: something else entirely')).toBeNull();
  });
});

describe('parseZdoCount', () => {
  it('reads the ZDO count from the periodic line', () => {
    expect(
      parseZdoCount('09/12/2026 09:46:44:  Connections 4 ZDOS:108465  sent:573 recv:1516'),
    ).toBe(108465);
  });

  it('returns null without a status line', () => {
    expect(parseZdoCount('09/11/2026 16:36:15: Connections 4')).toBeNull();
  });
});

describe('parseLastSave', () => {
  it('reads the completion line with its total duration', () => {
    const log = '09/12/2026 09:34:28: World save (5/5) done. Total time [249ms]';
    expect(parseLastSave(log)).toEqual({ at: '09/12/2026 09:34:28', totalMs: 249 });
  });

  it('returns null when no save has completed in the retained log', () => {
    expect(parseLastSave('09/12/2026 09:34:28: World save (2/5) Chunks writing done [229ms]')).toBeNull();
  });
});
```

- [ ] **Step 4: Run the tests — they must fail**

Run: `cd api && npx jest test/logs.spec.ts`
Expected: FAIL — `Cannot find module '../src/parsers/logs'`.

- [ ] **Step 5: Implement the parsers**

Create `api/src/parsers/logs.ts`:

```typescript
import { LoadedMod, SaveInfo } from '../types';

/**
 * Every function here returns null when its EVIDENCE is missing, never a zero or a guess.
 * Container logs rotate: a long-running pod loses its own boot lines, and a parser that
 * reported 0 mods in that case would be confidently wrong.
 */

const VERSION_RE = /Valheim version:\s*(\S+)\s*\(network version (\d+)\)/;

export function parseGameVersion(log: string): { game: string; network: number } | null {
  const m = log.match(VERSION_RE);
  return m ? { game: m[1], network: Number(m[2]) } : null;
}

const BEPINEX_RE = /User is running BepInExPack Valheim version (\S+?) from Thunderstore/;
const VPLUS_RE = /ValheimPlus \[([\d.]+)\] is loaded/;
const JOTUNN_RE = /Jotunn v([\d.]+)/;

export function parseLoadedMods(log: string): LoadedMod[] | null {
  // Boot lines absent entirely => we cannot distinguish "vanilla" from "rotated away".
  if (!VERSION_RE.test(log)) return null;

  const mods: LoadedMod[] = [];
  const bep = log.match(BEPINEX_RE);
  if (bep) mods.push({ name: 'BepInExPack_Valheim', version: bep[1] });
  const vplus = log.match(VPLUS_RE);
  if (vplus) mods.push({ name: 'ValheimPlus', version: vplus[1] });
  const jotunn = log.match(JOTUNN_RE);
  if (jotunn) mods.push({ name: 'Jotunn', version: jotunn[1] });
  return mods;
}

const GOT_CONNECTION_RE = /Got connection SteamID (\d+)/g;
const CLOSING_SOCKET_RE = /Closing socket (\d+)/g;
// Two real formats: "…: Connections 4" and "…:  Connections 4 ZDOS:108465  sent:573 recv:1516".
const COUNTER_RE = /:\s+Connections (\d+)(?!\d)/g;

export function parseConnections(
  log: string,
): { count: number; source: 'sockets' | 'counter' } | null {
  const open = new Set<string>();
  for (const m of log.matchAll(GOT_CONNECTION_RE)) open.add(m[1]);
  const closed = new Set<string>();
  for (const m of log.matchAll(CLOSING_SOCKET_RE)) closed.add(m[1]);

  if (open.size > 0) {
    for (const id of closed) open.delete(id);
    return { count: open.size, source: 'sockets' };
  }

  const counters = [...log.matchAll(COUNTER_RE)];
  if (counters.length > 0) {
    return { count: Number(counters[counters.length - 1][1]), source: 'counter' };
  }
  return null;
}

const ZDOS_RE = /ZDOS:(\d+)/g;

export function parseZdoCount(log: string): number | null {
  const all = [...log.matchAll(ZDOS_RE)];
  return all.length ? Number(all[all.length - 1][1]) : null;
}

const SAVE_DONE_RE = /^(\S+ \S+): World save \(5\/5\) done\. Total time \[(\d+)ms\]/gm;

export function parseLastSave(log: string): SaveInfo | null {
  const all = [...log.matchAll(SAVE_DONE_RE)];
  if (!all.length) return null;
  const last = all[all.length - 1];
  return { at: last[1].replace(/:$/, ''), totalMs: Number(last[2]) };
}
```

- [ ] **Step 6: Run the tests — they must pass**

Run: `cd api && npx jest test/logs.spec.ts`
Expected: PASS, all 12 tests.

If `parseLoadedMods(vanilla)` returns `null` instead of `[]`, the vanilla fixture is missing its `Valheim version:` line — re-capture it; do not weaken the test.

- [ ] **Step 7: Commit**

```bash
cd gameops && git add -A
git commit -m "Add log parsers with real captured fixtures

Pure functions: log text in, facts out. Every parser returns null when its
evidence is missing rather than a zero, because container logs rotate and a
long-running pod loses its own boot lines. Both real Connections formats are
handled: the bare counter and the periodic ZDOS line."
```

---

### Task 3: Pinned mod table and drift detection

**Files:**
- Create: `gameops/api/src/parsers/mods.ts`
- Test: `gameops/api/test/mods.spec.ts`

**Interfaces:**
- Consumes: `LoadedMod`, `PinnedMod`, `ModDrift` from `src/types.ts` (Task 2).
- Produces:
  - `parsePinnedMods(modsTable: string): PinnedMod[]`
  - `compareMods(pinned: PinnedMod[] | null, loaded: LoadedMod[] | null): ModDrift`

- [ ] **Step 1: Write the failing tests**

Create `api/test/mods.spec.ts`:

```typescript
import { parsePinnedMods, compareMods } from '../src/parsers/mods';

// Verbatim from the live valheim-mods ConfigMap on 2026-09-12.
const MODS_TABLE = `BepInExPack_Valheim  5.4.2350  https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/5.4.2350/               37a91c000b4e88f2ed7a4bd7d812239852d2e36cbf0ff0a9f5faacfba46b105f  pack
Jotunn               2.30.0    https://thunderstore.io/package/download/ValheimModding/Jotunn/2.30.0/                        f7f218ac3f97b27a7e65d62b5ebe7c29b93129bf3e56cf41b6870bef1ef161fd  plugins
ValheimPlus          10.1.0    https://thunderstore.io/package/download/Grantapher/ValheimPlus_Grantapher_Temporary/10.1.0/  8f9c59ff4f324b0ac6119e25b32859b27214f9892f7e95ca118c1127dbd4709a  bepinex`;

describe('parsePinnedMods', () => {
  it('parses the whitespace-aligned table', () => {
    const pinned = parsePinnedMods(MODS_TABLE);
    expect(pinned).toHaveLength(3);
    expect(pinned[2]).toEqual({
      name: 'ValheimPlus',
      version: '10.1.0',
      sha256: '8f9c59ff4f324b0ac6119e25b32859b27214f9892f7e95ca118c1127dbd4709a',
      layout: 'bepinex',
    });
  });

  it('skips comment and blank lines', () => {
    expect(parsePinnedMods('# a comment\n\n' + MODS_TABLE)).toHaveLength(3);
  });
});

describe('compareMods', () => {
  it('reports ok when every pinned mod is loaded at a matching version', () => {
    // ValheimPlus pins "10.1.0" but reports itself as "0.10.1.0" — the same release.
    const drift = compareMods(parsePinnedMods(MODS_TABLE), [
      { name: 'BepInExPack_Valheim', version: '5.4.2350' },
      { name: 'Jotunn', version: '2.30.0' },
      { name: 'ValheimPlus', version: '0.10.1.0' },
    ]);
    expect(drift.status).toBe('ok');
    expect(drift.differences).toEqual([]);
  });

  it('reports drift when a loaded version differs from the pin', () => {
    const drift = compareMods(parsePinnedMods(MODS_TABLE), [
      { name: 'BepInExPack_Valheim', version: '5.4.2350' },
      { name: 'Jotunn', version: '2.30.0' },
      { name: 'ValheimPlus', version: '0.10.0.2' },
    ]);
    expect(drift.status).toBe('drift');
    expect(drift.differences).toEqual(['ValheimPlus: pinned 10.1.0, loaded 0.10.0.2']);
  });

  it('reports drift when a pinned mod is not loaded at all', () => {
    const drift = compareMods(parsePinnedMods(MODS_TABLE), [
      { name: 'BepInExPack_Valheim', version: '5.4.2350' },
    ]);
    expect(drift.status).toBe('drift');
    expect(drift.differences).toContain('Jotunn: pinned 2.30.0, loaded nothing');
  });

  it('is unknown when either side is unknown — never a false all-clear', () => {
    expect(compareMods(parsePinnedMods(MODS_TABLE), null).status).toBe('unknown');
    expect(compareMods(null, []).status).toBe('unknown');
  });

  it('is ok for a vanilla server: nothing pinned, nothing loaded', () => {
    expect(compareMods([], []).status).toBe('ok');
  });
});
```

- [ ] **Step 2: Run — must fail**

Run: `cd api && npx jest test/mods.spec.ts`
Expected: FAIL — `Cannot find module '../src/parsers/mods'`.

- [ ] **Step 3: Implement**

Create `api/src/parsers/mods.ts`:

```typescript
import { LoadedMod, ModDrift, PinnedMod } from '../types';

export function parsePinnedMods(modsTable: string): PinnedMod[] {
  return modsTable
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith('#'))
    .map((line) => {
      const [name, version, , sha256, layout] = line.split(/\s+/);
      return { name, version, sha256, layout };
    });
}

/**
 * ValheimPlus pins as "10.1.0" and reports itself as "0.10.1.0" — the same release, written
 * two ways. Compare on the numeric components with leading zero-segments dropped, so the
 * detector does not cry drift over a formatting difference.
 */
function sameVersion(pinned: string, loaded: string): boolean {
  const norm = (v: string) => v.split('.').map(Number).filter((n, i, a) => !(i === 0 && n === 0 && a.length > 3)).join('.');
  return norm(pinned) === norm(loaded);
}

export function compareMods(
  pinned: PinnedMod[] | null,
  loaded: LoadedMod[] | null,
): ModDrift {
  if (pinned === null || loaded === null) {
    return { status: 'unknown', differences: [] };
  }

  const differences: string[] = [];
  for (const p of pinned) {
    const match = loaded.find((l) => l.name === p.name);
    if (!match) {
      differences.push(`${p.name}: pinned ${p.version}, loaded nothing`);
    } else if (!sameVersion(p.version, match.version)) {
      differences.push(`${p.name}: pinned ${p.version}, loaded ${match.version}`);
    }
  }
  return { status: differences.length ? 'drift' : 'ok', differences };
}
```

- [ ] **Step 4: Run — must pass**

Run: `cd api && npx jest test/mods.spec.ts`
Expected: PASS, all 7 tests. In particular the first `compareMods` test must pass **without** loosening it: `10.1.0` and `0.10.1.0` are the same release.

- [ ] **Step 5: Commit**

```bash
cd gameops && git add -A
git commit -m "Add pinned-mod parsing and drift detection

Compares the MODS table against what the server actually loaded. Unknown on
either side yields unknown, never a false all-clear, and the version compare
tolerates ValheimPlus pinning 10.1.0 while reporting 0.10.1.0."
```

---

### Task 4: Kubernetes access and ServerStatus assembly

**Files:**
- Create: `gameops/api/src/kube/kube.service.ts`, `gameops/api/src/servers/servers.service.ts`
- Test: `gameops/api/test/servers.service.spec.ts`

**Interfaces:**
- Consumes: parsers from Tasks 2–3; `ServerStatus` from `src/types.ts`.
- Produces:
  - `KubeService` with: `listGameDeployments()`, `readPodLog(ns, pod, tailLines)`, `readConfigMap(ns, name)`, `readService(ns, selectorApp)`, `readPodMetrics(ns, pod)`, `readVolume(pvcName, ns)`, `countSnapshots(volumeName)`
  - `ServersService.getAll(): Promise<ServerStatus[]>` with a 5-second in-memory cache
- Note for the implementer: `KubeService` is the ONLY file importing `@kubernetes/client-node`. `ServersService` takes it by constructor injection, which is what makes the test below possible without a cluster.

- [ ] **Step 1: Write the failing test with a fake KubeService**

Create `api/test/servers.service.spec.ts`:

```typescript
import { ServersService } from '../src/servers/servers.service';
import { KubeService } from '../src/kube/kube.service';

const MODS_TABLE = `ValheimPlus  10.1.0  https://example/  abc  bepinex`;

function fakeKube(overrides: Partial<KubeService> = {}): KubeService {
  const base = {
    listGameDeployments: async () => [
      {
        name: 'valheim',
        namespace: 'valheim',
        ready: true,
        restarts: 0,
        startedAt: '2026-09-11T16:16:00Z',
        podName: 'valheim-abc',
        memoryLimitMiB: 8192,
        pvcName: 'valheim-data',
        configMapName: 'valheim-config',
        modsConfigMapName: 'valheim-mods',
      },
    ],
    readPodLog: async () =>
      [
        '09/11/2026 16:16:29: Valheim version: l-1.0.12 (network version 40)',
        '09/11/2026 16:16:29: Console: ValheimPlus [0.10.1.0] is loaded.',
        '09/12/2026 09:46:44:  Connections 2 ZDOS:108465  sent:573 recv:1516',
        '09/12/2026 09:34:28: World save (5/5) done. Total time [249ms]',
      ].join('\n'),
    readConfigMap: async (_ns: string, name: string) =>
      name === 'valheim-mods'
        ? { MODS: MODS_TABLE }
        : { UPDATE_ON_START: 'false' },
    readService: async () => ({ address: '192.168.130.155', ports: [2456, 2457] }),
    readPodMetrics: async () => ({ cpuMillicores: 111, memoryMiB: 1509 }),
    readVolume: async () => ({
      // volumeName is load-bearing: ServersService passes it to countSnapshots. A fake that
      // omits it still passes these tests by accident, which is how a fake stops being a
      // faithful stand-in for the real thing.
      volumeName: 'pvc-bf017a82-fd33-48a0-a8c0-09e5d93111a1',
      actualBytes: 305635328,
      requestedBytes: 10737418240,
      snapshotGroupLabelled: true,
    }),
    countSnapshots: async () => 3,
  };
  return { ...base, ...overrides } as unknown as KubeService;
}

describe('ServersService', () => {
  it('assembles a ServerStatus from every source', async () => {
    const svc = new ServersService(fakeKube());
    const [s] = await svc.getAll();

    expect(s.name).toBe('valheim');
    expect(s.gameVersion).toBe('l-1.0.12');
    expect(s.networkVersion).toBe(40);
    expect(s.playersConnected).toBe(2);
    expect(s.playersSource).toBe('counter');
    expect(s.zdoCount).toBe(108465);
    expect(s.lastSave).toEqual({ at: '09/12/2026 09:34:28', totalMs: 249 });
    expect(s.cpuMillicores).toBe(111);
    expect(s.memoryMiB).toBe(1509);
    expect(s.drift.status).toBe('ok');
    expect(s.volume?.snapshotGroupLabelled).toBe(true);
    expect(s.address).toBe('192.168.130.155');
    expect(s.updateOnStart).toBe(false);
  });

  it('renders unknown, not zero, when a source fails', async () => {
    const svc = new ServersService(
      fakeKube({
        readPodMetrics: async () => {
          throw new Error('metrics-server down');
        },
      } as Partial<KubeService>),
    );
    const [s] = await svc.getAll();

    expect(s.cpuMillicores).toBeNull();
    expect(s.memoryMiB).toBeNull();
    // One failing source must not take the rest of the card down.
    expect(s.gameVersion).toBe('l-1.0.12');
  });

  it('serves the second call from cache within the TTL', async () => {
    let calls = 0;
    const svc = new ServersService(
      fakeKube({
        listGameDeployments: async () => {
          calls += 1;
          return [];
        },
      } as Partial<KubeService>),
    );
    await svc.getAll();
    await svc.getAll();
    expect(calls).toBe(1);
  });
});
```

- [ ] **Step 2: Run — must fail**

Run: `cd api && npx jest test/servers.service.spec.ts`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement KubeService**

Create `api/src/kube/kube.service.ts`:

```typescript
import { Injectable } from '@nestjs/common';
import {
  KubeConfig,
  CoreV1Api,
  AppsV1Api,
  CustomObjectsApi,
  Metrics,
} from '@kubernetes/client-node';

export interface GameDeployment {
  name: string;
  namespace: string;
  ready: boolean;
  restarts: number;
  startedAt: string | null;
  podName: string | null;
  memoryLimitMiB: number | null;
  pvcName: string | null;
  configMapName: string | null;
  modsConfigMapName: string | null;
}

const DISCOVERY_LABEL = 'game=valheim';

@Injectable()
export class KubeService {
  private readonly core: CoreV1Api;
  private readonly apps: AppsV1Api;
  private readonly custom: CustomObjectsApi;
  private readonly metrics: Metrics;

  constructor() {
    const kc = new KubeConfig();
    kc.loadFromDefault(); // in-cluster: the ServiceAccount token
    this.core = kc.makeApiClient(CoreV1Api);
    this.apps = kc.makeApiClient(AppsV1Api);
    this.custom = kc.makeApiClient(CustomObjectsApi);
    this.metrics = new Metrics(kc);
  }

  async listGameDeployments(): Promise<GameDeployment[]> {
    const res = await this.apps.listDeploymentForAllNamespaces({
      labelSelector: DISCOVERY_LABEL,
    });
    const out: GameDeployment[] = [];
    for (const d of res.items) {
      const ns = d.metadata!.namespace!;
      const app = d.spec!.selector!.matchLabels!['app'];
      const pods = await this.core.listNamespacedPod({
        namespace: ns,
        labelSelector: `app=${app}`,
      });
      const pod = pods.items[0];
      const gameContainer = pod?.spec?.containers.find((c) => c.name === 'valheim');
      const status = pod?.status?.containerStatuses?.find((c) => c.name === 'valheim');
      const limit = gameContainer?.resources?.limits?.['memory'];
      out.push({
        name: d.metadata!.name!,
        namespace: ns,
        ready: (d.status?.readyReplicas ?? 0) > 0,
        restarts: status?.restartCount ?? 0,
        startedAt: pod?.status?.startTime
          ? new Date(pod.status.startTime).toISOString()
          : null,
        podName: pod?.metadata?.name ?? null,
        memoryLimitMiB: limit ? parseMemoryToMiB(limit) : null,
        pvcName:
          pod?.spec?.volumes?.find((v) => v.persistentVolumeClaim?.claimName?.endsWith('-data'))
            ?.persistentVolumeClaim?.claimName ?? null,
        configMapName: `${d.metadata!.name!}-config`,
        modsConfigMapName: ns === 'valheim' ? 'valheim-mods' : null,
      });
    }
    return out;
  }

  async readPodLog(namespace: string, pod: string, tailLines = 4000): Promise<string> {
    return this.core.readNamespacedPodLog({
      name: pod,
      namespace,
      container: 'valheim',
      tailLines,
    });
  }

  async readConfigMap(namespace: string, name: string): Promise<Record<string, string>> {
    const cm = await this.core.readNamespacedConfigMap({ name, namespace });
    return cm.data ?? {};
  }

  async readService(
    namespace: string,
    app: string,
  ): Promise<{ address: string | null; ports: number[] }> {
    const svcs = await this.core.listNamespacedService({
      namespace,
      labelSelector: `app=${app}`,
    });
    const svc = svcs.items[0];
    return {
      address: svc?.status?.loadBalancer?.ingress?.[0]?.ip ?? null,
      ports: svc?.spec?.ports?.map((p) => p.port) ?? [],
    };
  }

  /**
   * The raw metrics API reports NANOCORES ("111027021n") and KiB ("1545632Ki") —
   * not the "114m"/"1509Mi" kubectl top prints. Convert here, once.
   */
  async readPodMetrics(
    namespace: string,
    pod: string,
  ): Promise<{ cpuMillicores: number; memoryMiB: number }> {
    const m = await this.metrics.getPodMetrics(namespace, pod);
    const c = m.containers.find((x) => x.name === 'valheim') ?? m.containers[0];
    return {
      cpuMillicores: Math.round(parseCpuToNanocores(c.usage.cpu) / 1e6),
      memoryMiB: Math.round(parseMemoryToMiB(c.usage.memory)),
    };
  }

  async readVolume(
    namespace: string,
    pvcName: string,
  ): Promise<{ actualBytes: number; requestedBytes: number; snapshotGroupLabelled: boolean } & { volumeName: string }> {
    const pvc = await this.core.readNamespacedPersistentVolumeClaim({
      name: pvcName,
      namespace,
    });
    const volumeName = pvc.spec!.volumeName!;
    const vol = (await this.custom.getNamespacedCustomObject({
      group: 'longhorn.io',
      version: 'v1beta2',
      namespace: 'longhorn-system',
      plural: 'volumes',
      name: volumeName,
    })) as any;
    const labels: Record<string, string> = vol.metadata?.labels ?? {};
    return {
      volumeName,
      actualBytes: Number(vol.status?.actualSize ?? 0),
      requestedBytes: Number(vol.spec?.size ?? 0),
      snapshotGroupLabelled: Object.keys(labels).some(
        (k) => k.startsWith('recurring-job-group.longhorn.io/') && k !== 'recurring-job-group.longhorn.io/default',
      ),
    };
  }

  async countSnapshots(volumeName: string): Promise<number> {
    const list = (await this.custom.listNamespacedCustomObject({
      group: 'longhorn.io',
      version: 'v1beta2',
      namespace: 'longhorn-system',
      plural: 'snapshots',
    })) as any;
    return (list.items ?? []).filter((s: any) => s.spec?.volume === volumeName).length;
  }
}

export function parseCpuToNanocores(v: string): number {
  if (v.endsWith('n')) return Number(v.slice(0, -1));
  if (v.endsWith('u')) return Number(v.slice(0, -1)) * 1e3;
  if (v.endsWith('m')) return Number(v.slice(0, -1)) * 1e6;
  return Number(v) * 1e9;
}

export function parseMemoryToMiB(v: string): number {
  const units: Record<string, number> = {
    Ki: 1 / 1024,
    Mi: 1,
    Gi: 1024,
    K: 1000 / 1024 / 1024,
    M: 1000 * 1000 / 1024 / 1024,
    G: 1000 * 1000 * 1000 / 1024 / 1024,
  };
  const m = v.match(/^(\d+(?:\.\d+)?)([A-Za-z]*)$/);
  if (!m) return 0;
  const [, num, unit] = m;
  return Number(num) * (units[unit] ?? 1 / 1024 / 1024);
}
```

- [ ] **Step 4: Implement ServersService**

Create `api/src/servers/servers.service.ts`:

```typescript
import { Injectable } from '@nestjs/common';
import { KubeService } from '../kube/kube.service';
import { ServerStatus } from '../types';
import {
  parseGameVersion,
  parseLoadedMods,
  parseConnections,
  parseZdoCount,
  parseLastSave,
} from '../parsers/logs';
import { parsePinnedMods, compareMods } from '../parsers/mods';

const CACHE_TTL_MS = 5000;

/** Never let one failing source empty the whole card. */
async function safe<T>(fn: () => Promise<T>): Promise<T | null> {
  try {
    return await fn();
  } catch {
    return null;
  }
}

@Injectable()
export class ServersService {
  private cache: { at: number; value: ServerStatus[] } | null = null;

  constructor(private readonly kube: KubeService) {}

  async getAll(): Promise<ServerStatus[]> {
    if (this.cache && Date.now() - this.cache.at < CACHE_TTL_MS) {
      return this.cache.value;
    }
    const deployments = await this.kube.listGameDeployments();
    const value = await Promise.all(deployments.map((d) => this.build(d)));
    this.cache = { at: Date.now(), value };
    return value;
  }

  private async build(d: Awaited<ReturnType<KubeService['listGameDeployments']>>[number]): Promise<ServerStatus> {
    const log = d.podName
      ? await safe(() => this.kube.readPodLog(d.namespace, d.podName!))
      : null;
    const config = await safe(() => this.kube.readConfigMap(d.namespace, d.configMapName!));
    const modsCm = d.modsConfigMapName
      ? await safe(() => this.kube.readConfigMap(d.namespace, d.modsConfigMapName!))
      : null;
    const metrics = d.podName
      ? await safe(() => this.kube.readPodMetrics(d.namespace, d.podName!))
      : null;
    const svc = await safe(() => this.kube.readService(d.namespace, d.name));
    const vol = d.pvcName ? await safe(() => this.kube.readVolume(d.namespace, d.pvcName!)) : null;
    const snapshots = vol ? await safe(() => this.kube.countSnapshots(vol.volumeName)) : null;

    const version = log ? parseGameVersion(log) : null;
    const loadedMods = log ? parseLoadedMods(log) : null;
    const pinnedMods = modsCm?.MODS ? parsePinnedMods(modsCm.MODS) : d.modsConfigMapName ? null : [];
    const connections = log ? parseConnections(log) : null;

    return {
      name: d.name,
      namespace: d.namespace,
      deployment: d.name,
      modded: config?.BEPINEX_ENABLED === 'true',
      ready: d.ready,
      restarts: d.restarts,
      startedAt: d.startedAt,
      cpuMillicores: metrics?.cpuMillicores ?? null,
      memoryMiB: metrics?.memoryMiB ?? null,
      memoryLimitMiB: d.memoryLimitMiB,
      gameVersion: version?.game ?? null,
      networkVersion: version?.network ?? null,
      pinnedMods,
      loadedMods,
      drift: compareMods(pinnedMods, loadedMods),
      playersConnected: connections?.count ?? null,
      playersSource: connections?.source ?? null,
      zdoCount: log ? parseZdoCount(log) : null,
      lastSave: log ? parseLastSave(log) : null,
      volume: vol
        ? {
            actualBytes: vol.actualBytes,
            requestedBytes: vol.requestedBytes,
            snapshotGroupLabelled: vol.snapshotGroupLabelled,
            snapshotCount: snapshots ?? 0,
          }
        : null,
      address: svc?.address ?? null,
      ports: svc?.ports ?? [],
      updateOnStart: config ? config.UPDATE_ON_START === 'true' : null,
    };
  }
}
```

- [ ] **Step 5: Run — must pass**

Run: `cd api && npx jest test/servers.service.spec.ts`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
cd gameops && git add -A
git commit -m "Add Kubernetes access layer and ServerStatus assembly

KubeService is the only file that imports the Kubernetes client, so
ServersService is testable against a fake with no cluster. Each source is
wrapped so one failure yields null for that field instead of emptying the
card, and metrics are converted from nanocores/KiB at the boundary."
```

---

### Task 5: The HTTP API

**Files:**
- Create: `gameops/api/src/servers/servers.controller.ts`, `gameops/api/src/servers/servers.module.ts`
- Modify: `gameops/api/src/app.module.ts`
- Test: `gameops/api/test/servers.e2e-spec.ts`

**Interfaces:**
- Consumes: `ServersService.getAll()` (Task 4).
- Produces: `GET /api/servers` → `ServerStatus[]` as JSON.

- [ ] **Step 1: Write the failing test**

Create `api/test/servers.e2e-spec.ts`:

```typescript
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { ServersController } from '../src/servers/servers.controller';
import { ServersService } from '../src/servers/servers.service';

describe('GET /api/servers', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      controllers: [ServersController],
      providers: [
        {
          provide: ServersService,
          useValue: {
            getAll: async () => [{ name: 'valheim', gameVersion: 'l-1.0.12' }],
          },
        },
      ],
    }).compile();
    app = moduleRef.createNestApplication();
    await app.init();
  });

  afterAll(async () => await app.close());

  it('returns the server list', async () => {
    const res = await request(app.getHttpServer()).get('/api/servers').expect(200);
    expect(res.body).toEqual([{ name: 'valheim', gameVersion: 'l-1.0.12' }]);
  });
});
```

- [ ] **Step 2: Run — must fail**

Run: `cd api && npx jest test/servers.e2e-spec.ts`
Expected: FAIL — `Cannot find module '../src/servers/servers.controller'`.

- [ ] **Step 3: Implement**

Create `api/src/servers/servers.controller.ts`:

```typescript
import { Controller, Get } from '@nestjs/common';
import { ServersService } from './servers.service';
import { ServerStatus } from '../types';

@Controller('api')
export class ServersController {
  constructor(private readonly servers: ServersService) {}

  @Get('servers')
  async list(): Promise<ServerStatus[]> {
    return this.servers.getAll();
  }
}
```

Create `api/src/servers/servers.module.ts`:

```typescript
import { Module } from '@nestjs/common';
import { ServersController } from './servers.controller';
import { ServersService } from './servers.service';
import { KubeService } from '../kube/kube.service';

@Module({
  controllers: [ServersController],
  providers: [ServersService, KubeService],
})
export class ServersModule {}
```

Add `ServersModule` to the `imports` array in `api/src/app.module.ts`.

- [ ] **Step 4: Run the whole API suite — must pass**

Run: `cd api && npx jest`
Expected: PASS — health, logs, mods, servers.service and servers e2e, output clean.

- [ ] **Step 5: Commit**

```bash
cd gameops && git add -A
git commit -m "Expose GET /api/servers"
```

---

### Task 6: The web UI

**Files:**
- Create: `gameops/web/src/api.ts`, `gameops/web/src/components/ServerCard.tsx`, `gameops/web/src/components/Field.tsx`
- Modify: `gameops/web/src/App.tsx`, `gameops/web/src/main.tsx`, `gameops/web/vite.config.ts`
- Test: `gameops/web/src/components/ServerCard.test.tsx`

**Interfaces:**
- Consumes: `GET /api/servers` returning `ServerStatus[]` (Task 5).
- Produces: a single page that polls every 10 seconds and renders one card per server.

- [ ] **Step 1: Design the visuals before writing components**

**Invoke the `/design` skill** for the card layout and visual language, using the operator's references: `https://www.tasteskill.dev/` and `https://impeccable.style/`. What is fixed by this plan and must survive any design: every field can read **unknown**; drift and an unlabelled snapshot volume are the two states that must be visually loud; and the page must be readable at a glance from across a room.

- [ ] **Step 2: Write the failing component test**

Create `web/src/components/ServerCard.test.tsx`:

```tsx
import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { ServerCard } from './ServerCard';

const base = {
  name: 'valheim',
  namespace: 'valheim',
  deployment: 'valheim',
  modded: true,
  ready: true,
  restarts: 0,
  startedAt: null,
  cpuMillicores: 111,
  memoryMiB: 1509,
  memoryLimitMiB: 8192,
  gameVersion: 'l-1.0.12',
  networkVersion: 40,
  pinnedMods: [],
  loadedMods: [],
  drift: { status: 'ok' as const, differences: [] },
  playersConnected: 2,
  playersSource: 'counter' as const,
  zdoCount: 108465,
  lastSave: { at: '09/12/2026 09:34:28', totalMs: 249 },
  volume: { actualBytes: 305635328, requestedBytes: 10737418240, snapshotGroupLabelled: true, snapshotCount: 3 },
  address: '192.168.130.155',
  ports: [2456, 2457],
  updateOnStart: false,
};

describe('ServerCard', () => {
  it('shows the server name and player count', () => {
    render(<ServerCard server={base} />);
    expect(screen.getByText('valheim')).toBeInTheDocument();
    expect(screen.getByText('2')).toBeInTheDocument();
  });

  it('renders "unknown" for a null field, never 0', () => {
    render(<ServerCard server={{ ...base, playersConnected: null, playersSource: null }} />);
    expect(screen.getByText(/unknown/i)).toBeInTheDocument();
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  it('shows drift loudly when versions disagree', () => {
    render(
      <ServerCard
        server={{
          ...base,
          drift: { status: 'drift', differences: ['ValheimPlus: pinned 10.1.0, loaded 0.10.0.2'] },
        }}
      />,
    );
    expect(screen.getByText(/ValheimPlus: pinned 10.1.0, loaded 0.10.0.2/)).toBeInTheDocument();
  });

  it('warns when the volume is not in a snapshot group', () => {
    render(
      <ServerCard server={{ ...base, volume: { ...base.volume, snapshotGroupLabelled: false } }} />,
    );
    expect(screen.getByText(/not in a snapshot group/i)).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run — must fail**

Run: `cd web && npx vitest run`
Expected: FAIL — `Failed to resolve import "./ServerCard"`.

- [ ] **Step 4: Implement the fetch layer and components**

Create `web/src/api.ts`. The `ServerStatus` shape is deliberately **restated** here rather than
imported from `api/src/types.ts`: the two halves have separate tsconfigs, builds and Docker
stages, and sharing one type would mean an npm workspace this app does not otherwise need. The
contract is the JSON returned by `GET /api/servers`; if you change the API type, change this one
in the same commit.

```typescript
export interface ServerStatus {
  name: string;
  namespace: string;
  deployment: string;
  modded: boolean;
  ready: boolean;
  restarts: number;
  startedAt: string | null;
  cpuMillicores: number | null;
  memoryMiB: number | null;
  memoryLimitMiB: number | null;
  gameVersion: string | null;
  networkVersion: number | null;
  pinnedMods: { name: string; version: string; sha256: string; layout: string }[] | null;
  loadedMods: { name: string; version: string }[] | null;
  drift: { status: 'ok' | 'drift' | 'unknown'; differences: string[] };
  playersConnected: number | null;
  playersSource: 'sockets' | 'counter' | null;
  zdoCount: number | null;
  lastSave: { at: string; totalMs: number } | null;
  volume: {
    actualBytes: number;
    requestedBytes: number;
    snapshotGroupLabelled: boolean;
    snapshotCount: number;
  } | null;
  address: string | null;
  ports: number[];
  updateOnStart: boolean | null;
}

export async function fetchServers(): Promise<ServerStatus[]> {
  const res = await fetch('/api/servers');
  if (!res.ok) throw new Error(`/api/servers returned ${res.status}`);
  return res.json();
}
```

Create `web/src/components/Field.tsx`:

```tsx
export function Field({ label, value }: { label: string; value: React.ReactNode | null }) {
  return (
    <div className="flex justify-between gap-4 py-1">
      <span className="text-slate-400">{label}</span>
      <span className={value === null || value === undefined ? 'text-slate-500 italic' : 'text-slate-100'}>
        {value === null || value === undefined ? 'unknown' : value}
      </span>
    </div>
  );
}
```

Create `web/src/components/ServerCard.tsx` (styling is refined in Step 1's design pass; this is the contract):

```tsx
import { ServerStatus } from '../api';
import { Field } from './Field';

const mib = (bytes: number) => `${Math.round(bytes / 1024 / 1024)} MiB`;

export function ServerCard({ server: s }: { server: ServerStatus }) {
  return (
    <article className="rounded-xl bg-slate-900 p-5 shadow">
      <header className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-50">{s.name}</h2>
        <span>{s.ready ? 'up' : 'down'}</span>
      </header>

      <Field label="Players" value={s.playersConnected} />
      <Field label="Game version" value={s.gameVersion} />
      <Field label="World (ZDOs)" value={s.zdoCount?.toLocaleString() ?? null} />
      <Field label="CPU" value={s.cpuMillicores !== null ? `${s.cpuMillicores}m` : null} />
      <Field
        label="Memory"
        value={s.memoryMiB !== null ? `${s.memoryMiB} / ${s.memoryLimitMiB ?? '?'} MiB` : null}
      />
      <Field label="Volume" value={s.volume ? mib(s.volume.actualBytes) : null} />
      <Field label="Last save" value={s.lastSave ? `${s.lastSave.totalMs} ms` : null} />
      <Field label="Join" value={s.address ? `${s.address}:${s.ports[0] ?? ''}` : null} />

      {s.drift.status === 'drift' && (
        <p role="alert" className="mt-3 rounded bg-amber-950 p-2 text-amber-200">
          {s.drift.differences.join('; ')}
        </p>
      )}
      {s.volume && !s.volume.snapshotGroupLabelled && (
        <p role="alert" className="mt-2 rounded bg-red-950 p-2 text-red-200">
          Volume is not in a snapshot group — backups are not running
        </p>
      )}
    </article>
  );
}
```

- [ ] **Step 5: Run — must pass**

Run: `cd web && npx vitest run`
Expected: PASS, 4 tests.

- [ ] **Step 6: Wire the page with polling**

Replace `web/src/App.tsx`:

```tsx
import { useQuery } from '@tanstack/react-query';
import { fetchServers } from './api';
import { ServerCard } from './components/ServerCard';

export default function App() {
  const { data, error, isLoading } = useQuery({
    queryKey: ['servers'],
    queryFn: fetchServers,
    refetchInterval: 10_000,
  });

  if (isLoading) return <p className="p-8 text-slate-300">Loading…</p>;
  if (error) return <p className="p-8 text-red-300">Cannot reach the API: {String(error)}</p>;

  return (
    <main className="min-h-screen bg-slate-950 p-8">
      <h1 className="mb-6 text-2xl font-semibold text-slate-50">Game servers</h1>
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {data!.map((s) => (
          <ServerCard key={`${s.namespace}/${s.name}`} server={s} />
        ))}
      </div>
    </main>
  );
}
```

Wrap the app in a `QueryClientProvider` in `web/src/main.tsx`, and add a dev proxy so `npm run dev` reaches a locally running API — in `web/vite.config.ts`:

```typescript
server: { proxy: { '/api': 'http://localhost:3000' } },
```

- [ ] **Step 7: Commit**

```bash
cd gameops && git add -A
git commit -m "Add the dashboard page: server cards, polling, unknown states

Every field renders 'unknown' rather than a zero when its source is absent.
Mod drift and an unlabelled snapshot volume are the two loud states."
```

---

### Task 7: Manifests in this repo

**Files:**
- Create: `gameops/namespace.yaml`, `gameops/rbac.yaml`, `gameops/deployment.yaml`, `gameops/service.yaml`, `gameops/ingressroute.yaml`, `gameops/README.md` (all in `kubernetes-manifests-personal`)

**Interfaces:**
- Consumes: the image from Task 1's Dockerfile, published in Task 9.
- Produces: namespace `gameops` with a read-only ServiceAccount and the workload, reachable at `gameops.arnoldtech.io`.

- [ ] **Step 1: Write the manifests**

`gameops/namespace.yaml`:

```yaml
# restricted: this app needs no root, no capabilities and no writable filesystem, unlike the
# game servers (whose image needs root for usermod/chown). enforce rejects a non-compliant
# Pod; warn makes a non-compliant DEPLOYMENT print a warning at apply time, which enforce
# alone would not do.
apiVersion: v1
kind: Namespace
metadata:
  name: gameops
  labels:
    app: gameops
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

`gameops/rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gameops
  namespace: gameops
  labels:
    app: gameops
---
# ⚠️ READ-ONLY BY CONSTRUCTION. get/list/watch only.
# `secrets` and `pods/exec` are deliberately ABSENT and must never be added:
#   - the dashboard never needs a secret value, and this cluster denies reading them anyway
#   - pods/exec is arbitrary command execution as root inside a game container, which would
#     turn an unauthenticated LAN page into a remote shell
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gameops-read
  labels:
    app: gameops
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "configmaps", "services", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["longhorn.io"]
  resources: ["volumes", "snapshots", "recurringjobs"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gameops-read
  labels:
    app: gameops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gameops-read
subjects:
- kind: ServiceAccount
  name: gameops
  namespace: gameops
```

`gameops/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gameops
  namespace: gameops
  labels:
    app: gameops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gameops
  template:
    metadata:
      labels:
        app: gameops
    spec:
      serviceAccountName: gameops
      # The app DOES need its token (it reads the API) -- unlike the game servers, which have
      # automountServiceAccountToken: false precisely because they never talk to Kubernetes.
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      imagePullSecrets:
      # Namespaced; created by the operator in this namespace by hand. Never committed.
      - name: gitea-registry-secret
      containers:
      - name: gameops
        image: gitea.arnoldtech.io/arnold-tech/gameops:0.1.0
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 3000
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        readinessProbe:
          httpGet:
            path: /api/health
            port: http
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/health
            port: http
          periodSeconds: 30
          failureThreshold: 3
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            memory: "256Mi"
```

`gameops/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gameops
  namespace: gameops
  labels:
    app: gameops
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 3000
    targetPort: http
  selector:
    app: gameops
```

`gameops/ingressroute.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gameops
  namespace: gameops
  annotations:
    # The ingressClass the kubernetescrd provider watches -- NOT the `traefik` IngressClass
    # object used by plain Ingresses.
    kubernetes.io/ingress.class: traefik-external
spec:
  entryPoints:
  - websecure
  routes:
  - kind: Rule
    match: Host(`gameops.arnoldtech.io`)
    services:
    - name: gameops
      port: 3000
  # Empty on purpose: Traefik falls back to TLSStore/default in ns traefik, which holds the
  # *.arnoldtech.io wildcard. Do NOT add a secretName and do NOT create a Certificate.
  tls: {}
```

- [ ] **Step 2: Validate, including the PSA negative control**

```powershell
cd gameops
kubectl apply -f namespace.yaml
# Negative control: a non-compliant pod MUST be rejected, proving the label is live.
kubectl run psa-probe -n gameops --image=busybox --restart=Never --dry-run=server -- sleep 1
kubectl apply --dry-run=server -f rbac.yaml -f deployment.yaml -f service.yaml -f ingressroute.yaml
cd ..
```

Expected: `namespace/gameops created`; the `psa-probe` line **errors** with `violates PodSecurity "restricted:latest"`; the four manifests report `created (server dry run)` with **no** `Warning: would violate PodSecurity`.

- [ ] **Step 3: Prove the ServiceAccount is genuinely read-only**

```powershell
$sa = "system:serviceaccount:gameops:gameops"
foreach ($v in @("get pods","get pods/log","list deployments","get configmaps")) {
  "{0,-22} {1}" -f $v, (kubectl auth can-i --as=$sa $v.Split(" ")[0] $v.Split(" ")[1])
}
foreach ($v in @("get secrets","create pods/exec","delete deployments","patch configmaps")) {
  "{0,-22} {1}" -f $v, (kubectl auth can-i --as=$sa $v.Split(" ")[0] $v.Split(" ")[1])
}
```

Expected: **yes** for the first four, **no** for all four of the second group. The first group passing is what proves the impersonation check works at all — a check that answers "no" to everything proves nothing.

- [ ] **Step 4: Write `gameops/README.md`**

````markdown
# gameops — game server dashboard

Read-only web dashboard for the Valheim servers on this cluster, at
`https://gameops.arnoldtech.io` (LAN only — pihole resolves every `*.arnoldtech.io` name to
Traefik, so no DNS record is needed).
App code: the `gameops` repo. Design: `../docs/superpowers/specs/2026-09-12-valheim-manager-design.md`.

## What it shows

Per server: up/down and restarts, players connected, game and network version, mods pinned
versus actually loaded (**drift**), CPU and memory against limits, volume usage, last save
duration, snapshot count and whether the volume carries its recurring-job label, and the join
address.

**A field reads `unknown` when its source is unavailable — never `0`.** Container logs rotate,
so a long-running pod eventually loses its own boot lines and with them the version and mod
information. A restart restores them.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace `gameops`, Pod Security `restricted` |
| `rbac.yaml` | ServiceAccount + read-only ClusterRole + binding |
| `deployment.yaml` | The app, hardened, one replica |
| `service.yaml` | ClusterIP :3000 |
| `ingressroute.yaml` | `gameops.arnoldtech.io` on the wildcard cert |

## Applying

```powershell
cd gameops/
kubectl apply -f namespace.yaml -f rbac.yaml -f deployment.yaml -f service.yaml -f ingressroute.yaml
```

**First time only**, create the registry pull secret in this namespace (it is namespaced, and
never committed):

```powershell
kubectl create secret docker-registry gitea-registry-secret -n gameops `
  --docker-server=gitea.arnoldtech.io --docker-username=<user> --docker-password=<token>
```

## Discovery

A server appears on the dashboard when its Deployment carries the label `game=valheim`. Adding
a new server needs no change here — label it and it shows up.

## The permissions, and why they stop where they do

`get`/`list`/`watch` only. **`secrets` and `pods/exec` are deliberately absent.** The app never
needs a secret value, and `exec` would make an unauthenticated LAN page a way to run commands
as root inside a game container. If a future feature seems to need either, that feature needs
a login first.

## Accepted risks

- **No authentication.** Anyone on the LAN can read it. It is read-only and shows no
  credentials. Revisit before adding any write action or exposing it beyond the LAN.
- **Player counts are approximate**, reconstructed from connect/disconnect events plus a
  counter the server prints every ten minutes.
````

- [ ] **Step 5: Commit**

```bash
git add gameops/
git commit -F - <<'EOF'
Add gameops manifests: read-only dashboard for the game servers

Namespace enforcing restricted, a ClusterRole that is get/list/watch only and
deliberately names neither secrets nor pods/exec, the hardened workload, and
an IngressRoute on the wildcard cert at gameops.arnoldtech.io.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 8: Label the game servers for discovery

**Files:**
- Modify: `valheim/deployment.yaml`, `valheim-public/deployment.yaml` (add one label each)

**Interfaces:**
- Consumes: nothing.
- Produces: both Deployments carry `game: valheim`, which is what `listGameDeployments()` selects on.

⚠️ **Done correctly this restarts nothing.** The label goes on each Deployment's own metadata,
which is not part of the pod template, so no rollout is triggered — Step 2 proves that by
dry-run and Step 3 confirms it by unchanged pod ages. The connection check stays anyway: if the
label lands in the pod template by mistake, both servers restart, and that check is the only
thing standing between the mistake and players dropped mid-session.

- [ ] **Step 1: Add the label to both Deployments**

In `valheim/deployment.yaml` and `valheim-public/deployment.yaml`, add `game: valheim` to
`metadata.labels` **only** — not to `spec.selector.matchLabels` and not to
`spec.template.metadata.labels`. The selector is immutable on an existing Deployment, and
changing it would require deleting and recreating the object.

`valheim/deployment.yaml`:

```yaml
metadata:
  name: valheim
  namespace: valheim
  labels:
    app: valheim
    # Discovery label for gameops (../gameops). It is on the Deployment's OWN metadata, never
    # in spec.selector.matchLabels -- that field is immutable and changing it forces a delete
    # and recreate of the Deployment.
    game: valheim
```

`valheim-public/deployment.yaml`:

```yaml
metadata:
  name: valheim-public
  namespace: valheim-public
  labels:
    app: valheim-public
    # Discovery label for gameops (../gameops). Deployment metadata only -- never
    # spec.selector.matchLabels, which is immutable.
    game: valheim
```

- [ ] **Step 2: Confirm a metadata-only label change does not restart anything**

```powershell
cd valheim-public
kubectl apply --dry-run=server -f deployment.yaml
cd ..
```

Expected: `deployment.apps/valheim-public configured (server dry run)`. A label on the
Deployment's own metadata does not change the pod template, so **no** rollout is triggered.

- [ ] **Step 3: Apply, with a connection check in the same action anyway**

Even though no restart is expected, check connections in the same action — the repo rule
exists because an assumption here once dropped four players:

```powershell
kubectl logs -n valheim-public deploy/valheim-public -c valheim --since=5m | Select-String "Got connection|Closing socket"
cd valheim-public; kubectl apply -f deployment.yaml; cd ..
kubectl logs -n valheim deploy/valheim -c valheim --since=5m | Select-String "Got connection|Closing socket"
cd valheim; kubectl apply -f deployment.yaml; cd ..
```

Expected: both say `configured`. Then confirm no rollout happened:

```powershell
kubectl get pods -n valheim-public -n valheim -o wide
```

Expected: the same pod names and ages as before the apply. If a pod restarted, the label went
into the pod template by mistake — revert and fix.

- [ ] **Step 4: Prove discovery works**

```powershell
kubectl get deploy -A -l game=valheim
```

Expected: exactly two rows, `valheim` and `valheim-public`.

- [ ] **Step 5: Commit**

```bash
git add valheim/deployment.yaml valheim-public/deployment.yaml
git commit -F - <<'EOF'
Label both game servers for gameops discovery

The label goes on each Deployment's own metadata, not the pod template and
not the selector: the selector is immutable, and a pod-template change would
restart a live server for a dashboard's benefit. Verified by dry-run and by
pod ages being unchanged after the apply.

<attribution lines from the session's system reminder>
EOF
```

---

### Task 9: Build, publish, deploy and verify live

**Files:**
- Create: `gameops/api/test/no-secrets.spec.ts`
- Modify: `gameops/deployment.yaml` (image tag, if it moves past 0.1.0)

**Interfaces:**
- Consumes: everything above.
- Produces: the dashboard live at `https://gameops.arnoldtech.io`.

- [ ] **Step 1: Add the guard test that no Secret value can reach the response**

Create `api/test/no-secrets.spec.ts`:

```typescript
import { readFileSync, readdirSync, statSync } from 'fs';
import { join } from 'path';

/**
 * The ClusterRole is what actually prevents secret access; this test prevents the code from
 * ever asking. It is a cheap tripwire against a future change that adds a secret read.
 */
function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

describe('the API never reads Secrets', () => {
  it('has no call to any secret-reading client method', () => {
    const offenders = walk(join(__dirname, '..', 'src'))
      .filter((f) => f.endsWith('.ts'))
      .filter((f) => /readNamespacedSecret|listSecret|['"]secrets['"]/.test(readFileSync(f, 'utf8')));
    expect(offenders).toEqual([]);
  });
});
```

Run: `cd api && npx jest test/no-secrets.spec.ts` — expected PASS.

- [ ] **Step 2: Build and push the image**

```bash
cd C:/Users/RyanArnold/Documents/GitHub/gameops
docker build -t gitea.arnoldtech.io/arnold-tech/gameops:0.1.0 .
docker push gitea.arnoldtech.io/arnold-tech/gameops:0.1.0
```

Expected: push succeeds. If it 401s, run `docker login gitea.arnoldtech.io` and retry.

- [ ] **Step 3: Operator creates the pull secret, then deploy**

```powershell
kubectl create secret docker-registry gitea-registry-secret -n gameops `
  --docker-server=gitea.arnoldtech.io --docker-username=<user> --docker-password=<token>
cd gameops
kubectl apply -f namespace.yaml -f rbac.yaml -f deployment.yaml -f service.yaml -f ingressroute.yaml
kubectl rollout status deploy/gameops -n gameops --timeout=180s
cd ..
```

Expected: `successfully rolled out`, no PodSecurity warning.

- [ ] **Step 4: Verify the API against known-true values**

```powershell
kubectl exec -n gameops deploy/gameops -- node -e "fetch('http://localhost:3000/api/servers').then(r=>r.json()).then(d=>console.log(JSON.stringify(d,null,1)))"
```

Expected: two entries. Check each against what you already know to be true right now:

| Field | Must match |
|---|---|
| `name` | `valheim` and `valheim-public` |
| `gameVersion` | `l-1.0.12` on both |
| `modded` | `true` for valheim, `false` for valheim-public |
| `drift.status` | `ok` for valheim (pins 10.1.0, loads 0.10.1.0) |
| `address` | `192.168.130.155` and `192.168.130.157` |
| `volume.snapshotGroupLabelled` | `true` for both |
| `updateOnStart` | `false` for valheim, `true` for valheim-public |

Cross-check two of them independently, so the dashboard is not merely agreeing with itself:

```powershell
kubectl top pod -n valheim-public
kubectl logs -n valheim deploy/valheim -c valheim | Select-String "is loaded" | Select-Object -Last 1
```

- [ ] **Step 5: Verify the page loads over the wildcard cert**

Open `https://gameops.arnoldtech.io` in a browser on the LAN.

Expected: the cards render, the certificate is the `*.arnoldtech.io` wildcard, and the values
update within ten seconds of a change. If the page does not load, the fault is Traefik or the
IngressRoute — never DNS, because pihole already resolves every `*.arnoldtech.io` name.

- [ ] **Step 6: Verify the "unknown" path for real**

The strongest available test of the rotation behaviour, without waiting weeks for a log to
rotate:

```powershell
kubectl exec -n gameops deploy/gameops -- node -e "fetch('http://localhost:3000/api/servers').then(r=>r.json()).then(d=>console.log(d.map(s=>[s.name,s.gameVersion,s.playersConnected]).join('\n')))"
kubectl rollout restart deploy/valheim-public -n valheim-public   # only if the server is empty
```

Immediately after the restart, before the new pod has logged its version line, the dashboard
must show `unknown` for that server's version — not `l-1.0.12` carried over, and not `null`
rendered as `0`. Confirm in the browser, then let it settle.

- [ ] **Step 7: Commit and record the results**

Append a `## Verified` section to `gameops/README.md` with what was actually observed
(pass/fail per row of Step 4, plus the Step 6 result and the date), then:

```bash
git add gameops/README.md
git commit -F - <<'EOF'
Record the gameops verification results

<attribution lines from the session's system reminder>
EOF
```
