/****************************************************************************************************************
  SUPPORTING INDEXES -- run this block once, before or after deploying the procedure below. Safe to re-run,
  each one checks if it already exists first.
****************************************************************************************************************/

-- Speeds up finding "people created this month" (the main filter in the SP)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Person_RowStart' AND object_id = OBJECT_ID('acct.Person')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Person_RowStart
        ON acct.Person (RowStart)
        INCLUDE (Id, FirstName, LastName, DateOfBirth, AddressId, EmailAddress, PhoneNumber, RowEnd);
END
GO

-- Speeds up the join + "primary contact only" filter
-- (AccountId is the only extra column this table actually has -- nothing address-related belongs here)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_AccountPerson_PersonId_AccountRoleId' AND object_id = OBJECT_ID('acct.AccountPerson')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountPerson_PersonId_AccountRoleId
        ON acct.AccountPerson (PersonId, AccountRoleId)
        INCLUDE (AccountId);
END
GO

-- Note: addr.Address is untouched -- it already has a clustered primary key on Id,
-- so it's already as fast as it can be for this lookup. No new index needed there.


/****************************************************************************************************************
  PROCEDURE: sf.GetPrimaryContactsForFabric

  Pulls everyone who became a primary contact this month, cleans up their name/email/birthdate,
  attaches their address, and hands it off to Fabric.
****************************************************************************************************************/

/****** Object:  StoredProcedure [sf].[GetPrimaryContactsForFabric]    Script Date: 7/14/2026 11:28:01 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [sf].[GetPrimaryContactsForFabric]
AS
/********************************************************************************************************************

Creator: Neha Ganatra

Create Date: 13 March 2025

Description: This procedure inserts data in Table 

Sample:  Execute [sf].[GetPrimaryContactsForFabric]

Change History
Modified Date			Modified By			Description
2026-07-15				Optimization pass	Cleaned up dead code, added indexes (see script above),
										no logic changes. Email check left as-is (not reviewed).
****************************************************************************************************************/


    SET NOCOUNT ON;
	-- "Right now" -- used below to work out the current month
	DECLARE @TodayDateTime DATETIME;
	SET @TodayDateTime = GETDATE();

	-- Server time isn't necessarily CST, so shift to it -- "this month" should mean CST, not UTC
	DECLARE @CSTHourDiff INT 
	SELECT @CSTHourDiff =  LEFT(current_utc_offset,3)  
	FROM sys.time_zone_info 
	WHERE Name = 'Central Standard Time'

	DECLARE @CSTTime DATETIME
	SELECT @CSTTime= DATEADD ( HOUR, @CSTHourDiff,@TodayDateTime)

	-- First day of this month, and first day of next month -- defines our "this month" window
	DECLARE @FirstOfCurrentMonth DATETIME, @FirstOfNextMonth DATETIME 

	SELECT @FirstOfCurrentMonth = DATETRUNC(MONTH, @CSTTime)

	SELECT @FirstOfNextMonth  = DATEADD(d, 1, EOMONTH(@CSTTime))

	BEGIN

	-- STEP 1: Everyone who's a primary contact (role = 2) and whose record started this month.
	-- Saved into a temp table so we don't redo this join in the final SELECT below.
	DROP TABLE IF EXISTS #NewPrimaryContactsCreatedDuringMonth
	SELECT b.AccountId , b.PersonId , a.RowStart , a.RowEnd, a.FirstName,a.LastName ,a.DateOfBirth , a.AddressId
	,a.EmailAddress , a.PhoneNumber
	INTO #NewPrimaryContactsCreatedDuringMonth
	FROM acct.Person a 
		INNER JOIN acct.AccountPerson b 
			ON b.PersonId = a.Id
	WHERE (a.[RowStart] >= @FirstOfCurrentMonth  AND a.[RowStart] < @FirstOfNextMonth)
		AND b.AccountRoleId = 2

	-- STEP 2: Clean up that list -- fix names, check emails, fix bad birthdates, attach address.
	 SELECT AccountId = a.AccountId, 
					PersonId = a.PersonId,

					-- Remove stray / or \ from the name; if it's missing, just show "Customer"
					FirstName = CASE  WHEN a.FirstName LIKE '%/%' THEN
								REPLACE(a.FirstName, '/', '')
								WHEN a.FirstName LIKE '%\%' THEN
								REPLACE(a.FirstName, '\', '')
								WHEN a.FirstName IS NULL THEN 'Customer'
									WHEN a.FirstName = '' THEN 'Customer'
									WHEN LEN(a.FirstName) = 0 THEN 'Customer'
									ELSE a.FirstName END ,
					
					-- Same cleanup as FirstName
					LastName = CASE   WHEN a.LastName LIKE '%/%' THEN
                          REPLACE(a.LastName, '/', '')
                      WHEN a.LastName LIKE '%\%' THEN
                          REPLACE(a.LastName, '\', '')
					WHEN a.LastName IS NULL THEN 'Customer'
									WHEN a.LastName = '' THEN 'Customer'
									WHEN LEN(a.LastName) = 0 THEN 'Customer'
									ELSE a.LastName END,

					-- Only keep the email if it looks like a real one, otherwise leave it blank
					EmailAddress = CASE WHEN [dbo].[isValidEmailFormat](EmailAddress) = 1 THEN EmailAddress ELSE '' END,
					PhoneNumber = a.PhoneNumber,

					-- Bad/placeholder birth years get flattened to 1/1/1900
					DateOfBirth = CASE WHEN  YEAR(a.DateOfBirth)< 1900 THEN '1/1/1900' ELSE a.DateOfBirth END ,

					-- Address info -- may be blank if the person has no address on file
					Country = b.Country,
					StreetAddress = b.StreetAddress,
					City = b.City,
					State = b.State,
					ZipCode = b.ZipCode,

					-- Always "True" -- everyone here is a primary contact by definition
					[PrimaryContact] = 'True',

					PersonRowStartDate = a.RowStart,
					[PersonRowEndDate] = a.RowEnd,

					-- Timestamp for when this batch was generated
					[DataloadCreateDate_CST] = @CSTTime
			 
			 FROM #NewPrimaryContactsCreatedDuringMonth a
				-- LEFT JOIN so people with no address on file still show up
				LEFT JOIN addr.Address b
					ON b.Id = a.AddressId

  END 

GO
