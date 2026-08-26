# Player — Technical

Defines the player entity, name normalization/reconciliation strategy, and duplicate handling. This is a defensive, semi-manual matching approach — not fuzzy-match-and-auto-merge — because a wrong auto-merge silently corrupts league history (mixes two people's results), which is worse than a temporary duplicate that a human can fix.

Related: `tournament-stage-technical.md` (source of per-stage player appearances), `melee-integration-technical.md` (where raw names originate), `decklists-technical.md`, `league-scoring-technical.md`.

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
  meleeUserId   String?  // melee.gg's own account id for this participant, if the scraped page exposes it
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
2. Look up `PlayerAlias` by `meleeUserId` first, if melee.gg's data exposes a stable per-account id for the participant (**this needs real-world verification against melee.gg's actual page structure** — see `melee-integration-technical.md` §Endpoints). A `meleeUserId` match is treated as authoritative and skips the steps below.
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

## 5. Interaction with scoring and standings

A `StagePlacement` (defined in `league-scoring-technical.md`) requires a non-null `playerId`. A placement stuck in `UnresolvedPlayerMatch` limbo therefore does **not** yet have a `StagePlacement` row and does not contribute to standings until resolved. The stage-sync flow (`tournament-stage-technical.md`) reflects this: a stage can be `CLOSED` with some `UnresolvedPlayerMatch` rows outstanding, but the affected player(s)' points for that stage won't appear in standings until an admin resolves the match. The sync response and `StageSyncLog.message` should surface the count of unresolved matches so this isn't silently missed.

## 6. Player profile API

```
GET /players/:playerId
```

```ts
interface PlayerProfileDto {
  id: string;
  displayName: string;
  totalPoints: number;
  stagesAttended: number;
  stageResults: {
    stageId: string;
    stageName: string;
    placement: number;
    fieldSize: number;
    points: number;
  }[];
  decklists: { stageId: string; decklistId: string; status: string }[];
  knownAliases: string[]; // distinct rawName values across all PlayerAlias rows, for transparency/debugging
}
```

## 7. Failure modes

- **Two players legitimately share the same normalized name** (two different real people, e.g. two "Marco Rossi"s): normalization alone cannot distinguish them. This is exactly why exact-normalized-name matches still go through the alias/candidate flow rather than blind auto-attach on first sight from a brand-new stage source with no prior alias — in practice, once `PlayerAlias.normalizedName` already resolves uniquely to one `Player`, a second distinct person with the same name will still be incorrectly matched unless caught manually. **Open question / limitation**: there is no reliable automatic disambiguation for two distinct real people who share an identical (post-normalization) name; this is called out as a known limitation for the organizer to catch during manual resolution (e.g. via `meleeUserId` divergence in §3 step 2, if melee.gg provides it) rather than solved automatically.
- **Admin merges two `Player` records after the fact** (discovering post-hoc that two Player rows are actually the same person): not covered by the automated flow above; treated as a manual data-migration operation (reassign `StagePlacement`/`Decklist`/`PlayerAlias` rows from one `Player.id` to another, then delete the now-empty duplicate) run directly against the DB or via a future dedicated admin endpoint — not yet built, flagged as a v2 concern.
- **`meleeUserId` present for some stages but not others** (e.g. melee.gg changes what it exposes over time): matching falls back to normalized-name/fuzzy matching per §3 for stages missing it; this is expected, not an error condition.
