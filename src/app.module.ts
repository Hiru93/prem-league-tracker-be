import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { AppController } from './app.controller';
import { PrismaModule } from './prisma/prisma.module';
import { LeaguesModule } from './leagues/leagues.module';
import { AuthModule } from './auth/auth.module';
import { AdminUsersModule } from './admin-users/admin-users.module';
import { StagesModule } from './stages/stages.module';
import { PlayersModule } from './players/players.module';
import { DecklistsModule } from './decklists/decklists.module';
import { ScoringModule } from './scoring/scoring.module';
import { MeleeIntegrationModule } from './melee-integration/melee-integration.module';
import { ScryfallModule } from './scryfall/scryfall.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    // See docs/security-technical.md §Rate limiting — 100 req/min/IP default,
    // stricter per-route throttles applied via @Throttle() on admin/mutation routes.
    ThrottlerModule.forRoot([
      {
        ttl: 60_000,
        limit: 100,
      },
    ]),
    PrismaModule,
    LeaguesModule,
    AuthModule,
    AdminUsersModule,
    StagesModule,
    PlayersModule,
    DecklistsModule,
    ScoringModule,
    MeleeIntegrationModule,
    ScryfallModule,
  ],
  controllers: [AppController],
  providers: [
    {
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
  ],
})
export class AppModule {}
