/****** Object:  StoredProcedure [product].[GetParkCalendar]  -- OPTIMIZED VERSION ******/
-- No business logic was changed. Same filters, same results.
-- Only how the work gets done is different (less repeated computation).
-- See the [REVIEW] comment below for one existing quirk in the original
-- code that I preserved as-is rather than "fixing", since it changes behavior.

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [product].[GetParkCalendar] (
    @parkId UNIQUEIDENTIFIER,
    @date DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    WITH reservations AS (
        -- How many active subscription reservations are already sitting against each attendance limit
        SELECT
            COUNT(*) Count,
            tr.ParkAttendanceLimitId
        FROM acct.Subscription s
        JOIN acct.TicketReservationSubscription trs
            ON trs.SubscriptionId = s.Id
        JOIN acct.TicketReservation tr
            ON trs.TicketReservationId = tr.Id
        JOIN park.ParkAttendanceLimit pal
            ON tr.ParkAttendanceLimitId = pal.Id
        WHERE s.SubscriptionStatusId IN (100, 200, 301, 1000) /* Pending, Active, Used, Presales */
            AND tr.IsActive = 1
            AND pal.ValidFrom >= sysdatetimeoffset()
            AND pal.ParkId = @parkId
        GROUP BY tr.ParkAttendanceLimitId
    ), categories as (
        -- Which categories (ride sessions / open play / etc.) run on this day of week for this park
        -- [REVIEW] cm.Deleted IS NULL sits in the WHERE clause, which turns the LEFT JOIN into
        -- an effective INNER JOIN (categories with no non-deleted CrowdMeter row get dropped
        -- entirely instead of showing up with a NULL crowd level). Kept exactly as original --
        -- flagging so your team can confirm this is intended before anyone touches it later.
        SELECT
            cat.Id,
            cat.IsOpenPlay,
            cat.Name,
            cat.Description,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships,
            cat.StartDate,
            cat.EndDate,
            cs.Id CategoryScheduleId,
            cs.DayOfWeek,
            cs.StartHour,
            cm.LevelId CrowdMeterLevelId
        FROM product.Category cat
        JOIN product.CategorySchedule cs
            ON cat.Id = cs.CategoryId
        LEFT JOIN booking.CrowdMeter cm
            ON cs.StartHour = cm.StartHour
                AND cs.DayOfWeek = cm.DayOfWeek
                AND cm.ParkId = cat.ParkId
        WHERE cat.ParkId = @parkId
            AND cm.Deleted IS NULL
            AND cat.IsActive = 1
            AND cs.IsActive = 1
            AND cs.DayOfWeek = (DATEPART(WEEKDAY, @date) - 1)
            AND NOT EXISTS (
                SELECT 1
                FROM product.CategoryScheduleBlackout csb
                WHERE csb.CategoryId = cat.Id
                    AND @date BETWEEN csb.StartDate AND csb.EndDate
            )
    ), tickets as (
        -- Cheapest regular ticket price per category/timeslot (excludes Parent, 5&Under, Spectator)
        SELECT
            cat.Id,
            cat.StartHour,
            IIF(IsOpenPlay = 1, 'Park Tickets', cat.Name) Name,
            cat.Description,
            MIN(tis.Amount) Amount,
            cat.CrowdMeterLevelId,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships,
            cat.IsOpenPlay
        FROM product.Ticket tic
        JOIN categories cat
            ON tic.CategoryId = cat.Id
        JOIN product.TicketSchedule tis
            ON tis.TicketId = tic.Id
                AND tis.CategoryScheduleId = cat.CategoryScheduleId
        WHERE tic.IsActive = 1
            AND tic.DisplayInStore = 1
            AND tic.ProductLevelId NOT IN (6, 9, 10) /* Parent, 5 & Under, Spectator */
            AND tis.Quantity > 0
            AND IIF(cat.StartDate < tic.StartDate, tic.StartDate, cat.StartDate) <= @date
            AND IIF(cat.EndDate > tic.EndDate, tic.EndDate, cat.EndDate) >= @date
            AND NOT EXISTS (
                SELECT 1
                FROM product.TicketScheduleBlackout tsb
                WHERE tsb.TicketId = tic.Id
                    AND @date BETWEEN tsb.StartDate AND tsb.EndDate
            )
        GROUP BY
            cat.Id,
            cat.StartHour,
            cat.Name,
            cat.Description,
            cat.CrowdMeterLevelId,
            cat.IsOpenPlay,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships
    ), fAUTickets as (
        -- Same as tickets above, but specifically for "5 & Under" (FAU) ticket type
        SELECT
            cat.Id,
            cat.StartHour,
            IIF(IsOpenPlay = 1, 'Park Tickets', cat.Name) Name,
            cat.Description,
            MIN(tis.Amount) Amount,
            cat.CrowdMeterLevelId,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships,
            cat.IsOpenPlay
        FROM product.Ticket tic
        JOIN categories cat
            ON tic.CategoryId = cat.Id
        JOIN product.TicketSchedule tis
            ON tis.TicketId = tic.Id
                AND tis.CategoryScheduleId = cat.CategoryScheduleId
        WHERE tic.IsActive = 1
            AND tic.DisplayInStore = 1
            AND tic.ProductLevelId = 9 /* 5 & Under */
            AND tis.Quantity > 0
            AND IIF(cat.StartDate < tic.StartDate, tic.StartDate, cat.StartDate) <= @date
            AND IIF(cat.EndDate > tic.EndDate, tic.EndDate, cat.EndDate) >= @date
            AND NOT EXISTS (
                SELECT 1
                FROM product.TicketScheduleBlackout tsb
                WHERE tsb.TicketId = tic.Id
                    AND @date BETWEEN tsb.StartDate AND tsb.EndDate
            )
        GROUP BY
            cat.Id,
            cat.StartHour,
            cat.Name,
            cat.Description,
            cat.CrowdMeterLevelId,
            cat.IsOpenPlay,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships
    ), bundles as (
        -- Cheapest bundle price per category/timeslot (combo-type products only, BundleTypeId = 1)
        SELECT
            cat.Id,
            cat.StartHour,
            IIF(IsOpenPlay = 1, 'Park Tickets', cat.Name) Name,
            cat.Description,
            MIN(bs.Amount) Amount,
            cat.CrowdMeterLevelId,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships,
            cat.IsOpenPlay
        FROM product.Bundle bun
        JOIN categories cat
            ON bun.CategoryId = cat.Id
        JOIN product.BundleSchedule bs
            ON bs.BundleId = bun.Id
                AND bs.CategoryScheduleId = cat.CategoryScheduleId
        WHERE bun.IsActive = 1
            AND bun.BundleTypeId = 1
            AND bs.Quantity > 0
            AND IIF(cat.StartDate < bun.StartDate, bun.StartDate, cat.StartDate) <= @date
            AND IIF(cat.EndDate > bun.EndDate, bun.EndDate, cat.EndDate) >= @date
            AND NOT EXISTS (
                SELECT 1
                FROM product.BundleScheduleBlackout bsb
                WHERE bsb.BundleId = bun.Id
                    AND @date BETWEEN bsb.StartDate AND bsb.EndDate
            )
        GROUP BY
            cat.Id,
            cat.StartHour,
            cat.Name,
            cat.Description,
            cat.CrowdMeterLevelId,
            cat.IsOpenPlay,
            cat.ExcludeOpenPlay,
            cat.ExcludeMemberships
    ), consolidation AS (
        -- Merge tickets + FAU tickets + bundles into one list, one row per category/timeslot,
        -- keeping the cheapest price where the same category shows up more than once.
        -- [OPT] Original wrapped this in both SELECT DISTINCT *and* GROUP BY -- the two were
        -- doing the same de-duplication job twice. GROUP BY alone already removes duplicates,
        -- so DISTINCT was pure extra work with nothing left for it to do. Removed it.
        SELECT
            c.Id,
            c.StartHour,
            c.Name,
            c.Description,
            MIN(c.Amount) Amount,
            c.CrowdMeterLevelId,
            c.ExcludeOpenPlay,
            c.ExcludeMemberships,
            c.IsOpenPlay
        FROM (
            SELECT
                COALESCE(t.Id, ft.Id) Id,
                COALESCE(t.StartHour, ft.StartHour) StartHour,
                COALESCE(t.Name, ft.Name) Name,
                COALESCE(t.Description, ft.Description) Description,
                COALESCE(t.Amount, ft.Amount) Amount,
                COALESCE(t.CrowdMeterLevelId, ft.CrowdMeterLevelId) CrowdMeterLevelId,
                COALESCE(t.ExcludeOpenPlay, ft.ExcludeOpenPlay) ExcludeOpenPlay,
                COALESCE(t.ExcludeMemberships, ft.ExcludeMemberships) ExcludeMemberships,
                COALESCE(t.IsOpenPlay, ft.IsOpenPlay) IsOpenPlay
            FROM tickets t
            FULL JOIN fautickets ft
                ON ft.StartHour = t.StartHour
                    AND t.Id = ft.Id
            UNION ALL
            SELECT
                Id,
                StartHour,
                Name,
                Description,
                Amount,
                CrowdMeterLevelId,
                ExcludeOpenPlay,
                ExcludeMemberships,
                IsOpenPlay
            FROM bundles
        ) c
        GROUP BY c.Id, c.Name, c.StartHour, c.Description, c.CrowdMeterLevelId, c.ExcludeOpenPlay, c.IsOpenPlay, c.ExcludeMemberships
    ),
    -- [OPT] These two used to be correlated subqueries re-run for every single output row
    -- (once per pal/category combo). Computed once here instead, then just looked up below.

    -- For each timeslot, what's the cheapest Open Play price (used to keep only the
    -- cheapest Open Play option per timeslot, same as original logic).
    cheapestOpenPlayPerSlot AS (
        SELECT StartHour, MIN(Amount) MinAmount
        FROM consolidation
        WHERE IsOpenPlay = 1
        GROUP BY StartHour
    ),
    -- Which timeslots have at least one category that says "exclude open play here"
    slotsExcludingOpenPlay AS (
        SELECT DISTINCT StartHour
        FROM consolidation
        WHERE ExcludeOpenPlay = 1
    )
    SELECT CONVERT(NVARCHAR(MAX), (
        SELECT
            pal.Id ParkAttendanceLimitId,
            cat.Id CategoryId,
            cat.Name,
            cat.Description,
            CASE WHEN cat.ExcludeOpenPlay = 0 THEN cat.CrowdMeterLevelId END CrowdMeterLevelId,
            CONVERT(DATETIME2, pal.ValidFrom) ValidFrom,
            CASE WHEN cat.IsOpenPlay = 0 THEN CONVERT(DATETIME2, pal.ValidTo) END ValidTo,
            cat.Amount,
            CONVERT(INT, FLOOR(pal.MaxAttendanceLimit - pal.EventBookings - pal.EmployeeCount - pal.TransientBookings)) -
                ISNULL(res.Count, 0) - ISNULL(mrCount.Count, 0) AS AvailableCapacity,
            cat.ExcludeMemberships,
            cat.IsOpenPlay,
            c.Code CurrencyCode,
            cc.ConversionRate
        FROM park.ParkAttendanceLimit pal
        JOIN park.Park pk
            ON pal.ParkId = pk.Id
        JOIN park.ParkEx pe
            ON pe.ParkId = pk.Id
        JOIN consolidation cat
            ON cat.StartHour = pal.ValidFromHour
        LEFT JOIN reservations res
            ON res.ParkAttendanceLimitId = pal.Id
        LEFT JOIN currency.Currency c
            ON c.Id = pk.CurrencyId
        LEFT JOIN currency.CurrencyConversion cc
            ON c.Id = cc.ToCurrencyId
                AND cc.FromCurrencyId = 1 /* USD */
                AND pe.PaymentProcessorVersion = 1 /* Braintree only */
        LEFT JOIN (
            -- Count MemberReservations for the given date and park
            SELECT
                pal.Id AS ParkAttendanceLimitId,
                COUNT(*) AS Count
            FROM acct.MemberReservation mr
            JOIN park.ParkAttendanceLimit pal ON mr.ParkAttendanceLimitId = pal.Id
            WHERE CONVERT(DATE, pal.ValidFrom) = @date
                AND pal.ParkId = @parkId
                AND mr.IsActive = 1
            GROUP BY pal.Id
        ) mrCount ON mrCount.ParkAttendanceLimitId = pal.Id
        -- [OPT] Pre-computed lookups joined in below instead of correlated subqueries per row
        LEFT JOIN cheapestOpenPlayPerSlot copp
            ON copp.StartHour = cat.StartHour
        LEFT JOIN slotsExcludingOpenPlay seop
            ON seop.StartHour = cat.StartHour
        WHERE pk.Id = @parkId
            /* Consolidate Open Play to cheapest option -- same rule as before, just using
               the pre-computed cheapest-per-slot lookup instead of a per-row subquery */
            AND (cat.IsOpenPlay = 0 OR copp.MinAmount = cat.Amount)
            /* Filter open play on timeslots that exclude open play -- same rule as before,
               using the pre-computed "which slots exclude open play" lookup */
            AND (seop.StartHour IS NULL OR
                cat.ExcludeOpenPlay = 1 OR NOT EXISTS (
                    SELECT 1
                    FROM consolidation cats
                    WHERE cats.StartHour = cat.StartHour
                        AND cats.Id = cat.Id
                )
            )
            AND cat.Amount IS NOT NULL
            AND CONVERT(DATE, pal.ValidFrom) = @date
            AND DATEADD(MINUTE, 30, pal.ValidFrom) >= SYSDATETIMEOFFSET()   -- add in 30 min buffer
            AND pk.IsActive = 1
            AND pal.MaxAttendanceLimit > 0
            AND (cat.IsOpenPlay = 0 OR @date <= DATEADD(DAY, 30, CONVERT(DATE, SYSDATETIMEOFFSET() AT TIME ZONE pk.Timezone)))
        ORDER BY pal.ValidFrom
        FOR JSON PATH
    )) data

END
GO
