# League Scoring — Overview

## What this is about

Prem League Tracker follows a **league** ("lega") made up of several **stages** ("tappe"). Each stage is a standalone Magic: The Gathering tournament, run and scored on melee.gg. What this document explains is how a player's performance in a single stage turns into league points, and how those points roll up into the overall league standings across the whole season.

## Why points are scaled by field size

A naive scoring system might just award points by placement ("1st place = 100, 2nd = 90, ..."). That's unfair across stages, because not every stage has the same number of players. Winning a stage with 8 players is a different achievement than winning a stage with 40 players. So the league scores placements *relative to the size of the field they were earned in*: the same relative finish (e.g. "top 10%") is worth more when it was contested against more people.

In practice this means:

- Winning a big stage is worth close to the maximum number of points available.
- Winning a small stage is still rewarded well, but a strong finish (not necessarily 1st) in a big stage can be worth more points than winning a small one.
- Nobody walks away with zero points — simply showing up and finishing the event guarantees at least a small, symbolic amount of points ("participation floor").

## How the season works

- The league runs across multiple stages over a season.
- A player accumulates points from **every stage they attend** — no stage is thrown out or discounted, even a player's worst result still counts.
- At the end of the season, players are ranked by their **total accumulated points** across all stages.
- The **top 8 players** in that ranking qualify for the season-ending final tournament.

## Breaking ties for the Top 8

Because points are summed across an entire season, it's possible for two or more players to finish with exactly the same total. When that happens, the player who **attended more stages** is ranked ahead — the reasoning being that consistent participation across the season should be rewarded over a similar score reached through fewer results.

If two players are tied on both total points *and* number of stages attended, there is currently no further automatic rule to break the tie. This is treated as an open question that the league organizer resolves manually on a case-by-case basis (see `league-scoring-technical.md` for how this is surfaced in the system).

## Related documents

- `tournament-stage-overview.md` — what a single stage looks like and how its results become final.
- `league-scoring-technical.md` — the exact formula, data shapes, and implementation notes.
