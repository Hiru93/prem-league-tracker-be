# Security — Overview

## Why this matters even for a tiny site

Prem League Tracker expects very little traffic (roughly 100 visits/day among friends), but basic security hygiene is treated as a first-class requirement anyway, not an afterthought — because getting it wrong is cheap to avoid up front and expensive to clean up after (a leaked database password, a wide-open CORS policy, or an unvalidated input causing bad data doesn't care how small the audience is).

## What we do

- **Rate limiting**: the API itself limits how many requests a single client can make in a short window, so it can't be trivially overwhelmed or abused, even accidentally (e.g. a buggy script hammering an endpoint).
- **Secrets handling**: things like the database connection string live only in environment variables, injected by the hosting provider or read from a local `.env` file that is never committed to the repository. No password or API key ever appears in source code.
- **CORS policy**: in production, only our actual deployed frontend is allowed to call the API from a browser. In local development, this is relaxed so developers aren't blocked while testing.
- **Input validation**: every piece of data the API accepts from the outside world (query params, request bodies) is checked against an expected shape before any code acts on it, rejecting anything malformed.
- **Database hardening**: the database itself uses a restricted-permission account (not a superuser), isn't reachable directly from the public internet outside of the app's own connection, and its credentials are never hardcoded anywhere.

## Related docs

- `security-technical.md` — the concrete implementation of all of the above.
- `hosting-deployment-be-technical.md` — where secrets are configured for the deployed environment.
- `backend-architecture-overview.md` — how validation fits into the request-handling flow.
