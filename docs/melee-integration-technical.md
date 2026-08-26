# Melee.gg Integration — Technical

Defines the defensive integration strategy for pulling data from melee.gg, and how that data maps onto our domain model. melee.gg has no documented public API or published rate limits, so this module must treat it as a semi-fragile external dependency at every layer.

Related: `tournament-stage-technical.md` (Stage/StagePlacement/StagePairing targets), `player-technical.md` (Player/PlayerAlias/UnresolvedPlayerMatch targets), `decklists-technical.md` (Decklist/DecklistEntry targets), `league-scoring-technical.md` (what depends on placements being correct).

**Important caveat, stated explicitly rather than glossed over**: melee.gg's exact page structure, whether it exposes an internal JSON API vs. requiring HTML scraping, whether stable per-account IDs are available, and whether multiple decklist snapshots are exposed, are all things this document describes at a *conceptual/architectural* level. They must be verified against melee.gg's real, current site before or during implementation. Where the doc says "endpoint" below, read it as "the conceptual data source," not a confirmed URL.

## 1. Module shape (NestJS)

```
src/melee-integration/
  melee-client.service.ts       // low-level HTTP/scraping client with retry+cache
  melee-sync.service.ts         // orchestrates a stage sync, maps raw data -> domain entities
  melee-sync.controller.ts      // admin-triggered sync endpoints (see tournament-stage-technical.md §2)
  dto/
    raw-tournament.dto.ts
    raw-standings-row.dto.ts
    raw-decklist.dto.ts
    raw-pairing.dto.ts
  melee-integration.module.ts
```

`MeleeSyncService` is the only consumer of `MeleeClientService`; nothing else in the codebase talks to melee.gg directly. This keeps the "melee.gg is fragile" concern isolated to one module.

## 2. Conceptual endpoints/pages consumed

| Conceptual source | Used for | Maps to |
|---|---|---|
| Tournament info page/endpoint | name, date, format, status (upcoming/live/completed), field size | `Stage` metadata (`tournament-stage-technical.md`) |
| Standings page/endpoint | final placement per participant, tiebreaker info if any | `StagePlacement` (`league-scoring-technical.md`) |
| Round/pairings page/endpoint | per-round matchups and results | `StagePairing` (`tournament-stage-technical.md`) |
| Decklist page/endpoint per participant | main deck + sideboard card list, submission timestamp, possibly multiple snapshots | `Decklist` + `DecklistEntry` (`decklists-technical.md`) |
| Player/roster info (embedded in standings or a separate roster page) | participant display name, possibly a stable account id | `PlayerAlias` (`player-technical.md`) |

Each is fetched via `MeleeClientService`, which returns typed raw DTOs (`RawTournamentDto`, `RawStandingsRowDto`, etc.) before any mapping to domain entities happens — this keeps "what melee.gg gave us" separate from "what we stored," which matters when melee.gg's format shifts (only the raw DTO/parsing layer needs to change).

```ts
interface RawTournamentDto {
  meleeTournamentId: string;
  name: string;
  status: 'upcoming' | 'in_progress' | 'completed' | 'unknown';
  startDate: string | null;
  playerCount: number | null;
  sourceUrl: string;
}

interface RawStandingsRowDto {
  meleeUserId: string | null;
  rawPlayerName: string;
  placement: number;
}

interface RawDecklistDto {
  meleeUserId: string | null;
  rawPlayerName: string;
  meleeDecklistId: string | null;
  snapshotLabel: string | null;
  submittedAt: string | null;
  mainDeck: { rawName: string; quantity: number }[];
  sideboard: { rawName: string; quantity: number }[];
}

interface RawPairingDto {
  round: number;
  tableNumber: number | null;
  player1RawName: string;
  player2RawName: string | null; // null = bye
  result: string | null;
}
```

## 3. Defensive fetching strategy

### 3.1 Rate limiting / politeness

Since there's no published limit, the client self-imposes a conservative one:

```ts
// melee-client.service.ts (sketch)
const MIN_REQUEST_INTERVAL_MS = parseInt(process.env.MELEE_MIN_REQUEST_INTERVAL_MS ?? '1500', 10);
```

