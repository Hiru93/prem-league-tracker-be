# Player — Technical

Defines the player entity, name normalization/reconciliation strategy, and duplicate handling. This is a defensive, semi-manual matching approach — not fuzzy-match-and-auto-merge — because a wrong auto-merge silently corrupts league history (mixes two people's results), which is worse than a temporary duplicate that a human can fix.

Related: `tournament-stage-technical.md` (source of per-stage player appearances), `melee-integration-technical.md` (where raw names originate), `decklists-technical.md`, `league-scoring-technical.md`, `data-model-technical.md` (canonical `Player.mergedIntoId` tombstone field, referenced in §8's merge action), `security-technical.md` (the `AdminAuthGuard`/`LeagueAccessGuard` pair protecting §8's merge endpoint).

## 1. Data model

```prisma
model Player {
  id            String   @id @default(cuid())
  displayName   String   // canonical name shown in UI, admin-editable
  createdAt     DateTime @default(now())
  updatedAt     DateTime @updatedAt

  aliases       PlayerAlias[]
  placements    StagePlacement[]
  decklists     Decklist[]

  @@index([displayName])
}

model PlayerAlias {
  id            String   @id @default(cuid())
  playerId      String
  player        Player   @relation(fields: [playerId], references: [id])
  rawName       String   // exact name string as it appeared on melee.gg for a given stage
  normalizedName String  // see §2, stored for fast lookup/dedupe
  meleeUserId   String?  // melee.gg's own account id for this participant, if the API response exposes it
  sourceStageId String?  // which stage's ingestion first produced this alias
  createdAt     DateTime @default(now())

  @@unique([normalizedName, playerId])
  @@index([normalizedName])
  @@index([meleeUserId])
}

model UnresolvedPlayerMatch {
  id            String   @id @default(cuid())
  stageId       String
  rawName       String
  normalizedName String
  candidatePlayerIds Json  // string[] of Player.id candidates found via fuzzy match, empty if none
  status        String   @default("PENDING") // PENDING | RESOLVED_EXISTING | RESOLVED_NEW
  resolvedPlayerId String?
  resolvedBy    String?  // admin identifier, e.g. userEmail
  resolvedAt    DateTime?
  createdAt     DateTime @default(now())
}
```

## 2. Name normalization

```ts
function normalizeName(raw: string): string {
  return raw
    .normalize('NFD').replace(/[̀-ͯ]/g, '') // strip diacritics
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase();
}
```

This handles case, whitespace, and accent differences ("Gallinarò" vs "Gallinaro"). It deliberately does **not** attempt to reconcile abbreviated forms ("M. Gallinaro" vs "Mattia Gallinaro") or nicknames automatically — those are ambiguous enough that an automatic match risks merging two different people (e.g. two different "M. Rossi"s). See §3.

## 3. Matching algorithm at ingestion

When a stage sync produces a raw participant name (`rawName`) for a placement or pairing:

1. Compute `normalizedName`.
2. Look up `PlayerAlias` by `meleeUserId` first, if melee.gg's API exposes a stable per-account id for the participant (**this needs confirming against melee.gg's real Swagger spec once access is obtained** — see `melee-integration-technical.md` §8). A `meleeUserId` match is treated as authoritative and skips the steps below.
3. If no `meleeUserId` match, look up `PlayerAlias` by exact `normalizedName`.
   - **Exact match found** → attach this stage's result to that `Player`, and insert a new `PlayerAlias` row only if the exact `rawName` string hasn't been seen before for that player (keeps a history of observed spellings).
   - **No exact match** → run a fuzzy pass (e.g. Levenshtein distance or a trigram similarity threshold) against existing `Player.displayName` and `PlayerAlias.normalizedName` values. Any candidate above a configured similarity threshold is recorded as a candidate, **not** auto-attached.
4. If fuzzy candidates exist (or none at all, for a genuinely new participant), create an `UnresolvedPlayerMatch` row with `status = PENDING` and **do not** attach the result to any `Player` yet, and do not create a new `Player` automatically either.

This means a stage sync can complete with some placements not yet linked to a `Player`. This is acceptable and expected — see §5 for how that's surfaced.

## 4. Manual resolution

```
GET /admin/player-matches?status=PENDING
```

```ts
interface UnresolvedPlayerMatchDto {
  id: string;
  stageId: string;
  rawName: string;
  candidates: { playerId: string; displayName: string; similarity: number }[];
}
```

