# Security — Technical

## Scope and posture

Expected load is ~100 visits/day (per the architecture memo), but security controls are implemented to the same standard as a higher-traffic service: rate limiting, strict secret handling, environment-scoped CORS, universal input validation, and a least-privilege database user. Low traffic reduces the *likelihood* of certain attack classes (e.g. brute-force volume, DoS impact) but does not reduce the *cost* of getting basics wrong (a leaked DB credential is equally catastrophic regardless of visitor count), so none of these controls are treated as optional or "add later."

## Rate limiting (protecting the API from abuse)

Use `@nestjs/throttler`, applied globally.

```ts
// app.module.ts
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';

@Module({
  imports: [
    ThrottlerModule.forRoot([{
      ttl: 60_000,   // 1 minute window
      limit: 100,    // 100 requests / IP / minute — generous headroom over expected real usage
    }]),
    // ...feature modules
  ],
  providers: [
    { provide: APP_GUARD, useClass: ThrottlerGuard },
  ],
})
export class AppModule {}
```

- The default (100 req/min/IP) is intentionally generous — it exists to blunt accidental abuse (a runaway frontend retry loop, a misconfigured script) and casual scraping, not to rate-limit legitimate browsing.
- Admin/mutation routes (e.g. the melee.gg sync trigger in `MeleeIntegrationModule`, see `melee-integration-technical.md`) get a stricter per-route override via `@Throttle({ default: { limit: 5, ttl: 60_000 } })`, since these are expensive (they call out to melee.gg and Scryfall) and are only ever invoked by the league admin.
- Throttler state is in-memory (default storage) — acceptable given the app runs as a single instance (see `hosting-deployment-be-technical.md`); if the app ever scaled to multiple instances, a shared store (e.g. Redis) would be required for the limit to hold across instances. Not needed at current scale.

## Secrets handling

- All secrets (database connection string, any future third-party API keys) are read exclusively from environment variables via `@nestjs/config`. No secret is ever hardcoded in source.
- Local development uses a `.env` file, which **must** be listed in `.gitignore` — this is a hard requirement, not a suggestion. Verify `.env` (and `.env.*.local` variants) appear in the repo's `.gitignore` before any secret-bearing `.env` file is ever created locally.
- A checked-in `.env.example` (with placeholder/empty values, never real secrets) documents which env vars the app expects, so a new contributor knows what to fill in without ever seeing a real credential.
- In production (Render) and CI (GitHub Actions), secrets are supplied by the platform's own secret storage (Render's environment variable dashboard; GitHub Actions' `secrets.*` context) — never by committing a populated `.env` file anywhere, including to a private repo. See `hosting-deployment-be-technical.md` for exactly how each secret is configured per environment.
- If a secret is ever accidentally committed, the fix is rotation (issue a new credential and revoke the old one), not just removal from a future commit — git history retains the old value regardless.

## CORS policy

Configured via Nest's built-in CORS support in `main.ts`, driven by an env var so the same code works in both environments:

```ts
// main.ts
const allowedOrigin = process.env.CORS_ORIGIN; // e.g. "https://<user>.github.io" in production

app.enableCors({
  origin: process.env.NODE_ENV === 'production'
    ? allowedOrigin
    : true, // permissive in development — any origin, so local frontend dev servers on any port work
  methods: ['GET', 'POST', 'PATCH', 'DELETE'],
  credentials: false, // no cookies/session credentials are used by this API (see auth note below)
});
```

- **Production**: `CORS_ORIGIN` is set to the exact deployed GitHub Pages origin for the frontend (e.g. `https://<org-or-user>.github.io`), and only that origin is allowed. No wildcard (`*`) in production.
- **Development**: `origin: true` (reflects the request's own origin) so local frontend development isn't blocked by CORS friction. This is safe because it only applies when `NODE_ENV !== 'production'`, i.e. never on the deployed instance.
- The API does not use cookies for authentication (see below), so `credentials: false` is correct and avoids the additional CORS complexity credentialed requests require.

## Input validation

- A global `ValidationPipe` is registered once in `main.ts`:

```ts
app.useGlobalPipes(new ValidationPipe({
  whitelist: true,          // strip unknown properties
  forbidNonWhitelisted: true, // reject requests containing unknown properties, rather than silently dropping them
  transform: true,          // auto-transform payloads into DTO class instances (enables type coercion, e.g. string -> number)
}));
```

- Every controller route that accepts a body, query, or param object beyond simple path ids defines a DTO class using `class-validator` decorators (`@IsString()`, `@IsInt()`, `@Min()`, `@IsOptional()`, etc.), imported per-feature-module (e.g. `stages/dto/create-stage.dto.ts`). No controller handler accepts a bare untyped `any`/`Record<string, unknown>` body.
- This applies uniformly across all feature modules (`StagesModule`, `PlayersModule`, `DecklistsModule`, `MeleeIntegrationModule`) — see `backend-architecture-technical.md` for the module layout these DTOs live inside.

## Authentication / admin actions

- The public read endpoints (stage listings, standings, decklists, player pages) require no authentication — this is a public league tracker site.
- Mutation/admin endpoints (triggering a melee.gg sync — see `melee-integration-technical.md`) are protected by a simple shared-secret bearer token guard (an `ADMIN_API_TOKEN` env var compared against an `Authorization: Bearer <token>` header via a Nest `CanActivate` guard). This is intentionally lightweight (no user accounts/sessions/OAuth) because the only "admin" is the league organizer and the operation is infrequent (once per stage close). If the admin surface grows, revisit in favor of a proper auth scheme — not needed for MVP scope.

## Database hardening

- The Neon Postgres connection string (including credentials) is supplied exclusively via the `DATABASE_URL` env var — never embedded in code or config files. See `hosting-deployment-be-technical.md` for how this is set per environment (local `.env`, Render environment variables).
- **Least-privilege DB user**: the application connects using a Postgres role scoped to the application database only, with privileges limited to what Prisma needs on the app's own schema (`SELECT`/`INSERT`/`UPDATE`/`DELETE` on app tables, plus DDL rights only for the role/connection used to run migrations — ideally a separate, more privileged "migration" connection string used only in CI/CD, distinct from the runtime app connection, if Neon's plan/tooling makes that practical; a single appropriately-scoped role is an acceptable simplification at this project's scale if maintaining two roles becomes overhead).
- **No direct public DB exposure**: the Postgres instance is reachable only via Neon's connection string (TLS-enforced by Neon by default) from the backend service; no port is exposed to the public internet by our own infrastructure, and no database credentials or connection details are ever surfaced through any API response or client-facing configuration.
- Neon connections use SSL/TLS by default (`sslmode=require` in the connection string) — this is Neon's default behavior and must not be disabled.

## Dependency hygiene

- `npm audit` (or equivalent) is run as part of CI alongside lint/test (see `hosting-deployment-be-technical.md`'s CI/CD description) to catch known-vulnerable dependencies before they reach production; a failing high-severity audit blocks merge in the same way a failing test does.

## Cross-references

- `hosting-deployment-be-technical.md` — exactly how `DATABASE_URL`, `CORS_ORIGIN`, `ADMIN_API_TOKEN`, and deploy secrets are configured per environment (local, CI, Render staging/production).
- `backend-architecture-technical.md` — module structure that DTOs and guards attach to.
- `data-model-technical.md` — schema the least-privilege DB role has scoped access to.
