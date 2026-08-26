# Decklists — Overview

## What this is about

Every player in a stage brings a deck — a list of Magic: The Gathering cards with quantities, split into a main deck and (optionally) a sideboard. This document describes how Prem League Tracker stores and displays those decklists once they're pulled in from melee.gg.

## What a decklist is, in plain terms

A decklist is simply "how many copies of which card." For example: 4 Lightning Bolt, 2 Wrath of God, 1 Teferi, Hero of Dominaria, and so on, for the main deck, plus a separate (usually shorter) list for the sideboard. What Prem League Tracker adds on top of the raw list is card detail — artwork, mana cost, card type — sourced from Scryfall, a well-known public MTG card database, so decklists can be displayed nicely rather than as plain text.

## Where decklists come from

Decklists are submitted by players on melee.gg as part of tournament registration, and Prem League Tracker pulls them in as part of the same stage-ingestion process described in `tournament-stage-overview.md`. Because melee.gg is a third party we don't control, decklist data can be messy in ways outside our control:

- A player might submit their decklist late, or not at all.
- melee.gg may expose more than one version of a decklist if a player updates it before/between rounds (e.g. sideboard swaps as part of a per-round submission flow some tournament formats use). Prem League Tracker treats a specific version as "the" decklist for a stage — see the technical doc for exactly which one and why.
- Card names might not match Scryfall's naming exactly (typos, alternate names, foreign-language cards), or a decklist might be partially unreadable.

## What we show

For a given player in a given stage, Prem League Tracker shows their submitted decklist as a readable card list, with card art and details pulled from Scryfall wherever we can match a card name. If a decklist is missing, incomplete, or a particular card entry couldn't be matched to a known card, that's shown transparently rather than silently hidden or guessed at.

## When decklists become visible

Showing a decklist too early can leak strategy mid-event — an opponent could scout a later pairing's deck before playing them. By default, a player's decklist for a stage stays hidden until that stage closes, then becomes visible automatically. An admin can override this per season (for example, to make a past/archived season's decklists visible right away) from the admin panel — see `security-overview.md` for how admin access works. While a decklist is hidden, the site (and the API behind it) simply doesn't serve its card list to the public; only its existence/status ("submitted, not yet visible") is shown.

## Related documents

- `tournament-stage-overview.md` — the stage a decklist belongs to.
- `player-overview.md` — whose decklist it is.
- `security-overview.md` — the admin login that gates the visibility override.
- `decklists-technical.md` — storage model, Scryfall matching, visibility enforcement, and edge case handling.
