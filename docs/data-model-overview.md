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

- League stages (tappe) and each player's final placement in them.
- Players (name, and enough identity info to match them across stages).
- Decklists submitted per player per stage, and the individual cards in them.
- A cache of card art/text looked up from Scryfall, so we don't need to ask Scryfall the same question over and over (see `scryfall-integration-overview.md`).

## Related docs

- `data-model-technical.md` — full reasoning restated as the canonical decision record, plus the concrete schema.
- `tournament-stage-overview.md`, `decklists-overview.md`, `player-overview.md`, `melee-integration-overview.md` — how each entity here is used day to day.
- `scryfall-integration-overview.md` — the card cache specifically.
