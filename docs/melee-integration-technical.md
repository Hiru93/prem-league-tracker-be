# Melee.gg Integration — Technical

## Status (updated 2026-08-26)

This document previously assumed melee.gg had no documented public API and had to be treated as a fragile scrape target (HTML parsing, structural-change detection, defensive per-field fallbacks). **That premise was wrong and this doc has been rewritten around the corrected one** — and has now been updated a second time with the *real* API contract, and a third time (second corner-case review) for the **per-League, auto-include, dual-trigger** sync model described below.

**Per-League sync (2026-08-26, second corner-case review)**: the platform now supports multiple concurrent leagues (see `data-model-technical.md`'s `League` model), each backed by its **own** melee.gg organization and its own melee.gg API credentials. Everything in this document that previously assumed a single global `MELEE_CLIENT_ID`/`MELEE_CLIENT_SECRET` pair now applies **per `League` row** instead — see §1a. Sync is also no longer solely admin-triggered: a daily scheduled job checks every league for newly-closed tournaments in addition to the existing manual admin-triggered sync (§2a), and every tournament found under a league's org is auto-included as a `Stage` with no manual "pick which tournaments count" step (§2b). An admin can mark a wrongly-auto-included stage `excluded` after the fact (§2c) — a safety net, not a pre-sync gate.

melee.gg publishes a real, public Swagger spec at `https://melee.gg/swagger/docs/v0.3.64.163` (linked from the browsable UI at `https://melee.gg/swagger/ui/index`), viewable **without any credentials** — no login wall on the documentation itself. It defines 25 endpoints across `TournamentApi`, `TournamentStandingApi`, `TournamentDecklistApi`, `TournamentPlayerApi`, `TournamentMatchApi`, `TournamentTeamApi` (plus two tags unrelated to this project, `AdminReportsApi` and `CyberpunkOrganizationApi`). §3 below lists the real endpoints, replacing the earlier conceptual/guessed list.

**Auth model correction**: the spec's `securityDefinitions` declare **HTTP Basic authentication** (`{"basic": {"type": "basic"}}`), described as "per-user — requests using these credentials will have access to tournaments that user has access to on the Melee site." This is **not** an OAuth2 client-credentials token exchange as the previous version of this doc assumed — there is no token endpoint, no token expiry/refresh to manage. The client ID/secret melee.gg issues (per its access-request process) is presumed to be used as the Basic-auth username/password pair; this needs final confirmation once real credentials are in hand, since it's an inference from the spec's description, not something we've been able to test end-to-end.

**Confirmed live**: an unauthenticated `GET /api/tournament/list` was actually tried against production and returned `HTTP 400` with body `{"StatusCode":400,...,"Content":{"Error":true,"Message":"Could not authenticate user."}}`. Note this is `400`, not the `401`/`403` documented on individual endpoints in the spec — the real, observed failure mode differs slightly from the spec's per-endpoint documentation. Code written against this API should treat `400` with this error message as an auth failure, not assume `401`/`403` are the only auth-related codes.

**Active external blocker, not this doc's concern to track**: obtaining real credentials requires (1) the organizing party for the league's tournaments authorizing melee.gg to grant API access, then (2) emailing `contact@melee.gg` to request them. Mattia has not completed this yet, and the timeline is outside our control (tracked as its own issue). Viewing the Swagger spec required none of that — but *calling* any endpoint with real data still does. This doc describes the **target design** to build against regardless of whether credentials have arrived — see §5 (mock mode) for how development proceeds in the meantime.

Related: `data-model-technical.md` (`League`, `Stage.excluded`), `tournament-stage-technical.md` (Stage/StagePlacement/StagePairing targets, including `isFinal`/`seasonId`), `player-technical.md` (Player/PlayerAlias/UnresolvedPlayerMatch targets), `decklists-technical.md` (Decklist/DecklistEntry targets, visibility), `league-scoring-technical.md` (what depends on placements being correct), `security-technical.md` (per-League credential encryption/decryption, admin login gating manual sync).

## 1. Authentication

melee.gg's API uses **HTTP Basic authentication** — no token exchange, no expiry/refresh to manage. Every request carries an `Authorization: Basic <base64(username:password)>` header.

```ts
// melee-client.service.ts (sketch)
interface MeleeCredentials {
  username: string; // presumed: the issued client ID
  password: string; // presumed: the issued client secret
}

function buildAuthHeader(creds: MeleeCredentials): string {
  return 'Basic ' + Buffer.from(`${creds.username}:${creds.password}`).toString('base64');
}
```

- Credentials are no longer a single global env-var pair. Each `League` row stores its own `meleeClientIdEncrypted`/`meleeClientSecretEncrypted` (AES-256-GCM ciphertext — see §1a and `security-technical.md`'s "League credential encryption" section for the encryption scheme itself, which this doc doesn't re-derive). There is still no separate auth/token service: no `MeleeAuthService`, no cached access token, no refresh logic — that simplification versus an OAuth2 client-credentials flow still holds, it just now happens once per `League` rather than once globally.
- If a `League` has no melee.gg credentials configured yet (the expected state for a newly-created league until its credentials are set, or globally until the external blocker in the Status section resolves), sync for that league falls back to mock mode — see §5 — rather than failing to boot or failing the whole app.
- A failed-auth response (per the Status section: observed as `HTTP 400` with `Message: "Could not authenticate user."`, not a `401`) should be treated as a fatal, non-retryable configuration error for that league's credentials specifically, not a transient failure and not something that should affect any other league's sync — see §4.2's non-retryable list and §6.

## 1a. Per-League credentials

```ts
// melee-credentials.provider.ts (sketch)
async function getMeleeCredentialsForLeague(prisma: PrismaClient, leagueId: string): Promise<MeleeCredentials> {
  const league = await prisma.league.findUniqueOrThrow({ where: { id: leagueId } });
  return {
    username: decrypt(league.meleeClientIdEncrypted),     // decrypt() is the shared helper from security-technical.md's
    password: decrypt(league.meleeClientSecretEncrypted), // "League credential encryption" section — not reimplemented here
  };
}
```

- Decryption happens **only at point of use** — immediately before building the Basic-auth header for a call to melee.gg's API — never earlier, never cached in plaintext, never logged or returned in any API response (the admin panel only ever shows a masked placeholder for a league's configured credentials, per `security-technical.md`).
- `League.meleeOrgId` (see `data-model-technical.md`) identifies which melee.gg organization's tournaments this league syncs from; it's the scoping value passed to `GET /api/tournament/list` (§3) to restrict results to this league's own tournaments, so one league's sync run can never pull in another league's data even if both happen to be configured against melee.gg at the same time.
- A sync run is always for exactly one `League` — `MeleeSyncService`'s entry point takes a `leagueId`, resolves that league's org id and decrypted credentials once at the start of the run, and uses them for every request made during that run.

