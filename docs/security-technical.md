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
- Admin scope grew beyond a single infrequent action (per the 2026-08-26 corner-case review): it now covers triggering a melee.gg sync, resolving an `UnresolvedPlayerMatch`, and toggling `Season.decklistVisibilityMode` — for Mattia today, and potentially other trusted moderators later. A shared-secret bearer token no longer fits (no per-admin identity, no way to revoke one moderator without rotating the secret for everyone), so this is a **proper login system** backed by the `AdminUser` model (`data-model-technical.md`), not a bearer-token endpoint.

### Login flow

```
POST /admin/auth/login
```

```ts
interface AdminLoginRequest {
  email: string;
  password: string;
}

interface AdminLoginResponse {
  accessToken: string;   // JWT, signed with ADMIN_JWT_SECRET
  expiresIn: number;     // seconds
}
```

- Passwords are stored as `AdminUser.passwordHash` (bcrypt or argon2, never plaintext, never logged) and verified with a constant-time compare (the hashing library's own `compare` function).
- On success, a JWT is issued via `@nestjs/jwt`, signed with `ADMIN_JWT_SECRET` (env var, never hardcoded), short-lived (e.g. 12h `expiresIn`), carrying `{ sub: adminUser.id, role: adminUser.role }` as claims. `AdminUser.lastLoginAt` is updated.
- On failure (unknown email, wrong password), the response is a generic `401 Unauthorized` with no indication of which part was wrong, to avoid user enumeration. Login attempts also go through the global rate limiter (above), with a stricter per-route throttle (e.g. `@Throttle({ default: { limit: 5, ttl: 60_000 } })`) to blunt brute-force attempts specifically.
- The token is returned in the response body, not set as a cookie — the admin frontend stores it (e.g. in memory / `sessionStorage`) and sends it back as `Authorization: Bearer <accessToken>` on subsequent admin requests. This keeps `credentials: false` in the CORS policy above accurate and sidesteps CSRF concerns that cookie-based sessions would introduce.

### Guarding admin routes

A Nest `AdminAuthGuard` (backed by `passport-jwt` or an equivalent manual `CanActivate` verifying the JWT signature/expiry against `ADMIN_JWT_SECRET`) protects every admin-only route:

```ts
@UseGuards(AdminAuthGuard)
@Post('admin/stages/:stageId/sync')
syncStage(...) { /* see tournament-stage-technical.md §2 */ }

@UseGuards(AdminAuthGuard)
@Post('admin/player-matches/:id/resolve')
resolvePlayerMatch(...) { /* see player-technical.md §4 */ }

@UseGuards(AdminAuthGuard)
@Patch('admin/seasons/:seasonId/decklist-visibility')
setDecklistVisibility(...) { /* see decklists-technical.md §4, data-model-technical.md (Season.decklistVisibilityMode) */ }
```

- `AdminAuthGuard` rejects with `401 Unauthorized` for a missing/invalid/expired token — no route falls back to unauthenticated access.
- `AdminUser.role` is available on the request (via the guard populating `request.adminUser` from the verified JWT claims) for any future action that needs to distinguish `ORGANIZER` from `MODERATOR`; no such distinction is enforced yet — all `AdminUser` accounts can perform all three guarded actions today, reserving `role` for future use as the admin surface grows.
- These are exactly the three actions the corner-case review calls out as needing login-gated access: triggering a melee.gg sync, resolving an ambiguous player match, and toggling decklist visibility.

## Database hardening

- The Neon Postgres connection string (including credentials) is supplied exclusively via the `DATABASE_URL` env var — never embedded in code or config files. See `hosting-deployment-be-technical.md` for how this is set per environment (local `.env`, Render environment variables).
- **Least-privilege DB user**: the application connects using a Postgres role scoped to the application database only, with privileges limited to what Prisma needs on the app's own schema (`SELECT`/`INSERT`/`UPDATE`/`DELETE` on app tables, plus DDL rights only for the role/connection used to run migrations — ideally a separate, more privileged "migration" connection string used only in CI/CD, distinct from the runtime app connection, if Neon's plan/tooling makes that practical; a single appropriately-scoped role is an acceptable simplification at this project's scale if maintaining two roles becomes overhead).
- **No direct public DB exposure**: the Postgres instance is reachable only via Neon's connection string (TLS-enforced by Neon by default) from the backend service; no port is exposed to the public internet by our own infrastructure, and no database credentials or connection details are ever surfaced through any API response or client-facing configuration.
- Neon connections use SSL/TLS by default (`sslmode=require` in the connection string) — this is Neon's default behavior and must not be disabled.

## Dependency hygiene

- `npm audit` (or equivalent) is run as part of CI alongside lint/test (see `hosting-deployment-be-technical.md`'s CI/CD description) to catch known-vulnerable dependencies before they reach production; a failing high-severity audit blocks merge in the same way a failing test does.

## Cross-references

- `hosting-deployment-be-technical.md` — exactly how `DATABASE_URL`, `CORS_ORIGIN`, and deploy secrets are configured per environment (local, CI, Render staging/production); `ADMIN_JWT_SECRET` follows the same per-environment secret pattern described there even though that doc predates this section.
- `backend-architecture-technical.md` — module structure that DTOs and guards attach to.
- `data-model-technical.md` — schema the least-privilege DB role has scoped access to, including the `AdminUser` model this section authenticates against.
- `tournament-stage-technical.md`, `player-technical.md`, `decklists-technical.md` — the three admin actions `AdminAuthGuard` protects.
