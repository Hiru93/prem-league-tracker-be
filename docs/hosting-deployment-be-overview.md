# Hosting & Deployment (Backend) — Overview

## Where the API runs

The backend API runs on [Vercel](https://vercel.com), as a serverless Function. The NestJS app's Express adapter is wrapped behind a single catch-all handler so Vercel can invoke it like any other serverless entrypoint — see `hosting-deployment-be-technical.md` for the wrapper shape.

## Why not a long-running host like Render

An earlier version of this doc chose Render specifically because NestJS is normally a long-running server process, and serverless platforms are a worse fit for that. Mattia later directed the project onto Vercel anyway, for platform consolidation with the frontend and simpler end-to-end deploy tooling. The tradeoff is accepted, not undone: cold starts on an idle-then-invoked request are expected at this project's traffic scale (~100 visits/day) — the same "occasional first-request latency is fine for this audience" reasoning that previously applied to Render's spin-down now applies to Vercel's cold starts. There is no scheduled/background job requirement that this ownership needs long-running compute for — the melee.gg sync is admin-triggered, not a persistent cron process inside the API itself (see `melee-integration-technical.md`).

## Where the database lives

The Postgres database runs on [Neon](https://neon.tech), provisioned through **Vercel's own Neon marketplace integration** rather than set up separately — this injects `DATABASE_URL` automatically per environment (Production, each Preview deployment). Neon's free tier has no forced expiry, unlike Render's own free Postgres add-on (deleted after 90 days) — the reasoning that ruled out Render's Postgres originally still stands, only the surrounding platform changed.

## Where the cache lives

**Upstash Redis**, provisioned through Vercel's Upstash marketplace integration, is the caching layer — an HTTP-based Redis client, which fits serverless functions better than a persistent TCP connection would. It caches Scryfall card data and short-TTL computed league standings. Postgres remains the system of record for all ingested domain data; Redis is a fast layer in front of it, never the only copy of anything. See `scryfall-integration-technical.md` and `data-model-technical.md`.

## How deployments happen

Vercel's native GitHub integration handles deploys directly — no custom GitHub Actions deploy step is needed:
- Every push and PR gets an automatic **Preview Deployment**.
- Pushing to `master` (configured as Vercel's Production Branch) triggers the **Production Deployment** automatically.
- Pushing to `staging` gets its own Preview Deployment; if a stable staging URL is wanted, it's aliased via `vercel alias`.

`ci.yml` (GitHub Actions) still runs lint/test as a required check on PRs into `develop`/`master` — it gates merges, it doesn't deploy anything. The previous `deploy-production.yml`/`deploy-staging.yml` workflows, written for the Render deploy-hook model, have been retired (see `hosting-deployment-be-technical.md`).

## Related docs

- `hosting-deployment-be-technical.md` — full deploy flow, environment variables, and CI configuration.
- `data-model-overview.md` — why a database is needed at all, which is what Neon hosts.
- `scryfall-integration-technical.md` — what Redis caches and why.
- `security-overview.md` — how secrets like database/cache credentials are protected.
