/****************************************************************************************************************
  SUPPORTING INDEXES — run this block once (outside the procedure), before or after deploying the proc below.

  Why these exist:
  The procedure filters and joins on the columns below every time it runs. Without indexes on them,
  SQL Server has to scan the full tables to find matching rows. These indexes let it jump straight
  to the relevant rows instead. Safe to re-run — each one checks if it already exists first.
****************************************************************************************************************/

-- The proc's first query filters acct.Person by RowStart (this month's date range).
-- This index lets SQL Server find "people created/changed this month" without scanning the whole table.
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

-- The proc joins acct.AccountPerson to Person on PersonId, and only keeps AccountRoleId = 2 (primary contacts).
-- This index covers both of those at once instead of forcing a table scan to check the role.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_AccountPerson_PersonId_AccountRoleId' AND object_id = OBJECT_ID('acct.AccountPerson')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountPerson_PersonId_AccountRoleId
        ON acct.AccountPerson (PersonId, AccountRoleId)
        INCLUDE (AccountId, Country, StreetAddress, City, State, ZipCode);
END
GO

-- The final step in the proc looks up each person's address by AddressId. This index makes that lookup fast.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Address_Id' AND object_id = OBJECT_ID('addr.Address')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Address_Id
        ON addr.Address (Id);
END
GO

/****************************************************************************************************************
  PROCEDURE: sf.GetPrimaryContactsForFabric

  In plain terms: this pulls a list of "primary contacts" (one designated contact per account) who became
  effective sometime in the current calendar month, cleans up a few messy fields (names, emails, bad birth
  years), attaches their address, and returns the whole thing as one result set for Fabric to pick up.
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
2026-07-15				Optimization pass	Removed dead/commented code; added supporting indexes
										(see companion script); added explanatory comments throughout.
										No logic changes. [dbo].[isValidEmailFormat] call left untouched
										pending review of its internal definition.
****************************************************************************************************************/


    SET NOCOUNT ON;
	-- Grab "right now" as our reference point for the month calculation below.

	DECLARE @TodayDateTime DATETIME;
	SET @TodayDateTime = GETDATE();

	-- The server's GETDATE() isn't necessarily CST, so we look up the CST offset and shift to it.
	-- This matters because "current month" should mean current month in CST, not UTC or server-local time.
	DECLARE @CSTHourDiff INT 
	SELECT @CSTHourDiff =  LEFT(current_utc_offset,3)  
	FROM sys.time_zone_info 
	WHERE Name = 'Central Standard Time'

	DECLARE @CSTTime DATETIME
	SELECT @CSTTime= DATEADD ( HOUR, @CSTHourDiff,@TodayDateTime)

	-- Work out the first day of this month and the first day of next month.
	-- Together these define the "this month" window used to filter people below.
	DECLARE @FirstOfCurrentMonth DATETIME, @FirstOfNextMonth DATETIME 

	SELECT @FirstOfCurrentMonth = DATETRUNC(MONTH, @CSTTime)

	SELECT @FirstOfNextMonth  = DATEADD(d, 1, EOMONTH(@CSTTime))

	BEGIN

	-- STEP 1: Find every person who is a primary contact (AccountRoleId = 2) on some account,
	-- and whose Person record became effective (RowStart) sometime this month.
	-- Stashed in a temp table so we don't repeat this join/filter work in the final SELECT below.
	DROP TABLE IF EXISTS #NewPrimaryContactsCreatedDuringMonth
	SELECT b.AccountId , b.PersonId , a.RowStart , a.RowEnd, a.FirstName,a.LastName ,a.DateOfBirth , a.AddressId
	,a.EmailAddress , a.PhoneNumber
	INTO #NewPrimaryContactsCreatedDuringMonth
	FROM acct.Person a 
		INNER JOIN acct.AccountPerson b 
			ON b.PersonId = a.Id
	WHERE (a.[RowStart] >= @FirstOfCurrentMonth  AND a.[RowStart] < @FirstOfNextMonth)
		AND b.AccountRoleId = 2

	-- STEP 2: Take that list and shape it into the final output —
	-- cleaning up names, validating emails, guarding against bad birthdates, and attaching an address.
	 SELECT AccountId = a.AccountId, 
					PersonId = a.PersonId,

					-- Strip stray slashes/backslashes from names; if a name is missing entirely, show "Customer".
					FirstName = CASE  WHEN a.FirstName LIKE '%/%' THEN
								REPLACE(a.FirstName, '/', '')
								WHEN a.FirstName LIKE '%\%' THEN
								REPLACE(a.FirstName, '\', '')
								WHEN a.FirstName IS NULL THEN 'Customer'
									WHEN a.FirstName = '' THEN 'Customer'
									WHEN LEN(a.FirstName) = 0 THEN 'Customer'
									ELSE a.FirstName END ,
					
					-- Same cleanup rule as FirstName.
					LastName = CASE   WHEN a.LastName LIKE '%/%' THEN
                          REPLACE(a.LastName, '/', '')
                      WHEN a.LastName LIKE '%\%' THEN
                          REPLACE(a.LastName, '\', '')
					WHEN a.LastName IS NULL THEN 'Customer'
									WHEN a.LastName = '' THEN 'Customer'
									WHEN LEN(a.LastName) = 0 THEN 'Customer'
									ELSE a.LastName END,

					-- Only pass the email through if it looks like a real email address; otherwise send blank.
					EmailAddress = CASE WHEN [dbo].[isValidEmailFormat](EmailAddress) = 1 THEN EmailAddress ELSE '' END,
					PhoneNumber = a.PhoneNumber,

					-- Guard against corrupt/placeholder birthdates (e.g. year 0001) by flattening them to 1/1/1900.
					DateOfBirth = CASE WHEN  YEAR(a.DateOfBirth)< 1900 THEN '1/1/1900' ELSE a.DateOfBirth END ,

					-- Address fields, pulled in from addr.Address (may be NULL if no address is on file).
					Country = b.Country,
					StreetAddress = b.StreetAddress,
					City = b.City,
					State = b.State,
					ZipCode = b.ZipCode,

					-- Every row here is, by definition, a primary contact — so this is always 'True'.
					[PrimaryContact] = 'True',

					PersonRowStartDate = a.RowStart,
					[PersonRowEndDate] = a.RowEnd,

					-- Stamp every row with the same "when this batch was generated" timestamp, in CST.
					[DataloadCreateDate_CST] = @CSTTime
			 
			 FROM #NewPrimaryContactsCreatedDuringMonth a
				-- LEFT JOIN so we still return the person even if they have no address on file.
				LEFT JOIN addr.Address b
					ON b.Id = a.AddressId

  END 

GO
