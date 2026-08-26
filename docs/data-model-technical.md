# Data Model — Technical

## Status

**Decision record.** This document resolves the backend's open question of whether a persistent database is needed at all, versus a live-fetch/in-memory proxy in front of melee.gg. **Decision: Postgres, used as the system of record for all league history.** This is not a proposal — it is the architecture the rest of the backend docs assume.

## Reasoning

### 1. Historical integrity

melee.gg tournament pages are editable by the organizer after the fact, and can be deleted entirely. A tournament's standings page today is not guaranteed to reflect what it showed the day the event closed. If Prem League Tracker treated melee.gg as a live source of truth queried on every request, our league's historical record would be exposed to silent retroactive changes or outright data loss outside our control. This is unacceptable for a league that exists specifically to track standings over a season and across multiple seasons.

The fix: once a stage (tappa) closes, we run an ingestion step that pulls the final standings and decklists from melee.gg and **snapshots** them into our own storage, permanently. From that point on, our own database — not melee.gg — is the source of truth for that stage. If the melee.gg page later changes or vanishes, our records are unaffected.

### 2. Rate limits / respectful use of melee.gg

melee.gg does not publish a documented, generously-limited public API contract the way Scryfall does. It's a tournament-organizing platform; scraping/calling it repeatedly for every visitor page load is both fragile (subject to undocumented throttling or IP blocks) and inconsiderate of a service we don't control and don't want to jeopardize our access to. Structuring the system so melee.gg is called **once per stage** (at ingestion time — either a manual admin-triggered sync after the tournament ends, or a scheduled job checking for newly-closed stages) rather than once per page view keeps our footprint on melee.gg minimal and predictable, regardless of how much traffic our own site gets.

### 3. Computed standings caching

Overall league standings are a sum of a player's points across every stage they've attended (see `league-scoring-technical.md` for the scoring formula itself). Computing this correctly requires access to every stage's placement data at once. If stage data lived only in melee.gg, computing standings on every request would mean: fetch N stages live from melee.gg, recompute, on every single page view, for every visitor. That's slow, expensive in outbound calls, and fragile (one melee.gg hiccup breaks standings for everyone).

With stage data persisted locally, standings computation becomes a query over our own rows — either computed on-the-fly per request (cheap once data is local: a `GROUP BY player` sum over a `Placement` table with a few hundred rows, easily sub-millisecond) or cached in a small aggregate table refreshed after each ingestion. Given this project's scale, on-the-fly recomputation from persisted data is sufficient; a separate materialized/cached standings table is not required for MVP but is a natural future optimization if the number of stages grows very large (not expected).

### 4. Traffic is tiny — keep infrastructure minimal

At ~100 visits/day, none of the usual reasons to reach for heavier infrastructure apply: no need for read replicas, connection pooling middleware (PgBouncer), sharding, or a separate cache store (Redis) in front of Postgres. A single small managed Postgres instance handles this project's read and write volume with enormous headroom. This is also why the Scryfall card cache (see `scryfall-integration-technical.md`) is just another table in the same Postgres instance rather than a separate caching layer — introducing new infrastructure to cache data at this scale would be pure overhead.

This reasoning directly informs the hosting choice in `hosting-deployment-be-technical.md`: a free-tier managed Postgres (Neon) is not just acceptable but is actually the right fit for the actual scale of this project, not merely a cost-cutting compromise.

### Ingestion model

Ingestion from melee.gg happens via an explicit sync operation — never on a read request path:
- Manually triggered by the league admin via an authenticated endpoint on `MeleeIntegrationModule` (see `melee-integration-technical.md`) once a stage's tournament has concluded, or
- Optionally, a scheduled job (e.g. `@nestjs/schedule` cron) that periodically checks for stages that have closed on melee.gg since the last sync and ingests them automatically.

Either path writes through the same `MeleeIntegrationService` ingestion logic and produces the same persisted rows described below.

## Schema sketch (Prisma)

This is the canonical schema; individual module docs (`tournament-stage-technical.md`, `player-technical.md`, `decklists-technical.md`, `melee-integration-technical.md`) describe how their module reads/writes these models but do not redefine them.