## 2. Module shape (NestJS)

```
src/melee-integration/
  melee-client.service.ts       // typed HTTP client against melee.gg's documented REST API (Basic auth header built from a given League's decrypted credentials, no auth service needed)
  melee-mock-client.service.ts  // fixture-backed implementation of the same client interface, for mock mode
  melee-sync.service.ts         // orchestrates a sync run for one League: lists its org's tournaments, auto-includes new ones as Stage rows, maps raw API responses -> domain entities
  melee-sync.controller.ts      // admin-triggered manual sync endpoint, POST /admin/leagues/:leagueId/sync (see §2a), guarded per security-technical.md
  melee-sync.scheduler.ts       // @nestjs/schedule cron job, once/day, iterates every League and triggers MeleeSyncService for each (see §2a)
  melee-credentials.provider.ts // resolves + decrypts a League's melee.gg credentials at point of use (see §1a)
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

`MeleeSyncService` depends on an injected `MeleeClient` interface; `MeleeClientService` (real API, credentialed per-League via §1a) and `MeleeMockClientService` (fixtures) are two interchangeable implementations of it, selected per sync run based on whether the target `League` has usable credentials (see §5). Nothing else in the codebase talks to melee.gg directly.

## 2a. Automatic + manual sync, both

Per the second corner-case review, ingestion is no longer solely admin-triggered — both paths are live simultaneously and write through the same `MeleeSyncService` logic, so a stage ends up identical regardless of which path ingested it:

- **Scheduled (automatic)**: a `@nestjs/schedule` cron job (`melee-sync.scheduler.ts`) runs **once per day** and, for every `League` in the system, calls `MeleeSyncService.syncLeague(leagueId)`. This is what catches a tournament that closed on melee.gg without anyone remembering to trigger a manual sync — the normal, expected way most stages get ingested day to day.
- **Manual (admin-triggered)**: an admin can still trigger a sync for a specific league on demand —

  ```
  POST /admin/leagues/:leagueId/sync
  ```

  Guarded by `AdminAuthGuard` + `LeagueAccessGuard` (see `security-technical.md`) — the caller must be `SUPER_ADMIN` or hold `AdminLeagueAccess` for this `leagueId`. Useful right after a stage closes, without waiting for the next scheduled run, or to retry a league whose previous sync failed.

  ```ts
  interface SyncLeagueResponse {
    leagueId: string;
    stagesCreated: number;    // newly auto-included tournaments this run
    stagesUpdated: number;    // already-known stages whose standings/decklists were refreshed
    syncLogIds: string[];
  }
  ```

- Both paths call `MeleeSyncService.syncLeague(leagueId, triggeredBy)`, where `triggeredBy` is `"scheduled"` for the cron path and `"manual:<adminEmail>"` for the admin-triggered path — recorded on each `StageSyncLog` row (see `tournament-stage-technical.md`) so it's always visible after the fact whether a given sync was automatic or manually requested. A manual sync doesn't disable or replace the scheduled job for that league — the two coexist, and a league that's synced manually today still gets checked again by tomorrow's scheduled run.

## 2b. Auto-include: every tournament under the org becomes a Stage

There is no admin step to pick which tournaments count. On each sync run for a `League`, `MeleeSyncService`:

1. Calls `GET /api/tournament/list` scoped to that league's `meleeOrgId` (§3).
2. For every tournament returned that doesn't yet have a matching `Stage.meleeTournamentId`, creates a new `Stage` row for it (attached to that league's currently-active `Season`, per `Season.isActive`) — this is the auto-include: showing up under the org is sufficient, there's no separate "approve this tournament" action anywhere in the admin flow.
3. For every tournament that already has a matching `Stage`, re-fetches and refreshes its standings/decklists if the tournament's status has changed since the last sync (e.g. it has since closed).

This deliberately trades "an admin might occasionally get an unwanted tournament synced in" for "no admin ever has to remember to manually add a stage" — the corner-case review's judgment was that the latter's day-to-day convenience outweighs the former's occasional cleanup, especially since §2c below makes the cleanup cheap and non-destructive.

## 2c. `Stage.excluded` — the safety net, not a gate

Because inclusion is automatic, the one place admin judgment is still needed is *after* the fact: an admin can mark an already-synced `Stage` as `excluded = true` (see `data-model-technical.md`) to correct a tournament that auto-synced but shouldn't count — the canonical example is a test event created in the same melee.gg org as the league's real tournaments.

```
PATCH /admin/leagues/:leagueId/stages/:stageId/excluded
```

```ts
interface SetStageExcludedRequest {
  excluded: boolean; // true to hide it, false to restore it
}
```

Guarded by `AdminAuthGuard` + `LeagueAccessGuard`, same as the manual sync endpoint. Setting `excluded = true`:

- Hides the stage from public standings and stage listings (see `tournament-stage-technical.md` for exactly how listings/detail routes treat it, and `league-scoring-technical.md` for standings aggregation).
- **Does not** delete any ingested data — `StagePlacement`/`Decklist`/`StagePairing` rows for that stage stay in the database untouched, and re-toggling `excluded` back to `false` restores full visibility with nothing to re-sync.
- **Does not** touch melee.gg in any way — this is purely a local flag, not an un-invite or a deletion on the melee.gg side.
- Writes an `AuditLog` entry (`STAGE_EXCLUDE` / `STAGE_INCLUDE`, per `security-technical.md`).

This is explicitly a **post-sync correction**, not a pre-sync approval gate — there is no state a `Stage` passes through before `excluded` is available to set; a tournament is auto-included first, and can be excluded after, if ever needed.

## 3. Real endpoints (from the public Swagger spec)

Pulled from `https://melee.gg/swagger/docs/v0.3.64.163` on 2026-08-26. Response bodies are **not** typed in the public spec (every `200` schema is a bare `{"type": "object"}` placeholder except list endpoints, which are wrapped in a generic `ApiResult` envelope) — so field names in the interfaces below are still our own naming for the raw DTOs, not confirmed melee.gg field names. That confirmation only happens once real credentials allow an actual authenticated call. Don't treat the field names as verified.

