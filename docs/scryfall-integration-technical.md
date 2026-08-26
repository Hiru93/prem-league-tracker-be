# Scryfall Integration — Technical

## Purpose

The `ScryfallModule` resolves card names (as ingested from melee.gg decklists) into structured Scryfall card data (image URIs, mana cost, type line, oracle text, colors, set/collector number) and persists that data in a local cache table, so the API never needs to call Scryfall on a hot read path.

This doc covers: resolution strategy, caching (schema + TTL), rate limiting, and fallback behavior. For where the cache table (`CardCache`) sits in the overall schema, see `data-model-technical.md`. For how decklist entries reference cached cards, see `decklists-technical.md`.

## Module shape

```
src/scryfall/
  scryfall.module.ts
  scryfall.service.ts        # public API used by DecklistsModule / MeleeIntegrationModule
  scryfall.client.ts         # thin HTTP client wrapping Scryfall's REST API
  scryfall-cache.repository.ts
  dto/
    scryfall-card.dto.ts
```

`ScryfallModule` exports `ScryfallService`. It depends on `PrismaModule` for cache persistence. No controller is required for MVP — resolution is invoked internally (e.g. during decklist ingestion), not exposed as a public endpoint. If a manual "force re-resolve this card" admin action is added later, it goes on `ScryfallController` under an admin-guarded route.

## Card resolution

Scryfall's REST API (`https://api.scryfall.com`) is used directly via HTTPS; no SDK/API key is required (Scryfall is a free, keyless public API).

Resolution order, per card name coming out of a decklist import:

1. **Cache lookup** — normalize the incoming name (trim, collapse whitespace, lowercase for the lookup key) and query `CardCache` by `normalizedName` (and `set`/`collectorNumber` if the source provided them, for exact-printing lookups). If a fresh entry exists (see TTL below), return it — no network call.
2. **Cache miss or stale entry** — call Scryfall:
   - If the import provided set code + collector number (melee.gg decklists sometimes carry this), use `GET /cards/:set/:collector_number`.
   - Otherwise use the fuzzy name endpoint: `GET /cards/named?fuzzy=<name>`. Fuzzy matching tolerates minor typos and partial names, which is important because melee.gg decklist text entry is free-form.
   - If the name appears to be non-English (heuristic: contains non-ASCII letters, or previous fuzzy lookup 404s), retry against `GET /cards/named?fuzzy=<name>` — Scryfall's fuzzy search already matches against printed foreign names in its search index, so a French/Japanese/German card name typically resolves directly without a separate "foreign name" endpoint.
3. **Persist** the returned card into `CardCache` (upsert by Scryfall `id`), update `fetchedAt`.
4. **Return** the DTO to the caller (`DecklistsModule` at ingestion time).

### Double-faced cards

Scryfall represents double-faced/transform/modal-DFC cards with a `card_faces` array instead of top-level `image_uris`/`oracle_text`. The client normalizes this:

- `CardCache.imageUrlFront` / `CardCache.imageUrlBack` (back nullable — null for single-faced cards).
- `CardCache.oracleTextFront` / `CardCache.oracleTextBack`.
- `CardCache.isDoubleFaced: boolean`.

The frontend decides whether to render a flip control based on `isDoubleFaced`.

## Caching strategy

### Why cache at all

Scryfall card data is near-static — a printed card's image, oracle text, and mana cost do not change after printing (the only changes are rare oracle-text errata, which are infrequent and non-urgent for a casual league site). Re-fetching on every decklist view would be wasteful and would put unnecessary load on a shared public service.

### Where it lives

The cache is a table in the same Postgres instance used for the rest of the app's data (see `data-model-technical.md` for the full schema and the reasoning for using Postgres at all). Using the primary DB — rather than a separate cache store like Redis — is deliberate: traffic is tiny (~100 visits/day per the architecture memo), so a second piece of infrastructure to cache near-static data isn't justified. A plain table with a `fetchedAt` timestamp is sufficient.

### TTL

