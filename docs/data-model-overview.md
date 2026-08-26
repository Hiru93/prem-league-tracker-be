# Data Model — Overview

## The question this doc answers

Does Prem League Tracker need its own database, or could the backend just fetch everything live from melee.gg whenever someone visits the site? **Answer: yes, it needs its own database — specifically Postgres.** This page explains why in plain terms; `data-model-technical.md` restates the reasoning in full and gives the concrete schema.

## Why we don't just fetch live from melee.gg every time

1. **melee.gg pages can change or disappear after the fact.** Tournament organizers can edit or remove results after a stage has finished. If our site always asked melee.gg fresh, our league history could silently change or vanish later. Once a stage is done, we take a permanent snapshot of it — that snapshot becomes the source of truth for our league history, independent of whatever happens to the original melee.gg page.
2. **melee.gg isn't built to be hammered with requests.** It's a tournament platform, not a public data API with generous published limits. If every visitor to our site triggered a fresh melee.gg fetch, we'd risk being throttled or blocked. Instead, we fetch each stage's data once (when it closes), store it, and serve every subsequent page view from our own storage.
3. **Overall standings need math across every stage.** A player's league position depends on their points from every stage they've played. Recomputing that from scratch by calling melee.gg live, every time, for every visitor, is slow and fragile. Storing each stage's results once means computing standings is just fast arithmetic over our own database.
4. **The site gets very little traffic** (roughly 100 visits/day), so whatever we use to store this data can be small and cheap. We don't need anything fancy — no read replicas, no heavy caching infrastructure — just a small managed Postgres database.

Given all of that, Postgres is the right tool: a mature, well-understood relational database, with excellent free managed hosting options (see `hosting-deployment-be-overview.md` for why we specifically use Neon), that's more than capable of handling this project's scale.

## What we store

- **Leagues** — the platform can run more than one league at once (see "Leagues: running more than one at a time" below). Every other piece of data ultimately traces back to exactly one league.
- **Seasons** — a fresh league edition runs each year, so every stage (and the season-ending final) belongs to a specific season, which in turn belongs to exactly one league — rather than there being one league forever.
- League stages (tappe) and each player's final placement in them, each scoped to a season. The season-ending final tournament is stored the same way as a stage, but flagged separately since its results are shown but don't count toward league points (see `league-scoring-overview.md`). A stage can also be marked excluded by an admin — see below.
- Players (name, and enough identity info to match them across stages).
- Decklists submitted per player per stage, and the individual cards in them, plus a visibility setting per season (decklists default to hidden until their stage closes — see `decklists-overview.md`).
- Admin accounts for whoever operates the site — Mattia, and other league organizers/moderators — used to log in and unlock admin-only actions (see `security-overview.md`).
- A cache of card art/text looked up from Scryfall, so we don't need to ask Scryfall the same question over and over (see `scryfall-integration-overview.md`).

## Leagues: running more than one at a time

Prem League Tracker isn't just Mattia's one league forever — it's a small platform that can host **several leagues concurrently**, each completely independent of the others. A league is the top-level container: it has its own name, its own melee.gg organization (the tournaments it pulls stage results from), and its own set of admins. One league's seasons, stages, players, and decklists never mix with another's.

Concretely, a **league** owns:

- Its own melee.gg organization — every tournament run under that org is what feeds this league's stages (see `melee-integration-overview.md` for how that sync works).
- That org's melee.gg API credentials, stored encrypted (see `security-overview.md`) — never shared with another league, even if the same person happens to organize both.
- Its own sequence of seasons. Unlike the original single-league design, more than one league can have an "active" season running at the same time — this is genuinely multiple leagues operating side by side, not one league with a swappable data source.
- Its own admins, who can only manage the league(s) they've been explicitly given access to (see "Admin roles" below).

Visitors discover leagues through a landing page that lists the currently-active ones; picking a league takes you into its own standings, stages, and decklists, with stable URLs scoped to that league from then on.

## Admin roles

Every admin account now has one of three roles, reflecting that admin work is scoped per league rather than being one flat "the admin" concept:

- **Super-admin** — exactly one account (Mattia's). Has access to everything, everywhere: every league, every season, every admin account. It's the only role that can create new leagues and create/assign other admins. There's no button or API call that can ever create a second super-admin account — that can only happen by someone with direct database access, on purpose.
- **Organizer** — a full admin for whichever league(s) they've been assigned to: triggering syncs, correcting data, managing seasons, merging duplicate players, toggling decklist visibility, and so on, but only within their assigned league(s).
- **Moderator** — the same day-to-day abilities as an organizer within their assigned league(s), except a moderator can't grant admin access to anyone else. Only the super-admin can do that, which avoids a compromised organizer or moderator account being used to add more admins.

See `security-overview.md` for the full login/authentication model these roles sit inside.

## Related docs

- `data-model-technical.md` — full reasoning restated as the canonical decision record, plus the concrete schema.
- `tournament-stage-overview.md`, `decklists-overview.md`, `player-overview.md`, `melee-integration-overview.md` — how each entity here is used day to day.
- `scryfall-integration-overview.md` — the card cache specifically.
- `security-overview.md` — the admin login system that gates sensitive actions.
