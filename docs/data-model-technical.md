# Data Model — Technical

## Status

**Decision record.** This document resolves the backend's open question of whether a persistent database is needed at all, versus a live-fetch/in-memory proxy in front of melee.gg. **Decision: Postgres, used as the system of record for all league history.** This is not a proposal — it is the architecture the rest of the backend docs assume.

## Reasoning

### 1. Historical integrity

melee.gg tournament pages are editable by the organizer after the fact, and can be deleted entirely. A tournament's standings page today is not guaranteed to reflect what it showed the day the event closed. If Prem League Tracker treated melee.gg as a live source of truth queried on every request, our league's historical record would be exposed to silent retroactive changes or outright data loss outside our control. This is unacceptable for a league that exists specifically to track standings over a season and across multiple seasons.

The fix: once a stage (tappa) closes, we run an ingestion step that pulls the final standings and decklists from melee.gg and **snapshots** them into our own storage, permanently. From that point on, our own database — not melee.gg — is the source of truth for that stage. If the melee.gg page later changes or vanishes, our records are unaffected.

### 2. Rate limits / respectful use of melee.gg

melee.gg does have a documented API (see `melee-integration-technical.md`), but it's still a tournament-organizing platform's API, not a generously-limited public data service the way Scryfall's is, and access to it is a credentialed, gated relationship we don't want to jeopardize. Calling it repeatedly for every visitor page load would still be both unnecessary load on a service we don't control and a bad way to treat that access. Structuring the system so melee.gg is called **once per stage** (at ingestion time — either a manual admin-triggered sync after the tournament ends, or a scheduled job checking for newly-closed stages) rather than once per page view keeps our footprint on melee.gg minimal and predictable, regardless of how much traffic our own site gets.

### 3. Computed standings caching

Overall league standings are a sum of a player's points across every stage they've attended (see `league-scoring-technical.md` for the scoring formula itself). Computing this correctly requires access to every stage's placement data at once. If stage data lived only in melee.gg, computing standings on every request would mean: fetch N stages live from melee.gg, recompute, on every single page view, for every visitor. That's slow, expensive in outbound calls, and fragile (one melee.gg hiccup breaks standings for everyone).

With stage data persisted locally, standings computation becomes a query over our own rows — either computed on-the-fly per request (cheap once data is local: a `GROUP BY player` sum over a `Placement` table with a few hundred rows, easily sub-millisecond) or cached in a small aggregate table refreshed after each ingestion. Given this project's scale, on-the-fly recomputation from persisted data is sufficient; a separate materialized/cached standings table is not required for MVP but is a natural future optimization if the number of stages grows very large (not expected).

### 4. Traffic is tiny — keep infrastructure minimal

At ~100 visits/day, none of the usual reasons to reach for heavier infrastructure apply: no need for read replicas, connection pooling middleware (PgBouncer), or sharding. A single small managed Postgres instance handles this project's read and write volume with enormous headroom.

This reasoning directly informs the hosting choice in `hosting-deployment-be-technical.md`: a free-tier managed Postgres (Neon) is not just acceptable but is actually the right fit for the actual scale of this project, not merely a cost-cutting compromise.

**Revised 2026-08-26**: the Scryfall card cache is **not** a Postgres table (an earlier version of this doc had it as one, `CardCache`) — it now lives in Upstash Redis, per the Vercel+Neon+Upstash hosting revision. See `scryfall-integration-technical.md` for the Redis key scheme/TTL, and the `DecklistEntry` model below for how a decklist line references a resolved card without a Postgres FK into it.

### Ingestion model

Ingestion from melee.gg happens via an explicit sync operation — never on a read request path:
- Manually triggered by the league admin via an authenticated endpoint on `MeleeIntegrationModule` (see `melee-integration-technical.md`) once a stage's tournament has concluded, or
- Optionally, a scheduled job (e.g. `@nestjs/schedule` cron) that periodically checks for stages that have closed on melee.gg since the last sync and ingests them automatically.

Either path writes through the same `MeleeIntegrationService` ingestion logic and produces the same persisted rows described below.

## Schema sketch (Prisma)

This is the canonical schema; individual module docs (`tournament-stage-technical.md`, `player-technical.md`, `decklists-technical.md`, `melee-integration-technical.md`) describe how their module reads/writes these models but do not redefine them.