**Shared pagination pattern** — every `list` endpoint below accepts the same three query params and returns the same envelope:

| Param | Type | Notes |
|---|---|---|
| `variables.page` | int | defaults to 1 |
| `variables.pageSize` | int | min 5, max 250, default 25 |
| `variables.ignoreCache` | bool | default false — force a fresh fetch instead of melee.gg's own cached response |

```ts
interface ApiResult<T> {
  StatusCode: number;
  Page: number | null;
  PageSize: number | null;
  RecordsFiltered: number | null;
  RecordsTotal: number | null;
  Content: T;
  HasMore: boolean | null;
}
```

**Endpoints used, by tag:**

| Endpoint | ID type | Notes |
|---|---|---|
| `GET /api/tournament/list` | — | Filters: `startDateFrom`, `startDateTo`, `tournamentId`, `lastUpdatedDate`. "Lists tournaments accessible to the authenticated staff member" — since a sync run authenticates with one `League`'s own credentials (§1a), this naturally scopes results to that league's org without needing an explicit org-id filter param; this is the endpoint §2b's auto-include walks on every sync run to discover new tournaments. |
| `GET /api/tournament/{id}` | tournament id: `int64` | Single tournament detail — maps to `Stage` metadata (`tournament-stage-technical.md`); `isFinal` is set by our admin (via a request field on the manual sync/link flow, see `tournament-stage-technical.md` §2), never read from melee.gg. `excluded` is likewise never read from melee.gg — it's a purely local admin flag, see §2c. |
| `GET /api/standing/list/current/{id}` | tournament id: `int64` | Current standings for a tournament — primary source for `StagePlacement` (`league-scoring-technical.md`). |
| `GET /api/standing/list/round/{id}` | round id: `int64` | Standings as of a specific round — useful for a `Stage` still `IN_PROGRESS`. |
| `GET /api/standing/{id}` | team id: `int64` | "Most current standings for a specific **team**" — only relevant if a tournament is team-based; the league's stages are assumed individual (see `player-technical.md`), so likely unused, kept for completeness. |
| `GET /api/player/list/{id}` | tournament id: `int64` | Tournament roster — maps to `PlayerAlias` (`player-technical.md`). |
| `GET /api/player/{id}` | player id: `int64` | Single player detail. Spec note: "Requires staff-level authorization." |
| `GET /api/player/metadata/{id}` / `/list/{id}` | player id / tournament id: `int64` | Key-value player metadata. Spec note: "Requires staff-level authorization" on both. |
| `GET /api/decklist/list/{id}` | tournament id: `int64` | All decklists for a tournament, optional `formatId` filter — primary source for `Decklist`/`DecklistEntry` (`decklists-technical.md`). |
| `GET /api/decklist/list/player/{id}` | player id: `int64` | A player's decklists within a tournament. |
| `GET /api/decklist/list/team/{id}` | team id: `int64` | Team decklists, optional `formatId` filter — likely unused (see standing/{id} note above). |
| `GET /api/decklist/player/{id}` | player id: `int64`, requires `formatId` | A specific player+format decklist. |
| `GET /api/decklist/{id}` | decklist id: **string GUID** (not int64, unlike the rest) | A single decklist by its own id; `includeCardAttributes` bool flag adds gameplay attributes per card. |
| `GET /api/match/list/{id}` | tournament id: `int64` | All matches for a tournament — maps to `StagePairing` (`tournament-stage-technical.md`). **This confirms pairings/rounds data IS exposed by the documented API** (previously an open question in this doc). |
| `GET /api/match/list/current/{id}` | tournament id: `int64` | Matches for the tournament's current round. |
| `GET /api/match/list/round/{id}` | round id: `int64` | Matches for a specific round. |
| `GET /api/match/{id}` | match id: **string GUID** | Single match detail. |
| `GET /api/team/list/{id}` / `GET /api/team/{id}` | tournament id / team id: `int64` | Team endpoints — likely unused for this individual-format league, kept for completeness. |

