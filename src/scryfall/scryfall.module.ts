import { Module } from '@nestjs/common';
import { ScryfallService } from './scryfall.service';

// scryfall.client.ts and scryfall-cache.service.ts land alongside this in
// Phase 2 — see docs/scryfall-integration-technical.md.
@Module({
  providers: [ScryfallService],
  exports: [ScryfallService],
})
export class ScryfallModule {}
