import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import scoringConfig from './config/scoring.config';
import { ScoringService } from './scoring.service';

@Module({
  imports: [ConfigModule.forFeature(scoringConfig)],
  providers: [ScoringService],
  exports: [ScoringService],
})
export class ScoringModule {}
