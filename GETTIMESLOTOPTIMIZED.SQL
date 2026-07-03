/****** Object: StoredProcedure [booking].[GetTimeslots] Script Date: 7/3/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [booking].[GetTimeslots]
(
    @cookieId UNIQUEIDENTIFIER,
    @parkId UNIQUEIDENTIFIER,
    @selectedDate DATE,
    @productLevelId INT,
    @requiresHandicapAccessible BIT,
    @usePercentAllocation BIT
)
AS
BEGIN
    SET NOCOUNT ON;

    /*============================================================
      1. Initialization
    ============================================================*/
    SET DATEFIRST 7;
    DECLARE @dow INT = DATEPART(dw, @selectedDate) - 1;

    DECLARE @productLevelOrdinal INT;
    SELECT @productLevelOrdinal = Ordinal 
    FROM prdct.ProductLevel 
    WHERE Id = @productLevelId;

    /*============================================================
      2. OPTIMIZED PRE-COMPUTED CTES
         (Major Performance Improvement)
    ============================================================*/
    WITH BundleAllocation AS
    (
        -- Precomputed once instead of repeated subquery
        SELECT BundleId, SUM(PercentAllocation) AS TotalAllocation
        FROM product.BundleProduct GROUP BY BundleId
    ),
    BookedQuantities AS
    (
        -- Replaces 2 OUTER APPLY for booked quantity
        SELECT p.BundleScheduleId, COUNT(*) AS BookedQuantity
        FROM booking.Booking b
        JOIN booking.BookingParticipant p ON p.BookingId = b.Id
        LEFT JOIN booking.Cart c ON c.BookingId = b.Id
        WHERE p.ParticipantTypeId = 1
          AND b.Canceled IS NULL AND b.Deleted IS NULL
          AND (c.CookieId IS NULL OR c.CookieId <> @cookieId)
        GROUP BY p.BundleScheduleId
    ),
    CartQuantities AS
    (
        -- Replaces 2 OUTER APPLY for cart quantity
        SELECT c.BaseBundleScheduleId AS BundleScheduleId, COUNT(*) AS CartQuantity
        FROM booking.Cart c
        LEFT JOIN booking.Booking b ON c.BookingId = b.Id
        WHERE (DATEADD(MINUTE, 25, c.TimeBegan) > GETDATE() OR c.TimeBegan IS NULL)
          AND c.CookieId <> @cookieId AND b.Canceled IS NULL AND c.CartReleased IS NULL
        GROUP BY c.BaseBundleScheduleId
    ),

    /*============================================================
      3. OPTIMIZED Bundles CTE (Main Change)
    ============================================================*/
    Bundles AS
    (
        SELECT 
            b.Id AS BundleId,
            cs.Id AS CategoryScheduleId,
            cs.StartHour,
            CASE WHEN MIN(bPar.Price) IS NOT NULL THEN MIN(bPar.Price) ELSE MIN(bs.Amount) END AS MinPrice,
            bp.Quantity,
            bs.Id AS BundleScheduleId,
            b.IsActive,
            COUNT(1) AS Available,
            ROW_NUMBER() OVER (PARTITION BY cs.StartHour ORDER BY b.IsActive DESC, MIN(bs.Amount)) AS rowNum
        FROM product.Bundle b
        JOIN product.BundleSchedule bs ON bs.BundleId = b.Id
        JOIN product.CategorySchedule cs ON cs.Id = bs.CategoryScheduleId
        JOIN product.Category c ON cs.CategoryId = c.Id
        JOIN product.BundleProduct bp ON bp.BundleId = b.Id
        LEFT JOIN product.Ticket t ON bp.TicketId = t.Id
        LEFT JOIN booking.Cart cart ON bs.Id = cart.BaseBundleScheduleId AND cart.CookieId = @cookieId
        LEFT JOIN booking.BookingParticipant bPar ON cart.BookingId = bPar.BookingId AND bPar.ParticipantTypeId = 1

        -- Using precomputed CTEs instead of OUTER APPLY
        LEFT JOIN BookedQuantities bsbq ON bsbq.BundleScheduleId = bs.Id
        LEFT JOIN CartQuantities bscq ON bscq.BundleScheduleId = bs.Id
        LEFT JOIN BookedQuantities csbq ON csbq.BundleScheduleId = cs.Id
        LEFT JOIN CartQuantities cscq ON cscq.BundleScheduleId = cs.Id

        JOIN BundleAllocation ba ON ba.BundleId = b.Id

        WHERE b.ParkId = @parkId
          AND b.BundleTypeId = 2 /* Party */
          AND ISNULL(b.StartDate, c.StartDate) <= @selectedDate
          AND ISNULL(b.EndDate, c.EndDate) >= @selectedDate
          AND cs.DayOfWeek = @dow
          AND t.ProductLevelId = @productLevelId
          AND bs.Amount > 0
          AND c.IsActive = 1
          AND b.IsActive = 1
          AND (@usePercentAllocation = 0 OR ba.TotalAllocation = 100)
          AND bs.Quantity - ISNULL(bsbq.BookedQuantity, 0) - ISNULL(bscq.CartQuantity, 0) > 0
          AND cs.Quantity - ISNULL(csbq.BookedQuantity, 0) - ISNULL(cscq.CartQuantity, 0) > 0

        GROUP BY b.Id, cs.Id, cs.StartHour, bp.Quantity, bs.Id, b.IsActive
    ),

    /*============================================================
      4. Original CTEs (Unchanged)
    ============================================================*/
    Schedules AS
    (
        SELECT sd.StartHour, sd.EndHour, pt.Description PartyTheme, pt.Id PartyThemeId,
               pt.ColorCode PartyThemeColorCode, pt.ImageUrl PartyThemeImageUrl,
               MIN(r.Price) MinPrice, COUNT(1) AvailableCount
        FROM booking.Schedule s
        LEFT JOIN booking.ScheduleDetails sd ON s.Id = sd.ScheduleId
        LEFT JOIN booking.Resource r ON sd.ResourceId = r.Id
        LEFT JOIN prdct.ProductLevel pl ON pl.Id = sd.MinimumProductLevelId
        LEFT JOIN booking.PartyTheme pt ON sd.PartyThemeId = pt.Id
        LEFT JOIN booking.Cart c ON c.SelectedResourceTypeId = r.ResourceTypeId AND c.CookieId = @cookieId
        LEFT JOIN booking.BookingResource br ON c.BookingId = br.BookingId
        WHERE s.ParkId = @parkId
          AND s.Date = @selectedDate
          AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
          AND (r.IsHandicapAccessible = @requiresHandicapAccessible OR @requiresHandicapAccessible = 0)
          AND s.Deleted IS NULL AND sd.Deleted IS NULL AND r.IsActive = 1 AND r.Deleted IS NULL
          AND (@usePercentAllocation = 0 OR (SELECT lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0)
                FROM booking.LocationResourceType lrt LEFT JOIN booking.ParkResourceTypeModifier prtm 
                  ON prtm.ResourceTypeId = lrt.ResourceTypeId AND prtm.ParkId = lrt.LocationId AND prtm.Deleted IS NULL
                WHERE lrt.LocationId = @parkId AND r.ResourceTypeId = lrt.ResourceTypeId) = 100)
          AND NOT EXISTS(SELECT 1 FROM booking.Booking b LEFT JOIN booking.Cart c ON b.Id = c.BookingId 
                         WHERE b.ScheduleDetailId = sd.Id AND b.Canceled IS NULL AND b.Deleted IS NULL AND (c.CookieId IS NULL OR @cookieId <> c.CookieId))
          AND NOT EXISTS(SELECT 1 FROM booking.Cart c LEFT JOIN booking.Booking b ON c.BookingId = b.Id 
                         WHERE c.ScheduleDetailId = sd.Id AND (DATEADD(MINUTE, 25, c.TimeBegan) > GETDATE() OR c.TimeBegan IS NULL)
                           AND c.CookieId <> @cookieId AND b.Canceled IS NULL AND c.CartReleased IS NULL)
        GROUP BY sd.StartHour, sd.EndHour, pt.Description, pt.Id, pt.ColorCode, pt.ImageUrl
    ),

    Templates AS
    (
        SELECT td.StartHour, td.EndHour, pt.Description PartyTheme, pt.Id PartyThemeId,
               pt.ColorCode PartyThemeColorCode, pt.ImageUrl PartyThemeImageUrl,
               MIN(r.Price) MinPrice, COUNT(1) AvailableCount
        FROM booking.Template t
        JOIN booking.TemplateDetails td ON t.Id = td.TemplateId
        JOIN booking.Resource r ON td.ResourceId = r.Id
        LEFT JOIN prdct.ProductLevel pl ON pl.Id = td.MinimumProductLevelId
        LEFT JOIN booking.PartyTheme pt ON td.PartyThemeId = pt.Id
        WHERE t.ParkId = @parkId
          AND t.StartDate <= @selectedDate AND t.EndDate >= @selectedDate
          AND td.DayOfWeek = @dow
          AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
          AND (r.IsHandicapAccessible = @requiresHandicapAccessible OR @requiresHandicapAccessible = 0)
          AND NOT EXISTS(SELECT 1 FROM booking.Schedule s WHERE s.ParkId = @parkId AND s.Date = @selectedDate AND s.Deleted IS NULL)
          AND t.IsActive = 1 AND t.Deleted IS NULL AND td.Deleted IS NULL AND r.IsActive = 1 AND r.Deleted IS NULL
          AND (@usePercentAllocation = 0 OR (SELECT lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0)
                FROM booking.LocationResourceType lrt LEFT JOIN booking.ParkResourceTypeModifier prtm 
                  ON prtm.ResourceTypeId = lrt.ResourceTypeId AND prtm.ParkId = lrt.LocationId AND prtm.Deleted IS NULL
                WHERE lrt.LocationId = @parkId AND r.ResourceTypeId = lrt.ResourceTypeId) = 100)
        GROUP BY td.StartHour, td.EndHour, pt.Description, pt.Id, pt.ColorCode, pt.ImageUrl
    ),

    DefaultTemplate AS
    (
        SELECT td.StartHour, td.EndHour, pt.Description PartyTheme, pt.Id PartyThemeId,
               pt.ColorCode PartyThemeColorCode, pt.ImageUrl PartyThemeImageUrl,
               MIN(r.Price) MinPrice, COUNT(1) AvailableCount
        FROM booking.Template t
        JOIN booking.TemplateDetails td ON t.Id = td.TemplateId
        JOIN booking.Resource r ON td.ResourceId = r.Id
        LEFT JOIN prdct.ProductLevel pl ON pl.Id = td.MinimumProductLevelId
        LEFT JOIN booking.PartyTheme pt ON td.PartyThemeId = pt.Id
        WHERE t.ParkId = @parkId
          AND t.StartDate IS NULL AND t.EndDate IS NULL AND t.IsDefault = 1
          AND td.DayOfWeek = @dow
          AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
          AND (r.IsHandicapAccessible = @requiresHandicapAccessible OR @requiresHandicapAccessible = 0)
          AND NOT EXISTS(SELECT 1 FROM booking.Schedule s WHERE s.ParkId = @parkId AND s.Date = @selectedDate AND s.Deleted IS NULL)
          AND NOT EXISTS(SELECT 1 FROM booking.Template t2 WHERE t2.ParkId = @parkId AND t2.StartDate <= @selectedDate AND t2.EndDate >= @selectedDate AND t2.Deleted IS NULL AND t2.IsActive = 1)
          AND t.IsActive = 1 AND t.Deleted IS NULL AND td.Deleted IS NULL AND r.IsActive = 1 AND r.Deleted IS NULL
          AND (@usePercentAllocation = 0 OR (SELECT lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0)
                FROM booking.LocationResourceType lrt LEFT JOIN booking.ParkResourceTypeModifier prtm 
                  ON prtm.ResourceTypeId = lrt.ResourceTypeId AND prtm.ParkId = lrt.LocationId AND prtm.Deleted IS NULL
                WHERE lrt.LocationId = @parkId AND r.ResourceTypeId = lrt.ResourceTypeId) = 100)
        GROUP BY td.StartHour, td.EndHour, pt.Description, pt.Id, pt.ColorCode, pt.ImageUrl
    )

    /*============================================================
      FINAL SELECT (Unchanged)
    ============================================================*/
    SELECT CONVERT(NVARCHAR(MAX), (
        SELECT r.StartHour StartTime, r.EndHour EndTime, r.AvailableCount Available,
               MIN(r.MinPrice) + MIN(b.MinPrice) Price,
               r.PartyTheme, r.PartyThemeId, r.PartyThemeColorCode, r.PartyThemeImageUrl,
               b.Quantity, b.BundleScheduleId BaseBundleScheduleId,
               cm.LevelId CrowdLevelId, eb.Id ExtraBundleScheduleId, ab.Id AdultBundleScheduleId, b.IsActive
        FROM Bundles b
        JOIN (
            SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount FROM Schedules
            UNION ALL SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount FROM Templates
            UNION ALL SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount FROM DefaultTemplate
        ) r ON r.StartHour IS NOT NULL
        OUTER APPLY (SELECT LevelId FROM booking.CrowdMeter m WHERE FLOOR(b.StartHour) = m.StartHour AND m.DayOfWeek = @dow AND m.ParkId = @parkId AND m.Deleted IS NULL) cm
        OUTER APPLY (SELECT TOP 1 bs.Id FROM product.Bundle eb JOIN product.BundleProduct bp ON eb.Id = bp.BundleId JOIN product.Ticket t ON bp.TicketId = t.Id JOIN product.BundleSchedule bs ON bs.BundleId = eb.Id 
                     WHERE eb.RelatedBundleId = b.BundleId AND bs.CategoryScheduleId = b.CategoryScheduleId AND eb.BundleTypeId = 4 AND t.ProductLevelId = @productLevelId) eb
        OUTER APPLY (SELECT TOP 1 bs.Id FROM product.Bundle ab JOIN product.BundleProduct bp ON ab.Id = bp.BundleId JOIN product.Ticket t ON bp.TicketId = t.Id JOIN product.BundleSchedule bs ON bs.BundleId = ab.Id 
                     WHERE bs.CategoryScheduleId = b.CategoryScheduleId AND ab.BundleTypeId = 4 AND t.ProductLevelId = 6) ab
        WHERE r.StartHour >= b.StartHour AND r.StartHour < b.StartHour + 1 AND b.rowNum = 1
        GROUP BY b.Quantity, r.StartHour, r.EndHour, r.PartyTheme, r.PartyThemeId, r.PartyThemeColorCode, r.PartyThemeImageUrl, r.AvailableCount, b.BundleScheduleId, cm.LevelId, eb.Id, ab.Id, b.IsActive
        ORDER BY r.StartHour, r.PartyTheme
        FOR JSON PATH
    )) AS Data;

END
GO
