# League Scoring — Technical

Implements the scoring model defined by the architecture decisions memo. This document is the source of truth for the scoring formula, aggregation, and Top-8/tie-break logic, and for the API shapes that expose them. Consumers (frontend `backend-api-contract-technical.md`) should reference this file rather than re-deriving the model.

Related: `tournament-stage-technical.md` (where per-stage placement data comes from), `player-technical.md` (identity behind each placement).

## 1. Formula

```
points(placement, N) = max(1, ceil(BASE_POINTS * (N - placement + 1) / N))
```

- `N` — number of players in the stage (field size), integer ≥ 1.
- `placement` — 1-indexed final placement in that stage, integer in `[1, N]`.
- `BASE_POINTS` — configurable constant, default `100`.
- Result is always an integer ≥ 1 (participation floor via `max(1, ...)`).

### Configuration

`BASE_POINTS` **must not** be hardcoded inline in scoring logic. Implement as an env-backed config value with a sane default:

```ts
// config/scoring.config.ts
import { registerAs } from '@nestjs/config';

export default registerAs('scoring', () => ({
  basePoints: parseInt(process.env.SCORING_BASE_POINTS ?? '100', 10),
}));
```

```ts
// scoring/scoring.util.ts
export function computeStagePoints(placement: number, fieldSize: number, basePoints: number): number {
  if (fieldSize < 1) throw new Error('fieldSize must be >= 1');
  if (placement < 1 || placement > fieldSize) throw new Error('placement out of range for fieldSize');
  const raw = (basePoints * (fieldSize - placement + 1)) / fieldSize;
  return Math.max(1, Math.ceil(raw));
}
```

Changing `BASE_POINTS` going forward only affects future stage ingestions — historical `StagePlacement.points` values already persisted (see `tournament-stage-technical.md`) are **not** retroactively recalculated unless an explicit admin "recompute" operation is run. This preserves historical integrity per the memo's Postgres decision: points are snapshotted at ingestion time, not derived live on every read.

### Worked example (N = 24, BASE_POINTS = 100)

| Placement | Calculation | Raw | Points |
|---|---|---|---|
| 1 | `100 * (24-1+1)/24 = 100*24/24` | 100.0 | 100 |
| 5 | `100 * (24-5+1)/24 = 100*20/24` | 83.33 | 84 |
| 12 | `100 * (24-12+1)/24 = 100*13/24` | 54.17 | 55 |
| 24 | `100 * (24-24+1)/24 = 100*1/24` | 4.17 | 5 |

Last place in a 24-player stage still nets 5 points (well above the floor of 1, which only kicks in for very large fields at the bottom, e.g. `N=200`, `placement=200` → `100*1/200 = 0.5` → `ceil = 1`).

## 2. When points are computed

Points are computed **once**, at stage-ingestion time (see `tournament-stage-technical.md` for the ingestion/lifecycle flow), and persisted per placement row. They are not recomputed on every standings request. This matches the memo's decision to snapshot per-stage data and avoid re-deriving everything live from melee.gg or from scratch on each request.

```prisma
model StagePlacement {
  id          String   @id @default(cuid())
  stageId     String
  stage       Stage    @relation(fields: [stageId], references: [id])
  playerId    String
  player      Player   @relation(fields: [playerId], references: [id])
  placement   Int      // 1-indexed
  fieldSize   Int      // N at time of ingestion, denormalized for auditability
  points      Int      // computed via computeStagePoints, snapshotted
  createdAt   DateTime @default(now())

  @@unique([stageId, playerId])
  @@index([stageId, placement])
}
```

Denormalizing `fieldSize` and `points` onto the placement row (rather than deriving them at read time from `Stage.playerCount`) means historical scores remain stable even if `BASE_POINTS` config changes later, and even if a stage's roster is later corrected (a correction creates a new ingestion event, not a silent mutation — see `tournament-stage-technical.md` §Lifecycle).

## 3. Overall standings aggregation

```
totalPoints(player) = SUM(StagePlacement.points WHERE playerId = player, across ALL stages attended)
stagesAttended(player) = COUNT(StagePlacement WHERE playerId = player)
```

No stage is dropped/discarded — every attended stage counts toward the total, including a player's worst result.

Because `StagePlacement.points` is already persisted, this aggregation is a cheap `GROUP BY` query and does not need a separate cached "standings" table for the traffic profile in the memo (~100 visits/day). Recommended as a straightforward Prisma aggregation, optionally wrapped in a short-TTL in-memory cache (e.g. 60s) at the service layer if it becomes a hot path — not a hard requirement at current scale.

```ts
// standings/standings.service.ts (sketch)
async function getOverallStandings(prisma: PrismaClient) {
  const rows = await prisma.stagePlacement.groupBy({
    by: ['playerId'],
    _sum: { points: true },
    _count: { _all: true },
  });
  // join to Player for display name, then sort per §4 below
}
```

## 4. Sorting and Top-8 cutoff

Sort order for overall standings, descending:

1. `totalPoints` (desc)
2. `stagesAttended` (desc) — tie-break
3. **unresolved beyond this point** (see §5)

The Top 8 rows after this sort qualify for the season-ending final.

```ts
interface StandingsRow {
  playerId: string;
  playerDisplayName: string;
  totalPoints: number;
  stagesAttended: number;
  qualifiesForFinal: boolean; // true for rank <= 8, subject to §5 caveat
  tieFlag: boolean; // true if this row is involved in an unresolved tie at the rank-8 boundary
}
```

`tieFlag` exists specifically to surface the open question from §5 in the API response, so the frontend can render "tie — organizer decision pending" instead of silently picking an arbitrary 8th qualifier.

## 5. Open question: unresolved ties

If, after sorting by `totalPoints` then `stagesAttended`, two or more players remain tied **at the rank-8 boundary** (i.e. the tie determines who does vs. doesn't make the cut), the system has no further automatic tie-break. This is intentional per the architecture memo — it is not a bug or a missing feature to build later.

Implementation requirement: the standings endpoint must **detect** this situation (multiple players sharing the same `(totalPoints, stagesAttended)` pair straddling the 8th/9th boundary) and expose it via `tieFlag`, rather than arbitrarily including one and excluding the other (e.g. by insertion order or player ID). The actual qualification decision in a tied scenario is made manually by the league organizer (Mattia) outside the system (e.g. a manual override flag on a future `FinalQualification` record, or simply a documented decision recorded outside the DB for now — no such override table exists yet; treat as a v2 concern if it's needed).

## 6. API shape

```
GET /leagues/:leagueId/standings
```

Response:

```ts
interface StandingsResponse {
  leagueId: string;
  basePoints: number;          // scoring config value used, for transparency
  generatedAt: string;         // ISO timestamp
  rows: StandingsRow[];        // sorted per §4, rank implicit in array order
}
```

```
GET /stages/:stageId/placements
```

Response:

```ts
interface StagePlacementDto {
  playerId: string;
  playerDisplayName: string;
  placement: number;
  fieldSize: number;
  points: number;
}
```

## 7. Failure modes

- **Stage not yet closed**: a stage in `open` or `in_progress` lifecycle state (see `tournament-stage-technical.md`) has no finalized placements yet. `GET /stages/:stageId/placements` returns `409 Conflict` with a message indicating the stage isn't finalized, rather than partial/live standings.
- **Empty league (no stages ingested)**: standings endpoint returns `rows: []`, not an error.
- **`fieldSize` of 0 or malformed placement data at ingestion**: reject the ingestion for that stage (see `tournament-stage-technical.md` §Failure modes) rather than persisting a `StagePlacement` that would divide by zero or produce a nonsensical points value.
