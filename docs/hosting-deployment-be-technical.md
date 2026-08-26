# Hosting & Deployment (Backend) — Technical

## Status

**Decision record, revised 2026-08-26.** This supersedes the original Render-based plan (API on a Render free web service, Postgres on Neon, no caching layer). Mattia directed the backend onto Vercel end-to-end; the sections below describe the current architecture only. The original Render reasoning is not reproduced here — see git history on this file if it's ever needed.

## Compute: Vercel serverless Function

**Decision**: the NestJS app is deployed as a single Vercel serverless Function, not a long-running container.

**Shape**: a catch-all entrypoint (e.g. `api/index.ts`) wraps Nest's Express adapter and exports a handler compatible with Vercel's Node.js runtime, alongside a `vercel.json` routing all paths to that function. `vercel dev` serves the API locally through the same entrypoint used in production, so local behavior matches deployed behavior. See `backend-architecture-technical.md` for where this entrypoint sits relative to the rest of the app's module structure.

**Reasoning / alternatives considered**:
- **Vercel** (chosen): platform consolidation with the frontend (same provider, same git-integrated deploy flow, one place to manage environment variables/secrets across both services), automatic Preview Deployments per PR, and free-tier Neon/Upstash marketplace integrations that provision and wire connection strings automatically. The known cost is cold starts on idle-then-invoked requests — accepted given ~100 visits/day.
- **Render**: the original choice, rejected on reconsideration. Long-running-container hosting is architecturally more natural for NestJS, but Vercel's tooling consolidation and simpler deploy story outweighed that for a small solo-maintained project with no genuine need for a persistent background process (the melee.gg sync is admin-triggered per stage close, not a continuous process — see `melee-integration-technical.md`).
- **Railway / Fly.io**: same tradeoffs as Render — viable long-running-container alternatives, not chosen for the same platform-consolidation reasoning.

## Database hosting: Neon (managed Postgres, via Vercel)

**Decision**: Postgres runs on Neon's free tier, provisioned through **Vercel's Neon marketplace integration** rather than a standalone Neon account wired in by hand.

**Reasoning**: Neon's free tier has no forced database expiry (unlike Render's own free Postgres, which is deleted after 90 days — incompatible with this project's core requirement of preserving league history indefinitely; see `data-model-technical.md`). Provisioning it through Vercel's marketplace integration means `DATABASE_URL` is injected automatically into each Vercel environment (Production, and per-Preview-deployment) without manual copy-pasting of connection strings. Neon also supports database branching, useful for a disposable Postgres instance in CI (see below) — a bonus, not the deciding factor.

`DATABASE_URL` is TLS-enforced (`sslmode=require`). No additional pooling/proxy infrastructure is introduced given the project's traffic scale (see `data-model-technical.md` and `security-technical.md`).

## Cache hosting: Upstash Redis (via Vercel)

**Decision**: Redis, provisioned through **Vercel's Upstash marketplace integration**, is the caching layer — replacing the originally-planned Postgres `CardCache` table for Scryfall data, and adding a short-TTL cache for computed league standings.

**Reasoning**: Upstash's client is HTTP-based (REST API over HTTPS), which fits a serverless function better than a persistent Redis TCP connection would — no connection pooling concerns across cold starts/concurrent invocations. Provisioning via Vercel's marketplace integration injects `UPSTASH_REDIS_REST_URL`/`UPSTASH_REDIS_REST_TOKEN` automatically per environment, the same pattern as the Neon integration above. Postgres remains the system of record for all ingested domain data (stages, players, placements, decklists) — Redis never holds the only copy of anything; see `scryfall-integration-technical.md` for what's cached and TTLs, and `data-model-technical.md` for what stays in Postgres.

Local development uses a dockerized Redis container (`redis:7-alpine`) as a stand-in for Upstash, wired via a plain `REDIS_URL` rather than the REST client — see `containerization-technical.md`. A single config module selects between the REST client (prod/preview) and the local `REDIS_URL` client (dev) so application code calling the cache is unaffected by which one is active.

## Environments

