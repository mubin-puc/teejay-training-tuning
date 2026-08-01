-- Index recommendations -- run once, safe to re-run.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InvoiceDetail_InvoiceHeaderId' AND object_id = OBJECT_ID('invoice.InvoiceDetail'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_InvoiceDetail_InvoiceHeaderId
        ON invoice.InvoiceDetail (InvoiceHeaderId, InvoiceDetailStatusId)
        INCLUDE (Description, UnitPrinciple, UnitTax, Quantity, ExternalId, DetailTypeId, RelatedInvoiceDetailId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Payment_InvoiceHeaderId' AND object_id = OBJECT_ID('invoice.Payment'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Payment_InvoiceHeaderId
        ON invoice.Payment (InvoiceHeaderId)
        INCLUDE (CardReaderId, Amount, FeeAmount, PaymentStatusId, PaymentOriginId, IsDeposit, PaymentMethodId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PaymentInvoiceDetail_PaymentId' AND object_id = OBJECT_ID('invoice.PaymentInvoiceDetail'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_PaymentInvoiceDetail_PaymentId
        ON invoice.PaymentInvoiceDetail (PaymentId, PaymentInvoiceDetailStatusId)
        INCLUDE (InvoiceDetailId, PaidPrinciple, PaidTax);
END
GO


/****** Object:  StoredProcedure [invoice].[GetInvoiceForBooking]    Script Date: 7/28/2026 2:03:39 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [invoice].[GetInvoiceForBooking] (
    @invoiceHeaderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CONVERT(NVARCHAR(MAX), (
        SELECT
            ih.Id,
            ih.ConfirmationCode,
            acpe.FirstName [Account.PrimaryAccountHolder.FirstName],
            acpe.LastName [Account.PrimaryAccountHolder.LastName],
            acpe.EmailAddress [Account.PrimaryAccountHolder.EmailAddress],
            pk.Name [Location.Name],
            br.Name [Location.Brand.Name],
            cur.Code [Currency.Code],
            (
                SELECT
                    id.Id,
                    id.Description,
                    id.UnitPrinciple,
                    id.UnitTax,
                    id.Quantity,
                    id.ExternalId,
                    id.DetailTypeId,
                    id.RelatedInvoiceDetailId
                FROM invoice.InvoiceDetail id
                WHERE id.InvoiceHeaderId = ih.Id
                    AND id.InvoiceDetailStatusId = 1 /* Active */
                FOR JSON PATH
            ) InvoiceDetails,
            (
                SELECT
                    p.Id,
                    p.CardReaderId,
                    p.Amount,
                    p.FeeAmount,
                    p.PaymentStatusId,
                    p.PaymentOriginId,
                    p.IsDeposit,
                    pm.LastFour [PaymentMethod.LastFour],
                    (
                        SELECT
                            pid.PaymentId,
                            pid.Id,
                            pid.InvoiceDetailId,
                            pid.PaidPrinciple,
                            pid.PaidTax
                        FROM invoice.PaymentInvoiceDetail pid
                        WHERE pid.PaymentId = p.Id
                            AND p.PaymentStatusId IN (2, 3) /* Captured, Authorized */ -- [REVIEW] filters the nested list only, not which Payment rows show up above -- flagging, not changing
                            AND pid.PaymentInvoiceDetailStatusId = 1 /* Active */
                        FOR JSON PATH
                    ) PaymentInvoiceDetails
                FROM invoice.Payment p
                LEFT JOIN acct.PaymentMethod pm
                    ON p.PaymentMethodId = pm.Id
                WHERE p.InvoiceHeaderId = ih.Id
                FOR JSON PATH
            ) Payments
        FROM invoice.InvoiceHeader ih
        JOIN currency.Currency cur
            ON ih.CurrencyId = cur.Id
        JOIN park.Park pk
            ON ih.LocationId = pk.Id
        JOIN dbo.Brands br
            ON pk.BrandId = br.Id
        JOIN acct.Account ac
            ON ih.AccountId = ac.Id
        JOIN acct.Person acpe
            ON ac.PersonId = acpe.Id
        WHERE ih.Id = @invoiceHeaderId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ))
END
GO
