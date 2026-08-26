# Scryfall Integration — Technical

## Status

**Revised 2026-08-26.** This doc originally specified a Postgres `CardCache` table as the resolution cache. Per the Vercel+Neon+Upstash hosting revision (`hosting-deployment-be-technical.md`), the cache now lives in **Upstash Redis**, not Postgres. Postgres remains the system of record for domain data (`DecklistEntry` and the rest — see `data-model-technical.md`); Redis is purely a cache in front of Scryfall, and can be evicted or flushed without any data loss beyond needing to re-resolve cards on next access.

## Purpose

The `ScryfallModule` resolves card names (as ingested from melee.gg decklists) into structured Scryfall card data (image URIs, mana cost, type line, oracle text, colors, set/collector number), caching results in Redis so the API never needs to call Scryfall on a hot read path.

This doc covers: resolution strategy, caching (Redis key scheme + TTL), rate limiting, and fallback behavior. For how `DecklistEntry` references a resolved card, see `data-model-technical.md`. For how decklist entries reference resolved cards, see `decklists-technical.md`.

## Module shape

```
src/scryfall/
  scryfall.module.ts
  scryfall.service.ts        # public API used by DecklistsModule / MeleeIntegrationModule
  scryfall.client.ts         # thin HTTP client wrapping Scryfall's REST API
  scryfall-cache.service.ts  # Redis-backed cache, wraps the shared cache client from cache-config module
  dto/
    scryfall-card.dto.ts
```

