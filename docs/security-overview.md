# Security — Overview

## Why this matters even for a tiny site

Prem League Tracker expects very little traffic (roughly 100 visits/day among friends), but basic security hygiene is treated as a first-class requirement anyway, not an afterthought — because getting it wrong is cheap to avoid up front and expensive to clean up after (a leaked database password, a wide-open CORS policy, or an unvalidated input causing bad data doesn't care how small the audience is).

## What we do

- **Rate limiting**: the API itself limits how many requests a single client can make in a short window, so it can't be trivially overwhelmed or abused, even accidentally (e.g. a buggy script hammering an endpoint).
- **Secrets handling**: things like the database connection string live only in environment variables, injected by the hosting provider or read from a local `.env` file that is never committed to the repository. No password or API key ever appears in source code.
- **CORS policy**: in production, only our actual deployed frontend is allowed to call the API from a browser. In local development, this is relaxed so developers aren't blocked while testing.
- **Input validation**: every piece of data the API accepts from the outside world (query params, request bodies) is checked against an expected shape before any code acts on it, rejecting anything malformed.
- **Database hardening**: the database itself uses a restricted-permission account (not a superuser), isn't reachable directly from the public internet outside of the app's own connection, and its credentials are never hardcoded anywhere.
- **Admin login**: the site's sensitive actions — triggering a melee.gg sync, resolving an ambiguous player match, correcting bad data, merging duplicate players, managing seasons, and toggling whether a season's decklists are visible early — are locked behind a real login (email + password, not a shared secret code). Only someone who's logged in as an admin can perform these actions; everyone else only ever sees the public, read-only site.

## Roles and multi-league access (revised 2026-08-26)

The platform can run **more than one league at once** (see `data-model-overview.md`), each with its own admins:

- **A single super-admin account (Mattia's, and only Mattia's)** has god-mode access to everything — every league, every admin, every piece of data. It's created once, outside the running application, at deploy time — there is deliberately no button or API call anywhere in the product that can create a second super-admin, even by accident or by someone with access to another admin account.
- **Regular admins** are attached to the specific league(s) they help run — someone helping organize one league can't see or touch a different league's data unless they're explicitly given access to it, and only the super-admin can grant that access.

## Login security (revised 2026-08-26)

- Passwords are hashed with a modern, deliberately-slow algorithm (argon2id) — never stored in any recoverable form.
- A login session uses two tokens: a short-lived one that expires in minutes, and a longer-lived one (stored in a cookie the browser handles automatically) that's used to quietly get a new short-lived one without asking for a password again — and that longer-lived token rotates every time it's used, so a stolen old copy of it stops working the moment the real session refreshes.
- Repeated failed login attempts trigger a temporary lockout on the account, on top of a general limit on how fast the login endpoint can be hit from any one place — both together, so neither an attacker guessing one password nor an attacker locking someone out on purpose has an easy path.
- Every league's melee.gg credentials are encrypted in the database, not stored as plain text, and are never shown back in the admin panel once saved.
- Sensitive admin actions (creating a league, creating an admin, correcting data, merging players, and more) are recorded in an audit trail — who did what, and when.

## Related docs

- `security-technical.md` — the concrete implementation of all of the above.
- `hosting-deployment-be-technical.md` — where secrets are configured for the deployed environment.
- `backend-architecture-overview.md` — how validation fits into the request-handling flow.
- `data-model-overview.md` — the leagues, admin accounts, and season decklist-visibility setting the login system protects.
