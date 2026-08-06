/****** Object:  StoredProcedure [invoice].[UpsertBookingInvoiceHeader]    Script Date: 7/28/2026 2:01:10 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [invoice].[UpsertBookingInvoiceHeader](
    @invoiceHeaderId INT = NULL,
    @invoiceHeader NVARCHAR(MAX),
    @changeUser NVARCHAR(256),
    @invoiceDetails NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRAN;
    BEGIN TRY

        IF ISNULL(@invoiceHeaderId, 0) = 0
            BEGIN
                -- Insert new Invoice Header
                INSERT INTO invoice.InvoiceHeader (ConfirmationCode, LocationId, AccountId, BookingId,
                    RecurringBillingPeriodId, RefundedInvoiceId, InvoiceStatusId, CurrencyId, CreatedBy, CreatedDate,
                    ModifiedBy, ModifiedDate)
                SELECT
                    i.ConfirmationCode,
                    i.LocationId,
                    i.AccountId,
                    i.BookingId,
                    i.RecurringBillingPeriodId,
                    i.RefundedInvoiceId,
                    i.InvoiceStatusId,
                    i.CurrencyId,
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    @changeUser,
                    SYSDATETIMEOFFSET()
                FROM OPENJSON(@invoiceHeader)
                    WITH (
                        ConfirmationCode CHAR(8),
                        LocationId UNIQUEIDENTIFIER,
                        AccountId INT,
                        BookingId INT,
                        RecurringBillingPeriodId INT,
                        RefundedInvoiceId INT,
                        InvoiceStatusId INT,
                        CurrencyId INT
                    ) i

                SET @invoiceHeaderId = SCOPE_IDENTITY();
            END
        ELSE
            BEGIN
                -- Update existing Invoice
                UPDATE ih
                SET
                    ih.RefundedInvoiceId = u.RefundedInvoiceId,
                    ih.InvoiceStatusId = u.InvoiceStatusId,
                    ih.ModifiedDate = SYSDATETIMEOFFSET(),
                    ih.ModifiedBy   = @changeUser
                FROM invoice.InvoiceHeader ih
                CROSS APPLY OPENJSON(@invoiceHeader)
                    WITH (
                        ConfirmationCode CHAR(8),
                        LocationId UNIQUEIDENTIFIER,
                        AccountId INT,
                        BookingId INT,
                        RecurringBillingPeriodId INT,
                        RefundedInvoiceId INT,
                        InvoiceStatusId INT,
                        CurrencyId INT
                    ) u
                WHERE ih.id = @invoiceHeaderId;
            END;

        IF (@invoiceDetails IS NOT NULL)
            BEGIN
                DROP TABLE IF EXISTS #invoiceDetails;

                SELECT
                    i.Id,
                    i.Description,
                    i.UnitPrinciple,
                    i.UnitTax,
                    i.Quantity,
                    i.DetailTypeId,
                    i.RelatedInvoiceDetailId,
                    i.SubscriptionId,
                    i.SubscriptionDiscountId,
                    i.EventReservationId,
                    i.RemoveFranchiseScheduleDetailId,
                    i.MemberReservationId,
                    i.TicketReservationId,
                    i.ItemFeeId,
                    i.ProductFeeId,
                    i.BookingItemId,
                    i.BookingParticipantId,
                    i.BookingResourceId,
                    i.BookingFeeId,
                    i.IsTaxable,
                    i.TaxCode,
                    i.ExternalId,
                    i.WaitlistId,
                    i.BundledItemPrinciple
                INTO #invoiceDetails
                FROM OPENJSON(@invoiceDetails)
                WITH (
                    Id INT,
                    Description NVARCHAR(256),
                    UnitPrinciple DECIMAL(18, 6),
                    UnitTax DECIMAL(18, 6),
                    Quantity INT,
                    DetailTypeId INT,
                    RelatedInvoiceDetailId NVARCHAR(64),
                    SubscriptionId INT,
                    SubscriptionDiscountId INT,
                    EventReservationId INT,
                    RemoveFranchiseScheduleDetailId INT,
                    MemberReservationId INT,
                    TicketReservationId INT,
                    ItemFeeId INT,
                    ProductFeeId INT,
                    BookingItemId INT,
                    BookingParticipantId INT,
                    BookingResourceId INT,
                    BookingFeeId INT,
                    IsTaxable BIT,
                    TaxCode NVARCHAR(20),
                    ExternalId NVARCHAR(64),
                    WaitlistId INT,
                    BundledItemPrinciple DECIMAL(18, 6)
                ) i;

                /* CORE: lock-order fix. Previously the InvoiceDetail UPDATE below carried a
                   correlated NOT EXISTS read against live invoice.PaymentInvoiceDetail inside
                   the same write statement, and the PaymentInvoiceDetail UPDATE that followed
                   re-joined live invoice.InvoiceDetail. That pattern (write on table A while
                   reading/joining table B in the same statement, then reversing it in the next
                   statement) is the deadlock precondition shared with booking.UpsertSpecialEvent
                   and booking.ConvertCartToBookingJustifi, which touch the same two tables.
                   Capturing the affected InvoiceDetail Ids into a temp table first (one cheap
                   read, locks released immediately) means neither UPDATE below needs to touch
                   the *other* live table while holding its own write lock. No logic change -
                   same rows qualify, same values written. */
                DROP TABLE IF EXISTS #voidInvoiceDetailIds;

                SELECT id.Id
                INTO #voidInvoiceDetailIds
                FROM invoice.InvoiceDetail id
                WHERE id.InvoiceHeaderId = @invoiceHeaderId
                    AND id.InvoiceDetailStatusId = 1 /* Active */
                    AND NOT EXISTS (
                        SELECT 1
                        FROM invoice.PaymentInvoiceDetail pid
                        WHERE pid.InvoiceDetailId = id.Id
                            AND pid.PaymentInvoiceDetailStatusId = 1 /* Active */
                    );

                UPDATE id
                SET id.InvoiceDetailStatusId = 2, /* Voided */
                    id.ModifiedBy = @changeUser,
                    id.ModifiedDate = SYSDATETIMEOFFSET()
                FROM invoice.InvoiceDetail id
                JOIN #voidInvoiceDetailIds v
                    ON v.Id = id.Id;

                /*Leon-9/11-Add logic to void PaymentInvoiceDetails when their associated InvoiceDetails are voided:*/
                UPDATE pid
                SET pid.PaymentInvoiceDetailStatusId = 2, /* Voided */
                    pid.ModifiedBy = @changeUser,
                    pid.ModifiedDate = SYSDATETIMEOFFSET()
                FROM invoice.PaymentInvoiceDetail pid
                JOIN #voidInvoiceDetailIds v
                    ON v.Id = pid.InvoiceDetailId
                WHERE pid.PaymentInvoiceDetailStatusId = 1; /* Active */


                /* UPDATE or INSERT InvoiceDetails for Booking */
                /*Leon-7/14-Replace Merge syntax with Update and Insert statements*/
                /*
                MERGE invoice.InvoiceDetail as tgt
                USING (
                    SELECT
                        @invoiceHeaderId InvoiceHeaderId,
                        i.Description,
                        i.UnitPrinciple,
                        i.UnitTax,
                        i.Quantity,
                        i.DetailTypeId,
                        i.SubscriptionDiscountId,
                        i.ItemFeeId,
                        i.ProductFeeId,
                        i.BookingItemId,
                        i.BookingParticipantId,
                        i.BookingResourceId,
                        i.BookingFeeId,
                        i.IsTaxable,
                        i.TaxCode,
                        i.ExternalId,
                        i.BundledItemPrinciple
                    FROM #invoiceDetails i
                ) src
                ON (
                    tgt.InvoiceHeaderId = src.InvoiceHeaderId
                        AND (
                            tgt.BookingItemId = src.BookingItemId
                                OR tgt.BookingFeeId = src.BookingFeeId
                                OR tgt.BookingParticipantId = src.BookingParticipantId
                                OR tgt.BookingResourceId = src.BookingResourceId
                                OR tgt.ExternalId = src.ExternalId /* Bundle Items */
                        )
                    AND tgt.InvoiceDetailStatusId = 1 /* Active */
                )
                WHEN MATCHED THEN
                    UPDATE
                    SET tgt.Description             = ISNULL(src.Description, tgt.Description),
                        tgt.UnitPrinciple           = ISNULL(src.UnitPrinciple, tgt.UnitPrinciple),
                        tgt.UnitTax                 = ISNULL(src.UnitTax, tgt.UnitTax),
                        tgt.Quantity                = ISNULL(src.Quantity, tgt.Quantity),
                        tgt.DetailTypeId            = ISNULL(src.DetailTypeId, tgt.DetailTypeId),
                        tgt.SubscriptionDiscountId  = ISNULL(src.SubscriptionDiscountId, tgt.SubscriptionDiscountId),
                        tgt.ItemFeeId               = ISNULL(src.ItemFeeId, tgt.ItemFeeId),
                        tgt.ProductFeeId            = ISNULL(src.ProductFeeId, tgt.ProductFeeId),
                        tgt.BookingItemId           = ISNULL(src.BookingItemId, tgt.BookingItemId),
                        tgt.BookingParticipantId    = ISNULL(src.BookingParticipantId, tgt.BookingParticipantId),
                        tgt.BookingResourceId       = ISNULL(src.BookingResourceId, tgt.BookingResourceId),
                        tgt.BookingFeeId            = ISNULL(src.BookingFeeId, tgt.BookingFeeId),
                        tgt.IsTaxable               = ISNULL(src.IsTaxable, tgt.IsTaxable),
                        tgt.TaxCode                 = ISNULL(src.TaxCode, tgt.TaxCode),
                        tgt.ExternalId              = ISNULL(src.ExternalId, tgt.ExternalId),
                        tgt.ModifiedBy              = @changeUser,
                        tgt.ModifiedDate            = SYSDATETIMEOFFSET(),
                        tgt.BundledItemPrinciple    = ISNULL(src.BundledItemPrinciple, tgt.BundledItemPrinciple)
                WHEN NOT MATCHED THEN
                    INSERT (
                            InvoiceHeaderId,
                            Description,
                            UnitPrinciple,
                            UnitTax,
                            Quantity,
                            DetailTypeId,
                            SubscriptionDiscountId,
                            ItemFeeId,
                            ProductFeeId,
                            BookingItemId,
                            BookingParticipantId,
                            BookingResourceId,
                            BookingFeeId,
                            IsTaxable,
                            TaxCode,
                            ExternalId,
                            CreatedBy,
                            CreatedDate,
                            ModifiedBy,
                            ModifiedDate,
                            BundledItemPrinciple,
                            InvoiceDetailStatusId
                    ) VALUES (
                        src.InvoiceHeaderId,
                        src.Description,
                        src.UnitPrinciple,
                        src.UnitTax,
                        src.Quantity,
                        src.DetailTypeId,
                        src.SubscriptionDiscountId,
                        src.ItemFeeId,
                        src.ProductFeeId,
                        src.BookingItemId,
                        src.BookingParticipantId,
                        src.BookingResourceId,
                        src.BookingFeeId,
                        src.IsTaxable,
                        src.TaxCode,
                        src.ExternalId,
                        @changeUser,
                        SYSDATETIMEOFFSET(),
                        @changeUser,
                        SYSDATETIMEOFFSET(),
                        src.BundledItemPrinciple,
                        1 /* Active */
                    );
                */

                -- 1. Update existing records
                UPDATE tgt
                SET tgt.Description             = ISNULL(src.Description, tgt.Description),
                    tgt.UnitPrinciple           = ISNULL(src.UnitPrinciple, tgt.UnitPrinciple),
                    tgt.UnitTax                 = ISNULL(src.UnitTax, tgt.UnitTax),
                    tgt.Quantity                = ISNULL(src.Quantity, tgt.Quantity),
                    tgt.DetailTypeId            = ISNULL(src.DetailTypeId, tgt.DetailTypeId),
                    tgt.SubscriptionDiscountId  = ISNULL(src.SubscriptionDiscountId, tgt.SubscriptionDiscountId),
                    tgt.ItemFeeId               = ISNULL(src.ItemFeeId, tgt.ItemFeeId),
                    tgt.ProductFeeId            = ISNULL(src.ProductFeeId, tgt.ProductFeeId),
                    tgt.BookingItemId           = ISNULL(src.BookingItemId, tgt.BookingItemId),
                    tgt.BookingParticipantId    = ISNULL(src.BookingParticipantId, tgt.BookingParticipantId),
                    tgt.BookingResourceId       = ISNULL(src.BookingResourceId, tgt.BookingResourceId),
                    tgt.BookingFeeId            = ISNULL(src.BookingFeeId, tgt.BookingFeeId),
                    tgt.IsTaxable               = ISNULL(src.IsTaxable, tgt.IsTaxable),
                    tgt.TaxCode                 = ISNULL(src.TaxCode, tgt.TaxCode),
                    tgt.ExternalId              = ISNULL(src.ExternalId, tgt.ExternalId),
                    tgt.ModifiedBy              = @changeUser,
                    tgt.ModifiedDate            = SYSDATETIMEOFFSET(),
                    tgt.BundledItemPrinciple    = ISNULL(src.BundledItemPrinciple, tgt.BundledItemPrinciple)
                FROM invoice.InvoiceDetail tgt
                INNER JOIN  #invoiceDetails src
                    on  tgt.InvoiceHeaderId = @invoiceHeaderId
                    AND tgt.InvoiceDetailStatusId = 1
                    AND (
                        tgt.BookingItemId = src.BookingItemId
                        OR tgt.BookingFeeId = src.BookingFeeId
                        OR tgt.BookingParticipantId = src.BookingParticipantId
                        OR tgt.BookingResourceId = src.BookingResourceId
                        OR tgt.ExternalId = src.ExternalId
                    );

                -- 2. Insert new records
                INSERT INTO invoice.InvoiceDetail (
                    InvoiceHeaderId,
                    Description,
                    UnitPrinciple,
                    UnitTax,
                    Quantity,
                    DetailTypeId,
                    SubscriptionDiscountId,
                    ItemFeeId,
                    ProductFeeId,
                    BookingItemId,
                    BookingParticipantId,
                    BookingResourceId,
                    BookingFeeId,
                    IsTaxable,
                    TaxCode,
                    ExternalId,
                    CreatedBy,
                    CreatedDate,
                    ModifiedBy,
                    ModifiedDate,
                    BundledItemPrinciple,
                    InvoiceDetailStatusId
                )
                SELECT
                    @invoiceHeaderId,
                    i.Description,
                    i.UnitPrinciple,
                    i.UnitTax,
                    i.Quantity,
                    i.DetailTypeId,
                    i.SubscriptionDiscountId,
                    i.ItemFeeId,
                    i.ProductFeeId,
                    i.BookingItemId,
                    i.BookingParticipantId,
                    i.BookingResourceId,
                    i.BookingFeeId,
                    i.IsTaxable,
                    i.TaxCode,
                    i.ExternalId,
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    i.BundledItemPrinciple,
                    1
                FROM #invoiceDetails i
                LEFT JOIN  invoice.InvoiceDetail tgt
                    ON  tgt.InvoiceHeaderId = @invoiceHeaderId
                    AND tgt.InvoiceDetailStatusId = 1
                    AND (
                        tgt.BookingItemId = i.BookingItemId
                        OR tgt.BookingFeeId = i.BookingFeeId
                        OR tgt.BookingParticipantId = i.BookingParticipantId
                        --	OR tgt.BookingResourceId = i.BookingResourceId
                        OR tgt.ExternalId = i.ExternalId
                    )
                WHERE tgt.Id IS NULL;

                /* Update related invoice detail for promotions */
                UPDATE id SET
                    id.RelatedInvoiceDetailId = (
                        SELECT TOP 1 baseId.Id
                        FROM invoice.InvoiceDetail baseId
                        WHERE baseId.InvoiceHeaderId = @invoiceHeaderId
                          AND REPLACE(id.ExternalId,'-Promo','') = baseId.ExternalId
                    ),
                    id.ModifiedBy = @changeUser,
                    id.ModifiedDate = SYSDATETIMEOFFSET()
                FROM invoice.InvoiceDetail id
                WHERE id.InvoiceHeaderId = @invoiceHeaderId
                  AND RIGHT(id.ExternalId, 6) = '-Promo';

                UPDATE id SET
                    id.RelatedInvoiceDetailId = (
                        SELECT TOP 1 baseId.Id
                        FROM invoice.InvoiceDetail baseId
                        JOIN booking.BookingParticipant bp
                            ON baseId.ExternalId = bp.ExternalId
                        WHERE baseId.InvoiceHeaderId = @invoiceHeaderId
                            AND bp.ParticipantTypeId = 1 -- Base
                    ),
                    id.ModifiedBy = @changeUser,
                    id.ModifiedDate = SYSDATETIMEOFFSET()
                FROM invoice.InvoiceDetail id
                WHERE id.InvoiceHeaderId = @invoiceHeaderId
                  AND ExternalId = 'Discount';

                UPDATE id SET
                    id.RelatedInvoiceDetailId = (
                        SELECT TOP 1 baseId.Id
                        FROM invoice.InvoiceDetail baseId
                        JOIN booking.BookingParticipant bp
                            ON baseId.ExternalId = bp.ExternalId
                        WHERE baseId.InvoiceHeaderId = @invoiceHeaderId
                            AND bp.ParticipantTypeId = 1 -- Base
                    ),
                    id.ModifiedBy = @changeUser,
                    id.ModifiedDate = SYSDATETIMEOFFSET()
                FROM invoice.InvoiceDetail id
                WHERE id.InvoiceHeaderId = @invoiceHeaderId
                    AND ExternalId like '%Entitlement%';

                UPDATE i SET
                    RelatedInvoiceDetailId = rid.Id
                FROM invoice.InvoiceDetail i
                JOIN #invoiceDetails d
                    ON d.ExternalId = i.ExternalId
                JOIN #invoiceDetails rd
                    ON rd.Id = d.RelatedInvoiceDetailId
                JOIN invoice.InvoiceDetail rid
                    ON rd.ExternalId = rid.ExternalId
                WHERE d.RelatedInvoiceDetailId IS NOT NULL
                    AND rid.InvoiceDetailStatusId = 1 /* Active */
                    AND i.InvoiceDetailStatusId = 1 /* Active */
                    AND i.InvoiceHeaderId = @invoiceHeaderId
                    AND rid.InvoiceHeaderId = @invoiceHeaderId;
            END;  -- @invoiceDetails IS NOT NULL

        EXEC invoice.GetInvoiceForBooking @invoiceHeaderId;

    END TRY
    BEGIN CATCH
        ROLLBACK TRAN;
        THROW;
    END CATCH
    COMMIT TRAN;
END
GO
