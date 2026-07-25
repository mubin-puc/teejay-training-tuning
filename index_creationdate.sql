DECLARE @path NVARCHAR(260);

SELECT @path = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX('\', REVERSE(path)), 260)) + N'log.trc'
FROM sys.traces
WHERE is_default = 1;

SELECT
    t.StartTime AS CreatedOn,
    t.DatabaseName,
    t.ObjectName AS IndexName,
    t.LoginName,
    t.ApplicationName
FROM ::fn_trace_gettable(@path, DEFAULT) t
JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
WHERE te.name = 'Object:Created'
  AND t.ObjectName IN (
        'IX_AccountsToIgnore_AccountId',
        'IX_Brands_UrlSlug',
        'IX_Park_UrlSlug',
        'IX_Payment_CreatedDate_Status',
        'IX_PmtPayment_CreatedDate_Status',
        'IX_reservationEventTypes',
        'IX_justiFiPayments_PaymentId',
        'IX_justiFiPayments_InvoiceHeaderId',
        'IX_applicationFeeSum_PaymentId',
        'IX_pprXRef_PaymentId',
        'IX_braintreePayments_Id',
        'IX_braintreePayments_InvoiceId',
        'IX_lineItemSubscriptionInfo_LineItemId',
        'IX_lineItemEventTypes_LineItemId',
        'IX_excludedAccounts_AccountId',
        'IX_results_Aggregate'
  )
ORDER BY t.StartTime DESC;
