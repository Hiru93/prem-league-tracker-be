# Melee.gg Integration — Technical

## Status (rewritten 2026-08-26)

This document previously assumed melee.gg had no documented public API and had to be treated as a fragile scrape target (HTML parsing, structural-change detection, defensive per-field fallbacks). **That premise was wrong and this doc has been rewritten around the corrected one.**

Re-verified against melee.gg's own policy (https://melee.gg/Policy/Api) and help docs (https://help.melee.gg/docs/api-use/): melee.gg has a real, documented **REST API (Swagger-based)**, gated behind **OAuth-style client-credentials auth** — a client ID and secret issued by melee.gg. Integration is against that documented API, not HTML scraping. The retry/backoff and rate-limit handling below still apply (any real API can be transiently unavailable or rate-limited), but the "the structure could silently change under us at any time" framing is gone — this is a contracted API surface, not a scrape target.

**Active external blocker, not this doc's concern to track**: obtaining real client credentials requires (1) the organizing party for the league's tournaments authorizing melee.gg to grant API access, then (2) emailing `contact@melee.gg` to request the client ID/secret. Mattia has not completed this yet, and the timeline is outside our control (tracked as its own issue). This doc describes the **target design** to build against regardless of whether credentials have arrived — see §5 (mock mode) for how development proceeds in the meantime.

Related: `tournament-stage-technical.md` (Stage/StagePlacement/StagePairing targets, including `isFinal`/`seasonId`), `player-technical.md` (Player/PlayerAlias/UnresolvedPlayerMatch targets), `decklists-technical.md` (Decklist/DecklistEntry targets, visibility), `league-scoring-technical.md` (what depends on placements being correct), `security-technical.md` (the admin login gating a manually-triggered sync).

## 1. Authentication

melee.gg issues a **client ID + client secret** per authorized organization/application (client-credentials style — conceptually the same shape as OAuth2 client-credentials grant: exchange the client ID/secret for a short-lived access token, then call the API with that token). Concretely:

```ts
// melee-auth.service.ts (sketch)
interface MeleeCredentials {
  clientId: string;
  clientSecret: string;
}

interface MeleeAccessToken {
  token: string;
  expiresAt: Date;
}
```

- `MELEE_CLIENT_ID` and `MELEE_CLIENT_SECRET` are read exclusively from environment variables via `@nestjs/config` — never hardcoded, never logged (per `security-technical.md`'s secrets-handling rules, which apply here without exception).
- `MeleeAuthService` exchanges the client ID/secret for an access token against melee.gg's token endpoint (the exact endpoint/flow shape is documented in melee.gg's Swagger spec, which is not yet in hand — see the blocker note above; this doc describes the conceptual client-credentials exchange, to be finalized against the real spec once available), caches the token in memory, and refreshes it before expiry.
- If `MELEE_CLIENT_ID`/`MELEE_CLIENT_SECRET` are unset (the expected state until the blocker above resolves), `MeleeAuthService` falls back to mock mode — see §5 — rather than failing to boot. This lets the rest of the backend (and its tests) run without real credentials.

## 2. Module shape (NestJS)

```
src/melee-integration/
  melee-auth.service.ts         // client-credentials exchange, token caching/refresh
  melee-client.service.ts       // typed HTTP client against melee.gg's documented REST API
  melee-mock-client.service.ts  // fixture-backed implementation of the same client interface, for mock mode
  melee-sync.service.ts         // orchestrates a stage sync, maps raw API responses -> domain entities
  melee-sync.controller.ts      // admin-triggered sync endpoint (see tournament-stage-technical.md §2), guarded per security-technical.md
  dto/
    raw-tournament.dto.ts
    raw-standings-row.dto.ts
    raw-decklist.dto.ts
    raw-roster-entry.dto.ts
  fixtures/
    tournament-info.sample.json
    standings.sample.json
    decklists.sample.json
    roster.sample.json
  melee-integration.module.ts
```

`MeleeSyncService` depends on an injected `MeleeClient` interface; `MeleeClientService` (real API) and `MeleeMockClientService` (fixtures) are two interchangeable implementations of it, selected at module-init time per §5. Nothing else in the codebase talks to melee.gg directly.

