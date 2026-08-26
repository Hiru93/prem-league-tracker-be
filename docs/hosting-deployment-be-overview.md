# Hosting & Deployment (Backend) — Overview

## Where the API runs

The backend API runs on [Render](https://render.com), on their free web service tier. Render runs our NestJS app as a normal, always-running Node process — which suits how NestJS apps work far better than a "serverless functions" platform would.

## Why not a serverless platform like Vercel

Vercel is excellent for static/frontend hosting (and is exactly what we use for the frontend, via GitHub Pages) but is a poor fit for a NestJS backend: serverless functions spin down when idle and cold-start on the next request, have execution time limits, and don't naturally support a persistent server process or background/scheduled jobs (like our melee.gg sync). Render, Railway, and Fly.io all support long-running Node containers on free tiers, which matches what NestJS actually needs. Render is the pick here for its simplicity of setup; Railway and Fly.io remain reasonable alternatives.

## Where the database lives

The Postgres database runs on [Neon](https://neon.tech), a managed Postgres provider with a genuinely free tier. This is a deliberate choice over using Render's own free Postgres offering, because **Render's free Postgres databases are automatically deleted after 90 days** — which would be disastrous for a project whose entire point is preserving league history across an entire season and beyond. Neon's free tier has no such expiry.

## How deployments happen

Code changes go through GitHub Actions:
- Opening a pull request runs the test suite and linter as a required check — nothing gets deployed from a PR.
- Merging to `master` automatically deploys the API to the production Render service.
- Pushing to a `staging` branch (if a second Render service is set up for staging) deploys to that staging environment, so changes can be verified before going live.

The credentials needed to trigger a Render deploy are stored securely in the repository's GitHub Settings, not in the codebase.

## Related docs

- `hosting-deployment-be-technical.md` — full CI/CD pipeline and environment configuration.
- `data-model-overview.md` — why a database is needed at all, which is what Neon hosts.
- `security-overview.md` — how secrets like database credentials and deploy tokens are protected.
