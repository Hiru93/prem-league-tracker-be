# Hosting & Deployment (Backend) — Technical

## API hosting: Render (free web service)

**Decision**: the NestJS API is deployed as a Render free-tier "Web Service," built directly from this repo.

**Reasoning / alternatives considered**:
- **Vercel**: rejected. Vercel's model is built around serverless functions (or, for Node, short-lived function invocations behind their routing layer). NestJS is designed as a long-running server process; forcing it into Vercel's serverless model means cold starts on every idle-then-invoked request, per-invocation execution time limits, and no natural place to run a persistent process or scheduled/background job (like a periodic melee.gg sync). It's a poor architectural fit even though Vercel is a fine choice for the frontend static site.
- **Render** (chosen): supports a genuinely long-running Node container on its free tier, has a simple GitHub-integrated deploy flow, and supports deploy hooks that fit cleanly into a GitHub Actions pipeline. Chosen as the default for setup simplicity.
- **Railway**: a viable alternative — similar long-running-container model, comparable free-tier ergonomics, also GitHub-integrated. Not chosen only because Render's setup is marginally simpler for this project's needs; revisit if Render's free tier terms change unfavorably.
- **Fly.io**: also viable — more infrastructure control (regions, machine sizing) but a steeper setup curve (Dockerfile-centric, `fly.toml` configuration, flyctl CLI) than this project needs for a small solo-maintained service. A reasonable choice if more control over deployment topology is ever needed.

**Known tradeoff**: Render's free web services spin down after a period of inactivity and cold-start on the next request (a delay of some seconds). Given ~100 visits/day, this is an accepted tradeoff, not a blocker — occasional first-request latency is acceptable for this audience. If it becomes annoying, Render's paid tier removes the spin-down; not needed at current scale.

## Database hosting: Neon (managed Postgres)

**Decision**: Postgres runs on Neon's free tier, not Render's own managed Postgres add-on.

**Reasoning**: Render's free Postgres databases are automatically deleted 90 days after creation — a hosting policy that is fundamentally incompatible with this project's core requirement of preserving league history indefinitely (see `data-model-technical.md` for why historical integrity is a first-order design goal). Neon's free tier has no such expiry, making it the only one of the two options actually compatible with the project's data-retention needs. Neon also supports database branching (useful for spinning up a disposable Postgres instance for e2e tests in CI — see `backend-architecture-technical.md`'s testing conventions), though branching is a bonus, not the deciding factor.

`DATABASE_URL` (the Neon connection string, TLS-enforced, `sslmode=require`) is the only piece of configuration the app needs to reach the database — no additional pooling/proxy infrastructure is introduced given the project's traffic scale (see `data-model-technical.md` and `security-technical.md`).

## Environments

| Environment | Purpose | Backend host | DB |
|---|---|---|---|
| Local dev | Developer machines | `npm run start:dev` | Local Postgres (Docker) or a personal Neon branch |
| CI (per-PR) | Lint + test only, no deploy | GitHub Actions runner | Ephemeral test DB (Docker Postgres service container, or a disposable Neon branch) |
| Staging (optional) | Pre-production verification | Second Render free web service | Separate Neon project/branch (never shares data with production) |
| Production | Live site | Render web service (primary) | Neon production project |

Staging is optional and only stood up if/when a second free Render service is provisioned; the pipeline below accounts for both cases.

## CI/CD pipeline (GitHub Actions)

Three workflows (or one workflow with conditional jobs — either is acceptable; described here as conceptually separate concerns):

### 1. PR check (runs on every PR targeting `develop` or `master`)

```yaml
name: CI
on:
  pull_request:
    branches: [develop, master]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npx prisma migrate deploy
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/postgres
      - run: npm run test
      - run: npm run test:e2e
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/postgres
      - run: npm audit --audit-level=high
```

This workflow is a **required status check** on `develop` and `master` — it never deploys anything, it only gates merges.

### 2. Deploy to production (runs on push to `master`)

```yaml
name: Deploy Production
on:
  push:
    branches: [master]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Render deploy
        run: curl -X POST "${{ secrets.RENDER_DEPLOY_HOOK_PRODUCTION }}"
```

Render's deploy hook is a pre-authenticated URL that, when POSTed to, triggers a new deploy of the linked service from its latest commit — no Render API token parsing or build logic needs to live in the workflow itself. Alternatively, Render's GitHub auto-deploy integration (deploy automatically whenever the linked branch updates) can be used instead of an explicit deploy-hook step; either is acceptable, but the explicit hook is documented here because it keeps the deploy trigger visible and auditable in the workflow file itself.

### 3. Deploy to staging (runs on push to `staging`, if a staging Render service exists)

```yaml
name: Deploy Staging
on:
  push:
    branches: [staging]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Render deploy (staging)
        run: curl -X POST "${{ secrets.RENDER_DEPLOY_HOOK_STAGING }}"
```

## Managing deploy secrets

Deploy hooks/tokens are never committed to the repository or hardcoded in workflow YAML. They're added by the repo owner through **GitHub → Settings → Secrets and variables → Actions → New repository secret**, e.g.:

- `RENDER_DEPLOY_HOOK_PRODUCTION` — the production service's Render deploy hook URL.
- `RENDER_DEPLOY_HOOK_STAGING` — the staging service's deploy hook URL (only if staging exists).

Workflows reference them exclusively via the `${{ secrets.NAME }}` expression, as shown above — GitHub Actions masks their values in logs automatically. No actual secret value is ever written into this documentation, the workflow files, or any tracked file in the repo — only the secret *names* are referenced.

Application runtime secrets (`DATABASE_URL`, `ADMIN_API_TOKEN`, `CORS_ORIGIN`, `SCRYFALL_*` config — see `security-technical.md` and `scryfall-integration-technical.md`) are separate from deploy secrets: those are configured directly in each Render service's own **Environment** dashboard (production service gets production values, staging service gets its own separate `DATABASE_URL` pointing at a separate Neon project/branch), not passed through GitHub Actions at all, since GitHub Actions in this pipeline only triggers the deploy — Render pulls its own environment configuration when the deploy runs.

## Migrations in the deploy flow

`prisma migrate deploy` runs as part of the Render build/start step (configured in the Render service's build command, e.g. `npm run build && npx prisma migrate deploy`) so schema migrations are applied automatically on every deploy, immediately before the new app version starts serving traffic. Migrations are never run manually against production outside of this path.

## Cross-references

- `data-model-technical.md` — why Postgres/Neon are required, and the schema `prisma migrate deploy` applies.
- `security-technical.md` — secrets handling principles this pipeline implements (`.env` never committed, env-var-only secrets, least-privilege DB access).
- `backend-architecture-technical.md` — unit vs. e2e testing conventions exercised by the CI workflow above.