```
POST /admin/player-matches/:id/resolve
```

```ts
interface ResolvePlayerMatchRequest {
  resolution: 'EXISTING' | 'NEW';
  playerId?: string; // required if resolution === 'EXISTING'
  displayName?: string; // required if resolution === 'NEW'
}
```

Resolving:
- `EXISTING`: attaches the pending placement/pairing/decklist rows to the chosen `Player`, creates a new `PlayerAlias` for the `rawName`, sets `status = RESOLVED_EXISTING`.
- `NEW`: creates a new `Player` with the given `displayName`, attaches the pending rows to it, creates the initial `PlayerAlias`, sets `status = RESOLVED_NEW`.

This is an admin-only, manual step by design (the league organizer). Automated fuzzy-merge is intentionally avoided — see the rationale in the section header.

## 4a. Scoping to seasons

`Player`, `PlayerAlias`, and `UnresolvedPlayerMatch` are **not** season-scoped — a player's cross-stage identity (which real person a name/alias resolves to) doesn't change from one season to the next, so identity resolution runs the same way regardless of which season a stage belongs to.

What *is* season-scoped is which stages count toward which season's standings — that scoping lives on `Stage.seasonId` (see `tournament-stage-technical.md`), not on `Player`. A `Player`'s history transitively spans every season they've ever played, since each `StagePlacement` is reachable to exactly one `Stage`, which is reachable to exactly one `Season`. Season-scoped views (e.g. "this player's results in Season 2026") are a filter over `StagePlacement.stage.seasonId`, not a separate identity per season.

## 5. Interaction with scoring and standings

A `StagePlacement` (defined in `league-scoring-technical.md`) requires a non-null `playerId`. A placement stuck in `UnresolvedPlayerMatch` limbo therefore does **not** yet have a `StagePlacement` row and does not contribute to standings until resolved. The stage-sync flow (`tournament-stage-technical.md`) reflects this: a stage can be `CLOSED` with some `UnresolvedPlayerMatch` rows outstanding, but the affected player(s)' points for that stage won't appear in standings until an admin resolves the match. The sync response and `StageSyncLog.message` should surface the count of unresolved matches so this isn't silently missed.

## 6. Player profile API

```
GET /players/:playerId?seasonId=<optional>
```

```ts
interface PlayerProfileDto {
  id: string;
  displayName: string;
  totalPoints: number;       // scoped to seasonId if provided, otherwise all-time across every season
  stagesAttended: number;    // same scoping as totalPoints
  stageResults: {
    stageId: string;
    seasonId: string;
    stageName: string;
    isFinal: boolean;        // included for transparency; final-stage results are also excluded from totalPoints — see league-scoring-technical.md
    placement: number;
    fieldSize: number;
    points: number;
  }[];
  decklists: { stageId: string; decklistId: string; status: string }[];
  knownAliases: string[]; // distinct rawName values across all PlayerAlias rows, for transparency/debugging
}
```

`seasonId` is an optional query param: when provided, `totalPoints`/`stagesAttended`/`stageResults` are filtered to that season only (matching the standings scoping in `league-scoring-technical.md` §3); when omitted, the profile shows the player's all-time history across every season they've played.

## 8. Merging duplicate players (2026-08-26, second corner-case review)

