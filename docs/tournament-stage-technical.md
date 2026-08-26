# Tournament Stage — Technical

Defines the data model and lifecycle for a stage ("tappa"), consistent with the memo's Postgres decision: stages are ingested from melee.gg and snapshotted, not live-proxied.

Related: `league-scoring-technical.md` (how placements become points), `melee-integration-technical.md` (how data is fetched and mapped into these models), `player-technical.md` (identity behind each placement/pairing), `decklists-technical.md` (decklists attached to a stage's players).

## 1. Data model

```prisma
enum StageStatus {
  OPEN
  IN_PROGRESS
  CLOSED
}

model Stage {
  id            String       @id @default(cuid())
  leagueId      String
  league        League       @relation(fields: [leagueId], references: [id])
  name          String       // e.g. "Tappa 3 - Modern"
  sequence      Int          // ordering within the league/season
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

  @@index([leagueId, sequence])
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

## 2. Lifecycle

```
OPEN ──(melee tournament detected/started)──> IN_PROGRESS ──(melee tournament completed + sync run)──> CLOSED
```

- **OPEN**: stage record exists (created manually by an admin, or auto-created as a placeholder for the season schedule) but no meaningful melee.gg data has been pulled yet, or the tournament hasn't started. `meleeTournamentId` may be null if the melee.gg event hasn't been created/linked yet.
- **IN_PROGRESS**: an admin has linked a melee.gg tournament (`meleeTournamentId` set) and the tournament is running. Live pairings *may* be pulled for informational display, but **no `StagePlacement` rows exist yet** — nothing counts toward scoring while in this state.
- **CLOSED**: an explicit sync operation (see `melee-integration-technical.md` §Sync trigger) has fetched final standings from melee.gg, and the backend has persisted `StagePlacement` rows for every player, set `Stage.playerCount`, and set `closedAt`. Once closed, the stage's placements are treated as immutable league history for scoring purposes.

### Transition triggers

- `OPEN → IN_PROGRESS`: manual admin action (linking a melee.gg tournament ID), or automatically inferred the first time a sync successfully fetches a tournament page that reports itself as underway.
- `IN_PROGRESS → CLOSED`: triggered by an explicit sync operation — either an admin hitting a "close stage" / "sync final results" endpoint, or (optionally, future) a scheduled job that polls linked in-progress stages and closes them once melee.gg reports the tournament complete. Per the memo, ingestion is explicit-per-stage, not per-request.

### Re-closing / corrections

A closed stage's data can be wrong (melee.gg data entry error, corrected after the fact). Because closed data is meant to be immutable league history, a correction is modeled as **re-running the sync explicitly** via an admin-only endpoint, which:

1. Records a new `StageSyncLog` row.
2. Overwrites `StagePlacement` rows for that stage (delete-and-reinsert in a transaction, keyed by `stageId`).
3. Does **not** silently happen automatically — this must be an explicit, audited admin action, since it changes historical scoring.

```
POST /admin/stages/:stageId/sync
```

```ts
interface SyncStageRequest {
  meleeTournamentId?: string; // required if not already linked on the Stage
}

interface SyncStageResponse {
  stageId: string;
  status: 'CLOSED' | 'IN_PROGRESS';
  playersIngested: number;
  syncLogId: string;
}
```

## 3. API shape

```
GET /stages/:stageId
```

```ts
interface StageDto {
  id: string;
  leagueId: string;
  name: string;
  sequence: number;
  status: 'OPEN' | 'IN_PROGRESS' | 'CLOSED';
  meleeUrl: string | null;
  playerCount: number | null;
  scheduledAt: string | null;
  closedAt: string | null;
}
```

```
GET /stages/:stageId/pairings?round=3
```

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

- **Sync attempted on a stage with no `meleeTournamentId` and none provided in the request**: `400 Bad Request`.
- **melee.gg unreachable or page structure changed during sync**: sync aborts, `StageSyncLog.status = 'failed'`, stage status is left unchanged (does not transition to CLOSED on a failed sync). See `melee-integration-technical.md` §Error handling for retry/backoff behavior.
- **Partial data** (e.g. standings fetched but a subset of placement rows are malformed/unparseable): sync records `StageSyncLog.status = 'partial'` with details in `message`, and — to avoid persisting an inconsistent "closed" state that Top-8/scoring logic would treat as authoritative — the stage is **not** transitioned to `CLOSED` until a sync fully succeeds. Admins can inspect `StageSyncLog.message` to see what failed.
- **Duplicate sync of an already-closed stage with identical data**: idempotent — re-running produces the same `StagePlacement` rows (delete-and-reinsert), no duplicate rows, thanks to the `@@unique([stageId, playerId])` constraint in `league-scoring-technical.md`.
- **`playerCount` mismatch** between the number of `StagePlacement` rows ingested and melee.gg's reported field size: treated as a data integrity warning, logged in `StageSyncLog.message`, but does not block closing the stage (melee.gg's own metadata can be inconsistent — see `melee-integration-technical.md`).
