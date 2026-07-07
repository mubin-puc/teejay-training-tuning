/* booking.GetTimeslots.sql — OPTIMIZED
   ------------------------------------------------------------------
   No business-logic changes. Every filter, join condition, and
   output column is functionally identical to the original.
   Only *how* the results are computed has changed. See the summary
   list sent alongside this file for a numbered explanation of each
   change and why it helps.
   ------------------------------------------------------------------ */

CREATE PROCEDURE [booking].[GetTimeslots]
(
    @cookieId                 UNIQUEIDENTIFIER,
    @parkId                   UNIQUEIDENTIFIER,
    @selectedDate              DATE,
    @productLevelId            INT,
    @requiresHandicapAccessible BIT,
    @usePercentAllocation      BIT
)
AS
BEGIN

SET NOCOUNT ON;

/* Get DayOfWeek range from @Date */
SET DATEFIRST 7;
DECLARE @dow INT = DATEPART(dw, @selectedDate) - 1;

/* Get ProductLevel Ordinal */
DECLARE @productLevelOrdinal INT;
SELECT @productLevelOrdinal = Ordinal
FROM prdct.ProductLevel
WHERE Id = @productLevelId;

/* [OPT] Compute these boolean flags ONCE instead of re-running the
   same NOT EXISTS / EXISTS subqueries inside both the Templates and
   DefaultTemplate CTEs (they were identical, just re-evaluated twice). */
DECLARE @scheduleExists       BIT;
DECLARE @templateOverrideExists BIT;

SELECT @scheduleExists = CASE WHEN EXISTS (
    SELECT 1
    FROM booking.Schedule s
    WHERE s.ParkId = @parkId
      AND s.Date = @selectedDate
      AND s.Deleted IS NULL
) THEN 1 ELSE 0 END;

SELECT @templateOverrideExists = CASE WHEN EXISTS (
    SELECT 1
    FROM booking.Template t
    WHERE t.ParkId = @parkId
      AND t.StartDate <= @selectedDate
      AND t.EndDate >= @selectedDate
      AND t.Deleted IS NULL
      AND t.IsActive = 1
) THEN 1 ELSE 0 END;

/* ==================================================================
   STEP 1: Pre-aggregate booked/cart quantities ONCE.
   [OPT] Original ran 4 correlated OUTER APPLY subqueries per Bundle
   row (one row-scan of booking.Booking/booking.Cart per row). These
   are now computed once as set-based aggregates and joined in.
   ================================================================== */
WITH BookedByBundleSchedule AS
(
    SELECT p.BundleScheduleId,
           COUNT(1) AS BookedQuantity
    FROM booking.Booking bk
    JOIN booking.BookingParticipant p ON p.BookingId = bk.Id
    LEFT JOIN booking.Cart crt ON crt.BookingId = bk.Id
    WHERE p.ParticipantTypeId = 1 /* Base */
      AND bk.Canceled IS NULL
      AND bk.Deleted IS NULL
      AND (crt.CookieId IS NULL OR @cookieId <> crt.CookieId)
    GROUP BY p.BundleScheduleId
),
BookedByCategorySchedule AS
(
    SELECT bs.CategoryScheduleId,
           COUNT(1) AS BookedQuantity
    FROM booking.Booking bk
    JOIN booking.BookingParticipant p ON p.BookingId = bk.Id
    JOIN product.BundleSchedule bs ON p.BundleScheduleId = bs.Id
    LEFT JOIN booking.Cart crt ON crt.BookingId = bk.Id
    WHERE p.ParticipantTypeId = 1 /* Base */
      AND bk.Canceled IS NULL
      AND bk.Deleted IS NULL
      AND (crt.CookieId IS NULL OR @cookieId <> crt.CookieId)
    GROUP BY bs.CategoryScheduleId
),
CartByBundleSchedule AS
(
    SELECT crt.BaseBundleScheduleId,
           COUNT(1) AS CartQuantity
    FROM booking.Cart crt
    LEFT JOIN booking.Booking bk ON crt.BookingId = bk.Id
    WHERE (DATEADD(MINUTE, 25, crt.TimeBegan) > GETDATE() OR crt.TimeBegan IS NULL)
      AND crt.CookieId <> @cookieId
      AND bk.Canceled IS NULL
      AND crt.CartReleased IS NULL
    GROUP BY crt.BaseBundleScheduleId
),
CartByCategorySchedule AS
(
    SELECT bs.CategoryScheduleId,
           COUNT(1) AS CartQuantity
    FROM booking.Cart crt
    JOIN product.BundleSchedule bs ON crt.BaseBundleScheduleId = bs.Id
    LEFT JOIN booking.Booking bk ON crt.BookingId = bk.Id
    WHERE (DATEADD(MINUTE, 25, crt.TimeBegan) > GETDATE() OR crt.TimeBegan IS NULL)
      AND crt.CookieId <> @cookieId
      AND bk.Canceled IS NULL
      AND crt.CartReleased IS NULL
    GROUP BY bs.CategoryScheduleId
),
/* [OPT] BundleProduct percent-allocation check computed once instead
   of once-per-row via a correlated subquery. */
