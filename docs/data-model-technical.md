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

With stage data persisted locally, standings computation becomes a query over our own rows — either computed on-the-fly per request (cheap once data is local: a `GROUP BY player` sum over a `StagePlacement` table with a few hundred rows, easily sub-millisecond) or cached in a small aggregate table refreshed after each ingestion. Given this project's scale, on-the-fly recomputation from persisted data is sufficient; a separate materialized/cached standings table is not required for MVP but is a natural future optimization if the number of stages grows very large (not expected).

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

`League`, `Season`, `AdminUser`, `AdminLeagueAccess`, `RefreshToken`, `AuditLog`, `Decklist`, and `DecklistEntry` are canonical here. **`Stage`, `StagePlacement`, `StagePairing`, `StageSyncLog`, `Player`, `PlayerAlias`, and `UnresolvedPlayerMatch` are canonical in their own module docs instead** (`tournament-stage-technical.md`, `league-scoring-technical.md`, `player-technical.md` — see the note after `AuditLog` below for why, revised 2026-08-26/issue #82). Every other module doc describes how it reads/writes whichever of these models it touches, but does not redefine them.

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

// Stage, StagePlacement (the actual model name — see note below), StagePairing,
// StageSyncLog, and Player/PlayerAlias/UnresolvedPlayerMatch are NOT redefined
// here — they're owned by tournament-stage-technical.md, league-scoring-technical.md,
// and player-technical.md respectively, per this doc's own rule that module docs
// describe how they read/write shared models but don't redefine them.
//
// Revised 2026-08-26 (issue #82): this used to include local sketches of
// Stage/Placement/Player that had drifted from those module docs' real,
// richer definitions (different field names — meleeEventId vs. meleeTournamentId,
// Placement vs. StagePlacement — and models like StagePairing/StageSyncLog/
// PlayerAlias/UnresolvedPlayerMatch that only ever existed in the module docs).
// The actual implemented `prisma/schema.prisma` follows the module docs; this
// file no longer keeps a second, competing sketch that can drift out of sync —
// see those docs' own `## 1. Data model` sections for the real field lists.

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
  matchConfidence MatchConfidence @default(UNMATCHED) // how rawCardName was resolved to scryfallCardId — see scryfall-integration-technical.md §Card resolution; added 2026-08-26 (issue #75) to canonicalize a concept decklists-technical.md had defined locally
  scryfallCardId  String?                         // Scryfall's own card UUID once resolved — a lookup key into Redis, not a Postgres FK (see scryfall-integration-technical.md); no relation() here since the card data itself is never stored in this database

  @@index([decklistId])
}