Sometimes the same real person still ends up as two different `Player` rows — the fuzzy-match/manual-resolution flow in §3–4 is deliberately conservative (a wrong auto-merge is worse than a temporary duplicate, per this doc's header), so a genuine duplicate can persist until an admin notices it and merges the two by hand. This is a built, first-class admin action now (superseding the earlier "v2 concern, no endpoint yet" note) — data model support (`Player.mergedIntoId`) is defined in `data-model-technical.md`.

```
POST /admin/leagues/:leagueId/players/:duplicateId/merge-into/:canonicalId
```

Guarded by `AdminAuthGuard` + `LeagueAccessGuard` (see `security-technical.md`) — `SUPER_ADMIN`, `ORGANIZER`, and `MODERATOR` can all perform a merge within a league they have `AdminLeagueAccess` for, same as the other guarded per-league admin actions (triggering a sync, resolving a player match, toggling decklist visibility). `:leagueId` scopes the guard check; `:duplicateId`/`:canonicalId` themselves are not season- or league-scoped identifiers (per §4a, `Player` identity spans every season a person has played), but both `Player` rows must have at least one `Placement`/`Decklist` reachable to a `Stage` in this league for the action to make sense — the endpoint doesn't hard-block a cross-league merge attempt at the data layer, but the guard's `:leagueId` requirement means an admin without access to a player's actual league can't reach this endpoint for them in the first place.

```ts
interface MergePlayersRequest {
  // no body needed — duplicateId, canonicalId, and leagueId are all in the URL
}

interface MergePlayersResponse {
  canonicalPlayerId: string;
  duplicatePlayerId: string;
  placementsReassigned: number;
  decklistsReassigned: number;
  auditLogId: string;
}
```

What happens, in a single transaction:

1. Every `Placement` row belonging to `duplicateId` is reassigned to `canonicalId` (`playerId` updated in place) — not copied, not deleted, the same row now points at the canonical player. If a `Placement` already exists for `canonicalId` on the same `stageId` (both the duplicate and the canonical player somehow have a row for the same stage — normally shouldn't happen, but is possible if the duplicate arose mid-season), the reassignment is rejected for that row and surfaced as a conflict (§9) rather than silently dropping one — an admin needs to resolve which one is correct first.
2. Every `Decklist` row belonging to `duplicateId` is reassigned the same way, subject to the same per-stage conflict check as step 1 (`Decklist` also has a `@@unique([stageId, playerId])` constraint, per `decklists-technical.md`).
3. `duplicateId`'s `Player.mergedIntoId` is set to `canonicalId` — a **tombstone, not a delete** (per `data-model-technical.md`'s historical-integrity principle). The duplicate row survives so standings/decklist history built before the merge stays queryable and auditable; it just no longer owns any `Placement`/`Decklist` rows directly (those were reassigned in steps 1–2).
4. An `AuditLog` row is written (`action: "PLAYER_MERGE"`, `targetType: "Player"`, `targetId: duplicateId`, `metadata: { canonicalPlayerId, placementsReassigned, decklistsReassigned }`).

After a merge, `duplicateId`'s own `mergedFrom`/`mergedInto` relation (see `data-model-technical.md`) exists purely for admin-UI/audit purposes — application code reading `Placement`/`Decklist` doesn't need to "follow" `mergedIntoId` to find the canonical player's data, since the rows themselves were reassigned in steps 1–2, not left in place with a redirect. A direct `GET /players/:duplicateId` lookup after a merge should redirect or 301 to the canonical player's profile (frontend concern, `player-technical.md` §6's route) rather than showing an empty/stale profile.

`PlayerAlias` rows are **not** reassigned by a merge — they stay attached to whichever `Player.id` they were originally created under. This is intentional: `duplicateId`'s aliases remain a historical record of "these raw names used to resolve to this now-merged row," which matters for debugging future ingestions, even though `duplicateId` no longer holds any placements/decklists directly.

## 9. Failure modes

- **Two players legitimately share the same normalized name** (two different real people, e.g. two "Marco Rossi"s): normalization alone cannot distinguish them. This is exactly why exact-normalized-name matches still go through the alias/candidate flow rather than blind auto-attach on first sight from a brand-new stage source with no prior alias — in practice, once `PlayerAlias.normalizedName` already resolves uniquely to one `Player`, a second distinct person with the same name will still be incorrectly matched unless caught manually. **Open question / limitation**: there is no reliable automatic disambiguation for two distinct real people who share an identical (post-normalization) name; this is called out as a known limitation for the organizer to catch during manual resolution (e.g. via `meleeUserId` divergence in §3 step 2, if melee.gg provides it) rather than solved automatically — the player-merge action in §8 is the fix once such a case is noticed after the fact.
- **`meleeUserId` present for some stages but not others** (e.g. melee.gg changes what it exposes over time): matching falls back to normalized-name/fuzzy matching per §3 for stages missing it; this is expected, not an error condition.
- **Merge attempted where `duplicateId` and `canonicalId` share a `Placement`/`Decklist` on the same `stageId`** (§8 step 1/2): `409 Conflict`, listing the colliding `stageId`(s) — the admin must resolve which row is authoritative (e.g. delete/correct one manually) before the merge can proceed; the endpoint never silently picks a winner.
- **Merge attempted with `duplicateId === canonicalId`, or where `duplicateId` already has a non-null `mergedIntoId`** (already merged into something): `400 Bad Request` — a player can't be merged into itself, and a merge chain (A merged into B, B merged into C) is not supported; re-pointing an already-merged player requires a `SUPER_ADMIN`-level manual correction, not this endpoint.