```prisma
// schema.prisma (sketch — field types illustrative, not exhaustive)

model Stage {
  id            String       @id @default(cuid())
  name          String                          // e.g. "Tappa 3 - Modern"
  meleeEventId  String       @unique             // melee.gg tournament id, for idempotent re-sync
  format        String                           // e.g. "Modern", "Pioneer"
  playerCount   Int                              // N in the scoring formula — snapshotted at close
  closedAt      DateTime                         // when the stage concluded on melee.gg
  ingestedAt    DateTime     @default(now())     // when we snapshotted it
  placements    Placement[]
  decklists     Decklist[]

  @@index([closedAt])
}

model Player {
  id            String       @id @default(cuid())
  displayName   String
  meleeProfileId String?     @unique             // melee.gg profile id, if resolvable, for cross-stage matching
  createdAt     DateTime     @default(now())
  placements    Placement[]
  decklists     Decklist[]
}

model Placement {
  id            String       @id @default(cuid())
  stageId       String
  stage         Stage        @relation(fields: [stageId], references: [id])
  playerId      String
  player        Player       @relation(fields: [playerId], references: [id])
  finalRank     Int                              // 1-indexed placement within the stage
  points        Int                              // computed via ScoringModule at ingestion time, persisted
  createdAt     DateTime     @default(now())

  @@unique([stageId, playerId])
  @@index([playerId])
}

model Decklist {
  id            String       @id @default(cuid())
  stageId       String
  stage         Stage        @relation(fields: [stageId], references: [id])
  playerId      String
  player        Player       @relation(fields: [playerId], references: [id])
  meleeDecklistUrl String?                       // original source link, kept for reference only
  archetypeName String?
  entries       DecklistEntry[]

  @@unique([stageId, playerId])
}

model DecklistEntry {
  id             String     @id @default(cuid())
  decklistId     String
  decklist       Decklist   @relation(fields: [decklistId], references: [id])
  rawCardName    String                          // exactly as imported, preserved even if unresolved
  quantity       Int
  isSideboard    Boolean    @default(false)
  resolved       Boolean    @default(false)
  cardCacheId    String?                         // FK to CardCache once resolved
  cardCache      CardCache? @relation(fields: [cardCacheId], references: [id])

  @@index([decklistId])
}

model CardCache {
  id               String   @id                  // Scryfall card id (their UUID) — natural key
  normalizedName   String                         // lowercased/trimmed, for lookup
  set              String?
  collectorNumber  String?
  name             String
  manaCost         String?
  typeLine         String?
  oracleTextFront  String?
  oracleTextBack   String?
  imageUrlFront    String?
  imageUrlBack     String?
  isDoubleFaced    Boolean  @default(false)
  colors           String[]                       // e.g. ["U", "R"]
  fetchedAt        DateTime @default(now())
  entries          DecklistEntry[]

  @@index([normalizedName])
}
```

Notes:
- `Placement.points` is persisted (not recomputed on every standings request) so that if `BASE_POINTS` config changes in the future, historical placements are unaffected — only newly-ingested stages use the new value. This preserves historical integrity in the same spirit as reason #1 above.
- `Stage.playerCount` is snapshotted at ingestion (not derived by counting `Placement` rows live) so the scoring formula's `N` is fixed to what it was when the stage closed, even if `Placement` rows were ever corrected later.
- `CardCache` uses Scryfall's own card id as primary key, avoiding a separate surrogate id and making upserts from `scryfall-integration-technical.md`'s resolution flow straightforward (`upsert` by `id`).

## Migrations

Managed via Prisma Migrate (`prisma migrate dev` locally, `prisma migrate deploy` in CI/CD — see `hosting-deployment-be-technical.md`). Migration files are committed to the repo under `prisma/migrations/` and are the only sanctioned way schema changes reach the Neon database — no manual schema edits against production.

## Cross-references

- `hosting-deployment-be-technical.md` — Neon as the Postgres host, and why (vs. Render's own Postgres).
- `scryfall-integration-technical.md` — `CardCache` population, TTL, and fallback behavior.
- `melee-integration-technical.md` — the ingestion flow that populates `Stage`, `Player`, `Placement`, `Decklist`, `DecklistEntry`.
- `league-scoring-technical.md` — the formula used to compute `Placement.points` at ingestion time.
- `tournament-stage-technical.md`, `decklists-technical.md`, `player-technical.md` — module-level API/behavior built on top of `Stage`/`Decklist`/`Player` respectively.