enum MatchConfidence {
  EXACT      // rawCardName matched a Scryfall card name exactly (case-insensitive), or an exact set+collector-number lookup was used
  FUZZY      // matched via Scryfall's fuzzy-name endpoint with a non-trivial name difference — display with a subtle "best guess" indicator
  UNMATCHED  // no Scryfall card found (or not yet attempted); entry stored/displayed as raw text only. Default — resolution moves it to EXACT/FUZZY on success, never the reverse.
}
```

Notes:
- `StagePlacement.points` is persisted (not recomputed on every standings request) so that if `BASE_POINTS` config changes in the future, historical placements are unaffected — only newly-ingested stages use the new value. This preserves historical integrity in the same spirit as reason #1 above. Full `StagePlacement` field list and the denormalized `fieldSize` reasoning: `league-scoring-technical.md` §2.
- `Stage.playerCount` is snapshotted at ingestion (not derived by counting `StagePlacement` rows live) so the scoring formula's `N` is fixed to what it was when the stage closed, even if placement rows were ever corrected later. Full `Stage` field list and lifecycle: `tournament-stage-technical.md`.
- `DecklistEntry.scryfallCardId` stores Scryfall's own card id once resolved, but is not a Postgres foreign key — the card data it identifies lives in Redis, not this database, and may be evicted/re-resolved independently (see `scryfall-integration-technical.md`).
- `DecklistEntry.matchConfidence` (added 2026-08-26, resolving issue #75): `resolved: Boolean` alone only captures matched-vs-not, not *how confidently* — `matchConfidence` carries that signal (exact name match vs. a fuzzy Scryfall match worth flagging to the user vs. genuinely unmatched). `resolved = (matchConfidence !== 'UNMATCHED')` always holds; the two fields aren't independent, but `resolved` is kept as its own boolean since most read paths (e.g. "does this entry have a card image") only care about that, not the finer distinction — `decklists-technical.md` §5 is the one place `matchConfidence` itself is surfaced to the API.
- **`Season`** (added 2026-08-26, per the corner-case review): supports running a fresh league each year rather than one league forever. Every `Stage` — including the season-ending final (`isFinal = true`) — belongs to exactly one `Season`. Standings aggregation (`league-scoring-technical.md`) is scoped per `Season`, not computed globally across all seasons ever played.
- **`Stage.isFinal`**: distinguishes the season-ending final tournament from regular stages. It's ingested through the same melee.gg sync pipeline as any other stage, but `league-scoring-technical.md`'s standings aggregation explicitly excludes `isFinal = true` stages — the final's own results are tracked and displayed (a "league champion" callout) but never feed back into league points, since qualification for the final is itself derived from the regular-season standings. See `tournament-stage-technical.md` §1a/§1b for `isFinal` and the related `excluded` admin safety-net flag.
- **`DecklistVisibilityMode`**: scoped **per `Season`**, not global — a season-level admin can choose to make decklists visible immediately for an archived/past season while a live season still defaults to hiding them until each stage closes. The default (`HIDDEN_UNTIL_STAGE_CLOSE`) avoids meta-leaking mid-event; see `decklists-technical.md` for enforcement details. This is the "configurable setting" from the admin panel — flipping it is one of the actions gated behind admin login (see `security-technical.md`).
- **`AdminUser`**: backs the admin login system (see `security-technical.md`). Replaces the earlier single-shared-secret bearer token — actions gated behind it include triggering a melee.gg sync, resolving an `UnresolvedPlayerMatch`, toggling `Season.decklistVisibilityMode`, and (2026-08-26 second corner-case review) managing seasons, correcting ingested data, merging players, and — `SUPER_ADMIN` only — creating admins and granting `AdminLeagueAccess`.
- **`League`** (added 2026-08-26, second corner-case review): the platform's top-level tenant concept — the project moved from "one league, one melee.gg org, forever" to supporting multiple concurrent leagues, each backed by its own org and its own encrypted credentials. Every `Season` belongs to exactly one `League`; `AdminLeagueAccess` scopes `ORGANIZER`/`MODERATOR` admins to specific leagues. `SUPER_ADMIN` bypasses `AdminLeagueAccess` entirely (implicit access to every league) rather than holding a row per league.
- **Player merge** (`Player.mergedIntoId`/`mergedInto`/`mergedFrom`, defined on the canonical `Player` model in `player-technical.md` §1, not duplicated here): an admin action (not a background job) for when the same real person ends up as two `Player` rows across stages (e.g. a melee.gg profile-id mismatch). Reassigns the duplicate's `StagePlacement`/`Decklist` rows to the canonical `Player`, then sets `mergedIntoId` on the duplicate rather than deleting it — the duplicate row survives as a tombstone so standings/decklist history stays queryable and auditable (an `AuditLog` entry is written for every merge). Application code reading `StagePlacement`/`Decklist` should already be reading from the canonical player post-merge since the rows themselves are reassigned; `mergedIntoId` exists for admin-UI/audit purposes, not as a redirect that read paths need to follow. Full merge-endpoint behavior: `player-technical.md` §8.
- **`RefreshToken`** / **`AuditLog`**: back the JWT refresh-token rotation flow and the admin audit log respectively — see `security-technical.md` for the full auth flow and what gets logged.

## Migrations

Managed via Prisma Migrate (`prisma migrate dev` locally, `prisma migrate deploy` in CI/CD — see `hosting-deployment-be-technical.md`). Migration files are committed to the repo under `prisma/migrations/` and are the only sanctioned way schema changes reach the Neon database — no manual schema edits against production.

## Cross-references

- `hosting-deployment-be-technical.md` — Neon as the Postgres host, and why (vs. Render's own Postgres); Upstash Redis as the Scryfall cache host.
- `scryfall-integration-technical.md` — the Redis cache key scheme, TTL, and fallback behavior for resolving `DecklistEntry.scryfallCardId`.
- `melee-integration-technical.md` — the ingestion flow that populates `League`, `Stage`, `Player`, `StagePlacement`, `Decklist`, `DecklistEntry`, including per-league auto-sync and the `Stage.excluded` safety net.
- `league-scoring-technical.md` — canonical `StagePlacement` model, the formula used to compute `StagePlacement.points` at ingestion time, and standings aggregation scoped per `Season` while excluding `isFinal` and `excluded` stages.
- `tournament-stage-technical.md` — canonical `Stage`/`StagePairing`/`StageSyncLog` models and lifecycle.
- `player-technical.md` — canonical `Player`/`PlayerAlias`/`UnresolvedPlayerMatch` models, name reconciliation, and the player-merge action.
- `decklists-technical.md` — module-level API/behavior built on top of the `Decklist`/`DecklistEntry` models above.
- `security-technical.md` — the full `AdminUser` auth flow (JWT + refresh token rotation, `SUPER_ADMIN` seeding, per-league `AdminLeagueAccess`, encryption of `League` melee.gg credentials, login lockout/rate-limiting, audit logging) and which actions its guards protect.
