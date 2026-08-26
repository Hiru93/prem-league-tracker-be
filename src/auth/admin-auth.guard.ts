import { CanActivate, Injectable } from '@nestjs/common';

// Placeholder — real JWT verification (Authorization: Bearer <accessToken>,
// signature/expiry check against ADMIN_JWT_SECRET, request.adminUser
// population) lands in Phase 3. See docs/security-technical.md
// §Guarding and authorizing admin routes.
//
// Deliberately fails closed (throws) rather than returning true — an
// unimplemented guard must never silently grant access.
@Injectable()
export class AdminAuthGuard implements CanActivate {
  canActivate(): boolean {
    throw new Error(
      'AdminAuthGuard is not implemented yet — see docs/security-technical.md (Phase 3)',
    );
  }
}