All outgoing requests within one sync run are serialized through a simple queue that enforces at least `MIN_REQUEST_INTERVAL_MS` between requests, rather than fetching pages concurrently. A single stage sync (tournament info + standings + N players' decklists + pairings) is not latency-sensitive — it runs as an explicit admin-triggered background operation, not on a user-facing request path, so trading speed for politeness is the right tradeoff.

### 3.2 Retry with backoff

```ts
interface RetryConfig {
  maxAttempts: number;      // default 4
  baseDelayMs: number;      // default 1000
  maxDelayMs: number;       // default 30000
}

async function fetchWithRetry(fn: () => Promise<Response>, cfg: RetryConfig): Promise<Response> {
  let attempt = 0;
  while (true) {
    attempt++;
    try {
      const res = await fn();
      if (res.status === 429 || res.status >= 500) throw new RetryableMeleeError(res.status);
      return res;
    } catch (err) {
      if (attempt >= cfg.maxAttempts || !(err instanceof RetryableMeleeError)) throw err;
      const delay = Math.min(cfg.maxDelayMs, cfg.baseDelayMs * 2 ** (attempt - 1));
      const jitter = delay * (0.5 + Math.random() * 0.5);
      await sleep(jitter);
    }
  }
}
```

- Retryable: network errors, `429 Too Many Requests`, `5xx`.
- Not retryable (fail fast): `404 Not Found` (tournament doesn't exist / URL wrong), `401`/`403` (blocked/auth issue — needs human attention, retrying won't help), and any successful response that fails to parse (structure change — see §4).
- A `429` response, if it carries a `Retry-After` header, should have that value respected as a floor on the backoff delay rather than the computed exponential value, when present.

### 3.3 Caching fetched pages

Raw fetched payloads (HTML or JSON, whatever the source turns out to be) are cached by URL for a short TTL to avoid re-fetching the same page multiple times within one sync run (e.g. a tournament info page might be referenced when resolving both standings and pairings):

```prisma
model MeleeFetchCache {
  id          String   @id @default(cuid())
  url         String   @unique
  rawBody     String   @db.Text
  fetchedAt   DateTime @default(now())
  statusCode  Int
}
```

- TTL: short, e.g. 1 hour (`MELEE_FETCH_CACHE_TTL_MS` env var) — this is a courtesy/debugging cache to avoid redundant fetches within and across nearby sync attempts, not a long-term store (that's what the domain tables in `tournament-stage-technical.md` etc. are for once parsed and confirmed correct).
- On a sync retry after a failure, previously successfully-fetched pages within the TTL window are reused from cache rather than re-fetched, so a failure partway through a multi-page sync doesn't force redundant traffic against melee.gg for the parts that already succeeded.
- Cache rows older than TTL are safe to prune (e.g. lazily, or via a periodic cleanup) since they're not authoritative data.

This is distinct from the `ScryfallCard` cache in `decklists-technical.md` (30-day TTL for stable card data) — melee.gg tournament pages change frequently while a tournament is live, so a much shorter TTL applies here.

## 4. Handling structural changes ("page changed shape")

Parsing raw melee.gg pages into `Raw*Dto` shapes is isolated into dedicated parser functions per data source (`parseTournamentInfo(html): RawTournamentDto`, etc.). When a parser can't find an expected field/selector:

- It throws a typed `MeleeParseError` including the parser name and (truncated) raw source, rather than returning a partially-populated or guessed DTO.
- `MeleeSyncService` catches `MeleeParseError` per data source independently — e.g. a broken pairings parser does not prevent standings and decklists from being ingested successfully, since these are somewhat independent conceptual sources per §2. This matches `tournament-stage-technical.md`'s partial-sync handling: the sync overall is marked `partial`, not `failed`, if the core standings ingestion succeeds but a secondary source (e.g. pairings) does not.
- Standings parsing failing (the one path that actually affects scoring — see `league-scoring-technical.md`) is treated as sync-critical: if standings can't be parsed, the whole sync is `failed` and the stage does not close, per `tournament-stage-technical.md` §Failure modes.
- `MeleeParseError` occurrences are logged with enough context (URL, parser name, timestamp) to prioritize fixing the parser, since a melee.gg redesign will surface as a cluster of these across syncs, not gradually.

## 5. Error handling summary

| Failure | Behavior |
|---|---|
| melee.gg unreachable (network/timeout) | Retry per §3.2; after exhausting retries, sync fails, `StageSyncLog.status = 'failed'`, stage unchanged. |
| `429` / throttled | Retry with backoff honoring `Retry-After` if present. |
| `404` on tournament URL | Fail fast, no retry — likely a wrong/stale `meleeTournamentId`; surfaced to admin immediately. |
| Standings page structure changed / unparseable | Sync fails (critical path), logged as `MeleeParseError`; stage unchanged. |
| Decklist/pairings page structure changed for one player/round | That entry is skipped (`Decklist.status = 'PARTIAL'` or missing pairing row), sync continues, overall `StageSyncLog.status = 'partial'`. |
| Player name ambiguous/new | Not a melee-integration failure — handed off to the player-matching flow in `player-technical.md` §3, sync continues normally. |
| melee.gg returns fewer/more players than expected `playerCount` | Logged as a warning in `StageSyncLog.message`, does not block sync (see `tournament-stage-technical.md` §Failure modes). |

## 6. Mapping summary (raw → domain)

```
RawTournamentDto        -> Stage (metadata fields, status transition per tournament-stage-technical.md §2)
RawStandingsRowDto[]    -> Player/PlayerAlias resolution (player-technical.md §3) -> StagePlacement (league-scoring-technical.md §2)
RawPairingDto[]         -> StagePairing (tournament-stage-technical.md §1), resolving player1/player2 the same way as standings
RawDecklistDto[]        -> Player/PlayerAlias resolution -> Decklist + DecklistEntry (decklists-technical.md §1-2), including Scryfall matching
```

All player-name resolution across standings, pairings, and decklists funnels through the single matching algorithm in `player-technical.md` §3, so the same person is recognized consistently regardless of which melee.gg data source their name came from within one sync run.

## 7. Open questions requiring real-world verification

- Whether melee.gg exposes a stable per-participant account id (`meleeUserId`) usable for reliable player matching, or only free-text display names.
- Whether melee.gg exposes multiple decklist snapshots per player per stage, or only the final submission.
- Whether melee.gg has an underlying JSON API (even if undocumented/internal) versus requiring HTML scraping — this affects the concrete implementation of `MeleeClientService` but not the architecture described above.
- Actual observed rate-limiting behavior (whether `429`s occur in practice, or bans manifest differently, e.g. silent HTML changes or CAPTCHA challenges) — the retry/backoff config values in §3 are reasonable defaults to start from, not values validated against real observed melee.gg behavior yet.
