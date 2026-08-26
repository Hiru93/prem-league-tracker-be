# Player — Overview

## What this is about

A **player** is a person who has participated in at least one stage of the league. This document describes what identifies a player, how their identity is recognized consistently across multiple stages even when melee.gg reports their name slightly differently each time, and what a player's profile shows.

## Where player identity comes from

Prem League Tracker doesn't have its own signup/account system for players — a player's name comes from however they registered on melee.gg for a given stage. That's convenient (no extra registration step for anyone) but it comes with a real-world wrinkle: the same person can show up in melee.gg's data slightly differently between stages. Common examples:

- "Mattia Gallinaro" in one stage, "mattia gallinaro" (different casing) in another.
- "M. Gallinaro" vs "Mattia Gallinaro".
- Extra whitespace, accented characters typed differently, or a nickname used one time and a full name another.

If Prem League Tracker treated every slightly different spelling as a brand-new player, the same real person could end up fragmented into several "ghost" player records, each with only some of their stages — which would silently break their season point total and their Top-8 standing.

## How we keep one person as one player

When a stage is ingested, every name that comes back from melee.gg is checked against players we already know about, using a normalized form of the name (case/whitespace/accent-insensitive) as a first pass. If it looks like a strong match to an existing player, the new stage result is attached to that existing player rather than creating a duplicate. If it's unclear, the system flags it rather than guessing — a clear affirmative match is required before results are merged into an existing player's history; ambiguous cases wait for a human (the league organizer) to confirm which player they belong to.

## What a player profile shows

A player's profile aggregates everything the league knows about that person across every stage they've played:

- Their display name (the version of their name we consider "canonical" for display purposes).
- Every stage they've attended, with their placement and points from each.
- Their running season point total and stage count (the same numbers used for league standings — see `league-scoring-overview.md`).
- Their decklists across stages, where available.

## Related documents

- `league-scoring-overview.md` — how a player's per-stage results become their season total.
- `tournament-stage-overview.md` — where per-stage player results originate.
- `player-technical.md` — identity matching/merging rules and data model.