```prisma
// schema.prisma (sketch — field types illustrative, not exhaustive)

model League {
  id                        String   @id @default(cuid())
  name                      String                          // e.g. "Prem League" — public-facing league identity
  slug                      String   @unique                // URL-stable identifier, e.g. "prem-league"
  meleeOrgId                String   @unique                // melee.gg organization id this league syncs from
  meleeClientIdEncrypted    String                          // AES-256-GCM ciphertext; see security-technical.md for the encryption scheme and master-key handling
  meleeClientSecretEncrypted String                         // AES-256-GCM ciphertext
  createdAt                 DateTime @default(now())

  seasons       Season[]
  adminAccess   AdminLeagueAccess[]

  @@index([slug])
}

model Season {
  id            String       @id @default(cuid())
  leagueId      String                          // every season belongs to exactly one league — see League above
  league        League       @relation(fields: [leagueId], references: [id])
  name          String                          // e.g. "Season 2026"
  year          Int
  isActive      Boolean      @default(false)     // the season new stages attach to by default, scoped per league — exactly one Season per League should be true at a time, not one globally (multiple leagues can each have an active season concurrently)
  decklistVisibilityMode DecklistVisibilityMode @default(HIDDEN_UNTIL_STAGE_CLOSE) // see DecklistVisibilityMode below
  startsAt      DateTime?
  endsAt        DateTime?
  createdAt     DateTime     @default(now())

  stages        Stage[]

  @@index([year])
  @@index([leagueId])
}

enum DecklistVisibilityMode {
  HIDDEN_UNTIL_STAGE_CLOSE  // default: a stage's decklists are only served in full once that stage is closed
  ALWAYS_VISIBLE            // admin override for this season: serve decklists as soon as they're ingested, regardless of stage status
}

model AdminUser {
  id                  String       @id @default(cuid())
  email               String       @unique                  // plaintext — not sensitive enough to justify field-level encryption's lookup-hash complexity (see security-technical.md)
  passwordHash        String                                // argon2id hash — never plaintext, never logged, never "encrypted" (hashing is the correct one-way primitive here)
  displayName         String?
  role                AdminRole    @default(ORGANIZER)
  failedLoginAttempts Int          @default(0)               // reset on success; drives the lockout policy in security-technical.md
  lockedUntil         DateTime?                               // null unless currently locked out
  createdAt           DateTime     @default(now())
  lastLoginAt         DateTime?

  leagueAccess        AdminLeagueAccess[]                    // which leagues this admin can manage — irrelevant/ignored for SUPER_ADMIN, who has implicit access to every league
  refreshTokens       RefreshToken[]
  auditLogEntries     AuditLog[]
}

enum AdminRole {
  SUPER_ADMIN // exactly one account, seeded outside the app only — see security-technical.md. God-mode: every league, every admin, every piece of data. Never created/promoted via any API or UI action.
  ORGANIZER   // per-league, via AdminLeagueAccess — full management of the league(s) they're assigned to
  MODERATOR   // per-league, via AdminLeagueAccess — same guarded actions as ORGANIZER within their assigned league(s), no ability to assign other admins
}

model AdminLeagueAccess {
  id          String    @id @default(cuid())
  adminUserId String
  adminUser   AdminUser @relation(fields: [adminUserId], references: [id])
  leagueId    String
  league      League    @relation(fields: [leagueId], references: [id])
  grantedAt   DateTime  @default(now())
  grantedBy   String                                          // AdminUser.id of the SUPER_ADMIN who granted this — SUPER_ADMIN is the only role that can create rows here

  @@unique([adminUserId, leagueId])
  @@index([leagueId])
}

model RefreshToken {
  id            String    @id @default(cuid())
  adminUserId   String
  adminUser     AdminUser @relation(fields: [adminUserId], references: [id])
  tokenHash     String    @unique                             // sha256 of the raw refresh token — the raw value is never stored, only ever set in the httpOnly cookie
  familyId      String                                         // shared across a rotation chain; reuse of a revoked token in the same family revokes the whole family (theft detection)
  deviceLabel   String?                                        // parsed User-Agent, best-effort, for the "active sessions" admin UI
  ipAddress     String?
  revoked       Boolean   @default(false)
  createdAt     DateTime  @default(now())
  expiresAt     DateTime                                       // ~30 days from issuance

  @@index([adminUserId])
  @@index([familyId])
}

model AuditLog {
  id          String    @id @default(cuid())
  adminUserId String?                                          // null for system-triggered events (e.g. the scheduled melee.gg sync)
  adminUser   AdminUser? @relation(fields: [adminUserId], references: [id])
  action      String                                           // e.g. "LOGIN", "LEAGUE_CREATE", "STAGE_EXCLUDE", "PLACEMENT_CORRECT", "PLAYER_MERGE", "SUPER_ADMIN_OVERRIDE"
  targetType  String?                                          // e.g. "League", "Stage", "Player"
  targetId    String?
  metadata    Json?                                            // action-specific detail (e.g. before/after values for a correction)
  createdAt   DateTime  @default(now())

  @@index([adminUserId])
  @@index([targetType, targetId])
}

model Stage {
  id            String       @id @default(cuid())
  seasonId      String                          // which season this stage's results count toward
  season        Season       @relation(fields: [seasonId], references: [id])
  name          String                          // e.g. "Tappa 3 - Modern"
  meleeEventId  String       @unique             // melee.gg tournament id, for idempotent re-sync
  format        String                           // e.g. "Modern", "Pioneer"
  isFinal       Boolean      @default(false)     // true for the season-ending final tournament — ingested like any stage, but excluded from league-scoring aggregation (see league-scoring-technical.md)
  excluded      Boolean      @default(false)     // admin safety-net: hides this stage from standings/display without deleting ingested data — for a tournament that auto-synced but shouldn't have (e.g. a test event in the same melee.gg org). Distinct from isFinal: excluded stages count toward nothing, isFinal stages are shown but don't count toward league points.
  playerCount   Int                              // N in the scoring formula — snapshotted at close
  closedAt      DateTime                         // when the stage concluded on melee.gg
  ingestedAt    DateTime     @default(now())     // when we snapshotted it
  placements    Placement[]
  decklists     Decklist[]

  @@index([closedAt])
  @@index([seasonId])
}

model Player {
  id            String       @id @default(cuid())
  displayName   String
  meleeProfileId String?     @unique             // melee.gg profile id, if resolvable, for cross-stage matching
  mergedIntoId  String?                          // set when an admin merges this (duplicate) player into another — see the player-merge note below. A tombstone, not a delete: preserves the audit trail per this doc's historical-integrity principle.
  mergedInto    Player?      @relation("PlayerMerge", fields: [mergedIntoId], references: [id])
  mergedFrom    Player[]     @relation("PlayerMerge")
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
  id              String    @id @default(cuid())
  decklistId      String
  decklist        Decklist  @relation(fields: [decklistId], references: [id])
  rawCardName     String                          // exactly as imported, preserved even if unresolved
  quantity        Int
  isSideboard     Boolean   @default(false)
  resolved        Boolean   @default(false)
  scryfallCardId  String?                         // Scryfall's own card UUID once resolved — a lookup key into Redis, not a Postgres FK (see scryfall-integration-technical.md); no relation() here since the card data itself is never stored in this database

  @@index([decklistId])
}
```