```ts
interface RawTournamentDto {
  meleeTournamentId: number; // int64 in the real API, not the string id previously assumed
  // exact field names for name/status/dates/playerCount not yet confirmed — see Status above
}

interface RawStandingsRowDto {
  meleePlayerId: number | null; // int64
  rawPlayerName: string;
  placement: number;
}

interface RawRosterEntryDto {
  meleePlayerId: number | null; // int64
  rawPlayerName: string;
}

interface RawDecklistDto {
  meleeDecklistId: string; // GUID, confirmed by the spec's {id} param type
  meleePlayerId: number | null; // int64
  rawPlayerName: string;
  formatId: string | null;
  mainDeck: { rawName: string; quantity: number }[];
  sideboard: { rawName: string; quantity: number }[];
}

interface RawPairingDto {
  meleeMatchId: string; // GUID
  round: number;
  // player/result fields not yet confirmed
}
```

Each call returns a typed raw DTO before any mapping to domain entities happens — this keeps "what melee.gg's API returned" separate from "what we stored," so a future spec version bump only touches the raw DTO/mapping layer, not the domain model.

## 4. Rate limits and error handling

The public Swagger spec (§3) doesn't publish explicit rate limits or a dedicated error-schema definition, so the client still applies conservative, real-API-appropriate defaults rather than assuming no limits exist at all — to be tightened/loosened once real usage against production reveals actual limits:

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
- **Not retryable (fail fast)**: `404 Not Found` (tournament id doesn't exist / wrong id), `400` with an auth-failure message (per Status — credentials missing/invalid for the `League` being synced; since Basic auth has no token to refresh, this just fails straight to the admin), `403` (credentials valid but not authorized for this resource — needs human attention, retrying won't help).
- **Per-League isolation**: since the scheduled job (§2a) iterates every `League` in one daily run, a failure syncing one league (bad/missing credentials, melee.gg outage scoped to that org, etc.) is caught and logged against that league's own `StageSyncLog`/run record and does **not** abort or skip the remaining leagues in that day's run — each league's sync is independent, so one misconfigured league can't silently starve every other league of its daily sync.
- A `429` response, if it carries a `Retry-After` header, has that value respected as a floor on the backoff delay rather than the computed exponential value, when present — standard behavior for a rate-limited REST API.