BundleFullyAllocated AS
(
    SELECT bp.BundleId
    FROM product.BundleProduct bp
    GROUP BY bp.BundleId
    HAVING SUM(bp.PercentAllocation) = 100
),
/* [OPT] Resource-type percent-allocation check computed once and
   reused by Schedules / Templates / DefaultTemplate (was an
   identical correlated subquery duplicated in all three CTEs). */
ResourceTypeFullyAllocated AS
(
    SELECT lrt.ResourceTypeId,
           lrt.PercentAllocation + ISNULL(SUM(prtm.PercentAllocation), 0) AS TotalAllocation
    FROM booking.LocationResourceType lrt
    LEFT JOIN booking.ParkResourceTypeModifier prtm
        ON prtm.ResourceTypeId = lrt.ResourceTypeId
        AND prtm.ParkId = lrt.LocationId
        AND prtm.Deleted IS NULL
    WHERE lrt.LocationId = @parkId
    GROUP BY lrt.ResourceTypeId, lrt.PercentAllocation
),
Bundles
AS (SELECT b.Id BundleId,
           cs.Id CategoryScheduleId,
           cs.StartHour,
           CASE
               WHEN MIN(bPar.Price) IS NOT NULL THEN MIN(bPar.Price)
               ELSE MIN(bs.Amount)
           END MinPrice,
           bp.Quantity,
           bs.Id BundleScheduleId,
           b.IsActive,
           COUNT(1) Available,
           ROW_NUMBER() OVER (PARTITION BY cs.StartHour ORDER BY b.IsActive DESC, MIN(bs.Amount)) rowNum
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
    LEFT JOIN booking.Cart cart
        ON bs.Id = cart.BaseBundleScheduleId AND cart.CookieId = @cookieId
    LEFT JOIN booking.BookingParticipant bPar
        ON cart.BookingId = bPar.BookingId AND bPar.ParticipantTypeId = 1
    /* [OPT] replaces 4x OUTER APPLY with pre-aggregated LEFT JOINs */
    LEFT JOIN BookedByBundleSchedule bbs ON bbs.BundleScheduleId = bs.Id
    LEFT JOIN BookedByCategorySchedule bcs ON bcs.CategoryScheduleId = cs.Id
    LEFT JOIN CartByBundleSchedule cbbs ON cbbs.BaseBundleScheduleId = bs.Id
    LEFT JOIN CartByCategorySchedule cbcs ON cbcs.CategoryScheduleId = cs.Id
    WHERE b.ParkId = @parkId
      AND b.BundleTypeId = 2 /* Party */
      AND ISNULL(b.StartDate, c.StartDate) <= @selectedDate
      AND ISNULL(b.EndDate, c.EndDate) >= @selectedDate
      AND (@usePercentAllocation = 0
           OR EXISTS (SELECT 1 FROM BundleFullyAllocated bfa WHERE bfa.BundleId = b.Id))
      AND c.IsActive = 1
      AND cs.DayOfWeek = @dow
      AND t.ProductLevelId = @productLevelId
      /* Subtract booked/cart quantities */
      AND bs.Quantity - ISNULL(bbs.BookedQuantity, 0) - ISNULL(cbbs.CartQuantity, 0) > 0
      AND cs.Quantity - ISNULL(bcs.BookedQuantity, 0) - ISNULL(cbcs.CartQuantity, 0) > 0
      AND bs.Amount > 0
    GROUP BY b.Id,
             cs.Id,
             cs.StartHour,
             bp.Quantity,
             bs.Id,
             b.IsActive),