Notes:
- `Placement.points` is persisted (not recomputed on every standings request) so that if `BASE_POINTS` config changes in the future, historical placements are unaffected — only newly-ingested stages use the new value. This preserves historical integrity in the same spirit as reason #1 above.
- `Stage.playerCount` is snapshotted at ingestion (not derived by counting `Placement` rows live) so the scoring formula's `N` is fixed to what it was when the stage closed, even if `Placement` rows were ever corrected later.
- `DecklistEntry.scryfallCardId` stores Scryfall's own card id once resolved, but is not a Postgres foreign key — the card data it identifies lives in Redis, not this database, and may be evicted/re-resolved independently (see `scryfall-integration-technical.md`).
- **`Season`** (added 2026-08-26, per the corner-case review): supports running a fresh league each year rather than one league forever. Every `Stage` — including the season-ending final (`isFinal = true`) — belongs to exactly one `Season`. Standings aggregation (`league-scoring-technical.md`) is scoped per `Season`, not computed globally across all seasons ever played.
- **`Stage.isFinal`**: distinguishes the season-ending final tournament from regular stages. It's ingested through the same melee.gg sync pipeline as any other stage, but `league-scoring-technical.md`'s standings aggregation explicitly excludes `isFinal = true` stages — the final's own results are tracked and displayed (a "league champion" callout) but never feed back into league points, since qualification for the final is itself derived from the regular-season standings.
- **`DecklistVisibilityMode`**: scoped **per `Season`**, not global — a season-level admin can choose to make decklists visible immediately for an archived/past season while a live season still defaults to hiding them until each stage closes. The default (`HIDDEN_UNTIL_STAGE_CLOSE`) avoids meta-leaking mid-event; see `decklists-technical.md` for enforcement details. This is the "configurable setting" from the admin panel — flipping it is one of the actions gated behind admin login (see `security-technical.md`).
- **`AdminUser`**: backs the admin login system (see `security-technical.md`). Replaces the earlier single-shared-secret bearer token — actions gated behind it include triggering a melee.gg sync, resolving an `UnresolvedPlayerMatch`, toggling `Season.decklistVisibilityMode`, and (2026-08-26 second corner-case review) managing seasons, correcting ingested data, merging players, and — `SUPER_ADMIN` only — creating admins and granting `AdminLeagueAccess`.
- **`League`** (added 2026-08-26, second corner-case review): the platform's top-level tenant concept — the project moved from "one league, one melee.gg org, forever" to supporting multiple concurrent leagues, each backed by its own org and its own encrypted credentials. Every `Season` belongs to exactly one `League`; `AdminLeagueAccess` scopes `ORGANIZER`/`MODERATOR` admins to specific leagues. `SUPER_ADMIN` bypasses `AdminLeagueAccess` entirely (implicit access to every league) rather than holding a row per league.
- **Player merge**: an admin action (not a background job) for when the same real person ends up as two `Player` rows across stages (e.g. a melee.gg profile-id mismatch). Reassigns the duplicate's `Placement`/`Decklist` rows to the canonical `Player`, then sets `mergedIntoId` on the duplicate rather than deleting it — the duplicate row survives as a tombstone so standings/decklist history stays queryable and auditable (an `AuditLog` entry is written for every merge). Application code reading `Placement`/`Decklist` should already be reading from the canonical player post-merge since the rows themselves are reassigned; `mergedIntoId` exists for admin-UI/audit purposes, not as a redirect that read paths need to follow.
- **`RefreshToken`** / **`AuditLog`**: back the JWT refresh-token rotation flow and the admin audit log respectively — see `security-technical.md` for the full auth flow and what gets logged.

