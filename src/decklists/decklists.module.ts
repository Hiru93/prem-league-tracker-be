import { Module } from '@nestjs/common';
import { DecklistsController } from './decklists.controller';
import { DecklistsService } from './decklists.service';

@Module({
  controllers: [DecklistsController],
  providers: [DecklistsService],
  exports: [DecklistsService],
})
export class DecklistsModule {}