Note: §4.3 (token-expiry handling) from the previous version of this doc no longer applies — Basic auth has no token to expire, so there's nothing to refresh mid-sync.

## 5. Mock mode (fixture-based)

Because real client credentials are an active external blocker with an unknown timeline (see Status above), `MeleeClientService` is not the only implementation of the client interface development runs against. Mock-mode selection now happens **per sync run, per `League`**, rather than once globally at module boot, since each league independently has or lacks usable credentials:

```ts
// melee-sync.service.ts (sketch)
async function getClientForLeague(leagueId: string): Promise<MeleeClient> {
  const league = await prisma.league.findUniqueOrThrow({ where: { id: leagueId } });
  const hasCredentials = Boolean(league.meleeClientIdEncrypted && league.meleeClientSecretEncrypted);
  if (!hasCredentials || process.env.MELEE_MOCK_MODE === 'true') {
    return mockClient; // MeleeMockClientService
  }
  const credentials = await getMeleeCredentialsForLeague(prisma, leagueId); // §1a, decrypted here
  return realClient.withCredentials(credentials); // MeleeClientService
}
```

- `MeleeMockClientService` implements the same client interface (`getTournamentInfo`, `getStandings`, `getRoster`, `getDecklists`) but reads from static JSON fixtures under `fixtures/` instead of calling melee.gg, returning the same `Raw*Dto` shapes described in §3. The same fixture set is reused for every league in mock mode — fixtures aren't per-league, since they're a stand-in for the shape of melee.gg's API, not for any particular org's real data.
- Fixtures are hand-authored to approximate what the real API is expected to return (based on melee.gg's public documentation and, once obtained, the real Swagger spec) — they are a best-effort target shape, not a guarantee of the exact real response, and should be revisited once real credentials land and the actual response shape can be confirmed/diffed against them.
- Mock mode is automatic per league (falls back whenever that league's `League` row has no usable credentials) so local development, CI, and any league without real credentials yet keep working end-to-end — `MeleeSyncService`, the domain mapping, player matching, and decklist ingestion are all exercised against fixture data exactly as they would be against the real API. A platform running some leagues with real credentials and others still in mock mode is expected and fine — each sync run resolves its own client independently.
- Once a league's real credentials are obtained (via `POST /admin/leagues` at creation, or a future "update credentials" admin action), switching that league to the real client is just supplying valid `meleeClientIdEncrypted`/`meleeClientSecretEncrypted` — no code change required, since `MeleeSyncService` only ever depends on the shared client interface, not on which implementation is active.

## 6. Error handling summary

| Failure | Behavior |
|---|---|
| melee.gg unreachable (network/timeout) | Retry per §4.2; after exhausting retries, sync fails, `StageSyncLog.status = 'failed'`, stage unchanged. |
| `429` / rate limited | Retry with backoff honoring `Retry-After` if present. |
| `400` with `Message: "Could not authenticate user."` (confirmed live behavior — see Status) | Fail fast, no retry — credentials missing/invalid, needs admin attention. Not a transient failure. |
| `403` ("Requires staff-level authorization" / not authorized for this resource, per several endpoints in §3) | Fail fast, no retry — surfaced to admin immediately; likely means the credentialed account's access scope doesn't cover this tournament/org. |
| `404` on tournament id | Fail fast, no retry — likely a wrong/stale `meleeTournamentId`; surfaced to admin immediately. |
| Standings fetch fails after retries | Sync fails (critical path — this is the one data source that affects scoring, see `league-scoring-technical.md`); stage unchanged. |
| Decklist/roster fetch fails for one participant | That entry is skipped (`Decklist.status = 'PARTIAL'` or missing roster row), sync continues, overall `StageSyncLog.status = 'partial'`. |
| Player name ambiguous/new | Not a melee-integration failure — handed off to the player-matching flow in `player-technical.md` §3, sync continues normally. |
| melee.gg returns fewer/more players than expected `playerCount` | Logged as a warning in `StageSyncLog.message`, does not block sync (see `tournament-stage-technical.md` §Failure modes). |
| `GET /api/tournament/list` (auto-include discovery, §2b) fails for a League | That league's whole sync run fails (nothing to auto-include or refresh without the tournament list); logged against that league only, other leagues' scheduled/manual syncs are unaffected (§4.2's per-League isolation note). |

## 7. Mapping summary (raw → domain)

```
RawTournamentDto      -> Stage (metadata fields; auto-included per §2b on first sight; isFinal/excluded set only by our admin, status transition per tournament-stage-technical.md §2)
RawStandingsRowDto[]  -> Player/PlayerAlias resolution (player-technical.md §3) -> StagePlacement (league-scoring-technical.md §2)
RawRosterEntryDto[]   -> Player/PlayerAlias resolution (player-technical.md §3)
RawDecklistDto[]      -> Player/PlayerAlias resolution -> Decklist + DecklistEntry (decklists-technical.md §1-2), including Scryfall matching and visibility per decklists-technical.md §4
RawPairingDto[]       -> Player/PlayerAlias resolution -> StagePairing (tournament-stage-technical.md), via TournamentMatchApi (§3)
```

All player-name resolution across standings, roster, and decklists funnels through the single matching algorithm in `player-technical.md` §3, so the same person is recognized consistently regardless of which melee.gg endpoint their name came from within one sync run.

## 8. Open items requiring real credentials

The public Swagger spec resolved several previously-open items (endpoint list confirmed, pairings/rounds confirmed present via `TournamentMatchApi`, auth model confirmed as Basic not OAuth2). What's left needs an actual authenticated call, not just the spec:

- Exact response field names for every endpoint in §3 (the spec's response schemas are untyped `object` placeholders).
- Confirmation that the issued client ID/secret are literally the Basic-auth username/password (inferred from the spec's auth description, not yet tested).
- Documented, published rate limits — the spec doesn't state any; §4.1's conservative defaults stay in place until real usage informs otherwise.
- Whether `meleePlayerId` (or whatever the real field is named) is present on every endpoint that returns a player name, or only some.
- Whether the league's tournaments are individual or team-structured on melee.gg — if team-structured, the `TournamentTeamApi`/team-scoped decklist and standing endpoints (currently assumed "likely unused") become primary, not incidental.
