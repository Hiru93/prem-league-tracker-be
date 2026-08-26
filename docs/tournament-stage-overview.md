# Tournament Stage — Overview

## What this is about

A **stage** ("tappa") is one tournament event in the league's season, run on melee.gg. This document describes what a stage represents, what information we keep about it, and how it moves through its lifecycle from "not yet played" to "final, part of league history."

Every stage belongs to a **season**, and every season belongs to exactly one **league** — the platform can run several leagues at once, and within a league it runs a fresh season each year, so stages don't just accumulate into one league forever; they're grouped by which season (and which league) they counted toward. See `data-model-overview.md` for the league and season concepts.

## What a stage represents

Think of a stage as a snapshot of one MTG tournament day: who showed up, how they were paired against each other round by round, and where everyone finished at the end. All of that lives natively on melee.gg, the third-party tournament platform the league uses to actually run events. Prem League Tracker doesn't run tournaments itself — it reads the results back out of melee.gg and folds them into the league.

For each stage we care about:

- **Basic info**: which stage of the season this is, when it happened, and a link back to the original melee.gg tournament page.
- **Final placements**: every player who competed, and where they finished — this is what feeds directly into league scoring (see `league-scoring-overview.md`).
- **Pairings**: the round-by-round matchups, kept mainly for reference/history rather than for scoring purposes.

## Why we keep our own copy

melee.gg is a tool the organizer uses to run the event, not a permanent historical archive the league controls. Tournament organizers can edit or delete tournament pages after the fact, and there's no guarantee melee.gg's data will remain available indefinitely or unchanged. Because the league's standings depend on stage results forever (a player's season total includes every stage they've ever played), once a stage is done and its results are official, Prem League Tracker takes its own permanent copy of the important data — placements above all. From that point on, the league's own records are authoritative, not melee.gg's live page.

## The life of a stage

A stage moves through a small number of states over its lifetime:

1. **Open** — the stage has been announced/created in our system (or discovered on melee.gg) but hasn't started yet, or is in the process of players registering.
2. **In progress** — the tournament is actively being played on melee.gg. Standings may still change round to round.
3. **Closed** — the tournament has finished on melee.gg and its results have been pulled in and permanently stored in Prem League Tracker. From this point the stage's placements are treated as final league history and feed into the season standings.

Only a **closed** stage contributes to league standings. A stage that's still open or in progress isn't final yet, so nothing about it can safely be locked into the season's points totals.

## Every tournament in the league's melee.gg org becomes a stage automatically

Stages aren't hand-picked by an admin anymore. As soon as a tournament exists under the league's melee.gg organization, it's automatically pulled in as a stage the next time that league syncs — whether that's the daily automatic check or an admin manually triggering a sync. There's no separate "approve this tournament" step.

Because that's automatic, there's a safety net for the rare case something gets swept in that shouldn't count — a test event run in the same melee.gg organization, for example. An admin can mark that stage **excluded**: it disappears from the public stage list and from standings, but nothing about it is deleted, and un-excluding it later needs no re-sync. This is something an admin fixes after noticing a mistake, not something they have to approve in advance for every tournament.

## The season-ending final is a special kind of stage

At the end of a season, the top 8 players in the standings play a season-ending final tournament. It's tracked and ingested exactly like a regular stage — same lifecycle, same melee.gg sync — but it's flagged as the final and treated differently by scoring: **its results are shown on the site (including a "league champion" callout) but do not add any points to the league standings.** The final is the reward for a good season, not another stage to score. See `league-scoring-overview.md` for how standings are computed and why the final is excluded from that math.

## Related documents

- `league-scoring-overview.md` — how a closed stage's placements turn into points.
- `melee-integration-overview.md` — how data actually gets pulled from melee.gg into a stage record.
- `tournament-stage-technical.md` — data model, lifecycle transitions, and API details.