- Default TTL: **30 days**, configurable via `SCRYFALL_CACHE_TTL_DAYS` env var (default `30`).
- Staleness check: `now - fetchedAt > TTL` triggers a background re-fetch attempt on next access; the stale cached value is still returned immediately (stale-while-revalidate), never blocking the response on a fresh Scryfall call.
- No scheduled bulk-refresh job is needed for MVP — refresh is lazy, on next access, which is sufficient given low traffic and static data.

### Cache table shape (see `data-model-technical.md` for canonical schema)

Key fields: `id` (Scryfall card id, primary key), `normalizedName`, `set`, `collectorNumber`, `name`, `manaCost`, `typeLine`, `oracleTextFront`, `oracleTextBack`, `imageUrlFront`, `imageUrlBack`, `isDoubleFaced`, `colors`, `fetchedAt`.

## Rate limiting (outbound, to Scryfall)

Scryfall publishes a soft rate limit of roughly **10 requests/second**, and recommends clients insert a **50–100ms delay** between sequential requests, especially for bulk operations. We respect this:

- `ScryfallClient` wraps every outbound call through a simple request queue that enforces a minimum **75ms** delay between consecutive requests (configurable via `SCRYFALL_MIN_REQUEST_INTERVAL_MS`, default `75`).
- Decklist ingestion (which may need to resolve 40–75 cards per deck across dozens of decks per stage) resolves cards **sequentially through this queue**, not in parallel — this is the dominant source of Scryfall traffic and the reason the throttle exists.
- On an HTTP `429` from Scryfall, back off with exponential delay (starting at 500ms, doubling, max 3 retries) before falling back to cache/unresolved behavior below.
- We do not use Scryfall's bulk-data downloads for MVP (they're a better fit for full-catalog mirrors, which this project doesn't need); on-demand per-card lookups plus our own long-TTL cache is enough at this scale.

## Fallback behavior

| Situation | Behavior |
|---|---|
| Card found in fresh cache | Return cached DTO, no network call. |
| Card found in stale cache, Scryfall reachable | Return cached DTO immediately; refresh cache in background. |
| Card found in stale cache, Scryfall unreachable/erroring | Return cached (stale) DTO — stale data beats no data. |
| Card never cached, Scryfall resolves it | Persist and return fresh DTO. |
| Card never cached, Scryfall returns 404 (name not found) | Persist a "unresolved" marker row (or simply do not persist, and mark the `DecklistEntry` as `resolved: false`) so the decklist still renders with a plain-text fallback (card name only, no image). Do not throw — ingestion of the rest of the decklist continues. |
| Card never cached, Scryfall unreachable (network/5xx/timeout) | Same as above: mark `DecklistEntry.resolved = false`, log the failure, continue ingestion. A later re-ingestion or lazy on-demand retry (e.g. next time the decklist page is loaded and unresolved entries exist) will retry resolution. |
| Foreign-language name fails fuzzy match | Same unresolved fallback; the raw imported name is preserved on `DecklistEntry.rawCardName` so it's still visible to the user, just without art/oracle text. |

The guiding rule: a Scryfall failure of any kind must never fail decklist ingestion or decklist page rendering as a whole — it degrades gracefully to a per-card fallback.

## Configuration (env vars)

- `SCRYFALL_API_BASE_URL` (default `https://api.scryfall.com`)
- `SCRYFALL_CACHE_TTL_DAYS` (default `30`)
- `SCRYFALL_MIN_REQUEST_INTERVAL_MS` (default `75`)
- `SCRYFALL_MAX_RETRIES` (default `3`)

## Testing conventions

- Unit tests for `ScryfallService`/`ScryfallClient` mock the HTTP layer (e.g. `nock` or a fake `HttpService`) — no real network calls in CI.
- Test cases must cover: fresh cache hit, stale cache hit with background refresh, cache miss + successful resolve, cache miss + 404, cache miss + network error, double-faced card normalization, fuzzy foreign-name resolution.
- Rate-limit queuing logic gets its own unit test asserting the minimum inter-request interval is respected (using fake timers, not real 75ms waits).
