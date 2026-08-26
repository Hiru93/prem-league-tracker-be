import { Module } from '@nestjs/common';
import { MeleeSyncController } from './melee-sync.controller';
import { MeleeSyncService } from './melee-sync.service';

// melee-sync.scheduler.ts (@nestjs/schedule cron, once/day) and
// melee-credentials.provider.ts / melee.client.ts land alongside this in
// Phase 2 — see docs/melee-integration-technical.md and
// docs/backend-architecture-technical.md's module breakdown.
@Module({
  controllers: [MeleeSyncController],
  providers: [MeleeSyncService],
  exports: [MeleeSyncService],
})
export class MeleeIntegrationModule {}
