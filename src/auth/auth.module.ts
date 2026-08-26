import { Module } from '@nestjs/common';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { AdminAuthGuard } from './admin-auth.guard';
import { LeagueAccessGuard } from './league-access.guard';
import { AuditLogService } from './audit-log.service';

@Module({
  controllers: [AuthController],
  providers: [AuthService, AdminAuthGuard, LeagueAccessGuard, AuditLogService],
  exports: [AuthService, AdminAuthGuard, LeagueAccessGuard, AuditLogService],
})
export class AuthModule {}
