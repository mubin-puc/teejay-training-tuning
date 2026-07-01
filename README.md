/****** Object:  StoredProcedure [booking].[GetPackagesByPark]    Script Date: 7/1/2026 11:42:35 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE   PROCEDURE [booking].[GetPackagesByPark] (
    @cookieId UNIQUEIDENTIFIER,
    @parkId UNIQUEIDENTIFIER,
    @preferredDate DATE,
    @requiresHandicapAccessible BIT,
    @usePercentAllocation BIT
) AS

BEGIN
    DECLARE @startDate DATE = DATEADD(D, -2, @preferredDate),
        @oneBack DATE = DATEADD(D, -1, @preferredDate),
        @oneAhead DATE = DATEADD(D, 1, @preferredDate),
        @endDate DATE = DATEADD(D, 2, @preferredDate);

    /* Get DayOfWeek range from @PreferredDate */
    SET DATEFIRST 7;
    DECLARE @preferences TABLE (
        Date      DATE NOT NULL,
        DayOfWeek INT  NOT NULL
    );
    INSERT INTO @preferences (Date, DayOfWeek)
    VALUES (@startDate, DATEPART(DW, @startDate) - 1),
           (@oneBack, DATEPART(DW, @oneBack) - 1),
           (@preferredDate, DATEPART(DW, @preferredDate) - 1),
           (@oneAhead, DATEPART(DW, @oneAhead) - 1),
           (@endDate, DATEPART(DW, @endDate) - 1);

    WITH Bundles AS (
        SELECT
            p.Date,
            b.ProductLevelId,
            b.MinPrice,
            b.Quantity,
            b.Name,
            b.Description,
            b.BundleTypeId
        FROM @preferences p
        OUTER APPLY (
            SELECT
                t.ProductLevelId,
                MIN(bs.Amount) MinPrice,
                bp.Quantity,
                b.Name,
                b.Description,
                b.BundleTypeId
            FROM product.Bundle b
            JOIN product.BundleSchedule bs
                ON bs.BundleId = b.Id
            JOIN product.CategorySchedule cs
                ON cs.Id = bs.CategoryScheduleId
            JOIN product.Category c
                ON cs.CategoryId = c.Id
            JOIN product.BundleProduct bp
                ON bp.BundleId = b.Id
            LEFT JOIN product.Ticket t
                ON bp.TicketId = t.Id
            JOIN product.Bundle rb
                ON rb.RelatedBundleId = b.Id /* Filter party bundles without addons */
            WHERE b.ParkId = @parkId
                AND b.BundleTypeId = 2 /* Party */
                AND (ISNULL(b.StartDate, c.StartDate) <= @startDate
                    OR ISNULL(b.StartDate, c.StartDate) <= @oneBack
                    OR ISNULL(b.StartDate, c.StartDate) <= @preferredDate)
                AND (ISNULL(b.EndDate, c.EndDate) >= @endDate
                    OR ISNULL(b.EndDate, c.EndDate) >= @preferredDate)
                AND cs.DayOfWeek = p.DayOfWeek
                AND bs.Quantity > 0
                AND c.IsActive = 1
                AND b.IsActive = 1
                AND rb.IsActive = 1
                AND (@usePercentAllocation = 0
                    OR (( /* Fully allocated */
                        SELECT SUM(bp.PercentAllocation)
                        FROM product.BundleProduct bp
                        WHERE bp.BundleId = b.Id
                        GROUP BY bp.BundleId
                    ) = 100
                    AND (
                        SELECT SUM(rbp.PercentAllocation)
                        FROM product.BundleProduct rbp
                        WHERE rbp.BundleId = rb.Id
                        GROUP BY rbp.BundleId
                    ) = 100))
            GROUP BY t.ProductLevelId,
                bp.Quantity,
                b.Name,
                b.Description,
                b.BundleTypeId
        ) b
    ),
    Schedules
    AS (
        SELECT
            p.DayOfWeek,
            pl.Ordinal,
            MIN(r.Price) MinPrice
        FROM booking.Schedule s
        JOIN @preferences p
            ON p.Date = s.Date
        LEFT JOIN booking.ScheduleDetails sd
            ON s.Id = sd.ScheduleId
        LEFT JOIN booking.Resource r
            ON sd.ResourceId = r.Id
        LEFT JOIN prdct.ProductLevel pl
            ON sd.MinimumProductLevelId = pl.Id
        WHERE s.ParkId = @parkId
            AND s.Date BETWEEN @startDate AND @endDate
            /* Active only */
            AND s.Deleted IS NULL
            AND sd.Deleted IS NULL
            AND r.IsActive = 1
            AND r.Deleted IS NULL
            AND (@usePercentAllocation = 0 OR ( /* Fully allocated */
                SELECT lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0)
                FROM booking.LocationResourceType lrt
                LEFT JOIN booking.ParkResourceTypeModifier prtm
                    ON prtm.ResourceTypeId = lrt.ResourceTypeId
                        AND prtm.ParkId = lrt.LocationId
                        AND prtm.Deleted IS NULL
                WHERE lrt.LocationId = @parkId
                    AND r.ResourceTypeId = lrt.ResourceTypeId
                GROUP BY lrt.PercentAllocation, prtm.ResourceTypeId
            ) = 100)
            AND (r.IsHandicapAccessible = @requiresHandicapAccessible OR @requiresHandicapAccessible = 0)
            /* Not booked */
            AND NOT EXISTS(
                SELECT 1
                FROM booking.Booking b
                LEFT JOIN booking.Cart c
                    ON b.Id = c.BookingId
                WHERE b.ScheduleDetailId = sd.Id
                    AND b.Deleted IS NULL
                    AND b.Canceled IS NULL
                    AND (
                        c.CookieId IS NULL
                        OR @cookieId <> c.CookieId
                    )
            )
            /* Not in a (non-expired) cart */
            AND NOT EXISTS(
                SELECT 1
                FROM booking.Cart c
                LEFT JOIN booking.Booking b
                    ON c.BookingId = b.Id
                WHERE c.ScheduleDetailId = sd.Id
                    AND (DATEADD(MINUTE, 25, c.TimeBegan) > GETDATE() OR c.TimeBegan IS NULL)
                    AND c.CookieId <> @cookieId
                    AND b.Canceled IS NULL
                    AND c.CartReleased IS NULL
            )
            GROUP BY p.DayOfWeek,
                pl.Ordinal),
    Templates
        AS (
            SELECT
                p.DayOfWeek,
                pl.Ordinal,
                MIN(r.Price) MinPrice
            FROM @preferences p
            JOIN booking.Template t
                ON (t.StartDate <= p.Date
                    AND t.EndDate >= p.Date)
                    OR (t.StartDate IS NULL
                        AND t.EndDate IS NULL
                        AND t.IsDefault = 1)
            LEFT JOIN booking.TemplateDetails td
                ON t.Id = td.TemplateId
            LEFT JOIN booking.Resource r
                ON td.ResourceId = r.Id
            LEFT JOIN prdct.ProductLevel pl
                ON td.MinimumProductLevelId = pl.Id
            WHERE t.ParkId = @parkId
                /* Not scheduled */
                AND p.DayOfWeek NOT IN (
                    SELECT s.DayOfWeek
                    FROM Schedules s
                )
                /* Active only */
                AND t.IsActive = 1
                AND t.Deleted IS NULL
                AND (td.Id IS NULL
                    OR (td.Deleted IS NULL
                        AND r.IsActive = 1
                        AND r.Deleted IS NULL
                        AND (r.IsHandicapAccessible = @requiresHandicapAccessible
                            OR @requiresHandicapAccessible = 0)
                    )
                )
                AND (@usePercentAllocation = 0 OR ( /* Fully allocated */
                    SELECT lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0)
                    FROM booking.LocationResourceType lrt
                    LEFT JOIN booking.ParkResourceTypeModifier prtm
                        ON prtm.ResourceTypeId = lrt.ResourceTypeId
                            AND prtm.ParkId = lrt.LocationId
                            AND prtm.Deleted IS NULL
                    WHERE lrt.LocationId = @parkId
                        AND r.ResourceTypeId = lrt.ResourceTypeId
                    GROUP BY lrt.PercentAllocation, prtm.ResourceTypeId
                ) = 100)
            GROUP BY p.DayOfWeek,
                pl.Ordinal
        )

    SELECT CONVERT(NVARCHAR(MAX),(
        SELECT (
            SELECT
                b.Name,
                b.Description,
                b.BundleTypeId,
                (
                    SELECT ISNULL(MIN(b.MinPrice) + MIN(r.MinPrice), 0) Amount
                    FOR JSON PATH
                ) BundleSchedules,
                (
                    SELECT
                        b.Quantity,
                        b.ProductLevelId [ParkProduct.ProductLevelId],
                        pl.Name [ParkProduct.ProductLevel.Name],
                        pl.WebColor [ParkProduct.ProductLevel.WebColor],
                        pl.Ordinal [ParkProduct.ProductLevel.Ordinal],
                        ppd.ProductLevelDescription [ParkProduct.ProductLevel.ParkProductLevel.ProductLevelDescription]
                    FOR JSON PATH
                ) BundleProducts
            FROM @preferences p
            LEFT JOIN Bundles b
                ON b.Date = p.Date
            LEFT JOIN prdct.ProductLevel pl
                ON b.ProductLevelId = pl.Id
            LEFT JOIN product.ParkProductLevel ppd
                ON ppd.ProductLevelId = b.ProductLevelId
                    AND ppd.ParkId = @parkId
            OUTER APPLY (
                SELECT s.MinPrice MinPrice
                FROM Schedules s
                WHERE pl.Ordinal <= ISNULL(s.Ordinal, pl.Ordinal)
                UNION ALL
                SELECT t.MinPrice MinPrice
                FROM Templates t
                WHERE pl.Ordinal <= ISNULL(t.Ordinal, pl.Ordinal)
            ) r
            WHERE b.ProductLevelId IS NOT NULL
            GROUP BY b.ProductLevelId,
                pl.Ordinal,
                pl.Name,
                pl.WebColor,
                ppd.ProductLevelDescription,
                b.Quantity,
                b.Name,
                b.Description,
                b.BundleTypeId
            HAVING MIN(b.MinPrice) > 0
                AND ISNULL(MIN(b.MinPrice) + MIN(r.MinPrice), 0) > 0
            ORDER BY pl.Ordinal
            FOR JSON PATH
        ) Bundles,
        (
            SELECT
                pa.MinimumProductLevelId,
                pa.Name,
                pa.RequiredHeight
            FROM park.ParkAttraction pa
            JOIN prdct.ProductLevel pl
                ON pl.Id = pa.MinimumProductLevelId
            WHERE pa.ParkId = @parkId
                AND pa.StatusId = 100
                AND pa.Deleted IS NULL
            ORDER BY pl.Ordinal,
                pa.Rank
            FOR JSON PATH
        ) Attractions
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) DATA

END
GO


