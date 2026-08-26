import { Injectable } from '@nestjs/common';

// AuditLogService.record(...) implementation lands in Phase 3 — see
// docs/security-technical.md §Audit logging. Exported from AuthModule so
// every other feature module can inject it, the same way PrismaService is
// injected from the global PrismaModule.
@Injectable()
export class AuditLogService {}
