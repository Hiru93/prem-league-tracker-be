# Tournament Stage — Technical

Defines the data model and lifecycle for a stage ("tappa"), consistent with the memo's Postgres decision: stages are ingested from melee.gg and snapshotted, not live-proxied.

**Updated 2026-08-26 (second corner-case review)**: stages are now reached through their league — public routes are nested under a league (e.g. `GET /leagues/:leagueSlug/stages`, §3) rather than being flat/global — and a `Stage` can be marked `excluded` (see `data-model-technical.md`), which this doc's listing/detail routes must consistently honor (§3a).

Related: `data-model-technical.md` (`League`, `Season.leagueId`, `Stage.excluded`), `league-scoring-technical.md` (how placements become points), `melee-integration-technical.md` (how data is fetched and mapped into these models, including auto-include and the per-league sync trigger), `player-technical.md` (identity behind each placement/pairing), `decklists-technical.md` (decklists attached to a stage's players).

## 1. Data model

```prisma
enum StageStatus {
  OPEN
  IN_PROGRESS
  CLOSED
}

model Stage {
  id            String       @id @default(cuid())
  seasonId      String
  season        Season       @relation(fields: [seasonId], references: [id]) // the league edition this stage's results count toward; see data-model-technical.md
  name          String       // e.g. "Tappa 3 - Modern"
  sequence      Int          // ordering within the season
  isFinal       Boolean      @default(false) // true only for the season-ending final tournament (Top-8) — see §1a
  excluded      Boolean      @default(false) // admin safety-net: hides this stage from standings/listings without deleting data — see §1b and melee-integration-technical.md §2c
  meleeTournamentId String?  @unique // melee.gg's identifier, nullable until first sync
  meleeUrl      String?
  status        StageStatus  @default(OPEN)
  playerCount   Int?         // denormalized field size (N), set on close
  scheduledAt   DateTime?
  closedAt      DateTime?
  createdAt     DateTime     @default(now())
  updatedAt     DateTime     @updatedAt

  placements    StagePlacement[]
  pairings      StagePairing[]
  syncLogs      StageSyncLog[]

  @@index([seasonId, sequence])
}

model StagePairing {
  id         String   @id @default(cuid())
  stageId    String
  stage      Stage    @relation(fields: [stageId], references: [id])
  round      Int
  tableNumber Int?
  player1Id  String
  player1    Player   @relation("Player1Pairings", fields: [player1Id], references: [id])
  player2Id  String?  // nullable: bye
  player2    Player?  @relation("Player2Pairings", fields: [player2Id], references: [id])
  result     String?  // free-text as sourced, e.g. "2-1", "2-0-1", "BYE"
  createdAt  DateTime @default(now())

  @@index([stageId, round])
}

model StageSyncLog {
  id          String   @id @default(cuid())
  stageId     String
  stage       Stage    @relation(fields: [stageId], references: [id])
  triggeredBy String   // "manual:<userEmail>" | "scheduled"
  status      String   // "success" | "partial" | "failed"
  message     String?  @db.Text
  startedAt   DateTime @default(now())
  finishedAt  DateTime?
}
```

`StagePlacement` is defined in `league-scoring-technical.md` §2; it belongs conceptually to the stage but its shape is owned by the scoring doc since `points`/`fieldSize` are scoring concerns.

`Season` (and `DecklistVisibilityMode`, `AdminUser`) are defined in `data-model-technical.md`; this doc only adds the `seasonId` FK on `Stage`.

### 1a. `isFinal` — the season-ending final tournament

Once a season's regular stages are complete, the Top 8 of the standings (per `league-scoring-technical.md` §4) play a season-ending final tournament. That final is **ingested exactly like any other stage** — same melee.gg sync flow, same `Stage`/`StagePlacement`/`StageSyncLog` rows — but with `isFinal = true` set (either when the admin creates/links the `Stage` record, or via a request field on the sync endpoint, see §2).

`isFinal = true` changes only one thing structurally: `league-scoring-technical.md`'s standings aggregation explicitly excludes it. The final's own results (who won, full bracket/placement) are stored and displayed — a "league champion" callout on the frontend — but never add points to the regular-season totals, since qualification for the final is derived *from* those totals in the first place. Everything else about a final stage (lifecycle states, decklist ingestion/visibility, pairings) behaves identically to a regular stage.

### 1b. `excluded` — hidden, not deleted

`Stage.excluded` (added 2026-08-26, second corner-case review) is unrelated to `isFinal` and serves a different purpose: since melee.gg sync now auto-includes every tournament under a league's org as a `Stage` with no manual approval step (`melee-integration-technical.md` §2b), an admin needs a way to correct a tournament that was wrongly swept in — a test event, a duplicate, or anything else that shouldn't be part of the league's record. Setting `excluded = true` on that `Stage`:

- Removes it from `GET /leagues/:leagueSlug/stages` (§3) and the standings aggregation in `league-scoring-technical.md` §3.
- **Does not** delete `StagePlacement`/`StagePairing`/`Decklist` rows — they remain in the database, and un-excluding restores the stage's visibility immediately with no re-sync needed.

**Consistency rule applied throughout this doc**: an excluded stage's detail route (`GET /leagues/:leagueSlug/stages/:stageId`) returns `404 Not Found` to any non-admin caller, exactly as if the stage didn't exist — the same treatment a listing gives it (omission). An admin viewing via an admin-scoped route (with `AdminAuthGuard` + `LeagueAccessGuard` satisfied for this stage's league) still sees it, since correcting/un-excluding it requires being able to view it first. This is a deliberate single rule (404-and-omit for the public surface) rather than mixing "hidden from lists but still directly viewable" — that split would leak the stage's existence to anyone who guessed or retained its URL.

Set/unset via `melee-integration-technical.md` §2c's `PATCH /admin/leagues/:leagueId/stages/:stageId/excluded` endpoint; this doc doesn't re-define that route.

## 2. Lifecycle

```
OPEN ──(melee tournament detected/started)──> IN_PROGRESS ──(melee tournament completed + sync run)──> CLOSED
```

- **OPEN**: stage record exists (created manually by an admin, or auto-created as a placeholder for the season schedule) but no meaningful melee.gg data has been pulled yet, or the tournament hasn't started. `meleeTournamentId` may be null if the melee.gg event hasn't been created/linked yet.
- **IN_PROGRESS**: an admin has linked a melee.gg tournament (`meleeTournamentId` set) and the tournament is running. Live pairings *may* be pulled for informational display, but **no `StagePlacement` rows exist yet** — nothing counts toward scoring while in this state.
- **CLOSED**: an explicit sync operation (see `melee-integration-technical.md` §2 for the module shape and §6 for error handling) has fetched final standings from melee.gg's API, and the backend has persisted `StagePlacement` rows for every player, set `Stage.playerCount`, and set `closedAt`. Once closed, the stage's placements are treated as immutable league history for scoring purposes.

### Transition triggers

- `OPEN → IN_PROGRESS`: a tournament is first discovered under the league's melee.gg org (auto-include, `melee-integration-technical.md` §2b) and reports itself as underway — this now happens automatically via either the daily scheduled sync or a manual admin-triggered sync (§2a of that doc), not via a separate "manually link a tournament ID" step as an older version of this doc assumed.
- `IN_PROGRESS → CLOSED`: triggered by a sync run (scheduled or manual, both write through the same ingestion logic) once melee.gg reports the tournament complete. Per the memo, ingestion is explicit-per-sync-run, not per-request — "explicit" no longer means "admin-only," since the daily scheduled job is also an explicit, logged sync run, just not a human-triggered one.

### Re-closing / corrections

A closed stage's data can be wrong (melee.gg data entry error, corrected after the fact). Because closed data is meant to be immutable league history, a correction is modeled as **re-running the sync explicitly** via an admin-only endpoint, which:

1. Records a new `StageSyncLog` row.
2. Overwrites `StagePlacement` rows for that stage (delete-and-reinsert in a transaction, keyed by `stageId`).
3. Does **not** silently happen automatically — this must be an explicit, audited admin action, since it changes historical scoring.

```
POST /admin/leagues/:leagueId/sync
```

Protected by `AdminAuthGuard` + `LeagueAccessGuard` (see `security-technical.md` §Authentication / admin actions and §Guarding and authorizing admin routes) — requires a valid admin session/JWT and either `SUPER_ADMIN` or an `AdminLeagueAccess` row for `leagueId`. This is the same league-wide manual sync endpoint defined in `melee-integration-technical.md` §2a — it re-syncs every stage in the league that has changed on melee.gg since the last sync (including re-closing an already-closed stage whose melee.gg data was corrected), rather than targeting one `stageId` in isolation, since auto-include means there's no separate per-stage "link" step to re-trigger.

```ts
interface SyncLeagueRequest {
  // no body needed — the league's meleeOrgId (data-model-technical.md) determines what gets pulled
}

interface SyncLeagueResponse {
  leagueId: string;
  stagesCreated: number;
  stagesUpdated: number;
  syncLogIds: string[];
}
```

To exclude a single wrongly-synced stage without waiting for/affecting the rest of the league's sync, use `Stage.excluded` (§1b) via `PATCH /admin/leagues/:leagueId/stages/:stageId/excluded` (`melee-integration-technical.md` §2c) instead — that's a local flag, not a re-sync.

## 3. API shape

```
GET /leagues/:leagueSlug/stages
```

Lists non-excluded stages for the league's active season (or a specific `?seasonId=` if provided) — `excluded = true` stages are omitted entirely (§1b's consistency rule), not returned with a flag for the client to filter.

```ts
interface StageListItemDto {
  id: string;
  seasonId: string;
  name: string;
  sequence: number;
  isFinal: boolean;
  status: 'OPEN' | 'IN_PROGRESS' | 'CLOSED';
  closedAt: string | null;
}
```

```
GET /leagues/:leagueSlug/stages/:stageId
```

Returns `404 Not Found` if the stage doesn't exist, doesn't belong to this league, **or has `excluded = true`** (§1b) — all three cases are indistinguishable to a public caller, by design.

```ts
interface StageDto {
  id: string;
  seasonId: string;
  name: string;
  sequence: number;
  isFinal: boolean;
  status: 'OPEN' | 'IN_PROGRESS' | 'CLOSED';
  meleeUrl: string | null;
  playerCount: number | null;
  scheduledAt: string | null;
  closedAt: string | null;
}
```

```
GET /leagues/:leagueSlug/stages/:stageId/pairings?round=3
```

Same `excluded`/404 treatment as the detail route above.

```ts
interface PairingDto {
  round: number;
  tableNumber: number | null;
  player1: { id: string; displayName: string };
  player2: { id: string; displayName: string } | null; // null = bye
  result: string | null;
}
```

## 4. Failure modes

- **League sync attempted for a league with no melee.gg org/credentials resolvable**: `400 Bad Request` from `POST /admin/leagues/:leagueId/sync`; the scheduled job instead logs this per-league and moves on to the next league (`melee-integration-technical.md` §4.2's per-League isolation note) rather than surfacing a synchronous error to anyone.
- **melee.gg unreachable, unauthorized, or the standings fetch otherwise fails during sync**: that stage's sync aborts, `StageSyncLog.status = 'failed'`, stage status is left unchanged (does not transition to CLOSED on a failed sync) — other stages in the same league sync run are unaffected. See `melee-integration-technical.md` §6 (Error handling summary) for retry/backoff behavior.
- **Partial data** (e.g. standings fetched but a subset of placement rows are malformed/unparseable): sync records `StageSyncLog.status = 'partial'` with details in `message`, and — to avoid persisting an inconsistent "closed" state that Top-8/scoring logic would treat as authoritative — the stage is **not** transitioned to `CLOSED` until a sync fully succeeds. Admins can inspect `StageSyncLog.message` to see what failed.
- **Duplicate sync of an already-closed stage with identical data**: idempotent — re-running produces the same `StagePlacement` rows (delete-and-reinsert), no duplicate rows, thanks to the `@@unique([stageId, playerId])` constraint in `league-scoring-technical.md`.
- **`playerCount` mismatch** between the number of `StagePlacement` rows ingested and melee.gg's reported field size: treated as a data integrity warning, logged in `StageSyncLog.message`, but does not block closing the stage (melee.gg's own metadata can be inconsistent — see `melee-integration-technical.md`).
- **A public request for an `excluded` stage** (direct detail/pairings URL, or a stale link from before it was excluded): `404 Not Found`, identical to a nonexistent stage — see §1b's consistency rule. An admin with `LeagueAccessGuard`-satisfied access to the stage's league can still view/un-exclude it via the admin-scoped surface.
