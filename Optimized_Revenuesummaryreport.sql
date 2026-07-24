-- Supporting indexes for base tables (run once). Safe to re-run.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AccountsToIgnore_AccountId' AND object_id = OBJECT_ID('maintenance.AccountsToIgnore'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountsToIgnore_AccountId ON maintenance.AccountsToIgnore (AccountId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Brands_UrlSlug' AND object_id = OBJECT_ID('dbo.Brands'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Brands_UrlSlug ON dbo.Brands (UrlSlug);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Park_UrlSlug' AND object_id = OBJECT_ID('park.Park'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Park_UrlSlug ON park.Park (UrlSlug) INCLUDE (BrandId, Timezone);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Payment_CreatedDate_Status' AND object_id = OBJECT_ID('invoice.Payment'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Payment_CreatedDate_Status ON invoice.Payment (CreatedDate, PaymentStatusId)
        INCLUDE (InvoiceHeaderId, PaymentChannelId, PaymentOriginId, IsDeposit, RefundedPaymentId, Amount, ExternalId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PmtPayment_CreatedDate_Status' AND object_id = OBJECT_ID('payment.Payment'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_PmtPayment_CreatedDate_Status ON payment.Payment (CreatedDate, PaymentStatusId)
        INCLUDE (InvoiceId, PaymentProviderId, IsDeposit, RequestId, ExternalId, Amount);
END
GO

/****** Object:  StoredProcedure [report].[RevenueSummaryReport]    Script Date: 7/23/2026 5:11:13 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [report].[RevenueSummaryReport] ( -- [OPT]
    @brandSlug NVARCHAR(25) = NULL,
    @locationSlug NVARCHAR(30) = NULL,
    @fromDate DATE,
    @toDate DATE,
    @isCorporate BIT,
    @isAggregate BIT
)
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #results;
    DROP TABLE IF EXISTS #applicationFeeDetail;
    DROP TABLE IF EXISTS #paymentPaymentReconciliationXRef;
    DROP TABLE IF EXISTS #reservationEventTypes;
    DROP TABLE IF EXISTS #justifiPayments;
    DROP TABLE IF EXISTS #braintreePayments;
    DROP TABLE IF EXISTS #applicationFeeSum; -- [OPT]
    DROP TABLE IF EXISTS #lineItemSubscriptionInfo; -- [OPT]
    DROP TABLE IF EXISTS #lineItemEventTypes; -- [OPT]

    CREATE TABLE #results (
        Brand NVARCHAR(256),
        Location NVARCHAR(256),
        TransactionDate DATE,
        DisbursementDate DATE,
        AccountId INT,
        AccountHolder NVARCHAR(512),
        Category NVARCHAR(64),
        Product NVARCHAR(256),
        ItemPrice DECIMAL(18, 6),
        Discount DECIMAL(18, 6),
        ZeeTax DECIMAL(18,6),
        CorpFeeTax DECIMAL(18, 6),
        CorpMembershipTax DECIMAL(18, 6),
        TotalPrice AS ItemPrice + Discount + ZeeTax + CorpFeeTax + CorpMembershipTax,
        RoyaltyRevenue DECIMAL(18, 6),
        ProcessingFee DECIMAL(18,6),
        TransactionType NVARCHAR(64),
        Provider NVARCHAR(64),
        Source NVARCHAR(64),
        ConfirmationCode CHAR(10),
        InvoiceNumber INT,
        PaymentId INT
    );

    -- Fee details result set
    CREATE TABLE #applicationFeeDetail (
        Brand NVARCHAR(256),
        Location NVARCHAR(256),
        TransactionDate DATETIMEOFFSET,
        DisbursementDate DATE,
        AccountId INT,
        AccountHolder NVARCHAR(512),
        Category NVARCHAR(64),
        Product NVARCHAR(256),
        ItemPrice DECIMAL(18, 6),
        Discount DECIMAL(18, 6),
        ZeeTax DECIMAL(18,6),
        CorpFeeTax DECIMAL(18, 6),
        CorpMembershipTax DECIMAL(18, 6),
        TotalPrice AS ItemPrice + Discount + ZeeTax + CorpFeeTax + CorpMembershipTax,
        RoyaltyRevenue DECIMAL(18, 6),
        ProcessingFee DECIMAL(18,6),
        TransactionType NVARCHAR(64),
        Provider NVARCHAR(64),
        Source NVARCHAR(64),
        ConfirmationCode CHAR(10),
        InvoiceNumber INT,
        PaymentId INT
    );

    CREATE TABLE #reservationEventTypes (
        EventReservationId INT,
        EventType NVARCHAR(64)
    )

    CREATE TABLE #paymentPaymentReconciliationXRef (
        PaymentId INT,
        PaymentReconciliationId INT,
        DisbursementDate DATE
    )

    INSERT INTO #reservationEventTypes (EventReservationId, EventType)
    SELECT
        er.Id EventReservationId,
        et.Name EventType
    FROM events.EventReservations er
    JOIN events.FranchiseScheduleDetails fsd
        ON er.FranchiseScheduleDetailId = fsd.Id
    JOIN events.FranchiseSchedules fs
        ON fsd.FranchiseScheduleId = fs.Id
    JOIN events.EventTypes et
        ON fs.EventTypeId = et.Id

    CREATE UNIQUE CLUSTERED INDEX IX_reservationEventTypes ON #reservationEventTypes (EventReservationId); -- [OPT] index

    CREATE TABLE #justiFiPayments (
        PaymentId INT,
        TransactionDate DATETIMEOFFSET,
        DisbursementDate DATE,
        PaymentChannelId INT,
        InvoiceHeaderId INT,
        PaymentOriginId INT,
        IsDeposit BIT,
        RefundedPaymentId INT,
        Amount DECIMAL(18, 6)
    )

    INSERT INTO #justiFiPayments (PaymentId, TransactionDate, DisbursementDate, PaymentChannelId, InvoiceHeaderId, PaymentOriginId, IsDeposit, RefundedPaymentId, Amount)
    SELECT
        p.Id,
        p.CreatedDate,
        CONVERT(DATE, pp.AvailableOn),
        p.PaymentChannelId,
        p.InvoiceHeaderId,
        p.PaymentOriginId,
        p.IsDeposit,
        p.RefundedPaymentId,
        p.Amount
    FROM invoice.Payment p 
		JOIN invoice.InvoiceHeader ih 
			ON p.InvoiceHeaderId = ih.Id
		JOIN park.Park pk 
			ON ih.LocationId = pk.Id
		LEFT JOIN invoice.PayoutPayment pp 
			ON p.ExternalId = pp.PaymentId
    WHERE CONVERT(DATE, p.CreatedDate AT TIME ZONE pk.Timezone) BETWEEN @fromDate AND @toDate
        AND p.PaymentStatusId IN (2, 3) /* Authorized, Captured */

    CREATE UNIQUE CLUSTERED INDEX IX_justiFiPayments_PaymentId ON #justiFiPayments (PaymentId); -- [OPT] index
    CREATE NONCLUSTERED INDEX IX_justiFiPayments_InvoiceHeaderId ON #justiFiPayments (InvoiceHeaderId); -- [OPT] index

    -- Computed once here, indexed, and reused by both instead of being re-evaluated twice.
    SELECT afd.PaymentId, SUM(afd.UnitPrinciple) Fee
    INTO #applicationFeeSum
    FROM invoice.ApplicationFeeDetail afd
    WHERE afd.ApplicationFeeTypeId <> 3
    GROUP BY afd.PaymentId

    CREATE UNIQUE CLUSTERED INDEX IX_applicationFeeSum_PaymentId ON #applicationFeeSum (PaymentId);


    -- /* JustiFi Purchases */
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product, ItemPrice,
        Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId, RoyaltyRevenue, ProcessingFee)
    SELECT
        br.Name,
        pk.Name,
        CONVERT(DATE,jfp.TransactionDate AT TIME ZONE pk.Timezone),
        DisbursementDate, --DisbursementDate
        ih.AccountId,
        CONCAT(per.FirstName, ' ', per.LastName) AccountHolder,
        CASE
            WHEN ret.EventType IS NOT NULL
                THEN ret.EventType
            WHEN id.DetailTypeId = 5 /* Tip */
                THEN 'Tip'
            WHEN id.DetailTypeId = 4 /* Fee */
                THEN 'Fee'
            WHEN ih.BookingId IS NOT NULL AND jfp.IsDeposit = 1
                THEN 'Booking Deposit'
            WHEN ih.BookingId IS NOT NULL
                THEN 'Booking'
            WHEN s.TicketId IS NOT NULL
                THEN 'Ticket'
            WHEN s.BundleId IS NOT NULL
                THEN 'Bundle'
            ELSE t.DisplayName
        END Category,
        id.Description,
        pid.PaidPrinciple, --ItemPrice
        COALESCE(disc.Discount, 0),--Discount
        IIF((id.ProductFeeId IS NULL AND id.BookingFeeId IS NULL), pid.PaidTax + COALESCE(disc.DiscountTax, 0), 0),--Zee Tax
        IIF((id.ProductFeeId IS NULL AND id.BookingFeeId IS NULL), 0, pid.PaidTax + COALESCE(disc.DiscountTax, 0)), --CorpFeeTax
        0,--CorpMembershipTax
        IIF(ih.RecurringBillingPeriodId IS NULL, 'Purchase', 'Recurring') TransactionType,
        IIF(pc.Id = 5, 'Appetize', pc.Name) Provider, /* 5=PointOfSale */
        CASE
            WHEN ih.BookingId IS NOT NULL
                THEN IIF(po.Id = 1, 'Online Booking', 'Admin Booking')
            ELSE IIF(po.Id = 1, 'CC2', 'POS')
        END, /* 1=Ecommerce */
        CONCAT('J-', ih.ConfirmationCode),
        ih.Id,
        jfp.PaymentId,
        --Royalty Revenue
        -- --Removed Tips from Royalty Revenue (id.DetailTypeId 5)
        IIF(id.DetailTypeId = 5 OR id.BookingFeeId IS NOT NULL OR id.ProductFeeId IS NOT NULL, 0, pid.PaidPrinciple + COALESCE(disc.Discount, 0)),
        afd.Fee * -1 --ProcessingFee
    FROM invoice.InvoiceHeader ih
    JOIN park.Park pk
        ON ih.LocationId = pk.Id
    JOIN dbo.Brands br
        ON pk.BrandId = br.Id
    JOIN #justiFiPayments jfp
        ON jfp.InvoiceHeaderId = ih.Id
	LEFT JOIN #applicationFeeSum afd -- [OPT] de-duped subquery
        ON afd.PaymentId = jfp.PaymentId
    JOIN invoice.PaymentChannel pc
        ON pc.Id = jfp.PaymentChannelId
    JOIN acct.Account a
        ON a.Id = ih.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    JOIN invoice.PaymentInvoiceDetail pid
        ON pid.PaymentId = jfp.PaymentId
            AND pid.PaymentInvoiceDetailStatusId = 1 /* Active */
    JOIN invoice.InvoiceDetail id
        ON id.Id = pid.InvoiceDetailId
            AND id.InvoiceDetailStatusId = 1 /* Active */
    LEFT JOIN acct.Subscription s
        ON s.Id = id.SubscriptionId
    LEFT JOIN #reservationEventTypes ret
        ON ret.EventReservationId = id.EventReservationId
    LEFT JOIN prdct.ParkProduct pp
        ON pp.Id = s.ProductId
    LEFT JOIN prdct.ProductTemplate pt
        ON pt.Id = pp.ProductTemplateId
    LEFT JOIN prdct.ProductType t
        ON t.Id = pt.ProductTypeId
    JOIN invoice.PaymentOrigin po
        ON po.Id = jfp.PaymentOriginId
    LEFT JOIN (
        SELECT
            dd.RelatedInvoiceDetailId,
            dpid.PaymentId,
            SUM(dpid.PaidPrinciple) Discount,
            SUM(dpid.PaidTax) DiscountTax
        FROM invoice.InvoiceDetail dd
        JOIN invoice.PaymentInvoiceDetail dpid
            ON dpid.InvoiceDetailId = dd.Id
        WHERE dd.InvoiceDetailStatusId = 1 /* Active */
            AND dpid.PaymentInvoiceDetailStatusId = 1 /* Active */
            AND dd.DetailTypeId = 3 /* Discount */
        GROUP BY dd.RelatedInvoiceDetailId, dpid.PaymentId
    ) disc ON disc.RelatedInvoiceDetailId = id.Id
        AND disc.PaymentId = jfp.PaymentId
    WHERE jfp.RefundedPaymentId IS NULL
        AND (@brandSlug IS NULL
            OR br.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE ih.AccountId = ati.AccountId
        )
        AND pc.Id <> 6 /* None */
        AND id.DetailTypeId <> 3 /* Discount */
        AND (@isCorporate = 1 OR (id.ProductFeeId IS NULL AND id.BookingFeeId IS NULL))
        AND (pid.PaidTax <> 0 OR pid.PaidPrinciple <> 0)

    -- /* JustiFi Refunds */
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product, ItemPrice,
        Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId, RoyaltyRevenue)
    SELECT
        br.Name,
        pk.Name,
        rp.TransactionDate,
        DisbursementDate,
        ih.AccountId,
        CONCAT(per.FirstName, ' ', per.LastName) AccountHolder,
        CASE
            WHEN ret.EventType IS NOT NULL
                THEN ret.EventType
            WHEN id.DetailTypeId = 5 /* Tip */
                THEN 'Tip'
            WHEN id.DetailTypeId = 4 /* Fee */
                THEN 'Fee'
            WHEN ih.BookingId IS NOT NULL AND op.IsDeposit = 1
                THEN 'Booking Deposit'
            WHEN ih.BookingId IS NOT NULL
                THEN 'Booking'
            WHEN s.TicketId IS NOT NULL
                THEN 'Ticket'
            WHEN s.BundleId IS NOT NULL
                THEN 'Bundle'
            ELSE t.DisplayName
        END Category,
        id.Description,
        ad.PrincipleAdjustment * ad.QuantityAdjustment,
        0,
        IIF(id.ProductFeeId IS NULL AND id.BookingFeeId IS NULL AND @isCorporate = 0, ad.TaxAdjustment * ad.QuantityAdjustment, 0),
        IIF(id.ProductFeeId IS NULL AND id.BookingFeeId IS NULL AND @isCorporate = 0, 0, ad.TaxAdjustment * ad.QuantityAdjustment),
        0,
        'Refund',
        IIF(pc.Id = 5, 'Appetize', pc.Name) Provider, /* 5=PointOfSale */
        CASE
            WHEN ih.BookingId IS NOT NULL
                THEN IIF(po.Id = 1, 'Online Booking', 'Admin Booking')
            ELSE IIF(po.Id = 1, 'CC2', 'POS')
        END, /* 1=Ecommerce */
        CONCAT('J-', ih.ConfirmationCode),
        ih.Id,
        rp.PaymentId,
        IIF(id.BookingFeeId IS NOT NULL OR id.ProductFeeId IS NOT NULL, 0, ad.PrincipleAdjustment * ad.QuantityAdjustment)
    FROM invoice.InvoiceHeader ih
    JOIN invoice.AdjustmentInvoice ai
        ON ih.Id = ai.InvoiceHeaderId
    JOIN invoice.AdjustmentPayment ap
        ON ai.Id = ap.AdjustmentInvoiceId
    JOIN park.Park pk
        ON pk.Id = ih.LocationId
    JOIN dbo.Brands br
        ON br.Id = pk.BrandId
    JOIN #justiFiPayments rp
        ON ap.PaymentId = rp.PaymentId
    JOIN acct.Account ac
        ON ih.AccountId = ac.Id
    JOIN acct.Person per
        ON ac.PersonId = per.Id
    JOIN invoice.Payment op
        ON op.Id = rp.RefundedPaymentId
    JOIN invoice.AdjustmentDetail ad
        ON ad.AdjustmentInvoiceId = ai.Id
    JOIN invoice.InvoiceDetail id
        ON ad.InvoiceDetailId = id.Id
    LEFT JOIN acct.Subscription s
        ON s.Id = id.SubscriptionId
    LEFT JOIN #reservationEventTypes ret
        ON ret.EventReservationId = id.EventReservationId
    LEFT JOIN prdct.ParkProduct pp
        ON pp.Id = s.ProductId
    LEFT JOIN prdct.ProductTemplate pt
        ON pt.Id = pp.ProductTemplateId
    LEFT JOIN prdct.ProductType t
        ON t.Id = pt.ProductTypeId
    JOIN invoice.PaymentOrigin po
        ON po.Id = rp.PaymentOriginId
    JOIN invoice.PaymentChannel pc
        ON pc.Id = rp.PaymentChannelId
    WHERE (@brandSlug IS NULL
            OR br.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE ih.AccountId = ati.AccountId
        )
        AND pc.Id <> 6 /* None */
        AND id.DetailTypeId <> 3 /* Discount */
    --
    -- /* JustiFi Processing Fees */

    INSERT INTO #applicationFeeDetail (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        br.Name, --Brand
        pk.Name, --Location
        CONVERT(DATE,pmt.TransactionDate AT TIME ZONE pk.Timezone), --TransactionDate
        DisbursementDate,--DisbursementDate
        a.Id, --AccountId
        CONCAT(per.FirstName, ' ', per.LastName) AccountHolder,
        'Fee', --Category
        'Processing Fee', --Product
        afd.Fee * -1, --ItemPrice
        0, --Discount
        0, --ZeeTax
        0, -- CorpFeeTax
        0,--CorpMembershipTax
        0, --RoyaltyRevenue
        CASE
            WHEN pmt.Amount < 0
                THEN 'Refund'
            WHEN ih.RecurringBillingPeriodId IS NOT NULL
                THEN 'Recurring'
            ELSE 'Purchase'
        END, --TransactionType
        IIF(pc.Id = 5, 'Appetize', pc.Name) Provider, /* 5=PointOfSale */ --Provider
        CASE
            WHEN ih.BookingId IS NOT NULL
                THEN IIF(po.Id = 1, 'Online Booking', 'Admin Booking')
            ELSE IIF(po.Id = 1, 'CC2', 'POS')
        END, /* 1=Ecommerce */ --Source
        CONCAT('J-', ih.ConfirmationCode),--ConfirmationCode
        ih.Id, --InvoiceId
        pmt.PaymentId --PaymentId
    FROM invoice.InvoiceHeader ih
    JOIN park.Park pk
        ON ih.LocationId = pk.Id
    JOIN dbo.Brands br
        ON pk.BrandId = br.Id
    JOIN #justiFiPayments pmt
        ON pmt.InvoiceHeaderId = ih.Id
    LEFT JOIN #applicationFeeSum afd -- [OPT] de-duped subquery
        ON afd.PaymentId = pmt.PaymentId
    JOIN invoice.PaymentChannel pc
        ON pc.Id = pmt.PaymentChannelId
    JOIN invoice.PaymentOrigin po
        ON po.Id = pmt.PaymentOriginId
    JOIN acct.Account a
        ON a.Id = ih.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    WHERE (@brandSlug IS NULL
            OR br.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE ih.AccountId = ati.AccountId
        )
        AND pc.Id <> 6 /* None */
        AND afd.Fee <> 0

    /* Braintree */
    INSERT INTO #paymentPaymentReconciliationXRef (PaymentId,
                                                   PaymentReconciliationId,
                                                   DisbursementDate)
    SELECT
        pmt.Id PaymentId,
        pr.Id PaymentReconciliationId,
        pr.DisbursementDate
    FROM payment.PaymentReconciliation pr
    JOIN payment.Payment pmt
        ON pmt.RequestId = pr.RequestId
    WHERE CONVERT(DATE, pmt.CreatedDate) BETWEEN @fromDate AND @toDate;

    INSERT INTO #paymentPaymentReconciliationXRef (PaymentId,
                                                   PaymentReconciliationId,
                                                   DisbursementDate)
    SELECT
        pmt.Id,
        pr.Id,
        pr.DisbursementDate
    FROM payment.PaymentReconciliation pr
    JOIN payment.Payment pmt
        ON pmt.ExternalId = pr.ExternalId
    WHERE CONVERT(DATE, pmt.CreatedDate) BETWEEN @fromDate AND @toDate
        AND NOT EXISTS(
            SELECT 1
            FROM #paymentPaymentReconciliationXRef pprxr
            WHERE pprxr.PaymentId = pmt.Id
              AND pprxr.PaymentReconciliationId = pr.Id
        )

    CREATE NONCLUSTERED INDEX IX_pprXRef_PaymentId ON #paymentPaymentReconciliationXRef (PaymentId); -- [OPT] index

    CREATE TABLE #braintreePayments (
        Id INT,
        InvoiceId INT,
        Amount DECIMAL(18, 6),
        TransactionDate DATE,
        DisbursementDate DATE,
        PaymentProviderId INT,
        IsDeposit BIT
    )

    INSERT INTO #braintreePayments (Id, InvoiceId, Amount, TransactionDate, DisbursementDate, PaymentProviderId, IsDeposit)
    SELECT
        p.Id,
        p.InvoiceId,
        p.Amount,
        CONVERT(DATE, p.CreatedDate),
        px.DisbursementDate,
        p.PaymentProviderId,
        p.IsDeposit
    FROM payment.Payment p
    LEFT JOIN #paymentPaymentReconciliationXRef px
        ON px.PaymentId = p.Id
    WHERE CONVERT(DATE, p.CreatedDate) BETWEEN @fromDate AND @toDate
        AND p.PaymentStatusId IN (2, 3) /* Submitted, settled */

    CREATE UNIQUE CLUSTERED INDEX IX_braintreePayments_Id ON #braintreePayments (Id); -- [OPT] index
    CREATE NONCLUSTERED INDEX IX_braintreePayments_InvoiceId ON #braintreePayments (InvoiceId);

    -- Computed once here, indexed, and reused by both.
    SELECT
        lis.LineItemId,
        lis.ProductName,
        t.DisplayName ProductType,
        sub.TicketId,
        sub.BundleId,
        pt.ProductTypeId
    INTO #lineItemSubscriptionInfo
    FROM payment.LineItemSubscription lis
    JOIN acct.Subscription sub
        ON lis.SubscriptionId = sub.Id
    LEFT JOIN prdct.ParkProduct p
        ON sub.ProductId = p.Id
    LEFT JOIN prdct.ProductTemplate pt
        ON p.ProductTemplateId = pt.Id
    LEFT JOIN prdct.ProductType t
        ON pt.ProductTypeId = t.Id
    GROUP BY lis.LineItemId, lis.ProductName, t.DisplayName, sub.TicketId, sub.BundleId, pt.ProductTypeId

    CREATE NONCLUSTERED INDEX IX_lineItemSubscriptionInfo_LineItemId ON #lineItemSubscriptionInfo (LineItemId);

    SELECT
        lier.LineItemId,
        ret.EventType
    INTO #lineItemEventTypes
    FROM payment.LineItemEventReservation lier
    JOIN #reservationEventTypes ret
        ON ret.EventReservationId = lier.EventReservationId
    GROUP BY lier.LineItemId, ret.EventType

    CREATE NONCLUSTERED INDEX IX_lineItemEventTypes_LineItemId ON #lineItemEventTypes (LineItemId);

    /* Braintree Payments */
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpMembershipTax, CorpFeeTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        br.Name,
        pk.Name,
        pmt.TransactionDate,
        pmt.DisbursementDate,
        ai.AccountId,
        CONCAT(per.FirstName, ' ', per.LastName) AccountHolder,
        CASE
            WHEN ret.EventType IS NOT NULL
                THEN ret.EventType
            WHEN li.ItemTypeId IN (2, 8) /* Fee, ItemFee */
                THEN 'Fee'
            WHEN lis.TicketId IS NOT NULL
                THEN 'Ticket'
            WHEN lis.BundleId IS NOT NULL
                THEN 'Bundle'
            ELSE lis.ProductType
        END Category,
        COALESCE(lis.ProductName, liif.ItemFeeName, lipf.FeeName, ret.EventType),
        li.Amount * li.Quantity,
        COALESCE(pli.Amount * pli.Quantity, 0) + COALESCE(aeli.Amount * aeli.Quantity, 0) + COALESCE(rdli.Amount * rdli.Quantity, 0),
        IIF((lis.ProductTypeId = 1 AND br.Id = 1) OR lipf.Id IS NOT NULL, /* Membership, Urban Air */
            0,
            li.Tax * li.Quantity + COALESCE(pli.Tax * pli.Quantity, 0) + COALESCE(aeli.Tax * aeli.Quantity, 0)
                + COALESCE(rdli.Tax * rdli.Quantity, 0)
        ),
        IIF(lis.ProductTypeId = 1 AND br.Id = 1 AND @isCorporate = 1, /* Membership, Urban Air */
            li.Tax * li.Quantity + COALESCE(pli.Tax * pli.Quantity, 0) + COALESCE(aeli.Tax * aeli.Quantity, 0)
                + COALESCE(rdli.Tax * rdli.Quantity, 0),
            0
        ),
        IIF(lipf.Id IS NOT NULL AND @isCorporate = 1,
            li.Tax * li.Quantity + COALESCE(pli.Tax * pli.Quantity, 0) + COALESCE(aeli.Tax * aeli.Quantity, 0)
                + COALESCE(rdli.Tax * rdli.Quantity, 0),
            0
        ),
        IIF(lipf.Id IS NOT NULL, 0, (li.Amount * li.Quantity) + COALESCE(pli.Amount * pli.Quantity, 0)
            + COALESCE(aeli.Amount * aeli.Quantity, 0) + COALESCE(rdli.Amount * rdli.Quantity, 0)),
        it.Name,
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        IIF(ai.StorefrontId = 1, 'CC2', 'POS'), /* Ecommerce */
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        pmt.Id
    FROM payment.Invoice inv
    JOIN #braintreePayments pmt
        ON pmt.InvoiceId = inv.Id
    JOIN payment.PaymentProvider pprov
        ON pmt.PaymentProviderId = pprov.Id
    JOIN payment.LineItem li
        ON li.InvoiceId = inv.Id
    JOIN acct.AccountInvoices ai
        ON ai.InvoiceId = inv.Id
    JOIN park.Park pk
        ON pk.Id = ai.ParkId
    JOIN dbo.Brands br
        ON br.Id = pk.BrandId
    JOIN acct.Account a
        ON a.Id = ai.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    LEFT JOIN #lineItemSubscriptionInfo lis -- [OPT] de-duped subquery
        ON lis.LineItemId = li.Id
    LEFT JOIN #lineItemEventTypes ret -- [OPT] de-duped subquery
        ON ret.LineItemId = li.Id
    LEFT JOIN payment.LineItemItemFee liif
        ON liif.ItemFeeLineItemId = li.Id
    LEFT JOIN payment.LineItemProductFee lipf
        ON lipf.LineItemId = li.Id
    JOIN payment.InvoiceType it
        ON it.Id = inv.InvoiceTypeId
    LEFT JOIN payment.LineItemPromotion lip
        ON lip.LineItemId = li.Id
    LEFT JOIN payment.LineItem pli
        ON lip.DiscountLineItemId = pli.Id
    LEFT JOIN payment.LineItemAccountEntitlement liae
        ON liae.LineItemId = li.Id
    LEFT JOIN payment.LineItem aeli
        ON liae.DiscountLineItemId = aeli.Id
    LEFT JOIN payment.LineItemRetentionDiscount lird
        ON lird.LineItemId = li.Id
    LEFT JOIN payment.LineItem rdli
        ON lird.DiscountLineItemId = rdli.Id
    WHERE NOT EXISTS (
            SELECT
                1
            FROM payment.LineItemPromotion lip
            WHERE lip.DiscountLineItemId = li.Id
        )
        AND NOT EXISTS (
            SELECT
                1
            FROM payment.LineItemAccountEntitlement liae
            WHERE liae.DiscountLineItemId = li.Id
        )
        AND NOT EXISTS (
            SELECT
                1
            FROM payment.LineItemRetentionDiscount lird
            WHERE lird.DiscountLineItemId = li.Id
        )
        AND (@isCorporate = 1 OR lipf.Id IS NULL)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE a.Id = ati.AccountId
        )
        AND (@brandSlug IS NULL
            OR br.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND li.Quantity > 0

    -- Braintree Normal Refunds
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpMembershipTax, CorpFeeTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        br.Name,
        pk.Name,
        rpmt.TransactionDate,
        rpmt.DisbursementDate,
        ai.AccountId,
        CONCAT(per.FirstName, ' ', per.LastName) AccountHolder,
        CASE
            WHEN ret.EventType IS NOT NULL
                THEN ret.EventType
            WHEN li.ItemTypeId IN (2, 8) /* Fee, Item fee */
                THEN 'Fee'
            WHEN lis.TicketId IS NOT NULL
                THEN 'Ticket'
            WHEN lis.BundleId IS NOT NULL
                THEN 'Bundle'
            ELSE lis.ProductType
        END Category,
        COALESCE(lis.ProductName, liif.ItemFeeName, lipf.FeeName),
        rli.Amount * rli.Quantity,
        0,
        IIF((lis.ProductTypeId = 1 AND br.Id = 1) OR lipf.Id IS NOT NULL, 0, rli.Tax * rli.Quantity), /* Membership, Urban air */
        IIF((lis.ProductTypeId = 1 AND br.Id = 1) AND @isCorporate = 1, rli.Tax * rli.Quantity, 0), /* Membership, Urban air */
        IIF(lipf.Id IS NOT NULL AND @isCorporate = 1, rli.Tax * rli.Quantity, 0),
        IIF(lipf.Id IS NOT NULL, 0, (rli.Amount * rli.Quantity)),
        it.Name,
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        IIF(ai.StorefrontId = 1, 'CC2', 'POS'), /* Ecommerce */
        CONCAT('B-', rinv.ConfirmationCode),
        rinv.Id,
        rpmt.Id
    FROM acct.AccountInvoices ai
    JOIN payment.InvoiceRefund ir
        ON ai.InvoiceId = ir.InvoiceId
    JOIN payment.Invoice rinv
        ON rinv.Id = ir.RefundInvoiceId
    JOIN #braintreePayments rpmt
        ON rpmt.Id = ir.RefundPaymentId
    JOIN payment.PaymentProvider pprov
        ON rpmt.PaymentProviderId = pprov.Id
    JOIN payment.LineItem rli
        ON rli.InvoiceId = rpmt.InvoiceId
    JOIN payment.LineItem li
        ON rli.RefundsLineItemId = li.Id
    JOIN park.Park pk
        ON pk.Id = ai.ParkId
    JOIN dbo.Brands br
        ON br.Id = pk.BrandId
    JOIN acct.Account a
        ON a.Id = ai.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    LEFT JOIN #lineItemSubscriptionInfo lis -- [OPT] de-duped subquery
        ON lis.LineItemId = li.Id
    LEFT JOIN #lineItemEventTypes ret -- [OPT] de-duped subquery
        ON ret.LineItemId = li.Id
    LEFT JOIN payment.LineItemItemFee liif
        ON liif.ItemFeeLineItemId = li.Id
    LEFT JOIN payment.LineItemProductFee lipf
        ON lipf.LineItemId = li.Id
    JOIN payment.InvoiceType it
        ON it.Id = rinv.InvoiceTypeId
    WHERE (@isCorporate = 1 OR lipf.Id IS NULL)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE a.Id = ati.AccountId
        )
        AND (@brandSlug IS NULL
            OR br.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)

    -- Braintree Deposit Payments
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        pmt.TransactionDate,
        pmt.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking Deposit',
        COALESCE(bp.BundleName, pf.Description, 'Special Event'),
        IIF(pf.Id IS NOT NULL, li.Amount, pmt.Amount - COALESCE(fee.Amount, 0)),
        0,
        0,
        IIF(pf.Id IS NULL, 0, li.Tax),
        0,
        IIF(pf.Id IS NOT NULL, 0, pmt.Amount - COALESCE(fee.Amount, 0)),
        'Purchase',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        IIF(bk.CreatedBy = 'System', 'Online Booking', 'Admin Booking'),
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        pmt.Id
    FROM payment.Invoice inv
    JOIN #braintreePayments pmt
        ON pmt.InvoiceId = inv.Id
    JOIN payment.PaymentProvider pprov
        ON pmt.PaymentProviderId = pprov.Id
    JOIN payment.LineItem li
        ON li.InvoiceId = inv.Id
    LEFT JOIN prdct.ProductFee pf
        ON CONVERT(NVARCHAR(64), pf.Id) = li.ExternalId
    JOIN booking.Booking bk
        ON bk.InvoiceId = inv.Id
    LEFT JOIN booking.BookingParticipant bp
        ON bp.BookingId = bk.Id
            AND bp.ExternalId = li.ExternalId
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    LEFT JOIN booking.BookingSpecialEvent bse
        ON bse.BookingId = bk.Id
    LEFT JOIN (
        SELECT
            l.InvoiceId,
            l.Amount + l.Tax Amount
        FROM payment.LineItem l
        WHERE l.ItemTypeId = 2 /* Fee */
        GROUP BY l.InvoiceId, l.Amount, l.Tax
    ) fee ON fee.InvoiceId = inv.Id
    WHERE pmt.IsDeposit = 1
        AND pmt.Amount > 0
        AND (li.IsPaid = 1
            OR bp.ParticipantTypeId = 1 /* Base */
            OR (bk.IsSpecialEvent = 1
                AND li.ExternalId = ''
                AND li.Amount = bse.BasePrice))
        AND (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )
        AND (@isCorporate = 1 OR li.ItemTypeId <> 2) /* Fee */

    -- Braintree Booking Payments
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        pmt.TransactionDate,
        pmt.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking',
        COALESCE(bp.BundleName, pf.Description, tk.Name, pp.Name, IIF(bk.IsSpecialEvent = 1 AND li.ItemTypeId <> 2,
            'Special Event', NULL), r.Name), /* Fee */
        li.Amount - IIF(bp.ParticipantTypeId = 1 OR (bk.IsSpecialEvent = 1 AND li.Amount = bse.BasePrice AND li.ExternalId = ''),
            COALESCE(deposit.Amount, 0), 0), /* Base */
        IIF(bp.ParticipantTypeId = 1, COALESCE(disc.Amount, 0) + (inv.Discount * -1), 0), /* Base */
        IIF(pf.Id IS NULL, li.Tax + IIF(bp.ParticipantTypeId = 1, COALESCE(disc.Tax, 0), 0), 0),
        IIF(pf.Id IS NULL, 0, li.Tax),
        0,
        li.Amount - IIF(bp.ParticipantTypeId = 1 OR (bk.IsSpecialEvent = 1 AND li.Amount = bse.BasePrice AND li.ExternalId = ''),
            COALESCE(deposit.Amount, 0), 0) + IIF(bp.ParticipantTypeId = 1, COALESCE(disc.Amount, 0) + (inv.Discount * -1), 0), /* Base */
        'Purchase',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        'Admin Booking',
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        pmt.Id
    FROM payment.Invoice inv
    JOIN #braintreePayments pmt
        ON pmt.InvoiceId = inv.Id
    JOIN payment.PaymentProvider pprov
        ON pmt.PaymentProviderId = pprov.Id
    JOIN payment.LineItem li
        ON li.InvoiceId = inv.Id
    LEFT JOIN product.Ticket tk
        ON tk.ExternalId = li.ExternalId
    LEFT JOIN prdct.ProductChannelProduct pcp
        ON pcp.ExternalId = li.ExternalId
    LEFT JOIN prdct.ParkProduct pp
        ON pp.Id = pcp.ParkProductId
    LEFT JOIN prdct.ProductFee pf
        ON CONVERT(NVARCHAR(64), pf.Id) = li.ExternalId
    JOIN booking.Booking bk
        ON bk.InvoiceId = inv.Id
    LEFT JOIN booking.BookingSpecialEvent bse
        ON bse.BookingId = bk.Id
    LEFT JOIN booking.BookingParticipant bp
        ON bp.BookingId = bk.Id
            AND bp.ExternalId = li.ExternalId
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN booking.ScheduleDetails sd
        ON sd.Id = bk.ScheduleDetailId
    JOIN booking.Resource r
        ON r.Id = sd.ResourceId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    LEFT JOIN (
        SELECT
            i.Id InvoiceId,
            pmt.Amount - l.Amount - l.Tax Amount
        FROM payment.Invoice i
        JOIN payment.Payment pmt
            ON pmt.InvoiceId = i.Id
        JOIN payment.LineItem l
            ON l.InvoiceId = i.Id
        WHERE pmt.IsDeposit = 1
            AND l.IsPaid = 1
        GROUP BY i.Id, pmt.Amount, l.Amount, l.Tax
    ) deposit ON deposit.InvoiceId = inv.Id
    LEFT JOIN (
        SELECT
            li.InvoiceId,
            SUM(li.Amount) Amount,
            SUM(li.Tax) Tax
        FROM payment.LineItem li
        WHERE li.ItemTypeId IN (3, 9) /* Promotion, account entitlement */
        GROUP BY li.InvoiceId
    ) disc ON disc.InvoiceId = inv.Id
    WHERE pmt.IsDeposit = 0
        AND (pp.ParkId IS NULL OR pp.ParkId = pk.Id)
        AND li.IsPaid = 0 /* Fee is paid, not line item is paid */
        AND (@isCorporate = 1 OR pf.Id IS NULL)
        AND pmt.Amount > 0
        AND li.Amount > 0
        AND (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )

    -- Braintree tips
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpMembershipTax, CorpFeeTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        pmt.TransactionDate,
        pmt.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking',
        'Tip',
        inv.Tip,
        0,
        0,
        0,
        0,
        0,
        'Purchase',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        'Admin Booking',
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        pmt.Id
    FROM payment.Invoice inv
    JOIN #braintreePayments pmt
        ON pmt.InvoiceId = inv.Id
    JOIN payment.PaymentProvider pp
        ON pmt.PaymentProviderId = pp.Id
    JOIN booking.Booking bk
        ON bk.InvoiceId = inv.Id
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    JOIN payment.PaymentProvider pprov
        ON pmt.PaymentProviderId = pprov.Id
    WHERE pmt.IsDeposit = 0
        AND pmt.Amount > 0
        AND (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND inv.Tip > 0
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )

    -- Braintree deposit refunds
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        rp.TransactionDate,
        rp.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking Deposit',
        IIF(bk.IsSpecialEvent = 1 AND rli.ItemTypeId <> 2,
            'Special Event',
            COALESCE(bd.Name, pf.Description, tk.Name, pp.Name, r.Name)
        ), /* Fee */
        rli.Amount * rli.Quantity,
        0,
        IIF(li.ItemTypeId = 2, 0, rli.Tax * rli.Quantity), /* Fee */
        IIF(li.ItemTypeId = 2, rli.Tax * rli.Quantity, 0), /* Fee */
        0,
        IIF(li.ItemTypeId = 2, 0, rli.Amount * rli.Quantity), /* Fee */
        'Refund',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        IIF(bk.CreatedBy = 'System', 'Online Booking', 'Admin Booking'),
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        rp.Id
    FROM payment.InvoiceRefund ir
    JOIN payment.Invoice inv
        ON ir.RefundInvoiceId = inv.Id
    JOIN #braintreePayments rp
        ON ir.RefundPaymentId = rp.Id
    JOIN payment.LineItem rli
        ON rli.InvoiceId = inv.Id
    JOIN payment.LineItem li
        ON rli.RefundsLineItemId = li.Id
    JOIN payment.PaymentProvider pprov
        ON rp.PaymentProviderId = pprov.Id
    JOIN booking.Booking bk
        ON ir.InvoiceId = bk.InvoiceId
    JOIN payment.Payment op
        ON ir.PaymentId = op.Id
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    LEFT JOIN product.Bundle bd
        ON bd.ExternalId = li.ExternalId
    LEFT JOIN prdct.ProductFee pf
        ON CONVERT(NVARCHAR(64), pf.Id) = li.ExternalId
    LEFT JOIN product.Ticket tk
        ON tk.ExternalId = li.ExternalId
    LEFT JOIN prdct.ProductChannelProduct pcp
        ON pcp.ExternalId = li.ExternalId
    LEFT JOIN prdct.ParkProduct pp
        ON pp.Id = pcp.ParkProductId
    JOIN booking.ScheduleDetails sd
        ON sd.Id = bk.ScheduleDetailId
    JOIN booking.[Resource] r
        ON r.Id = sd.ResourceId
    WHERE op.IsDeposit = 1
        AND rli.IsPaid = 1 /* Fee is paid, not line item is paid */
        AND (@isCorporate = 1 OR rli.ItemTypeId <> 2)
        AND (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND (pp.Id IS NULL OR pp.ParkId = pk.Id)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )

    -- Braintree Booking refunds
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        rp.TransactionDate,
        rp.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking',
        COALESCE(bd.Name, pf.Description, tk.Name, pp.Name, IIF(bk.IsSpecialEvent = 1 AND rli.ItemTypeId <> 2,
            'Special Event', NULL), r.Name), /* Fee */
        li.Amount * li.Quantity,
        0,
        IIF(li.ItemTypeId = 2, 0, li.Tax * li.Quantity), /* Fee */
        IIF(li.ItemTypeId = 2, li.Tax * li.Quantity, 0), /* Fee */
        0,
        IIF(li.ItemTypeId = 2, 0, li.Amount * li.Quantity), /* Fee */
        'Refund',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        'Admin Booking',
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        rp.Id
    FROM payment.InvoiceRefund ir
    JOIN #braintreePayments rp
        ON ir.RefundPaymentId = rp.Id
    JOIN payment.Invoice inv
        ON inv.Id = ir.RefundInvoiceId
    JOIN payment.LineItem li
        ON li.InvoiceId = rp.InvoiceId
    LEFT JOIN product.Bundle bd
        ON bd.ExternalId = li.ExternalId
    LEFT JOIN product.Ticket tk
        ON tk.ExternalId = li.ExternalId
    LEFT JOIN prdct.ProductChannelProduct pcp
        ON pcp.ExternalId = li.ExternalId
    LEFT JOIN prdct.ParkProduct pp
        ON pp.Id = pcp.ParkProductId
    JOIN payment.PaymentProvider pprov
        ON rp.PaymentProviderId = pprov.Id
    JOIN booking.Booking bk
        ON ir.InvoiceId = bk.InvoiceId
    JOIN payment.Payment op
        ON ir.PaymentId = op.Id
    JOIN payment.LineItem rli
        ON li.RefundsLineItemId = rli.Id
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    JOIN booking.ScheduleDetails sd
        ON sd.Id = bk.ScheduleDetailId
    JOIN booking.Resource r
        ON r.Id = sd.ResourceId
    LEFT JOIN prdct.ProductFee pf
        ON CONVERT(NVARCHAR(64), pf.Id) = li.ExternalId
    WHERE op.IsDeposit = 0
        AND (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND (pp.Id IS NULL OR pp.ParkId = pk.Id)
        AND (@isCorporate = 1 OR li.ItemTypeId <> 2) /* Fee */
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )

    -- Braintree Tip Refunds
    INSERT INTO #results (Brand, Location, TransactionDate, DisbursementDate, AccountId, AccountHolder, Category, Product,
        ItemPrice, Discount, ZeeTax, CorpFeeTax, CorpMembershipTax, RoyaltyRevenue, TransactionType, Provider, Source, ConfirmationCode, InvoiceNumber, PaymentId)
    SELECT
        b.Name,
        pk.Name,
        rp.TransactionDate,
        rp.DisbursementDate,
        a.Id,
        CONCAT(per.FirstName, ' ', per.LastName),
        'Booking',
        'Tip',
        inv.Tip,
        0,
        0,
        0,
        0,
        0,
        'Refund',
        CASE
            WHEN pprov.Id = 3 /* Point of sale */
                THEN 'Appetize'
            WHEN pprov.Id IN (2, 4) /* Braintree, BraintreeHandheld */
                THEN 'Braintree'
            ELSE pprov.Name
        END,
        'Admin Booking',
        CONCAT('B-', inv.ConfirmationCode),
        inv.Id,
        rp.Id
    FROM payment.InvoiceRefund ir
    JOIN payment.Invoice inv
        ON ir.RefundInvoiceId = inv.Id
    JOIN #braintreePayments rp
        ON ir.RefundPaymentId = rp.Id
    JOIN payment.PaymentProvider pprov
        ON rp.PaymentProviderId = pprov.Id
    JOIN booking.Booking bk
        ON ir.InvoiceId = bk.InvoiceId
    JOIN payment.Payment op
        ON ir.PaymentId = op.Id
    JOIN park.Park pk
        ON pk.Id = bk.ParkId
    JOIN dbo.Brands b
        ON pk.BrandId = b.Id
    JOIN acct.Account a
        ON a.Id = bk.AccountId
    JOIN acct.Person per
        ON per.Id = a.PersonId
    WHERE (@brandSlug IS NULL
            OR b.UrlSlug = @brandSlug)
        AND (@locationSlug IS NULL
            OR pk.UrlSlug = @locationSlug)
        AND NOT EXISTS (
            SELECT 1
            FROM maintenance.AccountsToIgnore ati
            WHERE bk.AccountId = ati.AccountId
        )
        AND inv.Tip <> 0

    IF (@isAggregate = 0)
    BEGIN
        SELECT
            r.Brand,
            r.Location,
            CONVERT(VARCHAR(10), CAST(r.TransactionDate AS DATE), 120) TransactionDate, -- [OPT] was FORMAT()
            CONVERT(VARCHAR(10), CAST(r.DisbursementDate AS DATE), 120) DisbursementDate,
            r.AccountId,
            r.AccountHolder,
            r.Category,
            r.Product,
            ROUND(r.ItemPrice, 2) ItemPrice,
            ROUND(r.Discount, 2) Discount,
            ROUND(r.ZeeTax, 2) ZeeTax,
            ROUND(r.CorpFeeTax, 2) CorpFeeTax,
            ROUND(r.CorpMembershipTax, 2) CorpMembershipTax,
            ROUND(r.TotalPrice, 2) TotalPrice,
            ROUND(r.RoyaltyRevenue, 2) RoyaltyRevenue,
            r.TransactionType,
            r.Provider,
            r.Source,
            r.ConfirmationCode,
            r.InvoiceNumber,
            r.PaymentId
        FROM #results r
        UNION ALL
        SELECT
            afd.Brand,
            afd.Location,
            CONVERT(VARCHAR(10), CAST(afd.TransactionDate AS DATE), 120) TransactionDate, -- [OPT] was FORMAT()
            CONVERT(VARCHAR(10), CAST(afd.DisbursementDate AS DATE), 120) DisbursementDate,
            afd.AccountId,
            afd.AccountHolder,
            afd.Category,
            afd.Product,
            ROUND(afd.ItemPrice, 2) ItemPrice,
            ROUND(afd.Discount, 2) Discount,
            ROUND(afd.ZeeTax, 2) ZeeTax,
            ROUND(afd.CorpFeeTax, 2) CorpFeeTax,
            ROUND(afd.CorpMembershipTax, 2) CorpMembershipTax,
            ROUND(afd.TotalPrice, 2) TotalPrice,
            ROUND(afd.RoyaltyRevenue, 2) RoyaltyRevenue,
            afd.TransactionType,
            afd.Provider,
            afd.Source,
            afd.ConfirmationCode,
            afd.InvoiceNumber,
            afd.PaymentId
		FROM #applicationFeeDetail afd
        ORDER BY
            TransactionDate,
            InvoiceNumber,
            PaymentId
    END
    ELSE
    BEGIN
        SELECT
            r.Brand,
            r.Location,
            CONVERT(VARCHAR(10), CAST(r.TransactionDate AS DATE), 120) TransactionDate, -- [OPT] was FORMAT()
            CONVERT(VARCHAR(10), CAST(r.DisbursementDate AS DATE), 120) DisbursementDate,
            r.AccountId,
            r.AccountHolder,
            ROUND(SUM(r.ItemPrice), 2) ItemPrice,
            ROUND(SUM(r.Discount), 2) Discount,
            ROUND(SUM(r.ZeeTax), 2) ZeeTax,
            ROUND(SUM(r.CorpFeeTax), 2) CorpFeeTax,
            ROUND(SUM(r.CorpMembershipTax), 2) CorpMembershipTax,
            ROUND(SUM(r.TotalPrice), 2) TotalPrice,
            ROUND(SUM(r.RoyaltyRevenue), 2) RoyaltyRevenue,
            ROUND(r.ProcessingFee, 2) ProcessingFee,
            r.TransactionType,
            r.Provider,
            r.Source,
            r.ConfirmationCode,
            r.InvoiceNumber,
            r.PaymentId
        FROM #results r
        GROUP BY
            r.Brand,
            r.Location,
            r.TransactionDate,
            r.DisbursementDate,
            r.AccountId,
            r.AccountHolder,
            r.TransactionType,
            r.Provider,
            r.Source,
            r.ConfirmationCode,
            r.InvoiceNumber,
            r.PaymentId,
            r.ProcessingFee
        ORDER BY
            r.TransactionDate,
            r.InvoiceNumber,
            r.PaymentId
    END
END
GO
