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
  credentials: true, // required — the refresh token travels as an httpOnly cookie (see Authentication below), revised 2026-08-26
});
```

- **Production**: `CORS_ORIGIN` is set to the exact deployed frontend origin(s), and only those origins are allowed. No wildcard (`*`) in production — a wildcard is also incompatible with `credentials: true` by spec, so this isn't just a policy choice, it's a hard requirement once cookies are in play.
- **Development**: `origin: true` (reflects the request's own origin) so local frontend development isn't blocked by CORS friction. Reflecting the request origin is compatible with `credentials: true` (unlike a literal `*`), and only applies when `NODE_ENV !== 'production'`.
- **Revised 2026-08-26**: `credentials: false` from the original version of this doc is no longer correct — the refresh-token rotation flow (below) requires an httpOnly cookie, which needs `credentials: true` on both the server's CORS config and every client-side request (`fetch(..., { credentials: 'include' })` / axios `withCredentials: true`) that hits an admin auth endpoint. The short-lived access token still travels as `Authorization: Bearer <accessToken>`, not a cookie — only the refresh token is cookie-based.

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
- **Status (revised 2026-08-26, second corner-case review)**: admin scope grew from 3 actions gated behind a single flat login into a full multi-league, multi-role system — see `data-model-technical.md` for `League`, `AdminUser.role` (`SUPER_ADMIN` / `ORGANIZER` / `MODERATOR`), `AdminLeagueAccess`, `RefreshToken`, and `AuditLog`. This section supersedes the original single-role JWT-in-response-body design entirely; there is no bearer-token-only mode left to fall back to.

### Role model recap

- **`SUPER_ADMIN`**: exactly one account, Mattia's. God-mode — full read/write on every `League`/`Season`/`Stage`/`Decklist`/`Player`/`AdminUser` in the system, and the only role permitted to create `AdminUser` rows and grant `AdminLeagueAccess`. Never created or promoted through any API endpoint or UI action — see **Seeding the super-admin** below.
- **`ORGANIZER`** / **`MODERATOR`**: scoped to whichever `League`(s) they have an `AdminLeagueAccess` row for. Both can perform the same guarded per-league actions today (trigger a sync, resolve a player match, toggle decklist visibility, manage seasons, correct data, merge players); `MODERATOR` is distinguished from `ORGANIZER` only in that it can never itself grant `AdminLeagueAccess` to anyone else (that stays `SUPER_ADMIN`-only, full stop — an `ORGANIZER` cannot add moderators to their own league either, avoiding a privilege-escalation path through a compromised `ORGANIZER` account).

### Seeding the super-admin

- The super-admin `AdminUser` row is created by a one-time seed script (`prisma/seed-super-admin.ts` or equivalent), run manually at initial deploy time, reading `SUPER_ADMIN_EMAIL` and `SUPER_ADMIN_INITIAL_PASSWORD` from env vars and hashing the password with argon2id before insert. The script refuses to run if an `AdminUser` with `role = SUPER_ADMIN` already exists (idempotent, not a reset mechanism).
- No controller route, DTO, or admin-panel action can set `role = SUPER_ADMIN` — this is enforced at the application layer (the admin-user-creation endpoint's DTO only accepts `ORGANIZER`/`MODERATOR` as valid input for `role`, full stop, regardless of who's calling it) so a bug or a compromised super-admin session can't mint a second super-admin through the running app. The only way to create or replace one is direct database access at deploy time.
- After first login, the super-admin should rotate the seeded password through the normal password-change flow (below) — the seed value is a bootstrap credential, not meant to be the long-term password.

### Password hashing

- `AdminUser.passwordHash` uses **argon2id** (via the `argon2` npm package), not bcrypt and not reversible encryption of any kind — password storage needs a one-way, deliberately-slow hash, which is what argon2id is designed for; encryption would imply the plaintext is recoverable, which is never the goal here.
- Verification uses the library's own `argon2.verify()` (constant-time by construction) — never a manual string comparison.

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
  accessToken: string;   // JWT, signed with ADMIN_JWT_SECRET, ~15 min expiry
  expiresIn: number;     // seconds
  leagueAccess: { leagueId: string; leagueName: string; role: 'ORGANIZER' | 'MODERATOR' }[]; // empty for SUPER_ADMIN, whose access is implicit/global
}
```