| Environment | Purpose | Backend host | DB | Cache |
|---|---|---|---|---|
| Local dev | Developer machines | `vercel dev` or `npm run start:dev` | Local Postgres (Docker) or a personal Neon branch | Local Redis (Docker) |
| CI (per-PR) | Lint + test only, no deploy | GitHub Actions runner | Ephemeral test DB (Docker Postgres service container, or a disposable Neon branch) | Not required for unit tests; e2e tests needing cache use a Docker Redis service container |
| Preview | Per-PR/per-push verification | Vercel Preview Deployment (automatic) | Neon (Preview-scoped connection, via marketplace integration) | Upstash (Preview-scoped, via marketplace integration) |
| Staging | Pre-production verification | Vercel Preview Deployment for the `staging` branch, optionally aliased to a stable URL | Neon (staging-scoped) | Upstash (staging-scoped) |
| Production | Live site | Vercel Production Deployment (`master` = Production Branch) | Neon production project | Upstash production instance |

Every push and PR gets its own Vercel Preview Deployment automatically — there's no manual "spin up a second service" step the way there was with Render.

## Deploy flow

Vercel's native GitHub integration is the entire deploy mechanism — no custom GitHub Actions deploy workflow is needed:

1. **Connect the repo**: the Vercel project is linked to `prem-league-tracker-be` via Vercel's GitHub App, with `master` configured as the Production Branch.
2. **Every push/PR** → Vercel builds and deploys a Preview Deployment automatically, with its own unique URL, using whichever environment variables are scoped to "Preview" in the Vercel project settings.
3. **Push to `master`** → Vercel automatically builds and promotes to the Production Deployment, using "Production"-scoped environment variables.
4. **Push to `staging`** → gets its own Preview Deployment like any other branch. If a fixed staging URL is wanted, alias it with `vercel alias set <preview-url> staging.<project>.vercel.app` — either run manually or as a small step in `ci.yml` triggered on pushes to `staging` (this only aliases an already-deployed Preview URL; it does not trigger the deploy itself).

`ci.yml` (GitHub Actions) is retained as the only required check — it runs lint/test/e2e against a PR and gates merges into `develop`/`master`, same as before. It does not deploy anything; Vercel's own git integration owns deploys entirely.

**Retired**: the previous `deploy-production.yml` and `deploy-staging.yml` workflows (which POSTed to Render deploy-hook URLs) have been deleted — there is no equivalent step needed with Vercel's git-integrated deploys, and no `RENDER_DEPLOY_HOOK_*` secrets remain in the repo.

## Managing secrets

Environment variables (`DATABASE_URL`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `ADMIN_API_TOKEN`/session secret, `CORS_ORIGIN`, `SCRYFALL_*` config — see `security-technical.md` and `scryfall-integration-technical.md`) are configured directly in the Vercel project's **Settings → Environment Variables**, scoped per environment (Production / Preview / Development), not passed through GitHub Actions — GitHub Actions in this pipeline never touches deploy secrets at all, since it no longer triggers deploys.

The Neon and Upstash marketplace integrations write their own connection variables (`DATABASE_URL`, `UPSTASH_REDIS_REST_URL`/`TOKEN`) into the Vercel project automatically when provisioned; these should not be duplicated or hand-entered.

No secret value is ever written into this documentation, workflow files, or any tracked file in the repo.

## Migrations in the deploy flow

`prisma migrate deploy` runs as part of the Vercel build step (configured via the project's Build Command, e.g. `npx prisma generate && npx prisma migrate deploy && npm run build`), so schema migrations apply automatically immediately before each deploy starts serving traffic. Migrations are never run manually against production outside of this path. Because every Preview Deployment also runs this build step against its own Neon connection, care is needed that Preview environments point at a non-production Neon branch/project — never at the production database.

## Cross-references

- `data-model-technical.md` — why Postgres/Neon are required, and the schema the migrations above apply.
- `scryfall-integration-technical.md` — what Upstash Redis caches, TTLs, and fallback behavior.
- `security-technical.md` — secrets handling principles this pipeline implements (`.env` never committed, env-var-only secrets, least-privilege DB access).
- `backend-architecture-technical.md` — unit vs. e2e testing conventions exercised by `ci.yml`, and where the serverless entrypoint sits in the app structure.
- `containerization-technical.md` — the local Docker Postgres/Redis stand-ins for Neon/Upstash.
