# Melee.gg Integration — Overview

## What this is about

melee.gg is the third-party platform the league actually plays its tournaments on. Prem League Tracker doesn't organize tournaments itself — it reads back tournament info, standings, decklists, and player rosters from melee.gg and turns them into the league's own historical record. This document explains, at a conceptual level, how that connection works.

## Sync is per-league now

**Update (2026-08-26, second corner-case review)**: the platform can run several leagues at once (see `data-model-overview.md`), and each league has its own melee.gg organization and its own melee.gg API credentials, kept encrypted and never shared between leagues. Syncing one league's tournaments never touches or exposes another league's data, even if both leagues happen to have real credentials configured at the same time.

Two things changed about *when* and *what* gets synced:

- **No more picking which tournaments count.** Previously this document assumed an admin would choose which melee.gg tournaments to link as stages. That step is gone: every tournament that exists under a league's melee.gg organization is automatically pulled in as a stage the next time that league syncs — nothing to opt in.
- **Sync happens automatically every day, on top of the existing manual trigger.** A background job checks every league once a day for newly-closed tournaments and ingests them without anyone needing to remember to click sync. An admin can still trigger a sync for their league on demand (e.g. right after a tournament wraps up, without waiting for the next day's automatic run) — both exist side by side.

Because inclusion is now automatic, there's one new admin safety net: if a tournament gets swept in that shouldn't count (a test event created in the same melee.gg organization, say), an admin can mark that stage **excluded** — it disappears from standings and public listings, but nothing about it is deleted, and un-excluding it later needs no re-sync. This is a correction an admin makes *after* seeing something wrongly included, not a gate they have to clear *before* anything gets included.

## melee.gg has a real, documented API — this isn't scraping

**Update (2026-08-26)**: earlier drafts of this document assumed melee.gg had to be treated like any random website — scraped defensively, expecting its page structure to shift without warning. That assumption was wrong. melee.gg publishes a real, documented REST API (a full Swagger specification is even publicly browsable, no login required, at `melee.gg/swagger/ui/index`), and access to actually *call* it is granted properly: an organization requests API credentials (a client ID and secret) by emailing melee.gg directly, after the tournament-organizing party authorizes it. Those credentials are used as a username/password pair (HTTP Basic authentication) on every request. Prem League Tracker integrates against that documented API, not by parsing HTML.

This is a meaningfully different, sturdier foundation than "treat melee.gg like a fragile scrape target": a documented API means a stable contract to build against, rather than a structure that could silently change. The integration still has to be a good citizen (respect rate limits, handle the occasional transient failure gracefully — see the technical doc), but that's normal, expected behavior for talking to any real API, not a defensive posture against an unstable source.

## Getting access is a real, separate blocker

Using melee.gg's API requires a client ID and secret, which melee.gg only issues after the organization running the tournaments authorizes the request. That authorization, plus emailing melee.gg to actually request the credentials, hasn't happened yet as of this writing for Mattia's own league — it depends on someone outside this project (the tournament organizer) and on melee.gg's own support turnaround, so there's no fixed timeline. This is tracked as its own external blocker, not something this document tries to resolve. Because credentials are now a per-league concern (see above), this blocker is specific to whichever league hasn't obtained its credentials yet — a new league joining the platform later goes through the same request process independently, and other leagues aren't affected by any one league's credentials still being pending.

Importantly, that blocker doesn't stop backend development: the integration is built and tested against realistic sample data (fixtures) standing in for the real API responses, so the rest of the system — ingestion, player matching, decklists, scoring — can be built and exercised end-to-end today. Swapping fixtures for the real API later is a configuration change, not a rewrite.

## What we actually pull from melee.gg's API

- **Tournament info** — basic metadata about a stage's tournament (name, date, format, status).
- **Standings** — the final placement of every player once a stage's tournament wraps up.
- **Roster** — who participated, so their names can be matched to (or create) a player record.
- **Decklists** — the cards each player registered for the tournament, when available.
- **Pairings/matches** — round-by-round matchups, confirmed available via the same API (not just assumed, as earlier drafts had it).

## When data is pulled

Data is **not** fetched from melee.gg every time someone visits the website. Instead, syncing happens deliberately — after a stage's tournament has finished, an admin (logged in — see `security-overview.md`) triggers the sync, or a scheduled job checks on it — and the result is stored permanently in Prem League Tracker's own database, per the data model described in `tournament-stage-overview.md`. Everyday visitors to the site are always served from that stored copy, never a live melee.gg call.

## What happens when melee.gg misbehaves

Even a well-documented API can be briefly unavailable or rate-limit a burst of requests. If a sync run hits a transient failure, it retries sensibly before giving up. If it can't get standings for a stage at all, that sync fails safely: nothing gets marked as final/closed, the rest of the site (all previously-synced stages, standings, decklists) keeps working exactly as before, and the failure is logged so an admin can investigate and retry later.

## Related documents

- `tournament-stage-overview.md` — the stage lifecycle this integration feeds into.
- `player-overview.md`, `decklists-overview.md` — the entities populated from melee.gg data.
- `security-overview.md` — the admin login required to trigger a sync.
- `melee-integration-technical.md` — the real API's authentication model, endpoints, retry/rate-limit handling, and the fixture-based mock mode used while credentials are pending.