On success:
- A short-lived (~15 min) access token JWT is issued via `@nestjs/jwt`, signed with `ADMIN_JWT_SECRET`, carrying `{ sub: adminUser.id, role: adminUser.role }` as claims — returned in the response body, stored by the admin frontend in memory (not `localStorage`/`sessionStorage`, to limit XSS exposure), sent back as `Authorization: Bearer <accessToken>`.
- A refresh token (opaque random value, not a JWT) is generated, its **sha256 hash** stored as a new `RefreshToken` row (`familyId` = a fresh UUID for this login), and the **raw** value set as an httpOnly, `Secure`, **`SameSite=None`** cookie (`refresh_token`) with a ~30-day `Max-Age`. The raw value is never persisted anywhere — only its hash.
- **`SameSite=None`, corrected 2026-08-26** (an earlier version of this doc said `SameSite=Strict`, which is wrong for this deployment): the frontend (GitHub Pages) and backend (Vercel) are genuinely different origins/sites, not just different ports — a `SameSite=Strict` (or `Lax`) cookie is simply never attached by the browser to a cross-site `fetch`, which would silently break the refresh flow in production while working fine in any same-site local setup. `SameSite=None` requires `Secure` (HTTPS-only, satisfied — both Vercel and GitHub Pages are HTTPS) and requires the frontend to send `credentials: 'include'` on every request to `/admin/auth/*` and any other cookie-authenticated route.
- **`SameSite=None` CSRF mitigation**: relaxing `SameSite` reopens the cross-site-request risk `Strict`/`Lax` normally close — a third-party site could get a browser to fire a credentialed request at `/admin/auth/refresh` (a same-origin-simple-enough POST that a naive CORS setup wouldn't preflight-block). Mitigate this explicitly: `AuthController`'s cookie-authenticated routes (`refresh`, `logout`, `logout-all`) verify the request's `Origin` header matches `CORS_ORIGIN` exactly server-side and reject (`403`) otherwise, in addition to (not instead of) the CORS policy above — this is sufficient given the API is meant to be called by exactly one trusted frontend origin per environment, not arbitrary third parties.
- `AdminUser.lastLoginAt` is updated and `failedLoginAttempts` reset to 0.
- An `AuditLog` row is written (`action: "LOGIN"`).

On failure (unknown email, wrong password, or account currently locked):
- Response is a generic `401 Unauthorized` with no indication of which part was wrong (avoids user enumeration) — a locked account also returns a generic `401`, not a distinct "locked" status, for the same reason.
- `AdminUser.failedLoginAttempts` increments on a wrong-password failure (not on unknown-email, to avoid leaking which emails exist via timing/counters tied to a nonexistent row). At **5** consecutive failures, `AdminUser.lockedUntil` is set (e.g. `now + 15min`, doubling on subsequent lockouts within a short window for basic backoff); a login attempt against a locked account is rejected before the password is even checked.
- Login attempts additionally go through the global rate limiter, with a stricter per-route throttle (`@Throttle({ default: { limit: 5, ttl: 60_000 } })`) — this is IP-scoped and independent of the per-account lockout above; the two together cover both "one account under attack from many IPs" and "one IP hammering many accounts."

### Refresh flow

```
POST /admin/auth/refresh
```

- Reads the `refresh_token` cookie (no request body needed — the cookie is the credential). Looks up `RefreshToken` by `sha256(rawToken)`.
- **Valid, unrevoked, unexpired**: issue a new access token *and* a new refresh token (new random value, same `familyId`, new `RefreshToken` row), mark the old `RefreshToken` row `revoked = true`, set the new raw value as the replacement cookie. This is rotation-on-every-use — a refresh token is single-use by design.
- **Token not found, already revoked, or expired**: this is the theft-detection path. If the token was found but already `revoked`, treat it as a signal of token theft/replay (someone used a token that was already rotated away) and revoke **every** `RefreshToken` row sharing that `familyId` — the entire session chain, not just this one token — forcing re-login on all of that session's history. Respond `401 Unauthorized` either way.
- No sliding/silent extension beyond rotation — a refresh token's `expiresAt` (~30 days from original issuance, not reset on rotation) is the hard ceiling on how long a session can stay alive without a fresh password login.

### Logout

```
POST /admin/auth/logout        // revokes only the current session's RefreshToken family
POST /admin/auth/logout-all    // revokes every RefreshToken row for this AdminUser, across all devices
```

Both clear the `refresh_token` cookie and write an `AuditLog` row (`"LOGOUT"` / `"LOGOUT_ALL"`). `logout-all` is the "log out everywhere" action from the corner-case review — useful if a device is lost or a session is suspected compromised.

### Guarding and authorizing admin routes

Two layers, applied together:

1. **`AdminAuthGuard`** — verifies the `Authorization: Bearer` JWT's signature/expiry against `ADMIN_JWT_SECRET`, rejects with `401 Unauthorized` if missing/invalid/expired, and populates `request.adminUser` from the verified claims (re-fetching the current `AdminUser` row, not just trusting stale JWT claims, so a role change or account lock takes effect immediately rather than waiting for the access token to expire).
2. **`LeagueAccessGuard`** — for any route scoped to a specific `:leagueId` (or a resource that resolves to one, e.g. `:stageId` → its `Stage.seasonId` → `Season.leagueId`), checks that `request.adminUser.role === 'SUPER_ADMIN'` **or** an `AdminLeagueAccess` row exists for `(adminUser.id, leagueId)`. Rejects with `403 Forbidden` otherwise — distinct from the guard above's `401`, since here the caller *is* authenticated, just not authorized for this league.

```ts
@UseGuards(AdminAuthGuard, LeagueAccessGuard)
@Post('admin/leagues/:leagueId/stages/:stageId/sync')
syncStage(...) { /* see tournament-stage-technical.md §2 */ }

@UseGuards(AdminAuthGuard, LeagueAccessGuard)
@Post('admin/leagues/:leagueId/player-matches/:id/resolve')
resolvePlayerMatch(...) { /* see player-technical.md §4 */ }

@UseGuards(AdminAuthGuard, LeagueAccessGuard)
@Patch('admin/leagues/:leagueId/seasons/:seasonId/decklist-visibility')
setDecklistVisibility(...) { /* see decklists-technical.md §4 */ }

@UseGuards(AdminAuthGuard) // SUPER_ADMIN-only check happens inside — no league to scope this to
@Post('admin/leagues')
createLeague(...) { /* SUPER_ADMIN only: registers a new League + encrypted melee.gg credentials, see below */ }

@UseGuards(AdminAuthGuard) // SUPER_ADMIN-only
@Post('admin/users')
createAdminUser(...) { /* SUPER_ADMIN only: creates an ORGANIZER/MODERATOR AdminUser and grants initial AdminLeagueAccess */ }
```

A small number of routes (`admin/leagues` creation, `admin/users` creation, any cross-league reporting) are `SUPER_ADMIN`-only with no `:leagueId` to scope against — these check `request.adminUser.role === 'SUPER_ADMIN'` directly (a plain condition in the handler or a dedicated `SuperAdminGuard`, either is fine) rather than going through `LeagueAccessGuard`.

## League credential encryption (2026-08-26, second corner-case review)

Multi-league support means melee.gg credentials can no longer be a single pair of env vars — each `League` row holds its own `meleeClientIdEncrypted`/`meleeClientSecretEncrypted` (see `data-model-technical.md`), encrypted at rest.

- **Algorithm**: AES-256-GCM (authenticated encryption — detects tampering, not just confidentiality).
- **Key**: a single master key, `CREDENTIALS_ENCRYPTION_KEY` (32 bytes, base64-encoded in the env var), read via `@nestjs/config` like every other secret — never hardcoded, never logged. One key encrypts every league's credentials; there is no per-league key.
- **Per-value storage**: each encrypted field stores `base64(iv) + ':' + base64(authTag) + ':' + base64(ciphertext)` as a single string column — a fresh random IV is generated per encryption call (never reused), so encrypting the same client secret twice produces different ciphertext.
- **Access pattern**: credentials are decrypted only at the point of use — immediately before building the Basic-auth header for a melee.gg API call (see `melee-integration-technical.md`) — never decrypted for display anywhere in the admin panel (the admin panel shows a masked placeholder, never the real client ID/secret, once set).
- **Key rotation**: if `CREDENTIALS_ENCRYPTION_KEY` ever needs to rotate, every `League`'s credentials must be re-encrypted under the new key in the same operation (decrypt-with-old, encrypt-with-new) — there's no dual-key transition period designed for MVP; this is an accepted operational cost given how rarely it should happen.
- Scoped only to melee.gg credentials, per the corner-case review's explicit decision **not** to field-encrypt anything else (player data is public by design; `AdminUser.email` stays plaintext; passwords/refresh tokens are hashed, which is a different and correct primitive for those).

## Audit logging (2026-08-26, second corner-case review)

An `AuditLog` row (see `data-model-technical.md`) is written for every admin action that changes state or represents a security-relevant event — not for read-only admin requests (e.g. viewing a league's stage list isn't logged, editing one is).

- **Logged**: `LOGIN`, `LOGOUT`, `LOGOUT_ALL`, `LEAGUE_CREATE`, `ADMIN_USER_CREATE`, `ADMIN_LEAGUE_ACCESS_GRANT`, `SEASON_CREATE`/`SEASON_ACTIVATE`/`SEASON_ARCHIVE`, `STAGE_EXCLUDE`/`STAGE_INCLUDE`, `PLACEMENT_CORRECT`, `DECKLIST_ENTRY_CORRECT`, `PLAYER_MERGE`, `DECKLIST_VISIBILITY_TOGGLE`, and any action taken by a `SUPER_ADMIN` against a league they don't hold an explicit `AdminLeagueAccess` row for (tagged distinctly, e.g. `SUPER_ADMIN_OVERRIDE`, so these stand out from routine per-league admin activity in a review).
- **Not logged**: public read endpoints, and admin-side read-only GETs.
- Written via a single `AuditLogService.record(adminUserId, action, targetType?, targetId?, metadata?)` call, invoked from each guarded mutation handler (or a shared interceptor keyed off the route's declared action name, either implementation is acceptable) — not left to individual controllers to remember ad hoc.
- `metadata` captures enough to reconstruct what changed for corrections specifically (e.g. `PLACEMENT_CORRECT` logs the before/after `finalRank`/`points`) — for simpler actions (`LOGIN`, `STAGE_EXCLUDE`) the action name and target are self-explanatory and `metadata` can be omitted.
- No admin-facing UI to *delete* audit log entries exists or should exist — this is an append-only trail. Retention/archival beyond that is out of scope for MVP at this project's scale.

## Database hardening

- The Neon Postgres connection string (including credentials) is supplied exclusively via the `DATABASE_URL` env var — never embedded in code or config files. See `hosting-deployment-be-technical.md` for how this is set per environment (local `.env`, Render environment variables).
- **Least-privilege DB user**: the application connects using a Postgres role scoped to the application database only, with privileges limited to what Prisma needs on the app's own schema (`SELECT`/`INSERT`/`UPDATE`/`DELETE` on app tables, plus DDL rights only for the role/connection used to run migrations — ideally a separate, more privileged "migration" connection string used only in CI/CD, distinct from the runtime app connection, if Neon's plan/tooling makes that practical; a single appropriately-scoped role is an acceptable simplification at this project's scale if maintaining two roles becomes overhead).
- **No direct public DB exposure**: the Postgres instance is reachable only via Neon's connection string (TLS-enforced by Neon by default) from the backend service; no port is exposed to the public internet by our own infrastructure, and no database credentials or connection details are ever surfaced through any API response or client-facing configuration.
- Neon connections use SSL/TLS by default (`sslmode=require` in the connection string) — this is Neon's default behavior and must not be disabled.

## Dependency hygiene

- `npm audit` (or equivalent) is run as part of CI alongside lint/test (see `hosting-deployment-be-technical.md`'s CI/CD description) to catch known-vulnerable dependencies before they reach production; a failing high-severity audit blocks merge in the same way a failing test does.

## Configuration (env vars, this section)

- `ADMIN_JWT_SECRET` — signs/verifies access tokens.
- `CREDENTIALS_ENCRYPTION_KEY` — 32-byte base64 master key for `League` melee.gg credential encryption.
- `SUPER_ADMIN_EMAIL` / `SUPER_ADMIN_INITIAL_PASSWORD` — consumed once by the seed script, not read by the running app afterward.

## Cross-references

- `hosting-deployment-be-technical.md` — exactly how `DATABASE_URL`, `CORS_ORIGIN`, and deploy secrets are configured per environment (local, CI, Vercel preview/production); `ADMIN_JWT_SECRET`/`CREDENTIALS_ENCRYPTION_KEY` follow the same per-environment secret pattern described there.
- `backend-architecture-technical.md` — module structure that DTOs and guards attach to.
- `data-model-technical.md` — `League`, `AdminUser`, `AdminLeagueAccess`, `RefreshToken`, `AuditLog` — the full schema this section implements auth/authorization/logging against.
- `melee-integration-technical.md` — where decrypted `League` credentials are actually used (building the Basic-auth header).
- `tournament-stage-technical.md`, `player-technical.md`, `decklists-technical.md` — the per-league admin actions `AdminAuthGuard` + `LeagueAccessGuard` protect.
