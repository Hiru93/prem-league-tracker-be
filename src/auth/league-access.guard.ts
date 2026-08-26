import { CanActivate, Injectable } from '@nestjs/common';

// Placeholder — real per-league authorization (SUPER_ADMIN bypass or an
// AdminLeagueAccess row for the route's :leagueId) lands in Phase 3.
// See docs/security-technical.md §Guarding and authorizing admin routes.
//
// Deliberately fails closed (throws) rather than returning true — an
// unimplemented guard must never silently grant access.
@Injectable()
export class LeagueAccessGuard implements CanActivate {
  canActivate(): boolean {
    throw new Error(
      'LeagueAccessGuard is not implemented yet — see docs/security-technical.md (Phase 3)',
    );
  }
}
