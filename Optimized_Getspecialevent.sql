-- Index recommendations -- run once, safe to re-run.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BookingItem_BookingId_Deleted' AND object_id = OBJECT_ID('booking.BookingItem'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BookingItem_BookingId_Deleted
        ON booking.BookingItem (BookingId, Deleted) INCLUDE (ParkProductId, Quantity, Price, IsTaxable, Included);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PmtPayment_InvoiceId_Status' AND object_id = OBJECT_ID('payment.Payment'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_PmtPayment_InvoiceId_Status
        ON payment.Payment (InvoiceId, PaymentStatusId) INCLUDE (Amount, IsDeposit);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InvPayment_InvoiceHeaderId_Status' AND object_id = OBJECT_ID('invoice.Payment'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_InvPayment_InvoiceHeaderId_Status
        ON invoice.Payment (InvoiceHeaderId, PaymentStatusId) INCLUDE (Amount, IsDeposit);
END
GO


/****** Object:  StoredProcedure [booking].[GetSpecialEvent] -- indexes only, logic unchanged ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROC [booking].[GetSpecialEvent](
    @bookingId INT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        CONVERT(NVARCHAR(MAX), (
            SELECT
                b.Id,
                b.ParkId,
                b.AccountId,
                b.ScheduleDetailId,
                b.PartyHostId,
                b.RequiresHandicap,
                b.HasProtectionPlan,
                b.InternalNotes,
                b.ExternalNotes,
                b.Booked,
                b.Paid,
                b.InvoiceId,
                b.Canceled,
                b.Deleted,
                b.RowVer,
                b.DepositPrice,
                b.IsSpecialEvent,
                b.ProductLevelId,
                sd.Id [ScheduleDetail.Id],
                sd.StartHour [ScheduleDetail.StartHour],
                sd.EndHour [ScheduleDetail.EndHour],
                s.Id [ScheduleDetail.Schedule.Id],
                s.Date [ScheduleDetail.Schedule.Date],
                r.Name [ScheduleDetail.Resource.ResourceType.Name],
                (
                    SELECT
                        bi.ParkProductId,
                        bi.Quantity,
                        bi.Price,
                        bi.IsTaxable,
                        bi.Included
                    FROM booking.BookingItem bi
                    WHERE bi.BookingId = b.Id
                        AND bi.Deleted IS NULL
                    FOR JSON PATH
                )    Items,
                se.OrganizationName [SpecialEvent.OrganizationName],
                se.TaxCode [SpecialEvent.TaxCode],
                se.IsTaxExempt [SpecialEvent.IsTaxExempt],
                se.ContactFirstName [SpecialEvent.ContactFirstName],
                se.ContactLastName [SpecialEvent.ContactLastName],
                se.PhoneNumber [SpecialEvent.PhoneNumber],
                se.BasePrice [SpecialEvent.BasePrice],
                se.BaseParticipantCount [SpecialEvent.BaseParticipantCount],
                se.ExtraPrice [SpecialEvent.ExtraPrice],
                se.ExtraParticipantCount [SpecialEvent.ExtraParticipantCount],
                se.CookieId [SpecialEvent.CookieId],
                se.IsQuote [SpecialEvent.IsQuote],
                se.IsGroupSales [SpecialEvent.IsGroupSales],
                se.ExpirationDate [SpecialEvent.ExpirationDate],
                p.EmailAddress [SpecialEvent.EmailAddress],
                pk.Id [Park.Id],
                pk.CurrencyId [Park.CurrencyId],
                pkex.PaymentProcessorVersion [Park.ParkEx.PaymentProcessorVersion],
                sal.SubAccountId [Park.SubAccountLocation.SubAccountId],
                i.Id [Invoice.Id],
                (
                    SELECT
                        p.Amount,
                        p.PaymentStatusId,
                        p.IsDeposit
                    FROM payment.Payment p
                    WHERE i.Id = p.InvoiceId
                    AND p.PaymentStatusId IN (2, 3)
                    FOR JSON PATH
                ) [Invoice.Payments],
                ih.Id [InvoiceHeader.Id],
                (
                    SELECT
                        p.Amount,
                        p.PaymentStatusId,
                        p.IsDeposit
                    FROM invoice.Payment p
                    WHERE ih.Id = p.InvoiceHeaderId
                    AND p.PaymentStatusId IN (2, 3) /* Captured, Authorized */
                    FOR JSON PATH
                ) [InvoiceHeader.Payments]
            FROM booking.Booking b
            JOIN booking.ScheduleDetails sd
                ON b.ScheduleDetailId = sd.Id
            JOIN booking.Schedule s
                ON sd.ScheduleId = s.Id
                AND s.Deleted IS NULL
            JOIN booking.Resource r
                ON sd.ResourceId = r.Id
            JOIN booking.ResourceType rt
                ON rt.Id = r.ResourceTypeId
            JOIN booking.BookingSpecialEvent se
                ON b.Id = se.BookingId
            LEFT JOIN payment.Invoice i
                ON b.InvoiceId = i.Id
            LEFT JOIN invoice.InvoiceHeader ih
                ON ih.BookingId = b.Id
            JOIN acct.Account a
                ON b.AccountId = a.Id
            JOIN acct.Person p
                ON a.PersonId = p.Id
            JOIN park.Park pk
                ON pk.Id = b.ParkId
            JOIN park.ParkEx pkex
                ON pk.Id = pkex.ParkId
            LEFT JOIN invoice.SubAccountLocation sal
                ON pk.Id = sal.LocationId
            WHERE @bookingId = b.Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )) DATA;

END
GO
