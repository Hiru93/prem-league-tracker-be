# Decklists — Technical

Defines storage for decklists, Scryfall card linking/caching, and handling of melee.gg data quality issues, consistent with the memo's Postgres decision (Scryfall data cached in its own long-TTL table).

Related: `tournament-stage-technical.md` (stage a decklist belongs to), `player-technical.md` (owning player), `melee-integration-technical.md` (how decklists are fetched and mapped in).

## 1. Data model

```prisma
model Decklist {
  id            String   @id @default(cuid())
  stageId       String
  stage         Stage    @relation(fields: [stageId], references: [id])
  playerId      String
  player        Player   @relation(fields: [playerId], references: [id])
  meleeDecklistId String? @unique // melee.gg's own id for this decklist snapshot, if exposed
  snapshotLabel String?  // e.g. "round-3-update", null for a single/only submission
  isLatest      Boolean  @default(true) // see §3
  submittedAt   DateTime?
  status        DecklistStatus @default(COMPLETE)
  rawSource     Json?    // original scraped/parsed payload, kept for debugging/reprocessing
  createdAt     DateTime @default(now())

  entries       DecklistEntry[]

  @@index([stageId, playerId, isLatest])
}

enum DecklistStatus {
  COMPLETE     // fully parsed, all entries matched or explicitly unmatched
  PARTIAL      // some entries could not be parsed from the source at all
  MISSING      // player had no decklist available on melee.gg
}

model DecklistEntry {
  id          String    @id @default(cuid())
  decklistId  String
  decklist    Decklist  @relation(fields: [decklistId], references: [id])
  section     DeckSection // MAIN | SIDEBOARD
  quantity    Int
  rawName     String    // exact name string as sourced from melee.gg
  scryfallCardId String? // FK to ScryfallCard.id, null if unmatched
  scryfallCard  ScryfallCard? @relation(fields: [scryfallCardId], references: [id])
  matchConfidence MatchConfidence @default(EXACT)

  @@index([decklistId])
}

enum DeckSection {
  MAIN
  SIDEBOARD
}

enum MatchConfidence {
  EXACT      // rawName matched a Scryfall card name exactly (case-insensitive)
  FUZZY      // matched via normalization/fuzzy lookup, flagged for review
  UNMATCHED  // no Scryfall card found; entry stored as raw text only
}

model ScryfallCard {
  id          String   @id // Scryfall's own card id (UUID)
  name        String
  setCode     String?
  manaCost    String?
  typeLine    String?
  oracleText  String?  @db.Text
  imageUrl    String?
  fetchedAt   DateTime @default(now())
  // TTL enforced at the application layer: re-fetch if fetchedAt older than 30 days.

  entries     DecklistEntry[]

  @@index([name])
}
```

## 2. Scryfall matching

Matching happens at ingestion time (when a decklist is parsed from melee.gg), not at read time:

1. Normalize `rawName` (trim, collapse whitespace, strip melee.gg formatting artifacts such as trailing set-code suffixes if present).
2. Look up `ScryfallCard` by exact normalized name (case-insensitive) in our local cache table first.
3. On cache miss, call Scryfall's public card-by-name endpoint (fuzzy search), cache the result as a new `ScryfallCard` row with `fetchedAt = now()`.
4. If Scryfall's fuzzy search returns a match but the returned name differs non-trivially from `rawName` (e.g. double-faced card naming, alternate spellings), store the entry with `matchConfidence = FUZZY` so it can be reviewed/displayed with a subtle "best guess" indicator.
5. If Scryfall returns no match at all (typo too severe, foreign-language card name Scryfall doesn't recognize, obscure/misprinted name from melee.gg's OCR-like parsing if applicable), store `scryfallCardId = null`, `matchConfidence = UNMATCHED`. The entry is still stored and displayed using `rawName` as plain text — never dropped silently.

Cache refresh: a `ScryfallCard` row older than 30 days (`fetchedAt`) is eligible for a background refresh on next reference, per the memo's caching decision. This is a soft TTL — a stale cached row is still usable (card text/art rarely changes) and refresh failure does not block decklist display.

## 3. Multiple snapshots between rounds

If melee.gg exposes more than one decklist snapshot for a player in a stage (e.g. an updated sideboard submitted before a later round), each snapshot is stored as its own `Decklist` row linked to the same `(stageId, playerId)`, distinguished by `snapshotLabel` and ordered by `submittedAt`.

- Exactly one `Decklist` per `(stageId, playerId)` has `isLatest = true` at any time — enforced at the application layer during ingestion (when a new snapshot is ingested, the previous latest is flipped to `false` in the same transaction).
- `GET /stages/:stageId/decklists` and player-facing views return only `isLatest = true` decklists by default.
- Older snapshots remain queryable (`GET /decklists/:id` by id, or a `?includeHistory=true` query param) for completeness, but are not surfaced in the default UI. This is a deliberate simplification: the league treats "the decklist" as the player's final/most recent submission for that stage, not a full round-by-round diff.
- **Open question**: melee.gg's actual support for exposing multiple historical decklist snapshots per player is not confirmed (see `melee-integration-technical.md` §Endpoints — this needs real-world verification against melee.gg's actual tournament pages). The schema above supports it if available; if melee.gg only ever exposes the final decklist, every stage/player pair simply has a single `Decklist` row with `isLatest = true` and no history to show.

## 4. API shape

```
GET /stages/:stageId/decklists/:playerId
```

```ts
interface DecklistDto {
  id: string;
  playerId: string;
  stageId: string;
  status: 'COMPLETE' | 'PARTIAL' | 'MISSING';
  submittedAt: string | null;
  main: DecklistEntryDto[];
  sideboard: DecklistEntryDto[];
}

interface DecklistEntryDto {
  quantity: number;
  rawName: string;
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

## 5. Failure modes

- **No decklist available on melee.gg for a player** (didn't submit, or melee.gg's decklist feature wasn't used for that stage): `Decklist.status = 'MISSING'` — the row is still created (empty `entries`) so the UI can distinguish "we checked and there's nothing" from "we haven't synced this yet." `GET /stages/:stageId/decklists/:playerId` returns `200` with `status: 'MISSING'` and empty arrays, not `404`.
- **Malformed/partial source data** (e.g. melee.gg's page includes a main deck but the sideboard section fails to parse, or quantities are non-numeric): parse what can be parsed, mark `Decklist.status = 'PARTIAL'`, store the raw unparsed fragment in `rawSource` for later manual inspection/reprocessing. Never fail the whole stage sync because one player's decklist is malformed — this is isolated per player (see `tournament-stage-technical.md` §Failure modes on partial syncs).
- **Scryfall API unreachable during ingestion**: entries are stored with `scryfallCardId = null`, `matchConfidence = UNMATCHED` as a temporary state, and are eligible for a later re-matching pass (e.g. a background job re-running unmatched entries). This does not block decklist ingestion itself — decklist storage does not hard-depend on Scryfall being up.
- **Quantity edge cases**: quantity `0` or negative is treated as a parse error for that entry (dropped from `entries`, contributes to `PARTIAL` status) rather than stored as-is.