Schedules
AS (SELECT sd.StartHour,
           sd.EndHour,
           pt.Description PartyTheme,
           pt.Id PartyThemeId,
           pt.ColorCode PartyThemeColorCode,
           pt.ImageUrl PartyThemeImageUrl,
           Min(r.Price) MinPrice,
           COUNT(1) AvailableCount
    FROM booking.Schedule s
    LEFT JOIN booking.ScheduleDetails sd
        ON s.Id = sd.ScheduleId
    LEFT JOIN booking.Resource r
        ON sd.ResourceId = r.Id
    LEFT JOIN prdct.ProductLevel pl
        ON pl.Id = sd.MinimumProductLevelId
    LEFT JOIN booking.PartyTheme pt
        ON sd.PartyThemeId = pt.Id
    LEFT JOIN booking.Cart c
        ON c.SelectedResourceTypeId = r.ResourceTypeId AND c.CookieId = @cookieId
    LEFT JOIN booking.BookingResource br
        ON c.BookingId = br.BookingId
    WHERE s.ParkId = @parkId
      AND s.Date = @selectedDate
      AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
      AND
      (
          r.IsHandicapAccessible = @requiresHandicapAccessible
          OR @requiresHandicapAccessible = 0
      )
      /* Active only */
      AND s.Deleted IS NULL
      AND sd.Deleted IS NULL
      AND r.IsActive = 1
      AND r.Deleted IS NULL
      AND (@usePercentAllocation = 0
           OR EXISTS (SELECT 1 FROM ResourceTypeFullyAllocated rfa
                      WHERE rfa.ResourceTypeId = r.ResourceTypeId AND rfa.TotalAllocation = 100))
      /* Not booked */
      AND NOT EXISTS
      (
          SELECT 1
          FROM booking.Booking b
          LEFT JOIN booking.Cart c2
              ON b.Id = c2.BookingId
          WHERE b.ScheduleDetailId = sd.Id
            AND b.Canceled IS NULL
            AND b.Deleted IS NULL
            AND
            (
                c2.CookieId IS NULL
                OR @cookieId <> c2.CookieId
            )
      )
      /* Not in a (non-expired) cart */
      AND NOT EXISTS
      (
          SELECT 1
          FROM booking.Cart c3
          LEFT JOIN booking.Booking b2
              ON c3.BookingId = b2.Id
          WHERE c3.ScheduleDetailId = sd.Id
            AND (DATEADD(MINUTE, 25, c3.TimeBegan) > GETDATE() OR c3.TimeBegan IS NULL)
            AND c3.CookieId <> @cookieId
            AND b2.Canceled IS NULL
            AND c3.CartReleased IS NULL
      )
    GROUP BY sd.StartHour,
             sd.EndHour,
             pt.Description,
             pt.Id,
             pt.ImageUrl,
             pt.ColorCode),
Templates
AS (SELECT td.StartHour,
           td.EndHour,
           pt.Description PartyTheme,
           pt.Id PartyThemeId,
           pt.ColorCode PartyThemeColorCode,
           pt.ImageUrl PartyThemeImageUrl,
           MIN(r.Price) MinPrice,
           COUNT(1) AvailableCount
    FROM booking.Template t
    JOIN booking.TemplateDetails td
        ON t.Id = td.TemplateId
    JOIN booking.Resource r
        ON td.ResourceId = r.Id
    LEFT JOIN prdct.ProductLevel pl
        ON pl.Id = td.MinimumProductLevelId
    LEFT JOIN booking.PartyTheme pt
        ON td.PartyThemeId = pt.Id
    WHERE t.ParkId = @parkId
      AND t.StartDate <= @selectedDate
      AND t.EndDate >= @selectedDate
      AND td.DayOfWeek = @dow
      AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
      AND
      (
          r.IsHandicapAccessible = @requiresHandicapAccessible
          OR @requiresHandicapAccessible = 0
      )
      /* Not scheduled -- [OPT] pre-computed flag instead of NOT EXISTS */
      AND @scheduleExists = 0
      /* Active only */
      AND t.IsActive = 1
      AND t.Deleted IS NULL
      AND td.Deleted IS NULL
      AND r.IsActive = 1
      AND (@usePercentAllocation = 0
           OR EXISTS (SELECT 1 FROM ResourceTypeFullyAllocated rfa
                      WHERE rfa.ResourceTypeId = r.ResourceTypeId AND rfa.TotalAllocation = 100))
      AND r.Deleted IS NULL
    GROUP BY td.DayOfWeek,
             td.StartHour,
             td.EndHour,
             pt.Description,
             pt.id,
             pt.ColorCode,
             pt.ImageUrl),