## Migrations

Managed via Prisma Migrate (`prisma migrate dev` locally, `prisma migrate deploy` in CI/CD — see `hosting-deployment-be-technical.md`). Migration files are committed to the repo under `prisma/migrations/` and are the only sanctioned way schema changes reach the Neon database — no manual schema edits against production.

## Cross-references

- `hosting-deployment-be-technical.md` — Neon as the Postgres host, and why (vs. Render's own Postgres); Upstash Redis as the Scryfall cache host.
- `scryfall-integration-technical.md` — the Redis cache key scheme, TTL, and fallback behavior for resolving `DecklistEntry.scryfallCardId`.
- `melee-integration-technical.md` — the ingestion flow that populates `League`, `Stage`, `Player`, `Placement`, `Decklist`, `DecklistEntry`, including per-league auto-sync and the `Stage.excluded` safety net.
- `league-scoring-technical.md` — the formula used to compute `Placement.points` at ingestion time, and standings aggregation scoped per `Season` while excluding `isFinal` and `excluded` stages.
- `tournament-stage-technical.md`, `decklists-technical.md`, `player-technical.md` — module-level API/behavior built on top of `Stage`/`Decklist`/`Player` respectively.
- `security-technical.md` — the full `AdminUser` auth flow (JWT + refresh token rotation, `SUPER_ADMIN` seeding, per-league `AdminLeagueAccess`, encryption of `League` melee.gg credentials, login lockout/rate-limiting, audit logging) and which actions its guards protect.
