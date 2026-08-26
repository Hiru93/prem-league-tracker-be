# Backend Architecture — Technical

## Stack

- **Framework**: NestJS (TypeScript), running as a standard long-running Node HTTP process (not serverless — see `hosting-deployment-be-technical.md` for why).
- **ORM**: Prisma. **Decision, explicit**: Prisma is chosen over TypeORM for this project because (a) its generated `PrismaClient` types are derived directly from `schema.prisma`, giving compile-time safety on every query without hand-maintained entity decorators drifting from the DB; (b) its migration workflow (`prisma migrate dev` / `prisma migrate deploy`) is more predictable and has better DX for a solo-maintained project than TypeORM's migration generation; (c) Prisma's query builder is simpler to reason about for the relatively simple relational queries this project needs (no need for TypeORM's more complex QueryBuilder/ActiveRecord duality). TypeORM remains a reasonable alternative but is not used here.
- **Database**: Postgres via Neon — see `data-model-technical.md` for schema and `hosting-deployment-be-technical.md` for hosting.
- **Validation**: `class-validator` + `class-transformer` DTOs, enforced via a global `ValidationPipe` — see `security-technical.md`.

## Module breakdown

```
src/
  app.module.ts
  main.ts

  prisma/
    prisma.module.ts        # @Global() — exports PrismaService
    prisma.service.ts       # extends PrismaClient, implements OnModuleInit/OnModuleDestroy

  leagues/                  # LeaguesModule — League CRUD (creation is SUPER_ADMIN-only), the league-picker landing list
    leagues.module.ts
    leagues.controller.ts
    leagues.service.ts
    dto/

  auth/                     # AuthModule — admin login/refresh/logout, AdminAuthGuard, LeagueAccessGuard, AuditLogService
    auth.module.ts
    auth.controller.ts      # POST /admin/auth/login|refresh|logout|logout-all
    auth.service.ts
    admin-auth.guard.ts
    league-access.guard.ts
    audit-log.service.ts    # AuditLogService.record(...) — see security-technical.md §Audit logging
    dto/

  admin-users/               # AdminUsersModule — SUPER_ADMIN-only creation of ORGANIZER/MODERATOR AdminUsers + AdminLeagueAccess grants
    admin-users.module.ts
    admin-users.controller.ts # POST /admin/users
    admin-users.service.ts
    dto/

  stages/                   # StagesModule — tournament stages (tappe), now league-scoped (GET /leagues/:leagueSlug/stages)
    stages.module.ts
    stages.controller.ts
    stages.service.ts
    dto/

  players/                  # PlayersModule — player roster, profile, and the player-merge admin action
    players.module.ts
    players.controller.ts
    players.service.ts
    dto/

  decklists/                # DecklistsModule — decklists + entries, resolved via ScryfallModule
    decklists.module.ts
    decklists.controller.ts
    decklists.service.ts
    dto/

  scoring/                  # ScoringModule — placement -> points formula, standings aggregation (per Season, excluding isFinal/excluded stages)
    scoring.module.ts
    scoring.service.ts      # no controller of its own; consumed by StagesModule/PlayersModule
    config/scoring.config.ts

  melee-integration/        # MeleeIntegrationModule — per-League ingestion from melee.gg: auto-include, scheduled + manual sync
    melee-integration.module.ts
    melee-sync.controller.ts   # POST /admin/leagues/:leagueId/sync, PATCH .../stages/:stageId/excluded
    melee-sync.service.ts
    melee-sync.scheduler.ts    # @nestjs/schedule cron, once/day, iterates every League
    melee-credentials.provider.ts # decrypts a League's melee.gg credentials at point of use
    melee.client.ts

  scryfall/                 # ScryfallModule — Scryfall card resolution + cache
    scryfall.module.ts
    scryfall.service.ts
    scryfall.client.ts

  common/
    guards/
    interceptors/
    filters/
    pipes/
```

This maps directly onto the other documentation areas: `data-model-technical.md`/`security-technical.md` (LeaguesModule, AuthModule, AdminUsersModule), `tournament-stage-technical.md` (StagesModule), `player-technical.md` (PlayersModule), `decklists-technical.md` (DecklistsModule), `league-scoring-technical.md` (ScoringModule), `melee-integration-technical.md` (MeleeIntegrationModule), and this repo's `scryfall-integration-technical.md` (ScryfallModule). The full persisted schema behind all of them is defined once in `data-model-technical.md` — modules do not each own a separate schema, they share the one Prisma schema and one Postgres database.

**New modules, 2026-08-26 (second corner-case review)**:
- **`LeaguesModule`** — owns `League` CRUD. Creation (`POST /admin/leagues`) is `SUPER_ADMIN`-only (a league's melee.gg org/credentials are sensitive enough that only the super-admin registers a new tenant), but the module also serves the public league-picker landing list (`GET /leagues`) and per-league lookup by slug used by every other league-scoped route.
- **`AuthModule`** — owns the whole login/refresh/logout flow (`security-technical.md`'s Login/Refresh/Logout flows) and both authorization guards (`AdminAuthGuard`, `LeagueAccessGuard`), since guards and the token flow they depend on are tightly coupled and easiest to reason about in one module. `AuditLogService` is folded into `AuthModule` rather than split into a separate `AuditLogModule` — audit logging is overwhelmingly triggered by the same guarded-mutation call sites `AuthModule` already owns the guards for, and at this project's scale a dedicated module would just be an extra import everywhere for no isolation benefit; every other feature module injects `AuditLogService` from `AuthModule`'s exports the same way it injects `PrismaService` from the global `PrismaModule`.
- **`AdminUsersModule`** — separate from `AuthModule` because it owns a different concern: `SUPER_ADMIN`-only creation of `ORGANIZER`/`MODERATOR` `AdminUser` rows and granting their initial `AdminLeagueAccess` (`POST /admin/users`), not authentication itself. Kept apart so `AuthModule` stays focused on "prove who you are" while `AdminUsersModule` handles "who gets to exist as an admin at all."

## Layering convention (per feature module)

**Controller**
- Owns route definitions, HTTP status codes, and request/response DTO shapes.
- Declares `@UseGuards()` / `@UsePipes()` where a route needs auth or extra validation beyond the global pipe.
- Contains **no business logic** — it calls exactly one service method per route and maps the result to a response DTO.

**Service**
- Contains business logic (e.g. `ScoringService.computeStandings(stageId)`).
- Is the only layer that calls other modules' services (constructor-injected).
- Is the layer unit tests target directly (see Testing below).

**Data access**
- For most modules, the service calls `PrismaService` directly (`this.prisma.stage.findMany(...)`) — a dedicated repository class is not introduced unless a module's queries become complex enough to warrant isolating them (e.g. `MeleeIntegrationModule`'s multi-step ingestion writes might warrant a small repository helper to keep the service readable). This project intentionally avoids a repository-per-entity ceremony layer Prisma already makes unnecessary for simple CRUD.

## Module dependencies

`PrismaModule` is `@Global()` and imported once in `AppModule`; every other module injects `PrismaService` without re-importing `PrismaModule`.

Dependency direction between feature modules (no cycles):

```
MeleeIntegrationModule ──▶ StagesModule ──▶ ScoringModule
                       ╲              ╲
                        ▼              ▼
                  DecklistsModule   PlayersModule
                       │
                       ▼
                 ScryfallModule
```

- `MeleeIntegrationModule` orchestrates ingestion: on sync, it creates/updates `Stage`, `Placement`, `Player`, and `Decklist`/`DecklistEntry` rows, so it depends on `StagesModule`, `PlayersModule`, and `DecklistsModule`'s services (each module exports the service methods ingestion needs, e.g. `StagesService.upsertStageResult(...)`). It also depends on `LeaguesModule` to resolve a `League`'s `meleeOrgId` and decrypted credentials before a sync run.
- `DecklistsModule` depends on `ScryfallModule` to resolve each `DecklistEntry`'s card data at ingestion time.
- `StagesModule` and `PlayersModule` depend on `ScoringModule` to compute per-stage points and aggregate league standings.
- `ScoringModule` and `ScryfallModule` are "leaf" modules — they depend only on `PrismaModule`, not on other feature modules — so they're easy to unit test and reuse.
- `AuthModule` and `AdminUsersModule` sit outside the ingestion/scoring dependency chain above — every other feature module's controllers depend on `AuthModule`'s exported guards (`AdminAuthGuard`, `LeagueAccessGuard`) and `AuditLogService` for their admin-facing routes, but `AuthModule` itself only depends on `PrismaModule`. `LeaguesModule` is depended on by `MeleeIntegrationModule` (above) and by every league-scoped controller that needs to resolve a `:leagueSlug`/`:leagueId` param, but doesn't depend on any other feature module itself.

Each module's `*.module.ts` explicitly lists `imports: []` for the modules it depends on and `exports: []` for the service(s) it makes available; no module reaches into another module's internals (repository classes, if any, are never exported).

## Configuration

- `@nestjs/config` (`ConfigModule.forRoot({ isGlobal: true })`) loads env vars once in `AppModule`.
- Feature-specific tunables (e.g. `BASE_POINTS` for scoring, Scryfall TTL/rate-limit settings) are read through typed config objects (e.g. `scoring.config.ts` exporting `registerAs('scoring', () => ({ basePoints: Number(process.env.BASE_POINTS ?? 100) }))`), never read from `process.env` ad hoc inside services. See `league-scoring-technical.md` for the scoring config specifically and `security-technical.md` for secrets handling in general.

## Testing conventions

- **Unit tests** (`*.spec.ts`, colocated with the file under test): target services directly, with `PrismaService` and any injected module services mocked (via Nest's `Test.createTestingModule` with `overrideProvider`). This is the primary place business logic (scoring math, ingestion mapping, cache TTL logic) is verified — fast, no DB, no network.
- **E2e tests** (`test/*.e2e-spec.ts`, run via `@nestjs/testing` + `supertest`): boot the full Nest application against a real (test) Postgres database — either a local Docker Postgres or a disposable Neon branch — and exercise actual HTTP routes end-to-end, including the global `ValidationPipe`, guards, and DB round-trips. E2e tests do **not** call the real Scryfall or melee.gg APIs — `ScryfallClient` and `MeleeClient` are swapped for test doubles in the e2e test module so tests are deterministic and don't depend on third-party uptime.
- Both suites run in CI on every PR (see `hosting-deployment-be-technical.md` for the CI pipeline); only unit + e2e + lint are required checks — no deploy happens from a PR.
- Coverage is not gated numerically; the convention is "every service method with a conditional branch or external-failure path has at least one unit test," which matters most for `ScoringModule` (formula edge cases, tie-breaks) and `ScryfallModule`/`MeleeIntegrationModule` (failure/fallback paths).

## Cross-references

- `data-model-technical.md` — full Prisma schema all modules read/write.
- `security-technical.md` — global `ValidationPipe`, guards, CORS, rate limiting applied across all controllers.
- `hosting-deployment-be-technical.md` — how this app is built, tested in CI, and deployed.
- `scryfall-integration-technical.md`, `melee-integration-technical.md`, `league-scoring-technical.md`, `tournament-stage-technical.md`, `player-technical.md`, `decklists-technical.md` — per-module detail for each box in the dependency diagram above.
