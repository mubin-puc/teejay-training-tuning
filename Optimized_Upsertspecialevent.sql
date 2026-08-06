/****************************************************************************************************************
  INDEXES -- supports the writes/voids inside UpsertSpecialEvent's transaction. Run once, safe to re-run.
  Shorter lock-hold time on these tables = less time other sessions spend queued behind this transaction.
****************************************************************************************************************/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BookingItem_BookingId' AND object_id = OBJECT_ID('booking.BookingItem'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BookingItem_BookingId ON booking.BookingItem (BookingId) INCLUDE (Deleted);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InvoiceDetail_BookingItemId' AND object_id = OBJECT_ID('invoice.InvoiceDetail'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_InvoiceDetail_BookingItemId ON invoice.InvoiceDetail (BookingItemId) INCLUDE (InvoiceDetailStatusId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BookingFee_BookingId' AND object_id = OBJECT_ID('booking.BookingFee'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BookingFee_BookingId ON booking.BookingFee (BookingId);
END
GO


/****** Object:  StoredProcedure [booking].[UpsertSpecialEvent] -- reviewed, indexes added, no logic changed ****
  [REVIEW] booking.CreateBookingAudit runs INSIDE the transaction (before COMMIT), extending how long
  this SP holds its locks. Moving it after COMMIT would shorten lock time further, same idea as the
  GetSpecialEvent call at the end (which was already correctly placed after COMMIT in the original).
  Not moved here -- flagging for your team, since audit logs are sometimes required to stay
  transactionally consistent with the change they're logging. Needs a business decision, not a
  unilateral code change.

  [REVIEW] The OPTION (RECOMPILE) fix already present on the PaymentInvoiceDetail UPDATE below (CORE-336
  area) addresses the confirmed 94M-row parameter-sniffing issue. If your client's screenshot still shows
  this UPDATE running long, check session 24 (the session THIS session was blocked by, per the Azure
  dashboard) before assuming this statement regressed -- it may be waiting on something upstream, not
  re-scanning.
****************************************************************************************************************/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROC [booking].[UpsertSpecialEvent](
    @specialEvent NVARCHAR(MAX),
    @booking NVARCHAR(MAX),
    @items NVARCHAR(MAX),
    @isTaxExempt BIT = 0,
    @bookingId INT = NULL,
    @changeUser NVARCHAR(256),
    @rowVer TIMESTAMP = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRAN;
    BEGIN TRY
        DECLARE @scheduleDetailId INT = (SELECT ScheduleDetailid FROM OPENJSON(@booking) WITH (ScheduleDetailId INT))
        IF
            ISNULL((SELECT
                MinimumProductLevelId
            FROM booking.ScheduleDetails
            WHERE @scheduleDetailId = Id)
            , 0) <> 300
        BEGIN
            UPDATE booking.ScheduleDetails
            SET MinimumProductLevelId = 300
            WHERE @scheduleDetailId = Id
        END

        /* If booking has been finalized/ no show/ deleted or cancelled */
        IF @bookingId IS NOT NULL AND EXISTS  (
            SELECT b.Paid
            FROM booking.Booking b
            WHERE b.Id = @bookingId
                AND (
                    b.Paid IS NOT NULL
                    OR b.NoShow IS NOT NULL
                    OR b.Canceled IS NOT NULL
                    OR b.Deleted IS NOT NULL
                    )
            )
            BEGIN
                THROW 52000, 'This booking has already been finalized.', 16;
            END

        IF ISNULL(@bookingId, 0) = 0
            BEGIN
                INSERT INTO booking.Booking
                    (
                        ParkId,
                        AccountId,
                        ScheduleDetailId,
                        ProductLevelId,
                        RequiresHandicap,
                        HasProtectionPlan,
                        InternalNotes,
                        ExternalNotes,
                        InvoiceId,
                        CreatedBy,
                        CreatedDate,
                        ModifiedBy,
                        ModifiedDate,
                        DepositPrice,
                        IsSpecialEvent,
                        RelatedBookingId
                    )
                SELECT
                    b.ParkId,
                    b.AccountId,
                    b.ScheduleDetailId,
                    b.ProductLevelId,
                    0,
                    0,
                    b.InternalNotes,
                    b.ExternalNotes,
                    b.InvoiceId,
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    b.DepositPrice,
                    b.IsSpecialEvent,
                    b.RelatedBookingId
                FROM OPENJSON(@booking)
                              WITH
                                  (
                                  ParkId UNIQUEIDENTIFIER,
                                  AccountId INT,
                                  ScheduleDetailId INT,
                                  ProductLevelId INT,
                                  InternalNotes NVARCHAR(1000),
                                  ExternalNotes NVARCHAR(1000),
                                  InvoiceId INT,
                                  DepositPrice DECIMAL(18, 6),
                                  IsSpecialEvent BIT,
                                  RelatedBookingId INT
                                  ) b;
                SET @bookingId = SCOPE_IDENTITY();

                INSERT INTO booking.BookingSpecialEvent
                    (
                        BookingId,
                        CookieId,
                        OrganizationName,
                        IsTaxExempt,
                        TaxCode,
                        ContactFirstName,
                        ContactLastName,
                        EmailAddress,
                        PhoneNumber,
                        BasePrice,
                        BaseParticipantCount,
                        ExtraPrice,
                        ExtraParticipantCount,
                        IsQuote,
                        IsGroupSales,
                        ExpirationDate
                    )
                SELECT
                    @bookingId,
                    NEWID(),
                    se.OrganizationName,
                    se.IsTaxExempt,
                    se.TaxCode,
                    se.ContactFirstName,
                    se.ContactLastName,
                    se.EmailAddress,
                    se.PhoneNumber,
                    se.BasePrice,
                    se.BaseParticipantCount,
                    se.ExtraPrice,
                    se.ExtraParticipantCount,
                    se.IsQuote,
                    se.IsGroupSales,
                    se.ExpirationDate
                FROM OPENJSON(@specialEvent)
                              WITH
                                  (
                                  OrganizationName NVARCHAR(256),
                                  IsTaxExempt BIT,
                                  TaxCode NVARCHAR(20),
                                  ContactFirstName NVARCHAR(100),
                                  ContactLastName NVARCHAR(100),
                                  EmailAddress NVARCHAR(255),
                                  PhoneNumber NVARCHAR(20),
                                  BasePrice DECIMAL(18, 6),
                                  BaseParticipantCount INT,
                                  ExtraPrice DECIMAL(18, 6),
                                  ExtraParticipantCount INT,
                                  IsQuote BIT,
                                  IsGroupSales BIT,
                                  ExpirationDate DATE
                                  ) se;

                INSERT INTO booking.BookingItem
                    (
                        BookingId, ParkProductId, ParkProductName, Included, Quantity, Price, IsTaxable, TaxCode, ExternalId,
                        CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
                    )
                SELECT
                    @bookingId,
                    i.ParkProductId,
                    i.ParkProductName,
                    i.Included,
                    i.Quantity,
                    CASE WHEN Included = 1 THEN 0 ELSE i.Price END Price,
                    CASE WHEN @isTaxExempt = 1 THEN 0 ELSE i.IsTaxable END IsTaxable,
                    pp.TaxCode,
                    pcp.ExternalId,
                    @changeUser,
                    SYSDATETIMEOFFSET(),
                    @changeUser,
                    SYSDATETIMEOFFSET()
                FROM OPENJSON(@items)
                              WITH
                                  (
                                  ParkProductId INT,
                                  ParkProductName NVARCHAR(255),
                                  Included BIT,
                                  Quantity INT,
                                  Price DECIMAL(18, 6),
                                  IsTaxable BIT,
                                  TaxCode NVARCHAR(20)
                                  ) i
                LEFT JOIN prdct.ParkProduct pp
                    ON pp.Id = i.ParkProductId
                LEFT JOIN prdct.ProductChannelProduct pcp
                    ON pcp.ParkProductId = i.ParkProductId;

                /* Insert BookingItemFees */
                IF (SELECT BasePrice FROM OPENJSON(@specialEvent) WITH (BasePrice DECIMAL(18,6))) <> 0
                BEGIN
                    INSERT INTO booking.BookingFee
                    (
                            BookingId,
                            ProductFeeId,
                            Price,
                            IsTaxable,
                            Description,
                            TaxCode
                    )
                    SELECT
                        @bookingId,
                        pf.Id,
                        pf.Amount,
                        CASE WHEN @isTaxExempt = 1 THEN 0 ELSE 1 END IsTaxable,
                        pf.Description,
                        pf.TaxCode
                    FROM prdct.ProductFee pf
                         JOIN booking.Booking b
                            ON b.ParkId = pf.ParkId
                    WHERE pf.ProductTypeId = 9
                        AND b.Id = @bookingId
                        AND GETDATE()
                        BETWEEN pf.ValidFrom and pf.ValidTo
                    ORDER by pf.id DESC
                END;
            END;
        ELSE
            BEGIN
            /* If booking exists */

                DECLARE @currentRowVersion TIMESTAMP =
                    (
                        SELECT TOP (1) b.RowVer
                        FROM booking.Booking b
                        WHERE @bookingId = b.Id
                    );

                IF @currentRowVersion = @rowVer
                    BEGIN
                        UPDATE booking.Booking
                        SET ScheduleDetailId = b.ScheduleDetailId,
                            InternalNotes    = b.InternalNotes,
                            ExternalNotes    = b.ExternalNotes,
                            DepositPrice     = b.DepositPrice,
                            ProductLevelId   = b.ProductLevelId,
                            RelatedBookingId = b.RelatedBookingId,
                            ModifiedBy       = @changeUser,
                            ModifiedDate     = SYSDATETIMEOFFSET()
                        FROM booking.Booking bk
                        JOIN
                        OPENJSON(@booking)
                                 WITH
                                     (
                                     Id INT,
                                     ScheduleDetailId INT,
                                     InternalNotes NVARCHAR(1000),
                                     ExternalNotes NVARCHAR(1000),
                                     DepositPrice DECIMAL(18, 6),
                                     ProductLevelId INT,
                                     RelatedBookingId INT
                                     ) b
                            ON b.Id = bk.Id
                        WHERE b.Id = bk.Id;

                        UPDATE booking.BookingSpecialEvent
                        SET OrganizationName      = u.OrganizationName,
                            IsTaxExempt           = u.IsTaxExempt,
                            TaxCode               = u.TaxCode,
                            ContactFirstName      = u.ContactFirstName,
                            ContactLastName       = u.ContactLastName,
                            EmailAddress          = u.EmailAddress,
                            PhoneNumber           = u.PhoneNumber,
                            BasePrice             = u.BasePrice,
                            BaseParticipantCount  = u.BaseParticipantCount,
                            ExtraPrice            = u.ExtraPrice,
                            ExtraParticipantCount = u.ExtraParticipantCount,
                            IsQuote               = u.IsQuote,
                            IsGroupSales          = u.IsGroupSales,
                            ExpirationDate        = u.ExpirationDate
                        FROM booking.BookingSpecialEvent s
                        JOIN booking.Booking b
                            ON s.BookingId = b.Id
                        OUTER APPLY (
                            SELECT OrganizationName,
                                     IsTaxExempt,
                                     TaxCode,
                                     ContactFirstName,
                                     ContactLastName,
                                     EmailAddress,
                                     PhoneNumber,
                                     ProductLevelId,
                                     BasePrice,
                                     BaseParticipantCount,
                                     ExtraPrice,
                                     ExtraParticipantCount,
                                     IsQuote,
                                     IsGroupSales,
                                     ExpirationDate
                            FROM
                            OPENJSON(@specialEvent)
                                 WITH
                                     (
                                     OrganizationName NVARCHAR(256),
                                     IsTaxExempt BIT,
                                     TaxCode NVARCHAR(20),
                                     ContactFirstName NVARCHAR(100),
                                     ContactLastName NVARCHAR(100),
                                     EmailAddress NVARCHAR(255),
                                     PhoneNumber NVARCHAR(20),
                                     ProductLevelId INT,
                                     BasePrice DECIMAL(18, 6),
                                     BaseParticipantCount INT,
                                     ExtraPrice DECIMAL(18, 6),
                                     ExtraParticipantCount INT,
                                     IsQuote BIT,
                                     IsGroupSales BIT,
                                     ExpirationDate DATE
                                     ) se
                            ) u
                        WHERE b.Id = @bookingId;

                        /* CORE: lock-order fix. These 3 statements used to write to one table
                           (InvoiceDetail / BookingItem / PaymentInvoiceDetail) while live-joining
                           another live table in the same statement. That's the same deadlock
                           precondition already fixed the same way in
                           invoice.UpsertBookingInvoiceHeader and booking.ConvertCartToBookingJustifi,
                           which write these same 3 tables. Capturing the affected Ids into temp
                           tables first (cheap reads, locks released immediately) means every
                           UPDATE below only ever writes its own table joined to a local temp
                           table - never two live tables in the same statement. Row scope for
                           each statement is unchanged from the original: statement 1 is scoped
                           to this booking's BookingItems, statement 3 (PaymentInvoiceDetail) is
                           scoped to this booking's whole InvoiceHeader, same as before.
                           No logic/result change. */
                        DROP TABLE IF EXISTS #voidBookingItemIds;
                        DROP TABLE IF EXISTS #voidBookingItemInvoiceDetailIds;
                        DROP TABLE IF EXISTS #headerInvoiceDetailIds;

                        SELECT bi.Id BookingItemId
                        INTO #voidBookingItemIds
                        FROM booking.BookingItem bi
                        WHERE bi.BookingId = @bookingId;

                        SELECT id.Id
                        INTO #voidBookingItemInvoiceDetailIds
                        FROM invoice.InvoiceDetail id
                        JOIN #voidBookingItemIds v
                            ON id.BookingItemId = v.BookingItemId;

                        SELECT id.Id
                        INTO #headerInvoiceDetailIds
                        FROM invoice.InvoiceDetail id
                        JOIN invoice.InvoiceHeader ih
                            ON id.InvoiceHeaderId = ih.Id
                        WHERE ih.BookingId = @bookingId;

                        -- 1. void the invoice details tied to this booking's items
                        UPDATE id
                        SET id.ModifiedBy = @changeUser,
                            id.ModifiedDate = SYSDATETIMEOFFSET(),
                            id.InvoiceDetailStatusId = 2 /* Voided */
                        FROM invoice.InvoiceDetail id
                        JOIN #voidBookingItemInvoiceDetailIds v
                            ON v.Id = id.Id;

                        -- 2. soft-delete the booking items themselves
                        UPDATE bi
                        SET bi.Deleted = SYSDATETIMEOFFSET(),
                            bi.ModifiedBy = @changeUser,
                            bi.ModifiedDate = SYSDATETIMEOFFSET()
                        FROM booking.BookingItem bi
                        JOIN #voidBookingItemIds v
                            ON bi.Id = v.BookingItemId;

                        -- 3. void the payment allocations for every invoice detail on this booking's header
                        UPDATE pid
                        SET pid.ModifiedBy = @changeUser,
                            pid.ModifiedDate = SYSDATETIMEOFFSET(),
                            pid.PaymentInvoiceDetailStatusId = 2 /* Voided */
                        FROM invoice.PaymentInvoiceDetail pid
                        JOIN #headerInvoiceDetailIds v
                            ON v.Id = pid.InvoiceDetailId
                        /* CORE: kill parameter-sniffing regression that scanned 94M-row
                           invoice.PaymentInvoiceDetail. A special-event booking touches <=~270
                           PID rows, so a per-call recompile always yields an index-seek plan
                           (IX_PaymentInvoiceDetail_InvoiceDetailId_...). ~450 calls/day => trivial
                           recompile cost. No logic/result change. */
                        OPTION (RECOMPILE);

                        INSERT INTO booking.BookingItem
                            (
                                BookingId,
                                ParkProductId,
                                ParkProductName,
                                Included,
                                Quantity,
                                Price,
                                IsTaxable,
                                TaxCode,
                                ExternalId,
                                CreatedBy,
                                CreatedDate,
                                ModifiedBy,
                                ModifiedDate
                            )
                        SELECT
                            @bookingId,
                            i.ParkProductId,
                            i.ParkProductName,
                            i.Included,
                            i.Quantity,
                            CASE WHEN Included = 1 THEN 0 ELSE i.Price END Price,
                            CASE WHEN @isTaxExempt = 1 THEN 0 ELSE i.IsTaxable END IsTaxable,
                            pp.TaxCode,
                            pcp.ExternalId,
                            @changeUser,
                            SYSDATETIMEOFFSET(),
                            @changeUser,
                            SYSDATETIMEOFFSET()
                        FROM OPENJSON(@items)
                                      WITH
                                          (
                                          ParkProductId INT,
                                          ParkProductName NVARCHAR(255),
                                          Included BIT,
                                          Quantity INT,
                                          Price DECIMAL(18, 6),
                                          IsTaxable BIT,
                                          TaxCode NVARCHAR(20),
                                          ExternalId NVARCHAR(50)
                                          ) i
                        LEFT JOIN prdct.ParkProduct pp
                            ON pp.Id = i.ParkProductId
                        LEFT JOIN prdct.ProductChannelProduct pcp
                           ON pcp.ParkProductId = i.ParkProductId;

                        IF
                            (SELECT InvoiceId FROM booking.Booking WHERE Id = @bookingId) IS NULL
                        BEGIN
                            UPDATE booking.BookingFee
                            SET IsTaxable = CASE WHEN @isTaxExempt = 1 THEN 0 ELSE 1 END
                            WHERE BookingId = @bookingId;
                        END

                        /* Insert BookingItemFees */
                        IF (
                            (SELECT BasePrice
                            FROM OPENJSON(@specialEvent)
                                WITH (BasePrice DECIMAL(18,6))) <> 0
                            AND NOT EXISTS (SELECT Id
                            FROM booking.BookingFee bf
                            WHERE bf.BookingId = @bookingId)
                        )
                        BEGIN
                            INSERT INTO booking.BookingFee
                            (
                                    BookingId,
                                    ProductFeeId,
                                    Price,
                                    IsTaxable,
                                    Description,
                                    TaxCode
                            )
                            SELECT
                                @bookingId,
                                pf.Id,
                                pf.Amount,
                                CASE WHEN @isTaxExempt = 1 THEN 0 ELSE 1 END IsTaxable,
                                pf.Description,
                                pf.TaxCode
                            FROM prdct.ProductFee pf
                                 JOIN booking.Booking b
                                    ON b.ParkId = pf.ParkId
                            WHERE pf.ProductTypeId = 9
                                AND b.Id = @bookingId
                                AND GETDATE()
                                BETWEEN pf.ValidFrom and pf.ValidTo
                            ORDER by pf.id DESC
                        END;
                        ELSE IF (
                            SELECT (BasePrice + (ExtraPrice * ExtraParticipantCount))
                            FROM OPENJSON(@specialEvent)
                                WITH (
                                    BasePrice DECIMAL(18,6),
                                    ExtraPrice DECIMAL(18,6),
                                    ExtraParticipantCount INT
                                )
                        ) = 0
                        BEGIN
                            DELETE FROM booking.BookingFee
                            WHERE BookingId = @bookingId;
                        END;
                    END;

                ELSE
                    BEGIN
                        IF @currentRowVersion IS NULL
                            BEGIN
                                THROW 52000, 'Record not found.', 16;
                            END;
                        ELSE
                            BEGIN
                                THROW 51000, 'You do not have the latest copy of this record.', 16;
                            END;
                    END;
            END;

        EXEC booking.CreateBookingAudit @bookingId, @changeUser;
    END TRY
    BEGIN CATCH
        ROLLBACK TRAN;
        THROW;
    END CATCH
    COMMIT TRAN;
    EXEC booking.GetSpecialEvent @bookingId = @bookingId;
END
GO
