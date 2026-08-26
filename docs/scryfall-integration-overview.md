# Scryfall Integration — Overview

## What this is

Prem League Tracker shows Magic: The Gathering card images and text (mana cost, type line, oracle text) throughout the site — most visibly on decklist pages, where every card a player registered needs an image and basic info. We don't store or maintain our own card database; instead we look up cards on [Scryfall](https://scryfall.com), the community-standard free API for Magic card data.

## Why Scryfall

Scryfall is the de facto standard third-party MTG data source: it's free, has no API key requirement, covers every printed card and reprint, and returns high-quality card images alongside structured text data. Building or licensing our own card database would be pure overhead for a small league site.

## How it works, in plain terms

1. When a decklist is ingested (see `melee-integration-overview.md` and `decklists-overview.md`), each card name on the list needs to be resolved to a real card: its image, mana cost, and other display data.
2. Rather than calling Scryfall fresh every single time someone views a decklist, we ask Scryfall once per card and then remember the answer. Card data essentially never changes — a card printed years ago still looks and reads the same today — so we keep our own cached copy for about a month before considering it worth re-checking.
3. This cache lives in our Postgres database (see `data-model-overview.md` for why we use Postgres at all), in a dedicated table just for card data.
4. Because Scryfall is a shared public service used by many tools, we're careful not to hammer it with requests — we space out calls and never query them at a pace close to their published limits.

## What happens when things go wrong

MTG cards are messy in a few specific ways, and we've planned for that:

- **A card can't be found.** Maybe a name was misspelled during import, or it's a promo/inofficial printing Scryfall doesn't have. We don't want a single bad card to break the whole decklist page — the deck still displays, with that entry marked as "unresolved" and a plain text fallback instead of an image.
- **Scryfall is temporarily down or slow.** If we already have a cached copy of the card, we keep serving that (even if it's a little stale) rather than showing an error. If we've never seen the card before and Scryfall is unreachable, we show the same "unresolved" fallback as above, and the system will simply try again later.
- **Double-faced cards** (cards with a front and back face, like transform or modal double-faced cards) get both faces stored, so the UI can show either or both sides correctly instead of only half a card.
- **Foreign-language card names** from melee.gg imports (a player might have entered a French or Japanese card name) are resolved using Scryfall's fuzzy/foreign-name search so they still map to the correct English card entry for consistent display.

## Related docs

- `data-model-overview.md` — where the card cache lives and why we persist data at all.
- `decklists-overview.md` — how decklists reference cards resolved through this integration.
- `melee-integration-overview.md` — where card names originate before being resolved here.
