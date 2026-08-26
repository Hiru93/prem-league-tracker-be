# Decklists — Technical

Defines storage for decklists and handling of melee.gg data quality issues. **Reconciled 2026-08-26 (issue #75)**: this doc previously redefined its own `DecklistEntry`/`ScryfallCard` Prisma models, diverging from the canonical schema in `data-model-technical.md` (different field names, a duplicate Postgres card-cache table the Redis migration in issue #23 had already replaced). §1 below now matches `data-model-technical.md` exactly rather than redefining it — per that doc's own rule, module docs describe how they use the canonical models, they don't redefine them. `matchConfidence` (this doc's one genuinely new concept, not present in the original canonical model) was folded into `data-model-technical.md`'s `DecklistEntry` as part of this reconciliation, since it's a real signal worth keeping (see §2). Routes in §4–6 were also updated to the `/leagues/:leagueSlug/...` pattern established elsewhere by the multi-league platform work (PR #80), which had missed this file.

Related: `tournament-stage-technical.md` (stage a decklist belongs to), `player-technical.md` (owning player), `melee-integration-technical.md` (how decklists are fetched and mapped in), `data-model-technical.md` (canonical `Decklist`/`DecklistEntry`/`MatchConfidence`, `Season.decklistVisibilityMode`), `scryfall-integration-technical.md` (the actual Redis-backed resolution flow §2 below builds on), `security-technical.md` (the admin guard on toggling visibility).

## 1. Data model

`Decklist` and `DecklistEntry` are defined canonically in `data-model-technical.md` — not reproduced here in full. This section covers only the fields/behavior specific to this module's concerns (snapshotting, status) that aren't already shown there.

```prisma
// canonical, from data-model-technical.md — shown here for reference only, do not edit this copy
model Decklist {
  id              String   @id @default(cuid())
  stageId         String
  stage           Stage    @relation(fields: [stageId], references: [id])
  playerId        String
  player          Player   @relation(fields: [playerId], references: [id])
  meleeDecklistUrl String?                       // original source link, kept for reference only
  archetypeName   String?
  entries         DecklistEntry[]

  @@unique([stageId, playerId])
}
```

This module additionally tracks a few fields on top of the canonical `Decklist` shape above, for handling melee.gg data-quality issues and (if melee.gg ever exposes it) multiple submissions per player:

```prisma
// additive fields this module owns on Decklist — not yet reflected in data-model-technical.md's
// sketch, since that doc keeps only the fields every other module needs to know about;
// these are decklists-technical.md-specific and are added directly to the real schema alongside it
model Decklist {
  // ...canonical fields above, plus:
  meleeDecklistId String? @unique // melee.gg's own id for this decklist snapshot, if exposed
  snapshotLabel   String?  // e.g. "round-3-update", null for a single/only submission — see §3
  isLatest        Boolean  @default(true) // see §3
  submittedAt     DateTime?
  status          DecklistStatus @default(COMPLETE)
  rawSource       Json?    // original fetched/parsed API payload, kept for debugging/reprocessing

  @@index([stageId, playerId, isLatest])
}

enum DecklistStatus {
  COMPLETE     // fully parsed, all entries matched or explicitly unmatched
  PARTIAL      // some entries could not be parsed from the source at all
  MISSING      // player had no decklist available on melee.gg
}
```

`DecklistEntry` itself (including `rawCardName`, `isSideboard`, `resolved`, `matchConfidence`, `scryfallCardId`) is used exactly as defined in `data-model-technical.md` — no additive fields needed here.

## 2. Scryfall matching

Matching happens at ingestion time (when a decklist is parsed from melee.gg), not at read time, via `ScryfallService` — the actual resolution algorithm (cache lookup, Scryfall API calls, retry/rate-limit behavior) is `scryfall-integration-technical.md`'s concern, not redefined here. What this module does with the result:

1. Normalize `rawCardName` (trim, collapse whitespace, strip melee.gg formatting artifacts such as trailing set-code suffixes if present) before calling `ScryfallService.resolve(...)`.
2. On a successful resolution, persist `scryfallCardId`, `resolved = true`, and the `matchConfidence` (`EXACT` or `FUZZY`) that `ScryfallService` determined — see `scryfall-integration-technical.md` §Card resolution for exactly how `EXACT` vs. `FUZZY` is decided. A `FUZZY` match (Scryfall's fuzzy search corrected something non-trivial — a typo, a partial name, an alternate spelling) is surfaced in the API (§5) with a subtle "best guess" indicator; `EXACT` is not.
3. On a failed resolution (Scryfall returns no match, or is unreachable — see `scryfall-integration-technical.md` §Fallback behavior), persist `scryfallCardId = null`, `resolved = false`, `matchConfidence = UNMATCHED` (the field's default). The entry is still stored and displayed using `rawCardName` as plain text — never dropped silently.

Card data itself (image, oracle text, mana cost) is never stored in this module's tables — it lives in Redis, resolved fresh via `scryfallCardId` at read time by `ScryfallService`, per `scryfall-integration-technical.md`. This module only ever persists the *result* of a match (`resolved`, `matchConfidence`, `scryfallCardId`), never the card data.

## 3. Multiple snapshots between rounds

If melee.gg exposes more than one decklist snapshot for a player in a stage (e.g. an updated sideboard submitted before a later round), each snapshot is stored as its own `Decklist` row linked to the same `(stageId, playerId)`, distinguished by `snapshotLabel` and ordered by `submittedAt`.

- Exactly one `Decklist` per `(stageId, playerId)` has `isLatest = true` at any time — enforced at the application layer during ingestion (when a new snapshot is ingested, the previous latest is flipped to `false` in the same transaction).
- `GET /leagues/:leagueSlug/stages/:stageId/decklists` and player-facing views return only `isLatest = true` decklists by default.
- Older snapshots remain queryable (`GET /leagues/:leagueSlug/decklists/:id` by id, or a `?includeHistory=true` query param) for completeness, but are not surfaced in the default UI. This is a deliberate simplification: the league treats "the decklist" as the player's final/most recent submission for that stage, not a full round-by-round diff.
- **Open question**: melee.gg's actual support for exposing multiple historical decklist snapshots per player is not confirmed (see `melee-integration-technical.md` §8 — this needs confirming against melee.gg's real Swagger spec once API access is obtained). The schema above supports it if available; if melee.gg only ever exposes the final decklist, every stage/player pair simply has a single `Decklist` row with `isLatest = true` and no history to show.

## 4. Visibility

Decklists exist to let people study the meta, but showing a decklist before its stage has finished can leak information mid-event (an opponent scouting a later-round pairing). Visibility is controlled by `Season.decklistVisibilityMode` (see `data-model-technical.md`):

```ts
function isDecklistVisible(stage: { status: StageStatus; isFinal: boolean }, season: { decklistVisibilityMode: DecklistVisibilityMode }): boolean {
  if (season.decklistVisibilityMode === 'ALWAYS_VISIBLE') return true;
  return stage.status === 'CLOSED'; // HIDDEN_UNTIL_STAGE_CLOSE (default): visible once the stage closes, applies equally to isFinal stages
}
```

- **Default (`HIDDEN_UNTIL_STAGE_CLOSE`)**: a decklist is hidden for as long as its stage is `OPEN` or `IN_PROGRESS`, and becomes visible automatically the moment the stage transitions to `CLOSED` (see `tournament-stage-technical.md` §2). No manual action needed for the common case.
- **Admin override (`ALWAYS_VISIBLE`)**: an admin can flip a season's `decklistVisibilityMode` (via the guarded endpoint in `security-technical.md`) to make that season's decklists visible immediately, regardless of stage status — e.g. for an archived past season where meta-leaking is no longer a concern.
- **What "hidden" means at the API level**: this is enforced at the point decklist content is served, not just in the UI. When a decklist is not visible, `GET /leagues/:leagueSlug/stages/:stageId/decklists/:playerId` for an **unauthenticated** request does not return `main`/`sideboard` entries at all — it returns the decklist's existence/status metadata only (so the UI can show "decklist hidden until this stage closes") with `main: []`, `sideboard: []`, and a `visible: false` flag. Full entries are only ever included once `isDecklistVisible` is true, or for a request carrying a valid admin session (admins can preview hidden decklists, e.g. to sanity-check ingestion before a stage closes).
- `GET /leagues/:leagueSlug/stages/:stageId/decklists` (the stage-level listing) applies the same rule per decklist row — it does not selectively expose a "hint" of hidden content (no partial card names, no counts) beyond the status metadata above.

## 5. API shape

```
GET /leagues/:leagueSlug/stages/:stageId/decklists/:playerId
```

```ts
interface DecklistDto {
  id: string;
  playerId: string;
  stageId: string;
  status: 'COMPLETE' | 'PARTIAL' | 'MISSING';
  visible: boolean;   // false when hidden per §4 — main/sideboard are empty in that case even if entries exist in storage
  submittedAt: string | null;
  main: DecklistEntryDto[];
  sideboard: DecklistEntryDto[];
}

interface DecklistEntryDto {
  quantity: number;
  rawCardName: string;   // matches DecklistEntry.rawCardName in data-model-technical.md — was rawName before the issue #75 reconciliation
  matchConfidence: 'EXACT' | 'FUZZY' | 'UNMATCHED';
  card: {
    scryfallCardId: string;
    name: string;
    imageUrl: string | null;
    manaCost: string | null;
    typeLine: string | null;
  } | null; // null when matchConfidence === 'UNMATCHED'
}
```

## 6. Failure modes

- **Decklist requested while hidden by an unauthenticated client**: not an error — returns `200` with `visible: false` and empty `main`/`sideboard` per §4, never a `403`/`404`, so the frontend can render a clear "hidden until stage closes" state rather than treating it as missing data.
- **No decklist available on melee.gg for a player** (didn't submit, or melee.gg's decklist feature wasn't used for that stage): `Decklist.status = 'MISSING'` — the row is still created (empty `entries`) so the UI can distinguish "we checked and there's nothing" from "we haven't synced this yet." `GET /leagues/:leagueSlug/stages/:stageId/decklists/:playerId` returns `200` with `status: 'MISSING'` and empty arrays, not `404`.
- **Malformed/partial source data** (e.g. melee.gg's page includes a main deck but the sideboard section fails to parse, or quantities are non-numeric): parse what can be parsed, mark `Decklist.status = 'PARTIAL'`, store the raw unparsed fragment in `rawSource` for later manual inspection/reprocessing. Never fail the whole stage sync because one player's decklist is malformed — this is isolated per player (see `tournament-stage-technical.md` §Failure modes on partial syncs).
- **Scryfall API unreachable during ingestion**: entries are stored with `scryfallCardId = null`, `matchConfidence = UNMATCHED` as a temporary state, and are eligible for a later re-matching pass (e.g. a background job re-running unmatched entries). This does not block decklist ingestion itself — decklist storage does not hard-depend on Scryfall being up.
- **Quantity edge cases**: quantity `0` or negative is treated as a parse error for that entry (dropped from `entries`, contributes to `PARTIAL` status) rather than stored as-is.