`ScryfallModule` exports `ScryfallService`. It depends on the shared cache client (see `hosting-deployment-be-technical.md`'s config module that selects between the Upstash REST client in prod/preview and a plain `REDIS_URL` client locally) rather than `PrismaModule` — no database access is needed for card resolution itself. No controller is required for MVP — resolution is invoked internally (e.g. during decklist ingestion), not exposed as a public endpoint. If a manual "force re-resolve this card" admin action is added later, it goes on `ScryfallController` under an admin-guarded route.

## Card resolution

Scryfall's REST API (`https://api.scryfall.com`) is used directly via HTTPS; no SDK/API key is required (Scryfall is a free, keyless public API).

Resolution order, per card name coming out of a decklist import:

1. **Cache lookup** — build the Redis lookup key (see key scheme below) from the normalized incoming name (trim, collapse whitespace, lowercase) plus set/collector number if the source provided them. If a fresh entry exists (see TTL below), return it — no network call.
2. **Cache miss or stale entry** — call Scryfall:
   - If the import provided set code + collector number (melee.gg decklists sometimes carry this), use `GET /cards/:set/:collector_number`.
   - Otherwise use the fuzzy name endpoint: `GET /cards/named?fuzzy=<name>`. Fuzzy matching tolerates minor typos and partial names, which is important because melee.gg decklist text entry is free-form.
   - If the name appears to be non-English (heuristic: contains non-ASCII letters, or previous fuzzy lookup 404s), retry against `GET /cards/named?fuzzy=<name>` — Scryfall's fuzzy search already matches against printed foreign names in its search index, so a French/Japanese/German card name typically resolves directly without a separate "foreign name" endpoint.
3. **Write-through to Redis** — store the resolved DTO under the lookup key (see below) and reset its TTL.
4. **Return** the DTO to the caller (`DecklistsModule` at ingestion time), which persists `scryfallCardId` and `resolved = true` on the `DecklistEntry` (see `data-model-technical.md`) — the card's actual data is not duplicated into Postgres.

### Re-resolution after cache eviction

Once a `DecklistEntry.scryfallCardId` is known (set on first successful resolution), a later cache miss for that same entry — e.g. after Redis TTL expiry — re-fetches directly via `GET /cards/:id` rather than re-running fuzzy name search. This is cheap and unambiguous (a direct id lookup, no matching heuristics), and means eviction never risks re-resolving to a different printing than originally matched.

### Double-faced cards

Scryfall represents double-faced/transform/modal-DFC cards with a `card_faces` array instead of top-level `image_uris`/`oracle_text`. The client normalizes this into the cached DTO:

- `imageUrlFront` / `imageUrlBack` (back nullable — null for single-faced cards).
- `oracleTextFront` / `oracleTextBack`.
- `isDoubleFaced: boolean`.

The frontend decides whether to render a flip control based on `isDoubleFaced`.

## Caching strategy

### Why cache at all

Scryfall card data is near-static — a printed card's image, oracle text, and mana cost do not change after printing (the only changes are rare oracle-text errata, which are infrequent and non-urgent for a casual league site). Re-fetching on every decklist view would be wasteful and would put unnecessary load on a shared public service.

### Where it lives

The cache is **Upstash Redis** (production/preview) or a dockerized `redis:7-alpine` container (local dev) — see `hosting-deployment-be-technical.md` for the environment-selecting config module. This replaces the originally-planned Postgres `CardCache` table: Redis's native key TTL removes the need for a manually-checked `fetchedAt` staleness column, and keeping resolution data out of Postgres keeps the primary database scoped to actual domain/league data (see `data-model-technical.md`).

### Redis key scheme

- **Primary lookup key**: `scryfall:card:<lookupKey>`, where `lookupKey` is `<set>:<collectorNumber>` (lowercased) when the import supplied an exact printing, otherwise the normalized fuzzy name (trimmed, collapsed whitespace, lowercased). Value: the full card DTO, JSON-serialized (`id`, `name`, `manaCost`, `typeLine`, `oracleTextFront`, `oracleTextBack`, `imageUrlFront`, `imageUrlBack`, `isDoubleFaced`, `colors`, `resolvedAt`).
- **Id-lookup key**: `scryfall:id:<scryfallCardId>`, same value shape, written alongside the primary key on every resolution. Used exclusively by the re-resolution-after-eviction path above (`GET /cards/:id` results are cached here, not under a name-derived key, since there's no name to derive one from).
- Distinct card names/printings that happen to resolve to the same underlying Scryfall card are cached under separate keys (once per distinct lookup key). This trades a small amount of duplicate cache storage for simplicity — no separate id-indirection layer is needed the way a relational `CardCache` table's primary-key-by-id upsert required.

### TTL

Two-tier TTL, to preserve the previous design's stale-while-revalidate behavior without a manually-checked timestamp column:

- **Soft TTL: 30 days**, configurable via `SCRYFALL_CACHE_SOFT_TTL_DAYS` (default `30`). Checked in application logic against the `resolvedAt` field stored in the cached value: if `now - resolvedAt > soft TTL`, the stale value is still returned immediately, and a background re-fetch is kicked off to refresh it (stale-while-revalidate).
- **Hard TTL: 60 days**, configurable via `SCRYFALL_CACHE_HARD_TTL_DAYS` (default `60`), set as Redis's native key expiry (`EX`/`PXAT` on write). Once the hard TTL passes, Redis evicts the key entirely and the next lookup is a full cache miss, going through fuzzy/id resolution again per the flow above.
- The gap between soft and hard TTL exists specifically so a Scryfall outage lasting a few weeks still serves stale-but-present data rather than falling straight to "unresolved" once the soft TTL passes.
- No scheduled bulk-refresh job is needed for MVP — refresh is lazy, on next access, which is sufficient given low traffic and near-static data.

## Rate limiting (outbound, to Scryfall)

Scryfall publishes a soft rate limit of roughly **10 requests/second**, and recommends clients insert a **50–100ms delay** between sequential requests, especially for bulk operations. We respect this:

- `ScryfallClient` wraps every outbound call through a simple request queue that enforces a minimum **75ms** delay between consecutive requests (configurable via `SCRYFALL_MIN_REQUEST_INTERVAL_MS`, default `75`).
- Decklist ingestion (which may need to resolve 40–75 cards per deck across dozens of decks per stage) resolves cards **sequentially through this queue**, not in parallel — this is the dominant source of Scryfall traffic and the reason the throttle exists.
- On an HTTP `429` from Scryfall, back off with exponential delay (starting at 500ms, doubling, max 3 retries) before falling back to cache/unresolved behavior below.
- We do not use Scryfall's bulk-data downloads for MVP (they're a better fit for full-catalog mirrors, which this project doesn't need); on-demand per-card lookups plus the Redis cache above is enough at this scale.

## Fallback behavior

| Situation | Behavior |
|---|---|
| Card found, within soft TTL | Return cached DTO, no network call. |
| Card found, past soft TTL but within hard TTL, Scryfall reachable | Return cached DTO immediately; refresh cache in background. |
| Card found, past soft TTL, Scryfall unreachable/erroring | Return cached (stale) DTO — stale data beats no data. |
| Card never cached (or past hard TTL), Scryfall resolves it | Write-through to Redis, return fresh DTO. |
| Card never cached, Scryfall returns 404 (name not found) | Do not write anything to Redis (no negative caching for MVP — a 404 is cheap enough to re-check on next access). Mark `DecklistEntry.resolved = false` in Postgres so the decklist still renders with a plain-text fallback (card name only, no image). Do not throw — ingestion of the rest of the decklist continues. |
| Card never cached, Scryfall unreachable (network/5xx/timeout) | Same as above: `DecklistEntry.resolved = false`, log the failure, continue ingestion. A later re-ingestion or lazy on-demand retry (e.g. next time the decklist page is loaded and unresolved entries exist) will retry resolution. |
| Foreign-language name fails fuzzy match | Same unresolved fallback; the raw imported name is preserved on `DecklistEntry.rawCardName` so it's still visible to the user, just without art/oracle text. |

The guiding rule: a Scryfall failure of any kind must never fail decklist ingestion or decklist page rendering as a whole — it degrades gracefully to a per-card fallback.

## Configuration (env vars)

- `SCRYFALL_API_BASE_URL` (default `https://api.scryfall.com`)
- `SCRYFALL_CACHE_SOFT_TTL_DAYS` (default `30`)
- `SCRYFALL_CACHE_HARD_TTL_DAYS` (default `60`)
- `SCRYFALL_MIN_REQUEST_INTERVAL_MS` (default `75`)
- `SCRYFALL_MAX_RETRIES` (default `3`)
- Redis connection: see `hosting-deployment-be-technical.md` (`UPSTASH_REDIS_REST_URL`/`UPSTASH_REDIS_REST_TOKEN` in prod/preview, `REDIS_URL` locally) — shared with the standings cache, not Scryfall-specific config.

## Testing conventions

- Unit tests for `ScryfallService`/`ScryfallClient` mock the HTTP layer (e.g. `nock` or a fake `HttpService`) — no real network calls in CI.
- Unit tests for `ScryfallCacheService` run against a real local Redis (Docker service container in CI, same as `ci.yml`'s Postgres service container) rather than mocking Redis — the key scheme and TTL logic are worth exercising for real.
- Test cases must cover: fresh (within soft TTL) cache hit, stale (past soft TTL) cache hit with background refresh, cache miss + successful resolve, cache miss + 404, cache miss + network error, double-faced card normalization, fuzzy foreign-name resolution, re-resolution after hard-TTL eviction via the id-lookup path.
- Rate-limit queuing logic gets its own unit test asserting the minimum inter-request interval is respected (using fake timers, not real 75ms waits).

## Cross-references

- `hosting-deployment-be-technical.md` — Upstash Redis provisioning, the local/prod cache-client config module, and env var injection.
- `data-model-technical.md` — `DecklistEntry.scryfallCardId`/`resolved` fields and why card data itself isn't stored in Postgres.
- `decklists-technical.md` — how ingestion invokes `ScryfallService` and renders unresolved entries.