## 3. Documented endpoints consumed (conceptual)

The exact request/response shapes come from melee.gg's Swagger spec, which isn't available to this repo yet (blocked on credentials — see Status above). This table describes the endpoints **conceptually**, by the data each is expected to expose, based on melee.gg's public API documentation pages. Field names below are illustrative placeholders to be reconciled against the real spec once obtained.

| Conceptual endpoint | Used for | Maps to |
|---|---|---|
| Tournament info | name, date, format, status (upcoming/live/completed), field size | `Stage` metadata (`tournament-stage-technical.md`), including `isFinal` set by the admin at link time, not read from melee.gg |
| Standings | final placement per participant, tiebreaker info if any | `StagePlacement` (`league-scoring-technical.md`) |
| Roster | tournament participants, display name, a stable per-account id if exposed | `PlayerAlias` (`player-technical.md`) |
| Decklists | main deck + sideboard card list per participant, submission timestamp, possibly multiple snapshots | `Decklist` + `DecklistEntry` (`decklists-technical.md`) |

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

interface RawRosterEntryDto {
  meleeUserId: string | null;
  rawPlayerName: string;
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
```

Each call returns a typed raw DTO before any mapping to domain entities happens — this keeps "what melee.gg's API returned" separate from "what we stored," so a future spec version bump only touches the raw DTO/mapping layer, not the domain model.

`StagePairing` (round-by-round matchups, see `tournament-stage-technical.md`) is out of scope for this rewrite's confirmed endpoint list — melee.gg's documented API is expected to expose pairings/rounds as part of the standard tournament data set, but this needs confirming against the real Swagger spec once available; treat it as likely-supported, not yet verified.

## 4. Rate limits and error handling

Unlike the previous "undocumented site, assume the worst" framing, a real documented API is expected to publish actual rate limits and a stable error-response contract in its Swagger spec. Until that spec is in hand, the client still applies conservative, real-API-appropriate defaults rather than assuming no limits exist at all:

### 4.1 Rate limiting

```ts
// melee-client.service.ts (sketch)
const MIN_REQUEST_INTERVAL_MS = parseInt(process.env.MELEE_MIN_REQUEST_INTERVAL_MS ?? '500', 10);
```

Requests within one sync run are serialized through a queue enforcing at least `MIN_REQUEST_INTERVAL_MS` between calls, and any documented per-minute/per-hour limit from the real spec is honored once known (tracked via a config value, not hardcoded, so it can be tightened/loosened without a code change). A stage sync is an explicit admin-triggered background operation, not on a user-facing request path, so there's no latency pressure pushing toward higher concurrency.

### 4.2 Retry with backoff

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

- **Retryable**: network errors, `429 Too Many Requests`, `5xx` — the standard set of transient failures for any real API, ours included.
- **Not retryable (fail fast)**: `404 Not Found` (tournament id doesn't exist / wrong id), `401` (access token missing/expired/invalid — triggers a token refresh via `MeleeAuthService` and a single retry, not the general backoff loop), `403` (credentials valid but not authorized for this resource — needs human attention, retrying won't help).
- A `429` response, if it carries a `Retry-After` header, has that value respected as a floor on the backoff delay rather than the computed exponential value, when present — standard behavior for a rate-limited REST API.

### 4.3 Token expiry mid-sync

A long-running sync (many decklists to fetch) can outlive the access token's lifetime. `MeleeClientService` checks token freshness before each call and transparently refreshes via `MeleeAuthService` if it's within a safety margin (e.g. 60s) of expiry, rather than letting calls fail with `401` and relying on the general retry path for this specific case.

## 5. Mock mode (fixture-based)

Because real client credentials are an active external blocker with an unknown timeline (see Status above), `MeleeClientService` is not the only implementation of the client interface development runs against.

```ts
// melee-integration.module.ts (sketch)
const useMock = !process.env.MELEE_CLIENT_ID || !process.env.MELEE_CLIENT_SECRET || process.env.MELEE_MOCK_MODE === 'true';

@Module({
  providers: [
    {
      provide: MELEE_CLIENT,
      useClass: useMock ? MeleeMockClientService : MeleeClientService,
    },
    MeleeSyncService,
  ],
})
export class MeleeIntegrationModule {}
```

- `MeleeMockClientService` implements the same client interface (`getTournamentInfo`, `getStandings`, `getRoster`, `getDecklists`) but reads from static JSON fixtures under `fixtures/` instead of calling melee.gg, returning the same `Raw*Dto` shapes described in §3.
- Fixtures are hand-authored to approximate what the real API is expected to return (based on melee.gg's public documentation and, once obtained, the real Swagger spec) — they are a best-effort target shape, not a guarantee of the exact real response, and should be revisited once real credentials land and the actual response shape can be confirmed/diffed against them.
- Mock mode is automatic (falls back whenever credentials are absent) so local development, CI, and any environment without real credentials keep working end-to-end — `MeleeSyncService`, the domain mapping, player matching, and decklist ingestion are all exercised against fixture data exactly as they would be against the real API.
- Once real credentials are obtained, switching to the real client is just supplying `MELEE_CLIENT_ID`/`MELEE_CLIENT_SECRET` — no code change required, since `MeleeSyncService` only ever depends on the shared client interface, not on which implementation is active.

## 6. Error handling summary

| Failure | Behavior |
|---|---|
| melee.gg unreachable (network/timeout) | Retry per §4.2; after exhausting retries, sync fails, `StageSyncLog.status = 'failed'`, stage unchanged. |
| `429` / rate limited | Retry with backoff honoring `Retry-After` if present. |
| `401` (token expired/invalid) | Refresh token via `MeleeAuthService` and retry once; if still `401`, fail fast — credentials likely invalid/revoked, needs admin attention. |
| `403` (not authorized for this resource) | Fail fast, no retry — surfaced to admin immediately; likely means access scope doesn't cover this tournament/org. |
| `404` on tournament id | Fail fast, no retry — likely a wrong/stale `meleeTournamentId`; surfaced to admin immediately. |
| Standings fetch fails after retries | Sync fails (critical path — this is the one data source that affects scoring, see `league-scoring-technical.md`); stage unchanged. |
| Decklist/roster fetch fails for one participant | That entry is skipped (`Decklist.status = 'PARTIAL'` or missing roster row), sync continues, overall `StageSyncLog.status = 'partial'`. |
| Player name ambiguous/new | Not a melee-integration failure — handed off to the player-matching flow in `player-technical.md` §3, sync continues normally. |
| melee.gg returns fewer/more players than expected `playerCount` | Logged as a warning in `StageSyncLog.message`, does not block sync (see `tournament-stage-technical.md` §Failure modes). |

## 7. Mapping summary (raw → domain)

```
RawTournamentDto      -> Stage (metadata fields, isFinal/seasonId set by admin, status transition per tournament-stage-technical.md §2)
RawStandingsRowDto[]  -> Player/PlayerAlias resolution (player-technical.md §3) -> StagePlacement (league-scoring-technical.md §2)
RawRosterEntryDto[]   -> Player/PlayerAlias resolution (player-technical.md §3)
RawDecklistDto[]      -> Player/PlayerAlias resolution -> Decklist + DecklistEntry (decklists-technical.md §1-2), including Scryfall matching and visibility per decklists-technical.md §4
```

All player-name resolution across standings, roster, and decklists funnels through the single matching algorithm in `player-technical.md` §3, so the same person is recognized consistently regardless of which melee.gg endpoint their name came from within one sync run.

## 8. Open items requiring the real Swagger spec

These are not blockers to building against this doc's design (mock mode covers development), but need reconciling once melee.gg credentials/spec access arrives:

- Exact request/response shapes for each endpoint in §3 (field names above are illustrative placeholders).
- The precise client-credentials token exchange endpoint and flow.
- Documented, published rate limits (to replace the conservative defaults in §4.1 with the real ceiling).
- Whether pairings/rounds data is exposed via the same API surface, and in what shape.
- Whether a stable per-participant account id (`meleeUserId`) is present on every endpoint that returns a player name, or only some.
