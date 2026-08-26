# Melee.gg Integration — Overview

## What this is about

melee.gg is the third-party platform the league actually plays its tournaments on. Prem League Tracker doesn't organize tournaments itself — it reads back tournament info, standings, decklists, and player rosters from melee.gg and turns them into the league's own historical record. This document explains, at a conceptual level, how that connection works and why it's treated carefully.

## melee.gg is not a partner API — it's an external dependency we don't control

Unlike a proper public API with a support contract and documented rate limits, melee.gg is a tournament-organizing website that Prem League Tracker reads data from as a matter of practicality. There's no guarantee about how stable its structure is, no official uptime commitment to us, and no published limit on how often it's safe to ask it for data. That means the integration has to assume, by default, that melee.gg:

- might be slow or briefly unavailable,
- might change how a page is structured without warning,
- and might penalize us (temporarily blocking or throttling requests) if we ask for data too aggressively.

Prem League Tracker's approach is to treat melee.gg the way you'd treat any fragile, unofficial data source: fetch politely, cache what's fetched, retry gracefully on hiccups, and never let a melee.gg problem take down the rest of the site or corrupt league data.

## What we actually pull from melee.gg

At a conceptual level (the exact page/endpoint details need to be verified against melee.gg's real, current structure — see the technical doc), Prem League Tracker reads:

- **Tournament info** — basic metadata about a stage's tournament (name, date, format).
- **Standings** — the final placement of every player once a stage's tournament wraps up.
- **Decklists** — the cards each player registered for the tournament, when available.
- **Player roster** — who participated, so their names can be matched to (or create) a player record.

## When data is pulled

Data is **not** fetched from melee.gg every time someone visits the website. Instead, syncing happens deliberately — after a stage's tournament has finished, either an admin triggers the sync manually or a scheduled job checks on it — and the result is stored permanently in Prem League Tracker's own database, per the data model described in `tournament-stage-overview.md`. Everyday visitors to the site are always served from that stored copy, never a live melee.gg call.

## What happens when melee.gg misbehaves

If melee.gg is unreachable, slow, or its page structure has changed in a way the integration doesn't understand, the sync for that stage simply fails safely: nothing gets marked as final/closed, the rest of the site (all previously-synced stages, standings, decklists) keeps working exactly as before, and the failure is logged so an admin can investigate and retry later.

## Related documents

- `tournament-stage-overview.md` — the stage lifecycle this integration feeds into.
- `player-overview.md`, `decklists-overview.md` — the entities populated from melee.gg data.
- `melee-integration-technical.md` — retry/backoff strategy, caching, and data mapping details.