DefaultTemplate
AS (SELECT td.StartHour,
           td.EndHour,
           pt.Description PartyTheme,
           pt.Id PartyThemeId,
           pt.ColorCode PartyThemeColorCode,
           pt.ImageUrl PartyThemeImageUrl,
           MIN(r.Price) MinPrice,
           COUNT(1) AvailableCount
    FROM booking.Template t
    JOIN booking.TemplateDetails td
        ON t.Id = td.TemplateId
    JOIN booking.Resource r
        ON td.ResourceId = r.Id
    LEFT JOIN prdct.ProductLevel pl
        ON pl.Id = td.MinimumProductLevelId
    LEFT JOIN booking.PartyTheme pt
        ON td.PartyThemeId = pt.Id
    WHERE t.ParkId = @parkId
      AND t.StartDate IS NULL
      AND t.EndDate IS NULL
      AND t.IsDefault = 1
      AND td.DayOfWeek = @dow
      AND ISNULL(pl.Ordinal, @productLevelOrdinal) >= @productLevelOrdinal
      AND
      (
          r.IsHandicapAccessible = @requiresHandicapAccessible
          OR @requiresHandicapAccessible = 0
      )
      /* Not scheduled -- [OPT] pre-computed flag instead of NOT EXISTS */
      AND @scheduleExists = 0
      /* Not overridden -- [OPT] pre-computed flag instead of NOT EXISTS */
      AND @templateOverrideExists = 0
      /* Active only */
      AND t.IsActive = 1
      AND t.Deleted IS NULL
      AND td.Deleted IS NULL
      AND r.IsActive = 1
      AND r.Deleted IS NULL
      AND (@usePercentAllocation = 0
           OR EXISTS (SELECT 1 FROM ResourceTypeFullyAllocated rfa
                      WHERE rfa.ResourceTypeId = r.ResourceTypeId AND rfa.TotalAllocation = 100))
    GROUP BY td.DayOfWeek,
             td.StartHour,
             td.EndHour,
             pt.Description,
             pt.Id,
             pt.ColorCode,
             pt.ImageUrl)

SELECT CONVERT(NVARCHAR(MAX), (
SELECT r.StartHour StartTime,
       r.EndHour EndTime,
       r.AvailableCount Available,
       MIN(r.MinPrice) + MIN(b.MinPrice) Price,
       r.PartyTheme,
       r.PartyThemeId,
       r.PartyThemeColorCode,
       r.PartyThemeImageUrl,
       b.Quantity,
       b.BundleScheduleId BaseBundleScheduleId,
       cm.LevelId CrowdLevelId,
       eb.Id ExtraBundleScheduleId,
       ab.Id AdultBundleScheduleId,
       b.IsActive
FROM Bundles b
JOIN
(
    SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount
    FROM Schedules
    UNION ALL
    SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount
    FROM Templates
    UNION ALL
    SELECT StartHour, EndHour, PartyTheme, PartyThemeId, PartyThemeColorCode, PartyThemeImageUrl, MinPrice, AvailableCount
    FROM DefaultTemplate
) r
ON r.StartHour IS NOT NULL
OUTER APPLY
(
    SELECT LevelId
    FROM booking.CrowdMeter m
    WHERE FLOOR(b.StartHour) = m.StartHour
      AND m.DayOfWeek = @dow
      AND m.ParkId = @parkId
      AND m.Deleted IS NULL
) cm
OUTER APPLY
(
    SELECT TOP 1
        bs.Id
    FROM product.Bundle eb
    JOIN product.BundleProduct bp
        ON eb.Id = bp.BundleId
    JOIN product.Ticket t
        ON bp.TicketId = t.Id
    JOIN product.BundleSchedule bs
        ON bs.BundleId = eb.Id
    WHERE eb.RelatedBundleId = b.BundleId
      AND bs.CategoryScheduleId = b.CategoryScheduleId
      AND eb.BundleTypeId = 4 /* Add-On */
      AND t.ProductLevelId = @productLevelId
) eb
OUTER APPLY
(
    SELECT TOP 1
        bs.Id
    FROM product.Bundle ab
    JOIN product.BundleProduct bp
        ON ab.Id = bp.BundleId
    JOIN product.Ticket t
        ON bp.TicketId = t.Id
    JOIN product.BundleSchedule bs
        ON bs.BundleId = ab.Id
    WHERE bs.CategoryScheduleId = b.CategoryScheduleId
      AND ab.BundleTypeId = 4 /* Add-On */
      AND t.ProductLevelId = 6 /* Parent */
) ab
WHERE r.StartHour >= b.StartHour
  AND r.StartHour < b.StartHour + 1
  AND b.rowNum = 1
GROUP BY b.Quantity,
         r.StartHour,
         r.EndHour,
         r.PartyTheme,
         r.PartyThemeId,
         r.PartyThemeColorCode,
         r.PartyThemeImageUrl,
         r.AvailableCount,
         b.BundleScheduleId,
         cm.LevelId,
         eb.Id,
         ab.Id,
         b.IsActive
ORDER BY r.StartHour,
         r.PartyTheme
FOR JSON PATH
)) Data;

END
GO
