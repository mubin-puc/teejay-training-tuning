/****************************************************************************************************************
  INDEXES -- run once, before or after the procedure below. Safe to re-run.
****************************************************************************************************************/

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_ChildContactPerson_PersonRowStartDate' AND object_id = OBJECT_ID('sf.ChildContactPerson')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_ChildContactPerson_PersonRowStartDate
        ON sf.ChildContactPerson (PersonRowStartDate DESC);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Person_RowStart_RowEnd' AND object_id = OBJECT_ID('acct.Person')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Person_RowStart_RowEnd
        ON acct.Person (RowStart, RowEnd)
        INCLUDE (FirstName, LastName, DateOfBirth);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_AccountPerson_PersonId_AccountRoleId_UCC' AND object_id = OBJECT_ID('acct.AccountPerson')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountPerson_PersonId_AccountRoleId_UCC
        ON acct.AccountPerson (PersonId, AccountRoleId)
        INCLUDE (AccountId);
END
GO


/****** Object:  StoredProcedure [sf].[UpsertChildContacts]    Script Date: 7/21/2026 5:16:05 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [sf].[UpsertChildContacts]
/********************************************************************************************************************

Creator: Neha Ganatra

Create Date: 13 March 2025

Description: This procedure inserts data in Table 

Sample:  Execute sf.UpsertChildContacts

Change History
Modified Date			Modified By			Description
2026-07-22				Optimization pass	Combined two reads of acct.Person into one; added indexes.
										No logic changes. NOLOCK left as-is, flagged for review.
****************************************************************************************************************/
AS
BEGIN TRY

    SET NOCOUNT ON;
	DECLARE @TodayDateTime DATETIME;
    SET @TodayDateTime = GETDATE();

	-- NOLOCK left as-is -- flagged for team review, not removed
	DECLARE @DeltaDate  [DATETIMEOFFSET] (7)
	SELECT @DeltaDate = MAX(PersonRowStartDate) 
	FROM [sf].[ChildContactPerson] WITH (NOLOCK)


	IF @DeltaDate IS NULL 
	BEGIN
		SET @DeltaDate = '1/1/2018'
	END 

	-- Now also grabbing name/birthdate/RowEnd here, so we don't need to re-read acct.Person later
	DROP TABLE IF EXISTS #DeltaChildContacts
	SELECT
		b.PersonId,
		a.RowStart,
		a.RowEnd,
		a.FirstName,
		a.LastName,
		a.DateOfBirth,
		b.AccountId
	INTO #DeltaChildContacts
	FROM acct.Person a
		INNER JOIN acct.AccountPerson b
			ON b.PersonId = a.Id
	WHERE b.AccountRoleId <> 2 
	AND a.RowStart > @DeltaDate
	AND a.RowEnd >=  '12/31/9999'

	DECLARE @RowInserted INT = 0
	SELECT @RowInserted = COUNT (1) FROM #DeltaChildContacts
--Insert into Primary Contact Information of New Account ------------------------
	
	IF @RowInserted = 0 
	BEGIN
		INSERT INTO[sf].[LogsChildContactPerson] ([CreatedOn],[CommandType],[RecordCount],[ErrorMessage])
		SELECT [CreatedOn] = @TodayDateTime,
			   [CommandType] = 'Record(s) Inserted',
			   [RecordCount] = @RowInserted,
			   [ErrorMessage]= 'No Error'
	END 

	 
	IF @RowInserted > 0 
	BEGIN
			INSERT INTO [sf].[ChildContactPerson]
			(AccountId, PersonId,FirstName, LastName,DateOfBirth,PersonRowStartDate,
				PersonRowEndDate,DataloadCreateDate
			)

			-- Reading from the temp table now instead of joining back to acct.Person again
			SELECT AccountId = a.AccountId, 
			PersonId = a.PersonId,
			FirstName = CASE WHEN a.FirstName IS NULL THEN 'Customer'
							WHEN a.FirstName = '' THEN 'Customer'
							WHEN LEN(a.FirstName) = 0 THEN 'Customer'
							ELSE a.FirstName END ,
		 LastName = CASE WHEN a.LastName IS NULL THEN 'Customer'
							WHEN a.LastName = '' THEN 'Customer'
							WHEN LEN(a.LastName) = 0 THEN 'Customer'
							ELSE a.LastName END,
			 DateOfBirth = CASE WHEN  YEAR(a.DateOfBirth)< 1900 THEN '1/1/1900' ELSE a.DateOfBirth END 	,
			PersonRowStartDate = a.RowStart,
			[PersonRowEndDate] = a.RowEnd,
			[DataloadCreateDate] = @TodayDateTime
			FROM  #DeltaChildContacts a
	
				 
		INSERT INTO [sf].[LogsChildContactPerson]  ([CreatedOn],[CommandType],[RecordCount],[ErrorMessage])
		SELECT [CreatedOn] = @TodayDateTime,
			   [CommandType] = 'Record(s) Inserted',
			   [RecordCount] = @RowInserted,
			   [ErrorMessage]= 'No Error'
	   END 

END TRY

BEGIN CATCH
    DECLARE @ErrorMessage NVARCHAR(4000),
            @ErrorSeverity INT,
            @ErrorState INT,
            @ErrorNumber INT,
            @ErrorLine INT;
    SELECT @ErrorMessage = ERROR_MESSAGE(),
           @ErrorSeverity = ERROR_SEVERITY(),
           @ErrorState = ERROR_STATE(),
           @ErrorNumber = ERROR_NUMBER(),
           @ErrorLine = ERROR_LINE();
    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorNumber, @ErrorState, @ErrorLine);
   

    INSERT INTO[sf].[LogsChildContactPerson]  ([CreatedOn],[CommandType],[RecordCount],[ErrorMessage])
    VALUES(@TodayDateTime,NULL, 0, @ErrorMessage);

END CATCH;

GO
