-- CreateEnum
CREATE TYPE "DecklistVisibilityMode" AS ENUM ('HIDDEN_UNTIL_STAGE_CLOSE', 'ALWAYS_VISIBLE');

-- CreateEnum
CREATE TYPE "AdminRole" AS ENUM ('SUPER_ADMIN', 'ORGANIZER', 'MODERATOR');

-- CreateEnum
CREATE TYPE "StageStatus" AS ENUM ('OPEN', 'IN_PROGRESS', 'CLOSED');

-- CreateEnum
CREATE TYPE "DecklistStatus" AS ENUM ('COMPLETE', 'PARTIAL', 'MISSING');

-- CreateEnum
CREATE TYPE "MatchConfidence" AS ENUM ('EXACT', 'FUZZY', 'UNMATCHED');

-- CreateTable
CREATE TABLE "League" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "meleeOrgId" TEXT NOT NULL,
    "meleeClientIdEncrypted" TEXT NOT NULL,
    "meleeClientSecretEncrypted" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "League_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Season" (
    "id" TEXT NOT NULL,
    "leagueId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "year" INTEGER NOT NULL,
    "isActive" BOOLEAN NOT NULL DEFAULT false,
    "decklistVisibilityMode" "DecklistVisibilityMode" NOT NULL DEFAULT 'HIDDEN_UNTIL_STAGE_CLOSE',
    "startsAt" TIMESTAMP(3),
    "endsAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Season_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AdminUser" (
    "id" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "passwordHash" TEXT NOT NULL,
    "displayName" TEXT,
    "role" "AdminRole" NOT NULL DEFAULT 'ORGANIZER',
    "failedLoginAttempts" INTEGER NOT NULL DEFAULT 0,
    "lockedUntil" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastLoginAt" TIMESTAMP(3),

    CONSTRAINT "AdminUser_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AdminLeagueAccess" (
    "id" TEXT NOT NULL,
    "adminUserId" TEXT NOT NULL,
    "leagueId" TEXT NOT NULL,
    "grantedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "grantedBy" TEXT NOT NULL,

    CONSTRAINT "AdminLeagueAccess_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RefreshToken" (
    "id" TEXT NOT NULL,
    "adminUserId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "deviceLabel" TEXT,
    "ipAddress" TEXT,
    "revoked" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "RefreshToken_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AuditLog" (
    "id" TEXT NOT NULL,
    "adminUserId" TEXT,
    "action" TEXT NOT NULL,
    "targetType" TEXT,
    "targetId" TEXT,
    "metadata" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AuditLog_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Stage" (
    "id" TEXT NOT NULL,
    "seasonId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "sequence" INTEGER NOT NULL,
    "isFinal" BOOLEAN NOT NULL DEFAULT false,
    "excluded" BOOLEAN NOT NULL DEFAULT false,
    "meleeTournamentId" TEXT,
    "meleeUrl" TEXT,
    "status" "StageStatus" NOT NULL DEFAULT 'OPEN',
    "playerCount" INTEGER,
    "scheduledAt" TIMESTAMP(3),
    "closedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Stage_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "StagePairing" (
    "id" TEXT NOT NULL,
    "stageId" TEXT NOT NULL,
    "round" INTEGER NOT NULL,
    "tableNumber" INTEGER,
    "player1Id" TEXT NOT NULL,
    "player2Id" TEXT,
    "result" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "StagePairing_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "StageSyncLog" (
    "id" TEXT NOT NULL,
    "stageId" TEXT NOT NULL,
    "triggeredBy" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    "message" TEXT,
    "startedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "finishedAt" TIMESTAMP(3),

    CONSTRAINT "StageSyncLog_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "StagePlacement" (
    "id" TEXT NOT NULL,
    "stageId" TEXT NOT NULL,
    "playerId" TEXT NOT NULL,
    "placement" INTEGER NOT NULL,
    "fieldSize" INTEGER NOT NULL,
    "points" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "StagePlacement_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Player" (
    "id" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "meleeProfileId" TEXT,
    "mergedIntoId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Player_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "PlayerAlias" (
    "id" TEXT NOT NULL,
    "playerId" TEXT NOT NULL,
    "rawName" TEXT NOT NULL,
    "normalizedName" TEXT NOT NULL,
    "meleeUserId" TEXT,
    "sourceStageId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "PlayerAlias_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "UnresolvedPlayerMatch" (
    "id" TEXT NOT NULL,
    "stageId" TEXT NOT NULL,
    "rawName" TEXT NOT NULL,
    "normalizedName" TEXT NOT NULL,
    "candidatePlayerIds" JSONB NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'PENDING',
    "resolvedPlayerId" TEXT,
    "resolvedBy" TEXT,
    "resolvedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "UnresolvedPlayerMatch_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Decklist" (
    "id" TEXT NOT NULL,
    "stageId" TEXT NOT NULL,
    "playerId" TEXT NOT NULL,
    "meleeDecklistUrl" TEXT,
    "archetypeName" TEXT,
    "meleeDecklistId" TEXT,
    "snapshotLabel" TEXT,
    "isLatest" BOOLEAN NOT NULL DEFAULT true,
    "submittedAt" TIMESTAMP(3),
    "status" "DecklistStatus" NOT NULL DEFAULT 'COMPLETE',
    "rawSource" JSONB,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Decklist_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "DecklistEntry" (
    "id" TEXT NOT NULL,
    "decklistId" TEXT NOT NULL,
    "rawCardName" TEXT NOT NULL,
    "quantity" INTEGER NOT NULL,
    "isSideboard" BOOLEAN NOT NULL DEFAULT false,
    "resolved" BOOLEAN NOT NULL DEFAULT false,
    "matchConfidence" "MatchConfidence" NOT NULL DEFAULT 'UNMATCHED',
    "scryfallCardId" TEXT,

    CONSTRAINT "DecklistEntry_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "League_slug_key" ON "League"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "League_meleeOrgId_key" ON "League"("meleeOrgId");

-- CreateIndex
CREATE INDEX "League_slug_idx" ON "League"("slug");

-- CreateIndex
CREATE INDEX "Season_year_idx" ON "Season"("year");

-- CreateIndex
CREATE INDEX "Season_leagueId_idx" ON "Season"("leagueId");

-- CreateIndex
CREATE UNIQUE INDEX "AdminUser_email_key" ON "AdminUser"("email");

-- CreateIndex
CREATE INDEX "AdminLeagueAccess_leagueId_idx" ON "AdminLeagueAccess"("leagueId");

-- CreateIndex
CREATE UNIQUE INDEX "AdminLeagueAccess_adminUserId_leagueId_key" ON "AdminLeagueAccess"("adminUserId", "leagueId");

-- CreateIndex
CREATE UNIQUE INDEX "RefreshToken_tokenHash_key" ON "RefreshToken"("tokenHash");

-- CreateIndex
CREATE INDEX "RefreshToken_adminUserId_idx" ON "RefreshToken"("adminUserId");

-- CreateIndex
CREATE INDEX "RefreshToken_familyId_idx" ON "RefreshToken"("familyId");

-- CreateIndex
CREATE INDEX "AuditLog_adminUserId_idx" ON "AuditLog"("adminUserId");

-- CreateIndex
CREATE INDEX "AuditLog_targetType_targetId_idx" ON "AuditLog"("targetType", "targetId");

-- CreateIndex
CREATE UNIQUE INDEX "Stage_meleeTournamentId_key" ON "Stage"("meleeTournamentId");

-- CreateIndex
CREATE INDEX "Stage_seasonId_sequence_idx" ON "Stage"("seasonId", "sequence");

-- CreateIndex
CREATE INDEX "StagePairing_stageId_round_idx" ON "StagePairing"("stageId", "round");

-- CreateIndex
CREATE INDEX "StagePlacement_stageId_placement_idx" ON "StagePlacement"("stageId", "placement");

-- CreateIndex
CREATE INDEX "StagePlacement_playerId_idx" ON "StagePlacement"("playerId");

-- CreateIndex
CREATE UNIQUE INDEX "StagePlacement_stageId_playerId_key" ON "StagePlacement"("stageId", "playerId");

-- CreateIndex
CREATE UNIQUE INDEX "Player_meleeProfileId_key" ON "Player"("meleeProfileId");

-- CreateIndex
CREATE INDEX "Player_displayName_idx" ON "Player"("displayName");

-- CreateIndex
CREATE INDEX "PlayerAlias_normalizedName_idx" ON "PlayerAlias"("normalizedName");

-- CreateIndex
CREATE INDEX "PlayerAlias_meleeUserId_idx" ON "PlayerAlias"("meleeUserId");

-- CreateIndex
CREATE UNIQUE INDEX "PlayerAlias_normalizedName_playerId_key" ON "PlayerAlias"("normalizedName", "playerId");

-- CreateIndex
CREATE UNIQUE INDEX "Decklist_meleeDecklistId_key" ON "Decklist"("meleeDecklistId");

-- CreateIndex
CREATE INDEX "Decklist_stageId_playerId_isLatest_idx" ON "Decklist"("stageId", "playerId", "isLatest");

-- CreateIndex
CREATE INDEX "DecklistEntry_decklistId_idx" ON "DecklistEntry"("decklistId");

-- AddForeignKey
ALTER TABLE "Season" ADD CONSTRAINT "Season_leagueId_fkey" FOREIGN KEY ("leagueId") REFERENCES "League"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AdminLeagueAccess" ADD CONSTRAINT "AdminLeagueAccess_adminUserId_fkey" FOREIGN KEY ("adminUserId") REFERENCES "AdminUser"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AdminLeagueAccess" ADD CONSTRAINT "AdminLeagueAccess_leagueId_fkey" FOREIGN KEY ("leagueId") REFERENCES "League"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RefreshToken" ADD CONSTRAINT "RefreshToken_adminUserId_fkey" FOREIGN KEY ("adminUserId") REFERENCES "AdminUser"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AuditLog" ADD CONSTRAINT "AuditLog_adminUserId_fkey" FOREIGN KEY ("adminUserId") REFERENCES "AdminUser"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Stage" ADD CONSTRAINT "Stage_seasonId_fkey" FOREIGN KEY ("seasonId") REFERENCES "Season"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StagePairing" ADD CONSTRAINT "StagePairing_stageId_fkey" FOREIGN KEY ("stageId") REFERENCES "Stage"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StagePairing" ADD CONSTRAINT "StagePairing_player1Id_fkey" FOREIGN KEY ("player1Id") REFERENCES "Player"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StagePairing" ADD CONSTRAINT "StagePairing_player2Id_fkey" FOREIGN KEY ("player2Id") REFERENCES "Player"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StageSyncLog" ADD CONSTRAINT "StageSyncLog_stageId_fkey" FOREIGN KEY ("stageId") REFERENCES "Stage"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StagePlacement" ADD CONSTRAINT "StagePlacement_stageId_fkey" FOREIGN KEY ("stageId") REFERENCES "Stage"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StagePlacement" ADD CONSTRAINT "StagePlacement_playerId_fkey" FOREIGN KEY ("playerId") REFERENCES "Player"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Player" ADD CONSTRAINT "Player_mergedIntoId_fkey" FOREIGN KEY ("mergedIntoId") REFERENCES "Player"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "PlayerAlias" ADD CONSTRAINT "PlayerAlias_playerId_fkey" FOREIGN KEY ("playerId") REFERENCES "Player"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Decklist" ADD CONSTRAINT "Decklist_stageId_fkey" FOREIGN KEY ("stageId") REFERENCES "Stage"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Decklist" ADD CONSTRAINT "Decklist_playerId_fkey" FOREIGN KEY ("playerId") REFERENCES "Player"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "DecklistEntry" ADD CONSTRAINT "DecklistEntry_decklistId_fkey" FOREIGN KEY ("decklistId") REFERENCES "Decklist"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
