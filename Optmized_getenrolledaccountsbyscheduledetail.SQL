-- Index recommendations -- run once, safe to re-run.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_EventReservations_FranchiseScheduleDetailId' AND object_id = OBJECT_ID('events.EventReservations'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_EventReservations_FranchiseScheduleDetailId
        ON events.EventReservations (FranchiseScheduleDetailId) INCLUDE (SubscriptionId, Canceled);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FranchiseScheduleDetails_FranchiseScheduleId' AND object_id = OBJECT_ID('events.FranchiseScheduleDetails'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_FranchiseScheduleDetails_FranchiseScheduleId
        ON events.FranchiseScheduleDetails (FranchiseScheduleId);
END
GO


/****** Object:  StoredProcedure [events].[GetEnrolledAccountsByScheduleDetail] -- OPTIMIZED ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [events].[GetEnrolledAccountsByScheduleDetail](
    @franchiseScheduleDetailId INT = NULL,
    @franchiseScheduleId INT = NULL,
    @franchiseScheduleExclusionId INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @franchiseScheduleExclusionId IS NOT NULL
        SELECT @franchiseScheduleDetailId = FranchiseScheduleDetailId
        FROM events.FranchiseScheduleExclusions
        WHERE Id = @franchiseScheduleExclusionId;

    -- Split into two branches instead of one OR across two different columns --
    -- lets SQL Server seek cleanly on whichever filter is actually being used,
    -- instead of one mixed plan getting reused for both cases.
    IF @franchiseScheduleDetailId IS NOT NULL
    BEGIN
        SELECT (
            SELECT DISTINCT
                s.AccountId,
                s.PersonId
            FROM events.EventReservations er
            JOIN acct.Subscription s
                ON er.SubscriptionId = s.Id
            WHERE er.FranchiseScheduleDetailId = @franchiseScheduleDetailId
              AND er.Canceled IS NULL
              AND s.AccountId IS NOT NULL
              AND s.PersonId IS NOT NULL
            FOR JSON PATH
        );
    END
    ELSE IF @franchiseScheduleId IS NOT NULL
    BEGIN
        SELECT (
            SELECT DISTINCT
                s.AccountId,
                s.PersonId
            FROM events.EventReservations er
            JOIN acct.Subscription s
                ON er.SubscriptionId = s.Id
            JOIN events.FranchiseScheduleDetails fsd
                ON er.FranchiseScheduleDetailId = fsd.Id
            WHERE fsd.FranchiseScheduleId = @franchiseScheduleId
              AND er.Canceled IS NULL
              AND s.AccountId IS NOT NULL
              AND s.PersonId IS NOT NULL
            FOR JSON PATH
        );
    END
END
GO
